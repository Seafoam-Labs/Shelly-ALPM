//! Inert examples based on devario-custom-packagbuilds' system integration split.
//! No host packages, services or scriptlets are changed.
const std = @import("std");
const rlpm = @import("Shelly_Rlpm");
const Fixture = @import("actions_fixture.zig");
const Archive = @import("archive_fixture.zig");
const io = std.testing.io;
const a = std.testing.allocator;
const flags: rlpm.TransactionFlags = .{ .no_hooks = true, .no_scriptlets = true };
const name = "devario-system-integration";
const previous = "devario-aqueous-desktop";
const helper = "usr/lib/devario/gpu-driver-setup";
const config = "etc/xdg/uwsm/env.d/60-devario-gpu.sh";
const info = "pkgname = " ++ name ++ "\npkgver = 1-1\narch = any\n";

fn archive(payload: bool, replacement: bool) !Archive {
    return Archive.init(if (payload) &.{
        .{ .path = ".PKGINFO", .contents = if (replacement) info ++ "conflict = " ++ previous ++ "\nreplaces = " ++ previous ++ "\n" else info },
        .{ .path = helper, .contents = "new packaged helper" },
    } else &.{
        .{ .path = ".PKGINFO", .contents = if (replacement) info ++ "conflict = " ++ previous ++ "\nreplaces = " ++ previous ++ "\n" else info },
    }, .none);
}

fn accept(_: ?*anyopaque, question: *rlpm.Callbacks.Question) void {
    switch (question.*) {
        .conflict => |*value| value.remove = true,
        .replace => |*value| value.replace = true,
        else => {},
    }
}

fn installed(owner: *rlpm.Owner) !*const rlpm.Package {
    const ref = (try owner.findPackage(owner.localDatabase().?, name)).?;
    return owner.packageMetadata(io, ref, .{ .files = true });
}

fn hasFile(package: *const rlpm.Package, path: []const u8) bool {
    for (package.files) |file| if (std.mem.eql(u8, file.name, path)) return true;
    return false;
}

test "Devario adopts unowned helpers and preserves contents attributes and inventory" {
    for ([_]bool{ false, true }) |payload| {
        var f = try Fixture.init();
        defer f.deinit();
        try f.write("root/" ++ helper, "installer helper");
        var input = try archive(payload, false);
        defer input.deinit();
        var owner = try f.owner();
        defer owner.deinit() catch unreachable;
        const tx = try owner.initializeTransaction(io, flags);
        defer owner.releaseTransaction() catch unreachable;
        try Fixture.add(tx, input.path);
        try tx.addMigration(.{ .package = name, .path = helper });
        try tx.prepare();
        try tx.preflight();
        const before = tx.manifest().?.adoptions.items[0].before;
        try std.testing.expectEqual(1, tx.plan().?.migrations.len);
        try tx.commit();
        try f.expect("root/" ++ helper, "installer helper");
        try std.testing.expectEqualDeep(before, (try tx.manifest().?.root.inspect(helper, false)).?);
        try std.testing.expectEqual(1, tx.execution.adoptions_planned);
        try std.testing.expectEqual(1, tx.execution.adoptions_committed);
        var fresh = try f.owner();
        defer fresh.deinit() catch unreachable;
        const package = try installed(&fresh);
        try std.testing.expect(hasFile(package, helper));
        try std.testing.expectEqual(@as(usize, if (payload) 0 else 1), package.adopted_files.len);
    }
}

test "Devario replacement transfers files including modified backup absent from archive" {
    for ([_]bool{ false, true }) |payload| {
        var f = try Fixture.init();
        defer f.deinit();
        try f.installed(previous, "1-1", helper ++ "\n" ++ config, null);
        try f.write("db/local/" ++ previous ++ "-1-1/files", "%FILES%\n" ++ helper ++ "\n" ++ config ++ "\n\n%BACKUP%\n" ++ config ++ "\t00000000000000000000000000000000\n\n");
        try f.write("root/" ++ helper, "old helper");
        try f.write("root/" ++ config, "administrator settings");
        var input = try archive(payload, true);
        defer input.deinit();
        var owner = try f.owner();
        defer owner.deinit() catch unreachable;
        owner.configuration.callbacks.question = accept;
        const tx = try owner.initializeTransaction(io, flags);
        defer owner.releaseTransaction() catch unreachable;
        try Fixture.add(tx, input.path);
        for ([_][]const u8{ helper, config }) |path|
            try tx.addMigration(.{ .package = name, .path = path, .source = .{ .replaced_package = previous } });
        try tx.prepare();
        try std.testing.expectEqual(1, tx.plan().?.replacements.len);
        try tx.commit();
        try f.expect("root/" ++ helper, "old helper");
        try f.expect("root/" ++ config, "administrator settings");
        try std.testing.expectError(error.FileNotFound, f.tmp.dir.access(io, "root/" ++ config ++ ".pacsave", .{}));
        var fresh = try f.owner();
        defer fresh.deinit() catch unreachable;
        try std.testing.expect((try fresh.findPackage(fresh.localDatabase().?, previous)) == null);
        const package = try installed(&fresh);
        try std.testing.expect(hasFile(package, helper) and hasFile(package, config));
        try std.testing.expectEqualStrings("00000000000000000000000000000000", package.backups[0].hash.?);
        try std.testing.expectEqual(2, tx.execution.adoptions_committed);
    }
}

fn apply(owner: *rlpm.Owner, input: []const u8, request: ?rlpm.Migration.Request) !void {
    const tx = try owner.initializeTransaction(io, flags);
    defer owner.releaseTransaction() catch unreachable;
    try Fixture.add(tx, input);
    if (request) |value| try tx.addMigration(value);
    try tx.prepare();
    try tx.commit();
}

test "adoptions survive fresh Owner upgrades and transition to archive payload" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("root/" ++ helper, "installer helper");
    var empty = try archive(false, false);
    defer empty.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    try apply(&owner, empty.path, .{ .package = name, .path = helper });
    var fresh = try f.owner();
    defer fresh.deinit() catch unreachable;
    try apply(&fresh, empty.path, null);
    try f.expect("root/" ++ helper, "installer helper");
    try std.testing.expectEqualStrings(helper, (try installed(&fresh)).adopted_files[0]);
    var payload = try archive(true, false);
    defer payload.deinit();
    try apply(&fresh, payload.path, null);
    try f.expect("root/" ++ helper, "new packaged helper");
    try std.testing.expectEqual(0, (try installed(&fresh)).adopted_files.len);
    const tx = try fresh.initializeTransaction(io, flags);
    defer fresh.releaseTransaction() catch unreachable;
    try tx.remove(name);
    try tx.prepare();
    try tx.commit();
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.access(io, "root/" ++ helper, .{}));
}

test "adopted configuration keeps its baseline and modified uninstall creates pacsave" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("root/" ++ config, "original configuration");
    var input = try archive(false, false);
    defer input.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    try apply(&owner, input.path, .{ .package = name, .path = config, .backup = true });
    const hash = try a.dupe(u8, (try installed(&owner)).backups[0].hash.?);
    defer a.free(hash);
    try f.write("root/" ++ config, "changed configuration");
    try apply(&owner, input.path, null);
    try std.testing.expectEqualStrings(hash, (try installed(&owner)).backups[0].hash.?);
    const tx = try owner.initializeTransaction(io, flags);
    defer owner.releaseTransaction() catch unreachable;
    try tx.remove(name);
    try tx.prepare();
    try tx.commit();
    try f.expect("root/" ++ config ++ ".pacsave", "changed configuration");
}

test "migration rejects unrelated ownership even with overwrite and NOCONFLICTS" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.installed("unrelated", "1-1", helper, null);
    try f.write("root/" ++ helper, "owned");
    var input = try archive(true, false);
    defer input.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    try owner.addListValue(io, .overwrite_files, "*");
    var mode = flags;
    mode.no_conflicts = true;
    const tx = try owner.initializeTransaction(io, mode);
    defer owner.releaseTransaction() catch unreachable;
    try Fixture.add(tx, input.path);
    try tx.addMigration(.{ .package = name, .path = helper });
    try tx.prepare();
    try std.testing.expectError(error.MigrationOwnershipConflict, tx.preflight());
    try std.testing.expectEqualStrings(helper, tx.manifest().?.failure.?.path.?);
    try f.expect("root/" ++ helper, "owned");
}

test "explicit unrelated removal is not a replacement migration source" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.installed(previous, "1-1", helper, null);
    var input = try archive(false, false);
    defer input.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    const tx = try owner.initializeTransaction(io, flags);
    defer owner.releaseTransaction() catch unreachable;
    try Fixture.add(tx, input.path);
    try tx.remove(previous);
    try tx.addMigration(.{ .package = name, .path = helper, .source = .{ .replaced_package = previous } });
    try std.testing.expectError(error.InvalidMigrationSource, tx.prepare());
}

test "missing paths are required by default and optional paths do not create ownership" {
    for ([_]bool{ false, true }) |optional| {
        var f = try Fixture.init();
        defer f.deinit();
        var input = try archive(false, false);
        defer input.deinit();
        var owner = try f.owner();
        defer owner.deinit() catch unreachable;
        const tx = try owner.initializeTransaction(io, flags);
        defer owner.releaseTransaction() catch unreachable;
        try Fixture.add(tx, input.path);
        try tx.addMigration(.{ .package = name, .path = helper, .optional = optional });
        try tx.prepare();
        if (optional) {
            try tx.commit();
            try std.testing.expect(!hasFile(try installed(&owner), helper));
        } else try std.testing.expectError(error.MigrationPathMissing, tx.preflight());
    }
}

test "migration API rejects unsafe paths duplicate claims late requests and unsupported modes" {
    var f = try Fixture.init();
    defer f.deinit();
    var input = try archive(false, false);
    defer input.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    {
        const tx = try owner.initializeTransaction(io, flags);
        defer owner.releaseTransaction() catch unreachable;
        try Fixture.add(tx, input.path);
        try std.testing.expectError(error.UnsafeArchivePath, tx.addMigration(.{ .package = name, .path = "../outside" }));
        try std.testing.expectError(error.InvalidMigrationPath, tx.addMigration(.{ .package = name, .path = "etc/conf\n%FILES%" }));
        try tx.addMigration(.{ .package = name, .path = helper, .optional = true });
        try std.testing.expectError(error.DuplicateMigration, tx.addMigration(.{ .package = "other", .path = helper }));
        try tx.prepare();
        try std.testing.expectError(error.InvalidTransactionState, tx.addMigration(.{ .package = name, .path = config }));
    }
    for ([_]rlpm.TransactionFlags{ .{ .database_only = true }, .{ .download_only = true } }) |mode| {
        const tx = try owner.initializeTransaction(io, mode);
        defer owner.releaseTransaction() catch unreachable;
        try std.testing.expectError(error.InvalidMigrationFlags, tx.addMigration(.{ .package = name, .path = helper }));
    }
}

test "adoption requires compatible types and rejects NoExtract and competing payloads" {
    for (0..4) |case| {
        var f = try Fixture.init();
        defer f.deinit();
        if (case == 0) try f.tmp.dir.createDirPath(io, "root/" ++ helper) else try f.write("root/" ++ helper, "existing");
        var input = try archive(false, false);
        defer input.deinit();
        var other = try Archive.init(&.{
            .{ .path = ".PKGINFO", .contents = "pkgname = other\npkgver = 1-1\narch = any\n" },
            .{ .path = if (case == 3) helper ++ "/child" else helper, .contents = "other" },
        }, .none);
        defer other.deinit();
        var owner = try f.owner();
        defer owner.deinit() catch unreachable;
        if (case == 1) try owner.addListValue(io, .no_extract, helper);
        const tx = try owner.initializeTransaction(io, flags);
        defer owner.releaseTransaction() catch unreachable;
        try Fixture.add(tx, input.path);
        if (case >= 2) try Fixture.add(tx, other.path);
        try tx.addMigration(.{ .package = name, .path = helper });
        try tx.prepare();
        try std.testing.expectError(switch (case) {
            0 => error.UnsupportedMigrationType,
            1 => error.MigrationNoExtractConflict,
            else => error.MigrationTargetConflict,
        }, tx.preflight());
    }
}

test "symlink adoption preserves the link rather than following its destination" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.symLink(io, "/not/a/host/file", "root/link", .{});
    var input = try archive(false, false);
    defer input.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    const tx = try owner.initializeTransaction(io, flags);
    defer owner.releaseTransaction() catch unreachable;
    try Fixture.add(tx, input.path);
    try tx.addMigration(.{ .package = name, .path = "link" });
    try tx.prepare();
    try tx.preflight();
    const before = tx.manifest().?.adoptions.items[0].before;
    try tx.commit();
    try std.testing.expectEqualDeep(before, (try tx.manifest().?.root.inspect("link", false)).?);
    try std.testing.expect(hasFile(try installed(&owner), "link"));
}

test "changed adoption fails revalidation without publishing ownership" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("root/" ++ helper, "before");
    var input = try archive(false, false);
    defer input.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    const tx = try owner.initializeTransaction(io, flags);
    defer owner.releaseTransaction() catch unreachable;
    try Fixture.add(tx, input.path);
    try tx.addMigration(.{ .package = name, .path = helper });
    try tx.prepare();
    try tx.preflight();
    try f.write("root/" ++ helper, "changed after review");
    try std.testing.expectError(error.StaleFilesystemState, tx.commit());
    try std.testing.expect((try owner.findPackage(owner.localDatabase().?, name)) == null);
}

test "publication failure leaves adopted contents and supports explicit retry" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("root/" ++ helper, "existing");
    var input = try archive(false, false);
    defer input.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    {
        const tx = try owner.initializeTransaction(io, flags);
        defer owner.releaseTransaction() catch unreachable;
        try Fixture.add(tx, input.path);
        try tx.addMigration(.{ .package = name, .path = helper });
        try tx.prepare();
        rlpm.Transaction.Executor.test_fault = .database_publish;
        defer rlpm.Transaction.Executor.test_fault = null;
        try std.testing.expectError(error.InjectedExecutionFailure, tx.commit());
        try std.testing.expectEqual(1, tx.execution.adoptions_planned);
        try std.testing.expectEqual(0, tx.execution.adoptions_committed);
        try std.testing.expect((try owner.findPackage(owner.localDatabase().?, name)) == null);
    }
    try f.expect("root/" ++ helper, "existing");
    try apply(&owner, input.path, .{ .package = name, .path = helper });
    try std.testing.expect(hasFile(try installed(&owner), helper));
}

test "same-name upgrades can explicitly adopt a formerly packaged file" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.installed(name, "0-1", helper, null);
    try f.write("root/" ++ helper, "keep old helper");
    var input = try archive(false, false);
    defer input.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    try apply(&owner, input.path, .{ .package = name, .path = helper, .source = .{ .replaced_package = name } });
    try f.expect("root/" ++ helper, "keep old helper");
    try std.testing.expectEqualStrings(helper, (try installed(&owner)).adopted_files[0]);
}

test "symlink aliases cannot bypass installed ownership or competing archive claims" {
    for ([_]bool{ false, true }) |competing| {
        var f = try Fixture.init();
        defer f.deinit();
        try f.write("root/usr/bin/devario-gpu-run", "existing");
        try f.tmp.dir.symLink(io, "/usr/bin", "root/bin", .{});
        if (!competing) try f.installed("unrelated", "1-1", "usr/bin/devario-gpu-run", null);
        var input = try archive(false, false);
        defer input.deinit();
        var other = try Archive.init(&.{
            .{ .path = ".PKGINFO", .contents = "pkgname = other\npkgver = 1-1\narch = any\n" },
            .{ .path = "usr/bin/devario-gpu-run", .contents = "other payload" },
        }, .none);
        defer other.deinit();
        var owner = try f.owner();
        defer owner.deinit() catch unreachable;
        const tx = try owner.initializeTransaction(io, flags);
        defer owner.releaseTransaction() catch unreachable;
        try Fixture.add(tx, input.path);
        if (competing) try Fixture.add(tx, other.path);
        try tx.addMigration(.{ .package = name, .path = "bin/devario-gpu-run" });
        try tx.prepare();
        try std.testing.expectError(if (competing) error.MigrationTargetConflict else error.MigrationOwnershipConflict, tx.preflight());
    }
}

test "replacement retains symlink ancestors needed to reach an adopted file" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("root/usr/bin/devario-gpu-run", "existing");
    try f.tmp.dir.symLink(io, "/usr/bin", "root/bin", .{});
    try f.installed(previous, "1-1", "bin\nbin/devario-gpu-run", null);
    var input = try archive(false, true);
    defer input.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    owner.configuration.callbacks.question = accept;
    try apply(&owner, input.path, .{
        .package = name,
        .path = "bin/devario-gpu-run",
        .source = .{ .replaced_package = previous },
    });
    try f.expect("root/usr/bin/devario-gpu-run", "existing");
    try std.testing.expect(hasFile(try installed(&owner), "bin/devario-gpu-run"));
    // access would follow the literal absolute link outside this private root.
    var buffer: [128]u8 = undefined;
    const length = try f.tmp.dir.readLink(io, "root/bin", &buffer);
    try std.testing.expectEqualStrings("/usr/bin", buffer[0..length]);
}

test "post-preflight mutation and cancellation at package start cannot publish adoption" {
    const Capture = struct {
        fixture: *Fixture,
        tx: *rlpm.Transaction,
        cancel: bool,
        fired: bool = false,

        fn event(context: ?*anyopaque, value: rlpm.Callbacks.Event) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (value != .package_operation or value.package_operation.boundary != .start) return;
            self.fired = true;
            if (self.cancel) {
                self.tx.owner.requestCancellation();
            } else self.fixture.write("root/" ++ helper, "changed by pre-package action") catch unreachable;
        }
    };
    for ([_]bool{ false, true }) |cancel| {
        var f = try Fixture.init();
        defer f.deinit();
        try f.write("root/" ++ helper, "reviewed helper");
        var input = try archive(false, false);
        defer input.deinit();
        var owner = try f.owner();
        defer owner.deinit() catch unreachable;
        const tx = try owner.initializeTransaction(io, flags);
        defer owner.releaseTransaction() catch unreachable;
        try Fixture.add(tx, input.path);
        try tx.addMigration(.{ .package = name, .path = helper });
        try tx.prepare();
        var capture: Capture = .{ .fixture = &f, .tx = tx, .cancel = cancel };
        owner.configuration.callbacks.event = Capture.event;
        owner.configuration.callbacks.event_context = &capture;
        defer owner.configuration.callbacks.event = null;
        try std.testing.expectError(if (cancel) error.Cancelled else error.StaleFilesystemState, tx.commit());
        try std.testing.expect(capture.fired);
        try std.testing.expectEqual(0, tx.execution.adoptions_committed);
        try std.testing.expect((try owner.findPackage(owner.localDatabase().?, name)) == null);
        if (!cancel) {
            try std.testing.expectEqual(.migration, tx.execution.boundary);
            try std.testing.expectEqualStrings(helper, tx.execution.path.?);
        }
    }
}

test "destination failure after replacement removal retains files and reports pending adoption" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.installed(previous, "1-1", helper, null);
    try f.write("root/" ++ helper, "old helper");
    var input = try Archive.init(&.{
        .{ .path = ".PKGINFO", .contents = info ++ "conflict = " ++ previous ++ "\nreplaces = " ++ previous ++ "\n" },
        .{ .path = "usr/share/devario/new-payload", .contents = "new" },
    }, .none);
    defer input.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    owner.configuration.callbacks.question = accept;
    {
        const tx = try owner.initializeTransaction(io, flags);
        defer owner.releaseTransaction() catch unreachable;
        try Fixture.add(tx, input.path);
        try tx.addMigration(.{ .package = name, .path = helper, .source = .{ .replaced_package = previous } });
        try tx.prepare();
        rlpm.Transaction.Executor.test_fault = .extract;
        defer rlpm.Transaction.Executor.test_fault = null;
        try std.testing.expectError(error.InjectedExecutionFailure, tx.commit());
        try std.testing.expectEqual(1, tx.execution.completed.items.len);
        try std.testing.expectEqual(1, tx.execution.adoptions_planned);
        try std.testing.expectEqual(0, tx.execution.adoptions_committed);
        try std.testing.expect((try owner.findPackage(owner.localDatabase().?, previous)) == null);
        try std.testing.expect((try owner.findPackage(owner.localDatabase().?, name)) == null);
    }
    try f.expect("root/" ++ helper, "old helper");
    // The old record has gone; a retry explicitly declares the now-unowned path.
    try apply(&owner, input.path, .{ .package = name, .path = helper });
    try std.testing.expect(hasFile(try installed(&owner), helper));
}

test "deleted adopted paths are dropped on upgrade and DBONLY cannot discard adoption metadata" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("root/" ++ helper, "existing");
    var input = try archive(false, false);
    defer input.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    try apply(&owner, input.path, .{ .package = name, .path = helper });
    {
        const tx = try owner.initializeTransaction(io, .{ .database_only = true });
        defer owner.releaseTransaction() catch unreachable;
        try Fixture.add(tx, input.path);
        try tx.prepare();
        try std.testing.expectError(error.InvalidMigrationFlags, tx.preflight());
    }
    try f.tmp.dir.deleteFile(io, "root/" ++ helper);
    try apply(&owner, input.path, null);
    const package = try installed(&owner);
    try std.testing.expectEqual(0, package.adopted_files.len);
    try std.testing.expect(!hasFile(package, helper));
}

fn allocationPreflight(allocator: std.mem.Allocator, fixture: *Fixture, input: []const u8, inherited: bool) !void {
    var owner = try rlpm.Owner.init(io, allocator, .{ .root = fixture.root, .database_path = fixture.db }, &.{});
    defer owner.deinit() catch unreachable;
    const tx = try owner.initializeTransaction(io, flags);
    defer owner.releaseTransaction() catch unreachable;
    try Fixture.add(tx, input);
    if (!inherited) try tx.addMigration(.{ .package = name, .path = helper, .backup = true });
    try tx.prepare();
    try tx.preflight();
    try std.testing.expectEqual(1, tx.manifest().?.adoptions.items.len);
}

test "allocation failures release explicit and inherited migration plans metadata and locks" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("root/" ++ helper, "existing");
    var input = try archive(false, false);
    defer input.deinit();
    try std.testing.checkAllAllocationFailures(a, allocationPreflight, .{ &f, input.path, false });
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    try apply(&owner, input.path, .{ .package = name, .path = helper, .backup = true });
    try std.testing.checkAllAllocationFailures(a, allocationPreflight, .{ &f, input.path, true });
}

fn declaredArchive(declaration: []const u8, payload: bool, replacement: bool) !Archive {
    const metadata = try std.fmt.allocPrint(a, "{s}{s}xdata = {s}={s}\n", .{
        info,
        if (replacement) "conflict = " ++ previous ++ "\nreplaces = " ++ previous ++ "\n" else "",
        rlpm.Migration.metadata_key,
        declaration,
    });
    defer a.free(metadata);
    return Archive.init(if (payload) &.{
        .{ .path = ".PKGINFO", .contents = metadata },
        .{ .path = helper, .contents = "new packaged helper" },
    } else &.{.{ .path = ".PKGINFO", .contents = metadata }}, .none);
}

const unowned_declaration = "{\"path\":\"" ++ helper ++ "\",\"from\":\"unowned\"}";
const replacement_declaration = "{\"path\":\"" ++ helper ++ "\",\"from\":\"package:" ++ previous ++ "\"}";

test "migration declarations transfer replaced files and remain inactive on clean install" {
    for ([_]bool{ false, true }) |replace| {
        var f = try Fixture.init();
        defer f.deinit();
        if (replace) {
            try f.installed(previous, "1-1", helper, null);
            try f.write("root/" ++ helper, "old helper");
        }
        var input = try declaredArchive(replacement_declaration, true, true);
        defer input.deinit();
        var owner = try f.owner();
        defer owner.deinit() catch unreachable;
        owner.configuration.callbacks.question = accept;
        const tx = try owner.initializeTransaction(io, flags);
        defer owner.releaseTransaction() catch unreachable;
        try Fixture.add(tx, input.path);
        try tx.prepare();
        try tx.preflight();
        try std.testing.expectEqual(@as(usize, if (replace) 1 else 0), tx.manifest().?.adoptions.items.len);
        if (replace) try std.testing.expectEqual(.declared, tx.manifest().?.adoptions.items[0].origin);
        try tx.commit();
        try f.expect("root/" ++ helper, if (replace) "old helper" else "new packaged helper");
    }
}

test "migration declarations adopt archive-absent unowned files with automatic discovery disabled" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("root/" ++ helper, "installer helper");
    var input = try declaredArchive(unowned_declaration, false, false);
    defer input.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    const tx = try owner.initializeTransaction(io, flags);
    defer owner.releaseTransaction() catch unreachable;
    try Fixture.add(tx, input.path);
    try tx.prepare();
    try tx.commit();
    try f.expect("root/" ++ helper, "installer helper");
    var fresh = try f.owner();
    defer fresh.deinit() catch unreachable;
    try std.testing.expectEqualStrings(helper, (try installed(&fresh)).adopted_files[0]);
}

test "migration automatic discovery is opt-in and does not freeze subsequent upgrades" {
    for ([_]bool{ false, true }) |automatic| {
        var f = try Fixture.init();
        defer f.deinit();
        try f.write("root/" ++ helper, "installer helper");
        var input = try archive(true, false);
        defer input.deinit();
        var owner = try f.owner();
        defer owner.deinit() catch unreachable;
        owner.configuration.auto_migrate_unowned = automatic;
        {
            const tx = try owner.initializeTransaction(io, flags);
            defer owner.releaseTransaction() catch unreachable;
            try Fixture.add(tx, input.path);
            try tx.prepare();
            if (!automatic) {
                try std.testing.expectError(error.FileConflicts, tx.preflight());
                continue;
            }
            try tx.preflight();
            try std.testing.expectEqual(.automatic, tx.manifest().?.adoptions.items[0].origin);
            try tx.commit();
            try f.expect("root/" ++ helper, "installer helper");
        }
        // A package-owned file follows normal extraction on reinstall.
        const tx = try owner.initializeTransaction(io, flags);
        defer owner.releaseTransaction() catch unreachable;
        try Fixture.add(tx, input.path);
        try tx.prepare();
        try tx.commit();
        try f.expect("root/" ++ helper, "new packaged helper");
    }
}

test "migration explicit wrong owner cannot fall back to automatic adoption" {
    for ([_]bool{ false, true }) |owned| {
        var f = try Fixture.init();
        defer f.deinit();
        try f.installed(previous, "1-1", if (owned) helper else "usr/other", null);
        try f.write("root/" ++ helper, "existing helper");
        var input = try declaredArchive(if (owned) unowned_declaration else replacement_declaration, true, true);
        defer input.deinit();
        var owner = try f.owner();
        defer owner.deinit() catch unreachable;
        owner.configuration.auto_migrate_unowned = true;
        owner.configuration.callbacks.question = accept;
        const tx = try owner.initializeTransaction(io, flags);
        defer owner.releaseTransaction() catch unreachable;
        try Fixture.add(tx, input.path);
        try tx.prepare();
        try std.testing.expectError(error.MigrationOwnershipConflict, tx.preflight());
        try f.expect("root/" ++ helper, "existing helper");
    }
}

test "migration declarations optional missing paths install payload and required paths fail" {
    for ([_]bool{ false, true }) |optional| {
        var f = try Fixture.init();
        defer f.deinit();
        var input = try declaredArchive(if (optional)
            "{\"path\":\"" ++ helper ++ "\",\"from\":\"unowned\",\"optional\":true}"
        else
            unowned_declaration, true, false);
        defer input.deinit();
        var owner = try f.owner();
        defer owner.deinit() catch unreachable;
        const tx = try owner.initializeTransaction(io, flags);
        defer owner.releaseTransaction() catch unreachable;
        try Fixture.add(tx, input.path);
        try tx.prepare();
        if (optional) {
            try tx.commit();
            try f.expect("root/" ++ helper, "new packaged helper");
        } else try std.testing.expectError(error.MigrationPathMissing, tx.preflight());
    }
}

test "migration metadata rejects malformed unknown and duplicate declarations" {
    for ([_][]const u8{
        "{}",                                       "{\"path\":\"../escape\",\"from\":\"unowned\"}",
        "{\"path\":\"etc/file\",\"from\":\"any\"}", "{\"path\":\"etc/file\",\"from\":\"unowned\",\"unknown\":true}",
    }) |invalid| {
        if (rlpm.Migration.parse(a, invalid)) |parsed| {
            parsed.deinit();
            return error.ExpectedInvalidMigrationMetadata;
        } else |_| {}
    }
    try std.testing.expectError(error.DuplicateMigration, rlpm.Migration.validateDeclarations(a, &.{ unowned_declaration, unowned_declaration }));
    const values = [_]rlpm.Package.XData{.{ .name = "shelly.migration.v2", .value = unowned_declaration }};
    try std.testing.expectError(error.UnsupportedMigrationVersion, rlpm.Migration.validateXdata(a, &values));
}

test "migration declared unowned payload returns to normal extraction on reinstall" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("root/" ++ helper, "installer helper");
    var input = try declaredArchive(unowned_declaration, true, false);
    defer input.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    try apply(&owner, input.path, null);
    try f.expect("root/" ++ helper, "installer helper");
    try apply(&owner, input.path, null);
    try f.expect("root/" ++ helper, "new packaged helper");
}

test "migration declared DBONLY fails and DOWNLOADONLY makes no adoption" {
    for ([_]bool{ false, true }) |download| {
        var f = try Fixture.init();
        defer f.deinit();
        try f.write("root/" ++ helper, "installer helper");
        var input = try declaredArchive(unowned_declaration, true, false);
        defer input.deinit();
        var owner = try f.owner();
        defer owner.deinit() catch unreachable;
        const tx = try owner.initializeTransaction(io, .{ .database_only = !download, .download_only = download, .no_hooks = true, .no_scriptlets = true });
        defer owner.releaseTransaction() catch unreachable;
        try Fixture.add(tx, input.path);
        try tx.prepare();
        if (download) try tx.commit() else try std.testing.expectError(error.InvalidMigrationFlags, tx.preflight());
        try std.testing.expectEqual(0, tx.execution.adoptions_committed);
        try f.expect("root/" ++ helper, "installer helper");
        try std.testing.expect((try owner.findPackage(owner.localDatabase().?, name)) == null);
    }
}

test "migration automatic discovery preserves native backup behavior" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("root/etc/config", "local settings");
    var input = try Archive.init(&.{
        .{ .path = ".PKGINFO", .contents = info ++ "backup = etc/config\n" },
        .{ .path = "etc/config", .contents = "distributed settings" },
    }, .none);
    defer input.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    owner.configuration.auto_migrate_unowned = true;
    const tx = try owner.initializeTransaction(io, flags);
    defer owner.releaseTransaction() catch unreachable;
    try Fixture.add(tx, input.path);
    try tx.prepare();
    try tx.commit();
    try std.testing.expectEqual(0, tx.execution.adoptions_committed);
    try f.expect("root/etc/config", "local settings");
    try f.expect("root/etc/config.pacnew", "distributed settings");
}

fn declarationAllocations(allocator: std.mem.Allocator) !void {
    try rlpm.Migration.validateDeclarations(allocator, &.{unowned_declaration});
}

test "migration declaration allocation failures release JSON and duplicate tracking" {
    try std.testing.checkAllAllocationFailures(a, declarationAllocations, .{});
}
