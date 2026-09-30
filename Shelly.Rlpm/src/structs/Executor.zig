//! Ordered package executor. Plan/manifest views remain transaction-owned when
//! local cache generations change. Reports describe partial progress, not rollback.
const std = @import("std");
const builtin = @import("builtin");
const Tx = @import("Transaction.zig");
const Plan = @import("TransactionPlan.zig");
const Manifest = @import("ExecutionManifest.zig");
const Package = @import("Package.zig");
const Root = @import("RootPath.zig");
const Ops = @import("RootOperations.zig");
pub const PayloadDurability = @import("PayloadDurability.zig");
const Writer = @import("LocalWriter.zig");
const Reader = @import("ArchiveReader.zig");
const Audit = @import("Audit.zig");
const DatabaseSnapshot = @import("DatabaseSnapshot.zig");
const Diagnostic = @import("Diagnostic.zig");
const Callbacks = @import("Callbacks.zig");
const PathPatterns = @import("PathPatterns.zig");
const BackupFile = @import("BackupFile.zig");
const Preflight = @import("Preflight.zig");

const ac = Reader.c;
const c = Ops.c;

pub const Boundary = enum {
    pre_hooks,
    pre_scriptlet,
    remove,
    extract,
    payload_sync,
    database_write,
    database_publish,
    post_scriptlet,
    cache_reload,
    post_hooks,
    complete,
};

pub const Report = struct {
    completed: std.ArrayList(Plan.Id) = .empty,
    remaining: []const Plan.Id = &.{},
    current: ?Plan.Id = null,
    boundary: Boundary = .pre_hooks,
    path: ?[]const u8 = null,
    mutations: usize = 0,
    database_published: bool = false,
    cause: ?anyerror = null,
    detail: ?[]const u8 = null,
    system_error: ?c_int = null,
    cleanup_failures: usize = 0,
    cleanup_cause: ?anyerror = null,
    payload_work_ms: i64 = 0,
    payload_sync_ms: i64 = 0,
    payload_sync_targets: usize = 0,
    database_publish_ms: i64 = 0,
};
/// Compiled out of production. Deterministic I/O-boundary fault injection.
pub var test_fault: if (builtin.is_test) ?Boundary else void = if (builtin.is_test) null else {};
/// Baseline comparison for the disposable benchmark only; no runtime setting.
pub var test_immediate_payload_sync: if (builtin.is_test) bool else void = if (builtin.is_test) false else {};

fn checkpoint(tx: *Tx, boundary: Boundary, path: ?[]const u8) !void {
    tx.execution.boundary = boundary;
    tx.execution.path = if (path) |value| try tx.storage.allocator().dupe(u8, value) else null;
    if (comptime builtin.is_test)
        if (test_fault == boundary) return error.InjectedExecutionFailure;
    try tx.owner.checkCancelled();
    try tx.lock.?.validate();
    try tx.manifest().?.revalidateRoots(tx.owner.configuration.root, tx.owner.configuration.database_path);
}

pub fn run(tx: *Tx) !void {
    errdefer |err| {
        tx.execution.cause = err;
        if (tx.owned_actions) |*actions| {
            if (actions.started)
                Audit.log(
                    tx,
                    "transaction {s}",
                    .{
                        if (err == error.Cancelled)
                            "interrupted"
                        else
                            "failed",
                    },
                );
            actions.fail();
        }
        // Disk is authoritative even when mutation failed halfway through.
        reload(tx) catch {};
    }
    const plan = tx.plan().?;
    const a = tx.storage.allocator();
    const remaining = try a.alloc(Plan.Id, plan.removals.len + plan.additions.len);
    @memcpy(remaining[0..plan.removals.len], plan.removals);
    for (plan.additions, remaining[plan.removals.len..]) |add, *id|
        id.* = add.package;
    tx.execution.remaining = remaining;
    try checkpoint(tx, .pre_hooks, null);
    const actions = try tx.startActions();
    var observed_database = tx.snapshot;
    try checkDatabase(tx, observed_database);
    // Reserve progress storage before the first mutation.
    try tx.execution.completed.ensureTotalCapacity(a, plan.removals.len + plan.additions.len);
    for (plan.removals) |id| {
        tx.execution.current = id;
        tx.execution.database_published = false;
        try packageEvent(tx, id, null, .start);
        try checkpoint(tx, .pre_scriptlet, null);
        try actions.beforePackage(id);
        try checkDatabase(tx, observed_database);
        var payload = Payload.init(tx, id, null);
        defer payload.deinit();
        try removePayload(tx, id, &payload);
        try payload.flush();
        progress(tx, id, 100);
        Audit.log(
            tx,
            "removed {s} ({s})",
            .{
                plan.package(id).name,
                plan.package(id).version.raw,
            },
        );
        try checkpoint(tx, .post_scriptlet, null);
        try actions.afterPackage(id);
        try checkDatabase(tx, observed_database);
        try packageEvent(tx, id, null, .done);
        try checkpoint(tx, .database_write, null);
        var record = try Writer.Record.init(&tx.owned_manifest.?.database, tx.io, a);
        defer record.deinit() catch |err| cleanupFailure(tx, err);
        const old = try Writer.recordName(a, plan.package(id));
        try checkpoint(tx, .database_publish, old);
        const publication_start = std.Io.Clock.awake.now(tx.io);
        try record.publish(old, null);
        tx.execution.database_publish_ms += publication_start.untilNow(tx.io, .awake).toMilliseconds();
        tx.execution.database_published = true;
        observed_database = try DatabaseSnapshot.capture(tx.owner, tx.io);
        tx.execution.mutations += 1;
        try checkpoint(tx, .cache_reload, null);
        try reload(tx);
        tx.execution.completed.appendAssumeCapacity(id);
        tx.execution.remaining = tx.execution.remaining[1..];
    }
    for (plan.additions) |addition| {
        const id = addition.package;
        tx.execution.current = id;
        tx.execution.database_published = false;
        try packageEvent(tx, id, addition, .start);
        try checkpoint(tx, .pre_scriptlet, null);
        try actions.beforePackage(id);
        try checkDatabase(tx, observed_database);
        var payload = Payload.init(tx, id, addition.old);
        defer payload.deinit();
        if (addition.old) |old| try removePayload(tx, old, &payload);
        try checkpoint(tx, .database_write, null);
        var record = try Writer.Record.init(&tx.owned_manifest.?.database, tx.io, a);
        defer record.deinit() catch |err| cleanupFailure(tx, err);
        var package = try install(tx, addition, &record, &payload);
        try payload.flush();
        try checkpoint(tx, .database_write, null);
        try record.metadata(&package);
        const name = try Writer.recordName(a, &package);
        const old = if (addition.old) |old_id| try Writer.recordName(a, plan.package(old_id)) else null;
        try checkpoint(tx, .database_publish, name);
        const publication_start = std.Io.Clock.awake.now(tx.io);
        try record.publish(old, name);
        tx.execution.database_publish_ms += publication_start.untilNow(tx.io, .awake).toMilliseconds();
        tx.execution.database_published = true;
        observed_database = try DatabaseSnapshot.capture(tx.owner, tx.io);
        tx.execution.mutations += 1;
        try checkpoint(tx, .cache_reload, null);
        try reload(tx);
        progress(tx, id, 100);
        switch (addition.action) {
            .install, .reinstall => Audit.log(
                tx,
                "{s} {s} ({s})",
                .{
                    if (addition.action == .install)
                        "installed"
                    else
                        "reinstalled",
                    package.name,
                    package.version.raw,
                },
            ),
            .upgrade, .downgrade => Audit.log(
                tx,
                "{s} {s} ({s} -> {s})",
                .{
                    if (addition.action == .upgrade)
                        "upgraded"
                    else
                        "downgraded",
                    package.name,
                    plan.package(addition.old.?).version.raw,
                    package.version.raw,
                },
            ),
        }
        try checkpoint(tx, .post_scriptlet, null);
        try actions.afterPackage(id);
        try checkDatabase(tx, observed_database);
        try packageEvent(tx, id, addition, .done);
        tx.execution.completed.appendAssumeCapacity(id);
        tx.execution.remaining = tx.execution.remaining[1..];
    }
    tx.execution.current = null;
    try checkpoint(tx, .post_hooks, null);
    try actions.finish();
    tx.execution.boundary = .complete;
    tx.execution.path = null;
}

fn cleanupFailure(tx: *Tx, err: anyerror) void {
    tx.execution.cleanup_failures += 1;
    tx.execution.cleanup_cause = err;
    tx.owner.transactionEvent(
        .{ .diagnostic = Diagnostic.init(.transaction, err, null) },
    );
}

fn checkDatabase(tx: *Tx, expected: [32]u8) !void {
    const actual = try DatabaseSnapshot.capture(tx.owner, tx.io);
    if (!std.mem.eql(u8, &expected, &actual)) return error.StaleDatabaseState;
}

fn reload(tx: *Tx) !void {
    const local = &tx.owner.local.?;
    try local.invalidateCache();
    try local.reloadDatabase(tx.io, tx.owner.configuration.gpg_directory);
}

fn packageEvent(
    tx: *Tx,
    id: Plan.Id,
    add: ?Plan.Addition,
    boundary: Callbacks.Boundary,
) !void {
    const plan = tx.plan().?;
    const reference = plan.candidates[@intFromEnum(id)].reference;
    const old_id = if (add) |item| item.old else id;
    const views = try tx.storage.allocator().alloc(
        Callbacks.PackageView,
        if (add != null and old_id != null) 2 else 1,
    );
    views[0] = .{ .reference = reference, .package = plan.package(id) };
    if (views.len == 2)
        views[1] = .{
            .reference = plan.candidates[@intFromEnum(old_id.?)].reference,
            .package = plan.package(old_id.?),
        };
    tx.owner.transactionEvent(.{ .package_operation = .{
        .operation = if (add) |item| switch (item.action) {
            .install => .install,
            .upgrade => .upgrade,
            .reinstall => .reinstall,
            .downgrade => .downgrade,
        } else .remove,
        .boundary = boundary,
        .old = if (old_id) |old| plan.candidates[@intFromEnum(old)].reference else null,
        .new = if (add != null) reference else null,
        .views = views,
    } });
}

fn progress(tx: *Tx, id: Plan.Id, percent: u8) void {
    const cb = tx.owner.configuration.callbacks;
    if (cb.progress) |callback| {
        tx.owner.in_callback = true;
        defer tx.owner.in_callback = false;
        callback(
            cb.progress_context,
            .{
                .phase = .transaction,
                .package = tx.plan().?.candidates[@intFromEnum(id)].reference,
                .percent = percent,
                .position = tx.execution.completed.items.len + 1,
                .total = tx.plan().?.removals.len + tx.plan().?.additions.len,
            },
        );
    }
}

/// One operation owns both removal and extraction progress and writeback.
const Payload = struct {
    tx: *Tx,
    id: Plan.Id,
    tracker: PayloadDurability,
    total: usize = 0,
    completed: usize = 0,
    percent: u8 = 0,
    started: std.Io.Timestamp,
    reported: std.Io.Timestamp,

    fn init(tx: *Tx, id: Plan.Id, old: ?Plan.Id) Payload {
        const now = std.Io.Clock.awake.now(tx.io);
        var result: Payload = .{
            .tx = tx,
            .id = id,
            .tracker = .init(tx.owner.allocator),
            .started = now,
            .reported = now,
        };
        if (!tx.flags.database_only)
            for (tx.owned_manifest.?.entries.items) |entry| {
                if (entry.package == id or
                    (old != null and entry.package == old.? and entry.archive_index == null))
                    result.total += 1;
            };
        progress(tx, id, 0);
        return result;
    }

    fn deinit(self: *Payload) void {
        if (self.tracker.system_error) |code| self.tx.execution.system_error = code;
        self.tracker.deinit();
    }

    fn policy(self: *Payload) Ops.Durability {
        if (comptime builtin.is_test)
            if (test_immediate_payload_sync) return .immediate;
        return .{ .batch = &self.tracker };
    }

    fn step(self: *Payload) void {
        self.completed += 1;
        const percent: u8 = @intCast(@min(99, @as(u128, self.completed) * 99 / @max(1, self.total)));
        const now = std.Io.Clock.awake.now(self.tx.io);
        if (percent <= self.percent or self.reported.durationTo(now).toMilliseconds() < 100) return;
        self.percent = percent;
        self.reported = now;
        progress(self.tx, self.id, percent);
    }

    fn flush(self: *Payload) !void {
        const tx = self.tx;
        tx.execution.payload_work_ms += self.started.untilNow(tx.io, .awake).toMilliseconds();
        if (tx.flags.database_only or self.tracker.targets.items.len == 0) return;
        try checkpoint(tx, .payload_sync, self.tracker.targets.items[0].path);
        payloadLog(tx, .function, "Finishing writes for {s}", .{tx.plan().?.package(self.id).name});
        // The percentage describes processed entries, not kernel flush progress.
        if (self.percent < 99) progress(tx, self.id, 99);
        const started = std.Io.Clock.awake.now(tx.io);
        defer tx.execution.payload_sync_ms += started.untilNow(tx.io, .awake).toMilliseconds();
        for (self.tracker.targets.items, 0..) |target, index| {
            try checkpoint(tx, .payload_sync, target.path);
            try self.tracker.flushTarget(index);
            tx.execution.payload_sync_targets += 1;
            try tx.owner.checkCancelled();
        }
        payloadLog(
            tx,
            .debug,
            "Finished writes for {s} in {d} ms",
            .{
                tx.plan().?.package(self.id).name,
                started.untilNow(tx.io, .awake).toMilliseconds(),
            },
        );
    }
};

fn payloadLog(
    tx: *Tx,
    level: Callbacks.LogLevel,
    comptime format: []const u8,
    args: anytype,
) void {
    const callbacks = tx.owner.configuration.callbacks;
    const callback = callbacks.log orelse return;
    const message = std.fmt.allocPrint(tx.owner.allocator, format, args) catch return;
    defer tx.owner.allocator.free(message);
    tx.owner.in_callback = true;
    defer tx.owner.in_callback = false;
    callback(callbacks.log_context, .{ .level = level, .message = message });
}

fn removePayload(tx: *Tx, id: Plan.Id, payload: *Payload) !void {
    if (tx.flags.database_only) return;
    const m = &tx.owned_manifest.?;
    for (m.entries.items) |entry| {
        if (entry.package != id or entry.archive_index != null) continue;
        defer payload.step();
        const current = (try m.root.inspect(entry.path, false)) orelse continue;
        if (try PathPatterns.match(
            tx.owner.allocator,
            tx.owner.configuration.no_upgrade,
            entry.file.name,
        ) == .matched)
            continue;
        var retained = entry.action == .shared_directory and current.directory();
        const replacement: ?Plan.Id = for (tx.plan().?.additions) |add| {
            if (add.old == id) break add.package;
        } else null;
        for (m.archives.items) |incoming|
            if (incoming.find(entry.path)) |file| {
                if (file.file.kind == .directory and current.directory()) retained = true;
                if (incoming.id != replacement and !std.mem.endsWith(u8, entry.file.name, "/")) retained = true;
                if (incoming.id == replacement)
                    for (incoming.package.backups) |backup| {
                        if (std.mem.eql(u8, backup.name, entry.path)) retained = true;
                    };
            };
        if (retained) continue;
        try checkpoint(tx, .remove, entry.path);
        var save = false;
        if (!tx.flags.no_save and !current.directory()) {
            for (m.locals.items) |local|
                if (local.id == id) {
                    for (local.package.backups) |backup|
                        if (std.mem.eql(u8, backup.name, entry.path)) {
                            var hash: [32]u8 = undefined;
                            if (backup.hash) |old|
                                save = try m.root.hash(tx.io, entry.path, &hash) and
                                    !std.mem.eql(u8, old, &hash);
                        };
                };
        }
        if (save) {
            const destination = try std.fmt.allocPrint(tx.storage.allocator(), "{s}.pacsave", .{entry.path});
            try Ops.rotatePacsaveWithDurability(
                &m.root,
                tx.io,
                tx.owner.allocator,
                destination,
                payload.policy(),
            );
            try Ops.renameWithDurability(&m.root, entry.path, destination, payload.policy());
            tx.owner.transactionEvent(
                .{
                    .pacsave_created = .{
                        .path = entry.path,
                        .old = tx.plan().?.candidates[@intFromEnum(id)].reference,
                    },
                },
            );
        } else try Ops.removeWithDurability(&m.root, entry.path, current.directory(), payload.policy());
        tx.execution.mutations += 1;
    }
}

fn install(tx: *Tx, addition: Plan.Addition, record: *Writer.Record, payload: *Payload) !Package {
    const m = &tx.owned_manifest.?;
    var archive: *Manifest.Archive = undefined;
    for (m.archives.items) |*item|
        if (item.id == addition.package) {
            archive = item;
            break;
        };
    var result = archive.package;
    for (m.database_changes.items) |change|
        if (change.package == addition.package) {
            result.files = change.files;
            result.backups = try tx.storage.allocator().dupe(BackupFile, change.backups);
            result.install_reason = change.reason;
            result.installed_database = change.installed_database;
            break;
        };
    result.install_date = @intCast(std.Io.Clock.real.now(tx.io).toSeconds());
    var reader = try Reader.openFile(tx.owner.allocator, archive.package.verified_archive.?.path());
    defer reader.deinit();
    var effects: std.AutoHashMapUnmanaged(usize, *const Manifest.Entry) = .empty;
    defer effects.deinit(tx.owner.allocator);
    for (m.entries.items) |*entry|
        if (entry.package == addition.package) {
            if (entry.archive_index) |index| try effects.put(tx.owner.allocator, index, entry);
        };
    var ordinal: usize = 0;
    while (try reader.next()) |file| : (ordinal += 1) {
        const path = Reader.normalizedName(file.name);
        const member: ?[:0]const u8 = if (std.mem.eql(u8, path, ".INSTALL"))
            "install"
        else if (std.mem.eql(u8, path, ".CHANGELOG"))
            "changelog"
        else if (std.mem.eql(u8, path, ".MTREE"))
            "mtree"
        else
            null;
        if (member) |name| {
            try checkpoint(tx, .database_write, path);
            try writeArchiveEntry(
                tx,
                &reader,
                record.record,
                name,
                .{
                    .package = addition.package,
                    .file = file,
                    .path = path,
                    .action = .install,
                },
                true,
            );
            const fd = c.openat(record.record, name, c.O_RDONLY | c.O_NOFOLLOW | c.O_CLOEXEC);
            if (fd < 0) return Ops.failure();
            defer _ = c.close(fd);
            if (c.fsync(fd) != 0) return Ops.failure();
            continue;
        }
        if (tx.flags.database_only or path.len == 0 or path[0] == '.') continue;
        if (effects.get(ordinal)) |entry| {
            defer payload.step();
            const hash = try extract(tx, &reader, entry.*, payload);
            for (@constCast(result.backups)) |*backup|
                if (std.mem.eql(u8, backup.name, entry.path)) {
                    backup.hash = hash;
                };
        }
    }
    try reader.finish();
    return result;
}

fn extract(tx: *Tx, reader: *Reader, entry: Manifest.Entry, payload: *Payload) !?[]const u8 {
    const m = &tx.owned_manifest.?;
    if (entry.action == .no_extract) return null;
    const before = try m.root.inspect(entry.path, false);
    if (before != null and before.?.directory() and entry.file.kind == .directory) return null;
    var old_hash: ?[]const u8 = null;
    var old_backup = false;
    var new_backup = false;
    for (tx.plan().?.additions) |add|
        if (add.package == entry.package) {
            if (add.old) |old|
                for (m.locals.items) |local|
                    if (local.id == old) {
                        for (local.package.backups) |backup|
                            if (std.mem.eql(u8, backup.name, entry.path)) {
                                old_backup = true;
                                old_hash = backup.hash;
                            };
                    };
        };
    for (m.archives.items) |archive|
        if (archive.id == entry.package) {
            for (archive.package.backups) |backup|
                if (std.mem.eql(u8, backup.name, entry.path)) {
                    new_backup = true;
                };
        };
    const existing_file = before != null and !before.?.directory() and entry.file.kind != .directory;
    const no_upgrade = existing_file and
        try PathPatterns.match(
            tx.owner.allocator,
            tx.owner.configuration.no_upgrade,
            entry.file.name,
        ) == .matched;
    const backup = existing_file and !no_upgrade and (old_backup or new_backup);
    const destination = if (no_upgrade or backup)
        try std.fmt.allocPrint(
            tx.storage.allocator(),
            "{s}.pacnew",
            .{entry.path},
        )
    else
        entry.path;
    const had_pacnew = (no_upgrade or backup) and try m.root.inspect(destination, false) != null;
    try checkpoint(tx, .extract, destination);
    if (std.fs.path.dirname(destination)) |path|
        try Ops.mkdirsWithDurability(&m.root, path, payload.policy());
    if (before != null and !before.?.directory() and entry.file.kind == .directory)
        try Ops.removeWithDurability(
            &m.root,
            entry.path,
            false,
            payload.policy(),
        );
    var stage = try Ops.Stage.initWithDurability(&m.root, tx.io, destination, payload.policy());
    var stage_live = true;
    defer if (stage_live) stage.deinit() catch |err| cleanupFailure(tx, err);
    if (entry.file.kind == .hardlink) {
        const target = try Root.normalize(entry.file.link_target.?);
        const source = (try m.root.open(target, true)) orelse return error.HardlinkTargetMissing;
        defer _ = c.close(source);
        if (!(try Root.state(source)).regular()) return error.InvalidHardlink;
        var buffer: [80]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&buffer, "/proc/{d}/fd/{d}", .{ c.getpid(), source });
        if (c.linkat(c.AT_FDCWD, path, stage.fd, "entry", c.AT_SYMLINK_FOLLOW) != 0) return Ops.failure();
    } else {
        try writeArchiveEntry(tx, reader, stage.fd, "entry", entry, false);
    }
    if (payload.policy() == .immediate and (entry.file.kind == .regular or entry.file.kind == .hardlink)) {
        const fd = c.openat(stage.fd, "entry", c.O_RDONLY | c.O_NOFOLLOW | c.O_CLOEXEC);
        if (fd < 0) return Ops.failure();
        defer _ = c.close(fd);
        if (c.fsync(fd) != 0) return Ops.failure();
    }
    try stage.publish();
    tx.execution.mutations += 1;
    var digest: [32]u8 = undefined;
    const new_hash = if ((backup or new_backup) and try m.root.hash(tx.io, destination, &digest))
        try tx.storage.allocator().dupe(u8, &digest)
    else
        null;
    var pacnew = no_upgrade;
    if (backup) {
        var local_digest: [32]u8 = undefined;
        const local_hash: ?[]const u8 = if (try m.root.hash(tx.io, entry.path, &local_digest))
            &local_digest
        else
            null;
        switch (Preflight.backupAction(old_hash, local_hash, new_hash)) {
            .replace => try Ops.renameWithDurability(&m.root, destination, entry.path, payload.policy()),
            .preserve => if (!had_pacnew) {
                try Ops.removeWithDurability(&m.root, destination, false, payload.policy());
            },
            .pacnew => pacnew = true,
            else => unreachable,
        }
    }
    if (pacnew) tx.owner.transactionEvent(.{ .pacnew_created = .{
        .path = entry.path,
        .old = blk: {
            for (tx.plan().?.additions) |add|
                if (add.package == entry.package)
                    break :blk if (add.old) |id|
                        tx.plan().?.candidates[@intFromEnum(id)].reference
                    else
                        null;
            break :blk null;
        },
        .new = tx.plan().?.candidates[@intFromEnum(entry.package)].reference,
        .from_no_upgrade = no_upgrade,
    } });
    stage_live = false;
    stage.deinit() catch |err| {
        cleanupFailure(tx, err);
        return err;
    };
    return new_hash;
}

fn writeArchiveEntry(
    tx: *Tx,
    reader: *Reader,
    directory: c_int,
    name: [:0]const u8,
    entry: Manifest.Entry,
    metadata: bool,
) !void {
    const header = ac.archive_entry_clone(reader.current_entry.?) orelse return error.OutOfMemory;
    defer ac.archive_entry_free(header);
    var buffer: [96]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&buffer, "/proc/{d}/fd/{d}/{s}", .{ c.getpid(), directory, name });
    ac.archive_entry_set_pathname(header, path);
    ac.archive_entry_set_hardlink(header, null);
    if (metadata) ac.archive_entry_set_perm(header, 0o644);
    const disk = ac.archive_write_disk_new() orelse return error.OutOfMemory;
    defer _ = ac.archive_write_free(disk);
    // Match add.c's extraction flags. SECURE_SYMLINKS is replaced by held
    // private staging descriptors; ACL is not enabled by the pinned native.
    if (ac.archive_write_disk_set_options(
        disk,
        ac.ARCHIVE_EXTRACT_OWNER | ac.ARCHIVE_EXTRACT_PERM | ac.ARCHIVE_EXTRACT_TIME | ac.ARCHIVE_EXTRACT_UNLINK | ac.ARCHIVE_EXTRACT_XATTR,
    ) != ac.ARCHIVE_OK)
        return error.ExtractionFailed;
    try archiveStatus(tx, disk, ac.archive_write_header(disk, header), entry);
    while (true) {
        var bytes: ?*const anyopaque = null;
        var size: usize = 0;
        var offset: ac.la_int64_t = 0;
        const status = ac.archive_read_data_block(reader.handle, &bytes, &size, &offset);
        if (status == ac.ARCHIVE_EOF) break;
        if (status != ac.ARCHIVE_OK) return error.ArchiveFailed;
        try tx.owner.checkCancelled();
        try archiveStatus(tx, disk, @intCast(ac.archive_write_data_block(disk, bytes, size, offset)), entry);
    }
    try archiveStatus(tx, disk, ac.archive_write_finish_entry(disk), entry);
    try archiveStatus(tx, disk, ac.archive_write_close(disk), entry);
}

fn archiveStatus(tx: *Tx, disk: *ac.struct_archive, status: c_int, entry: Manifest.Entry) !void {
    if (status == ac.ARCHIVE_OK) return;
    const code = ac.archive_errno(disk);
    if (status != ac.ARCHIVE_WARN or code == c.ENOSPC) {
        tx.execution.system_error = code;
        const message = ac.archive_error_string(disk);
        if (message != null)
            tx.execution.detail = try tx.storage.allocator().dupe(u8, std.mem.span(message));
        return switch (code) {
            c.ENOSPC, c.EDQUOT => error.NoSpaceLeft,
            c.EPERM, c.EACCES => error.PathPermissionDenied,
            c.EROFS => error.ReadOnlyFilesystem,
            c.ENOMEM => error.OutOfMemory,
            else => error.ExtractionFailed,
        };
    }
    const m = &tx.owned_manifest.?;
    try m.warnings.append(
        m.arena.allocator(),
        .{
            .cause = error.ExtractionWarning,
            .package = entry.package,
            .path = entry.path,
        },
    );
}
