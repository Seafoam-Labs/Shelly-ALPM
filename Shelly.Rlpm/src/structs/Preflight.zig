//! Read-only preparation of the filesystem executor's input. No extraction.
const std = @import("std");
const Tx = @import("Transaction.zig");
const Manifest = @import("ExecutionManifest.zig");
const Plan = @import("TransactionPlan.zig");
const Package = @import("Package.zig");
const File = @import("PackageFile.zig");
const Root = @import("RootPath.zig");
const Reader = @import("ArchiveReader.zig");
const Patterns = @import("PathPatterns.zig");
const Verification = @import("Verification.zig");
const LocalWriter = @import("LocalWriter.zig");
const SignaturePolicy = @import("SignaturePolicy.zig");
const OpenPgp = @import("OpenPgp.zig");
const Callbacks = @import("Callbacks.zig");
const ImmutableFile = @import("ImmutableFile.zig");
const OwnerConfiguration = @import("OwnerConfiguration.zig");
const BackupFile = @import("BackupFile.zig");
const PackageRelation = @import("PackageRelation.zig");

fn policyFor(tx: *Tx, id: Plan.Id) SignaturePolicy {
    const expected = tx.owned_plan.?.package(id);
    if (expected.origin == .sync)
        return tx.owner.sync_databases.items[tx.owned_plan.?.candidates[@intFromEnum(id)].repository.?].signature_policy;
    return switch (expected.archive_source) {
        .local_file => tx.owner.configuration.effectiveLocalSignaturePolicy(),
        .remote_file => tx.owner.configuration.effectiveRemoteSignaturePolicy(),
        .repository => blk: {
            for (tx.owner.sync_databases.items) |db| {
                if (std.meta.eql(expected.archive_repository, db.identity)) break :blk db.signature_policy;
            }
            // Portable archives may outlive their source Owner/registration.
            break :blk expected.archive_signature_policy orelse
                tx.owner.configuration.effectiveLocalSignaturePolicy();
        },
    };
}

pub fn populate(tx: *Tx, manifest: *Manifest) !void {
    var builder: Builder = .{
        .tx = tx,
        .m = manifest,
        .a = manifest.arena.allocator(),
        .plan = &tx.owned_plan.?,
    };
    builder.run() catch |err| {
        manifest.failure = .{
            .cause = err,
            .package = builder.current_package,
            .path = builder.current_path,
        };
        return err;
    };
    manifest.complete = true;
    try manifest.check();
}

/// Sealed bytes cannot change, but keyring trust/revocation and detached
/// signatures can. Reapply the captured effective source policy before use.
pub fn reverify(tx: *Tx, manifest: *const Manifest) !void {
    var download_index: usize = 0;
    for (manifest.archives.items) |archive| {
        try tx.owner.checkCancelled();
        const expected = tx.owned_plan.?.package(archive.id);
        const file = if (expected.origin == .sync) blk: {
            const item = &tx.downloaded_files.?[download_index];
            download_index += 1;
            break :blk item;
        } else null;
        const signature = if (file) |download|
            if (download.signature) |*sig|
                try std.Io.Dir.cwd().readFileAlloc(
                    tx.io,
                    sig.path(),
                    tx.owner.allocator,
                    .limited(
                        OpenPgp.max_signature_size,
                    ),
                )
            else
                null
        else
            null;
        defer if (signature) |bytes| tx.owner.allocator.free(bytes);
        const policy = policyFor(tx, archive.id);
        _ = try Verification.check(
            tx.owner.allocator,
            tx.io,
            tx.owner.verificationContext(),
            &archive.package.verified_archive.?,
            if (file) |download|
                download.path
            else
                expected.archive_path.?,
            .{
                .requirement = policy.package,
                .trust = policy.package_trust,
                .md5 = expected.md5_sum,
                .sha256 = expected.sha256_sum,
                .base64_signature = expected.base64_signature,
                .detached_signature = if (file != null) .{ .bytes = signature } else .read_from_path,
            },
            &tx.owner.last_verification,
        );
    }
}

const Builder = struct {
    tx: *Tx,
    m: *Manifest,
    a: std.mem.Allocator,
    plan: *const Plan,
    cleared: std.StringHashMapUnmanaged(void) = .empty,
    created_directories: std.StringHashMapUnmanaged(void) = .empty,
    file_owners: std.StringHashMapUnmanaged(std.ArrayList(Plan.Id)) = .empty,
    targets: std.StringHashMapUnmanaged(std.ArrayList(Manifest.Entry)) = .empty,
    local_indices: std.AutoHashMapUnmanaged(Plan.Id, usize) = .empty,
    current_package: ?Plan.Id = null,
    current_path: ?[]const u8 = null,

    fn phase(
        self: *Builder,
        value: Callbacks.Phase,
        boundary: Callbacks.Boundary,
    ) void {
        // Pure removal has no native package-loading/file-conflict phases.
        if (self.plan.additions.len == 0) return;
        if (value == .disk_space and self.tx.flags.database_only) return;
        self.tx.owner.transactionEvent(.{ .phase = .{ .phase = value, .boundary = boundary } });
    }

    fn run(self: *Builder) !void {
        self.phase(.load_packages, .start);
        {
            errdefer self.phase(.load_packages, .failed);
            try self.loadArchives();
            try self.loadLocal();
        }
        self.phase(.load_packages, .done);
        try self.tx.owner.checkCancelled();
        if (!self.tx.flags.database_only) {
            self.phase(.file_conflicts, .start);
            {
                errdefer self.phase(.file_conflicts, .failed);
                try self.conflicts();
                if (self.m.conflicts.items.len != 0) return error.FileConflicts;
                for (self.plan.removals) |id|
                    try self.removePackage(id, null);
                for (self.m.archives.items) |archive| {
                    if (self.oldOf(archive.id)) |old| try self.removePackage(old, archive.id);
                    try self.additions(archive);
                }
            }
            self.phase(.file_conflicts, .done);
        }
        try self.databaseChanges();
        if (self.tx.owner.configuration.check_space) self.phase(.disk_space, .start);
        {
            errdefer if (self.tx.owner.configuration.check_space) self.phase(.disk_space, .failed);
            try self.space();
        }
        if (self.tx.owner.configuration.check_space) self.phase(.disk_space, .done);
        try self.tx.owner.checkCancelled();
    }

    fn loadArchives(self: *Builder) !void {
        var download_index: usize = 0;
        for (self.plan.additions, 0..) |addition, index| {
            try self.tx.owner.checkCancelled();
            self.current_package = addition.package;
            const callbacks = self.tx.owner.configuration.callbacks;
            if (callbacks.log) |log| {
                var buffer: [512]u8 = undefined;
                const message = std.fmt.bufPrint(
                    &buffer,
                    "Checking package archive ({d}/{d}): {s}",
                    .{
                        index + 1,
                        self.plan.additions.len,
                        self.plan.package(addition.package).name,
                    },
                ) catch
                    "Checking package archive";
                log(callbacks.log_context, .{ .level = .function, .message = message });
            }
            const expected = self.plan.package(addition.package);
            const downloaded = if (expected.origin == .sync) blk: {
                const file = &self.tx.downloaded_files.?[download_index];
                download_index += 1;
                break :blk file;
            } else null;
            const path = if (downloaded) |file|
                file.path
            else
                expected.archive_path orelse
                    return error.InvalidPackageOwnership;
            self.current_path = try self.a.dupe(u8, path);
            var snapshot = if (downloaded) |file|
                try file.snapshot.clone()
            else if (expected.verified_archive) |*file|
                try file.clone()
            else
                try ImmutableFile.copyRegular(
                    self.tx.io,
                    path,
                    null,
                );
            var transferred = false;
            defer if (!transferred) snapshot.deinit();
            const policy = policyFor(self.tx, addition.package);
            const signature = if (downloaded) |file|
                if (file.signature) |*sig|
                    try std.Io.Dir.cwd().readFileAlloc(
                        self.tx.io,
                        sig.path(),
                        self.a,
                        .limited(
                            OpenPgp.max_signature_size,
                        ),
                    )
                else
                    null
            else
                null;
            const validation = try Verification.check(
                self.tx.owner.allocator,
                self.tx.io,
                self.tx.owner.verificationContext(),
                &snapshot,
                path,
                .{
                    .requirement = policy.package,
                    .trust = policy.package_trust,
                    .md5 = expected.md5_sum,
                    .sha256 = expected.sha256_sum,
                    .base64_signature = expected.base64_signature,
                    .detached_signature = if (downloaded != null) .{ .bytes = signature } else .read_from_path,
                },
                &self.tx.owner.last_verification,
            );
            var loaded = try Package.loadArchive(self.tx.owner.allocator, snapshot.path(), .{ .mode = .full });
            errdefer if (!transferred) loaded.deinit();
            try metadataMatches(expected, &loaded);
            if (loaded.architecture) |arch|
                if (!std.mem.eql(u8, arch, "any") and
                    self.tx.owner.configuration.architectures.len != 0)
                {
                    var accepted = false;
                    for (self.tx.owner.configuration.architectures) |allowed|
                        if (std.mem.eql(u8, arch, allowed)) {
                            accepted = true;
                            break;
                        };
                    if (!accepted) return error.InvalidArchitecture;
                };
            loaded.validation = validation;
            loaded.archive_signature_policy = policy;
            loaded.archive_source = expected.archive_source;
            loaded.archive_repository = expected.archive_repository;
            // Ensure there is storage before transferring descriptor ownership.
            try self.m.archives.ensureUnusedCapacity(self.a, 1);
            loaded.verified_archive = snapshot;
            transferred = true;
            self.m.archives.appendAssumeCapacity(.{ .id = addition.package, .package = loaded });
            try self.scan(&self.m.archives.items[self.m.archives.items.len - 1]);
        }
        self.current_package = null;
        self.current_path = null;
    }

    fn scan(self: *Builder, archive: *Manifest.Archive) !void {
        var reader = try archive.package.openArchive(self.tx.owner.allocator);
        defer reader.deinit();
        var payload: std.ArrayList(Manifest.Entry) = .empty;
        var metadata: std.ArrayList(Manifest.Entry) = .empty;
        defer {
            archive.payload = payload.items;
            archive.metadata = metadata.items;
        }
        var names: std.StringHashMapUnmanaged(void) = .empty;
        var ordinal: usize = 0;
        var verified_bytes: u64 = 0;
        var reported = std.Io.Clock.awake.now(self.tx.io);
        while (try reader.next()) |borrowed| : (ordinal += 1) {
            try self.tx.owner.checkCancelled();
            self.reportArchiveProgress(archive.id, ordinal, verified_bytes, &reported);
            self.current_path = try self.a.dupe(u8, borrowed.name);
            // Conventional tar root header carries no package file.
            if (borrowed.kind == .directory and
                (std.mem.eql(u8, borrowed.name, ".") or
                    std.mem.eql(u8, borrowed.name, "./")))
                continue;
            const normalized = try Root.normalize(borrowed.name);
            const path = std.mem.trimEnd(u8, normalized, "/");
            var file = try Plan.copyValue(File, self.a, borrowed);
            file.name = if (file.kind == .directory)
                try std.fmt.allocPrint(self.a, "{s}/", .{path})
            else
                try self.a.dupe(u8, path);
            if (file.kind != .directory and normalized.len != path.len) return error.UnsafeArchivePath;
            if ((try names.getOrPut(self.a, file.name)).found_existing) return error.DuplicateArchivePath;
            if (file.kind == .hardlink)
                file.link_target = try self.a.dupe(
                    u8,
                    try Root.normalize(file.link_target.?),
                );
            if (file.kind == .symlink and file.link_target.?.len == 0) return error.UnsafeSymlink;
            var hash = std.crypto.hash.Md5.init(.{});
            var count: u64 = 0;
            var buffer: [64 * 1024]u8 = undefined;
            while (true) {
                const n = try reader.read(&buffer);
                if (n == 0) break;
                hash.update(buffer[0..n]);
                count = try std.math.add(u64, count, n);
                verified_bytes +|= n;
                self.reportArchiveProgress(archive.id, ordinal, verified_bytes, &reported);
                try self.tx.owner.checkCancelled();
            }
            if (file.kind == .regular and count != file.size.?) return error.ArchiveFailed;
            var digest: [16]u8 = undefined;
            hash.final(&digest);
            const hex = std.fmt.bytesToHex(digest, .lower);
            const entry: Manifest.Entry = .{
                .package = archive.id,
                .file = file,
                .path = try self.a.dupe(u8, path),
                .action = .install,
                .archive_index = ordinal,
                .new_hash = if (file.kind == .regular)
                    try self.a.dupe(u8, &hex)
                else
                    null,
            };
            if (path[0] == '.') {
                // libalpm reserves every root-dot entry. Only known database
                // members may be published later, and those must be regular.
                for ([_][]const u8{ ".PKGINFO", ".BUILDINFO", ".INSTALL", ".CHANGELOG", ".MTREE" }) |reserved| {
                    if (std.mem.eql(u8, path, reserved) and file.kind != .regular)
                        return error.UnsafeArchivePath;
                }
                try metadata.append(self.a, entry);
            } else {
                const result = try archive.by_path.getOrPut(self.a, entry.path);
                if (result.found_existing) return error.DuplicateArchivePath;
                result.value_ptr.* = payload.items.len;
                try payload.append(self.a, entry);
            }
        }
        try reader.finish();
        for (payload.items) |*entry| {
            if (entry.file.kind == .hardlink) {
                var target = entry.file.link_target.?;
                var depth: usize = 0;
                while (true) : (depth += 1) {
                    if (depth >= payload.items.len) return error.UnsafeHardlink;
                    const source = payload.items[
                        archive.by_path.get(target) orelse
                            return error.UnsafeHardlink
                    ];
                    if (!try self.matches(.no_extract, entry.file.name) and
                        try self.matches(.no_extract, source.file.name))
                        return error.UnsafeHardlink;
                    if (source.file.kind == .hardlink) {
                        target = source.file.link_target.?;
                        continue;
                    }
                    if (source.file.kind != .regular) return error.UnsafeHardlink;
                    entry.new_hash = source.new_hash;
                    break;
                }
            }
        }
        // The mtree must describe the actual stream. Reject disagreement instead
        // of letting conflict checks and extraction see different payloads.
        self.current_path = if (archive.package.files_source == .mtree)
            ".MTREE"
        else
            archive.package.archive_path;
        if (archive.package.files.len != payload.items.len) return error.ArchiveInventoryMismatch;
        for (archive.package.files) |file| {
            self.current_path = file.name;
            const path = std.mem.trimEnd(u8, try Root.normalize(file.name), "/");
            const entry = payload.items[archive.by_path.get(path) orelse return error.ArchiveInventoryMismatch];
            if (std.mem.endsWith(u8, file.name, "/") != (entry.file.kind == .directory))
                return error.ArchiveInventoryMismatch;
        }
        // PKGINFO may retain backup declarations for files no longer shipped
        // (for example java.policy in JDK 27). libalpm keeps those records
        // without a hash; they are not assertions about the archive inventory.
        for (archive.package.backups) |backup| {
            self.current_path = backup.name;
            _ = try Root.normalize(backup.name);
        }
        // Downstream phases consume the scanned stream's metadata, never a
        // size/mode/scriptlet assertion that only appeared in .MTREE.
        const files = try archive.package.archive_arena.?.allocator().alloc(File, payload.items.len);
        for (payload.items, files) |entry, *file|
            file.* = try Plan.copyValue(
                File,
                archive.package.archive_arena.?.allocator(),
                entry.file,
            );
        std.mem.sort(File, files, {}, fileLess);
        archive.package.files = files;
        archive.package.files_source = .archive;
        archive.package.members = .{
            .install = .absent,
            .changelog = .absent,
            .mtree = .absent,
        };
        for (metadata.items) |entry| {
            if (std.mem.eql(u8, entry.path, ".INSTALL")) archive.package.members.install = .present;
            if (std.mem.eql(u8, entry.path, ".CHANGELOG")) archive.package.members.changelog = .present;
            if (std.mem.eql(u8, entry.path, ".MTREE")) archive.package.members.mtree = .present;
        }
        archive.package.has_scriptlet = archive.package.members.install == .present;
    }

    fn reportArchiveProgress(
        self: *Builder,
        id: Plan.Id,
        entries: usize,
        bytes: u64,
        reported: *std.Io.Timestamp,
    ) void {
        const callbacks = self.tx.owner.configuration.callbacks;
        const log = callbacks.log orelse return;
        const now = std.Io.Clock.awake.now(self.tx.io);
        if (reported.durationTo(now).toMilliseconds() < 250) return;
        reported.* = now;
        var buffer: [512]u8 = undefined;
        const message = std.fmt.bufPrint(
            &buffer,
            "Checking {s}: {d} archive entries, {d} bytes read",
            .{
                self.plan.package(id).name,
                entries,
                bytes,
            },
        ) catch
            "Checking package archive contents";
        log(callbacks.log_context, .{ .level = .function, .message = message });
    }

    fn loadLocal(self: *Builder) !void {
        const db = &self.tx.owner.local.?;
        for (self.plan.candidates, 0..) |candidate, index| {
            if (candidate.package.origin != .local) continue;
            self.current_package = @enumFromInt(index);
            self.current_path = candidate.package.metadata_directory;
            try self.tx.owner.checkCancelled();
            try db.loadMetadata(self.tx.io, candidate.reference.id, .{ .files = true });
            const package = try Plan.copyMetadata(
                self.a,
                db.packages.packages.items[@intFromEnum(candidate.reference.id)],
            );
            for (package.files) |file| {
                _ = try Root.normalize(file.name);
                const result = try self.file_owners.getOrPut(self.a, file.name);
                if (!result.found_existing) result.value_ptr.* = .empty;
                try result.value_ptr.append(self.a, @enumFromInt(index));
            }
            try self.local_indices.put(self.a, @enumFromInt(index), self.m.locals.items.len);
            try self.m.locals.append(self.a, .{ .id = @enumFromInt(index), .package = package });
        }
        self.current_package = null;
        self.current_path = null;
    }

    fn matches(
        self: *Builder,
        comptime list: OwnerConfiguration.StringList,
        name: []const u8,
    ) !bool {
        return try Patterns.match(self.tx.owner.allocator, self.tx.owner.configuration.list(list), name) == .matched;
    }

    fn overwrite(self: *Builder, name: []const u8) !bool {
        if (try self.matches(.overwrite_files, name)) return true;
        const absolute = try std.fmt.allocPrint(self.a, "{s}{s}", .{ self.tx.owner.configuration.root, name });
        return self.matches(.overwrite_files, absolute);
    }

    fn removed(self: *const Builder, id: Plan.Id) bool {
        for (self.plan.removals) |old|
            if (old == id) return true;
        return false;
    }

    fn replaced(self: *const Builder, id: Plan.Id) bool {
        for (self.plan.additions) |addition|
            if (addition.old == id) return true;
        return false;
    }

    fn local(self: *const Builder, id: Plan.Id) *const Package {
        return &self.m.locals.items[self.local_indices.get(id).?].package;
    }

    fn ownerOf(self: *const Builder, name: []const u8) ?Plan.Id {
        const owners = self.file_owners.get(name) orelse return null;
        return owners.items[0];
    }

    fn owns(self: *const Builder, id: Plan.Id, name: []const u8) bool {
        const owners = self.file_owners.get(name) orelse return false;
        return std.mem.indexOfScalar(Plan.Id, owners.items, id) != null;
    }

    fn oldOf(self: *const Builder, id: Plan.Id) ?Plan.Id {
        for (self.plan.additions) |addition|
            if (addition.package == id) return addition.old;
        return null;
    }

    fn addConflict(self: *Builder, entry: Manifest.Entry, other: ?Plan.Id, target: bool) !void {
        try self.m.conflicts.append(
            self.a,
            .{
                .path = entry.path,
                .package = entry.package,
                .other = other,
                .kind = if (target) .target else .filesystem,
            },
        );
    }

    fn observe(self: *Builder, path: []const u8) !?Root.State {
        _ = try self.m.remember(".", true);
        var cursor: usize = 0;
        while (std.mem.indexOfScalarPos(u8, path, cursor, '/')) |index| {
            const prefix = path[0..index];
            _ = try self.m.remember(prefix, false);
            _ = try self.m.remember(prefix, true);
            cursor = index + 1;
        }
        return self.m.remember(path, false);
    }

    fn conflicts(self: *Builder) !void {
        for (self.m.archives.items) |archive|
            for (archive.payload) |entry| {
                const result = try self.targets.getOrPut(self.a, entry.path);
                if (!result.found_existing) result.value_ptr.* = .empty;
                for (result.value_ptr.items) |other| {
                    if (entry.file.kind == .directory and other.file.kind == .directory) continue;
                    if (std.mem.eql(u8, entry.file.name, other.file.name) and try self.overwrite(entry.file.name))
                        continue;
                    try self.addConflict(entry, other.package, true);
                }
                try result.value_ptr.append(self.a, entry);
            };
        for (self.m.archives.items) |archive|
            for (archive.payload) |entry| {
                self.current_package = archive.id;
                self.current_path = entry.path;
                try self.tx.owner.checkCancelled();
                var parent_cursor: usize = 0;
                while (std.mem.indexOfScalarPos(u8, entry.path, parent_cursor, '/')) |index| {
                    if (self.targets.get(entry.path[0..index])) |parents|
                        for (parents.items) |parent| {
                            if (parent.file.kind != .directory) try self.addConflict(entry, parent.package, true);
                        };
                    parent_cursor = index + 1;
                }
                // Existing ancestors may be symlinks, but must resolve to directories
                // inside the root, or be owned file->directory transitions.
                var cursor: usize = 0;
                while (std.mem.indexOfScalarPos(u8, entry.path, cursor, '/')) |index| {
                    const prefix = entry.path[0..index];
                    if (try self.m.root.inspect(prefix, false)) |before| {
                        const followed = try self.m.root.inspect(prefix, true);
                        if ((followed == null or !followed.?.directory()) and !self.plannedDirectory(prefix)) {
                            _ = before;
                            try self.addConflict(entry, self.ownerOf(prefix), false);
                        }
                    }
                    cursor = index + 1;
                }
                const before = (try self.observe(entry.path)) orelse continue;
                if (before.directory() and entry.file.kind == .directory) continue;
                const old = self.oldOf(archive.id);
                if (old) |id|
                    if (!before.directory() and self.owns(id, entry.file.name)) continue;
                var resolved = false;
                for (self.m.locals.items) |item|
                    if ((self.removed(item.id) or self.replaced(item.id)) and
                        self.owns(item.id, entry.path))
                    {
                        resolved = true;
                        break;
                    };
                if (resolved and !before.directory()) continue;
                if (before.directory() and entry.file.kind != .directory and
                    try self.canReplaceDirectory(entry.path, old))
                    continue;
                if (!before.directory() and self.ownerOf(entry.path) == null and
                    backupHash(archive.package, entry.path) != .absent)
                    continue;
                if (!before.directory() and try self.overwrite(entry.file.name)) continue;
                try self.addConflict(entry, self.ownerOf(entry.path), false);
            };
        self.current_package = null;
        self.current_path = null;
    }

    fn plannedDirectory(self: *Builder, path: []const u8) bool {
        const owner = self.ownerOf(path) orelse return false;
        if (!self.removed(owner) and !self.replaced(owner)) return false;
        for (self.m.archives.items) |archive|
            if (archive.find(path)) |entry|
                if (entry.file.kind == .directory)
                    return true;
        return false;
    }

    fn canReplaceDirectory(self: *Builder, path: []const u8, old: ?Plan.Id) !bool {
        const directory = try std.fmt.allocPrint(self.a, "{s}/", .{path});
        var owners: std.ArrayList(Plan.Id) = .empty;
        for (self.m.locals.items) |item|
            if (self.owns(item.id, directory)) {
                if (old != item.id and !self.removed(item.id)) return false;
                try owners.append(self.a, item.id);
            };
        if (owners.items.len == 0) return false;
        return self.directoryOwned(path, owners.items);
    }

    fn directoryOwned(self: *Builder, path: []const u8, owners: []const Plan.Id) anyerror!bool {
        const fd = (try self.m.root.open(path, false)) orelse return true;
        defer _ = Root.c.close(fd);
        const held = try std.fmt.allocPrint(self.a, "/proc/{d}/fd/{d}", .{ Root.c.getpid(), fd });
        var dir = try std.Io.Dir.cwd().openDir(self.tx.io, held, .{ .iterate = true });
        defer dir.close(self.tx.io);
        var iterator = dir.iterate();
        while (try iterator.next(self.tx.io)) |entry| {
            try self.tx.owner.checkCancelled();
            const child = try std.fmt.allocPrint(self.a, "{s}/{s}", .{ path, entry.name });
            const before = (try self.observe(child)) orelse return error.StaleFilesystemState;
            const name = if (before.directory()) try std.fmt.allocPrint(self.a, "{s}/", .{child}) else child;
            var owned = false;
            for (owners) |id|
                if (self.owns(id, name)) {
                    owned = true;
                    break;
                };
            if (!owned) return false;
            if (before.directory() and !try self.directoryOwned(child, owners)) return false;
        }
        return true;
    }

    fn removePackage(self: *Builder, id: Plan.Id, replacement: ?Plan.Id) !void {
        const package = self.local(id);
        self.current_package = id;
        // Native removes deepest paths first; local inventories are sorted.
        var i = package.files.len;
        while (i != 0) {
            i -= 1;
            const file = package.files[i];
            const path = std.mem.trimEnd(u8, file.name, "/");
            self.current_path = path;
            var entry: Manifest.Entry = .{
                .package = id,
                .file = file,
                .path = path,
                .action = .remove,
                .before = try self.observe(path),
            };
            if (entry.before == null or try self.matches(.no_upgrade, file.name)) entry.action = .preserve;
            for (self.m.archives.items) |archive|
                if (archive.find(path)) |new| {
                    if (new.file.kind == .directory and entry.before != null and entry.before.?.directory())
                        entry.action = .shared_directory;
                    if (archive.id != replacement and !std.mem.endsWith(u8, file.name, "/"))
                        entry.action = .preserve; // transfer
                    if (archive.id == replacement and backupHash(archive.package, path) != .absent)
                        entry.action = .preserve;
                };
            if (entry.action == .remove and entry.before != null and entry.before.?.directory()) {
                for (self.m.locals.items) |item|
                    if (item.id != id and !self.removed(item.id) and
                        !self.replaced(item.id) and
                        self.owns(item.id, file.name))
                    {
                        entry.action = .shared_directory;
                        break;
                    };
                entry.remove_if_empty = true;
                const parent = try self.m.root.ancestor(path);
                defer _ = Root.c.close(parent);
                const parent_state = try Root.state(parent);
                if (parent_state.device != entry.before.?.device or
                    parent_state.mount_id != entry.before.?.mount_id)
                    entry.action = .preserve;
                // Existing nonempty directories may remain after removals. The
                // executor must use rmdir, never recursive deletion.
            }
            if (entry.action == .remove and entry.before != null and !entry.before.?.directory() and
                !self.tx.flags.no_save)
            {
                if (backupHash(package.*, path) == .hash) {
                    var hash: [32]u8 = undefined;
                    _ = try self.m.remember(path, true);
                    if (try self.m.root.hash(self.tx.io, path, &hash) and
                        !std.mem.eql(
                            u8,
                            &hash,
                            backupHash(package.*, path).hash,
                        ))
                    {
                        entry.action = .pacsave;
                        entry.destination = try std.fmt.allocPrint(self.a, "{s}.pacsave", .{path});
                        try self.rotatePacsave(entry.destination.?);
                    }
                }
            }
            try self.m.entries.append(self.a, entry);
            if (entry.action == .remove or entry.action == .pacsave)
                try self.cleared.put(self.a, entry.path, {});
        }
    }

    fn rotatePacsave(self: *Builder, destination: []const u8) !void {
        _ = try self.observe(destination);
        const parent = std.fs.path.dirname(destination) orelse ".";
        const fd = (try self.m.root.open(parent, true)) orelse return;
        defer _ = Root.c.close(fd);
        const held = try std.fmt.allocPrint(self.a, "/proc/{d}/fd/{d}", .{ Root.c.getpid(), fd });
        var dir = try std.Io.Dir.cwd().openDir(self.tx.io, held, .{ .iterate = true });
        defer dir.close(self.tx.io);
        const prefix = try std.fmt.allocPrint(self.a, "{s}.", .{std.fs.path.basename(destination)});
        var iterator = dir.iterate();
        // Avoid unbounded work from an adversarial numeric suffix; only existing
        // paths need rotation, descending by numeric suffix.
        var rotations: std.ArrayList(struct {
            number: u64,
            rotation: Manifest.Rotation,
        }) = .empty;
        iterator = dir.iterate();
        while (try iterator.next(self.tx.io)) |entry| {
            if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
            const number = std.fmt.parseInt(u64, entry.name[prefix.len..], 10) catch continue;
            if (number == 0 or number == std.math.maxInt(u64)) return error.InvalidBackup;
            const from = try std.fmt.allocPrint(self.a, "{s}.{d}", .{ destination, number });
            const to = try std.fmt.allocPrint(self.a, "{s}.{d}", .{ destination, number + 1 });
            _ = try self.observe(from);
            _ = try self.observe(to);
            try rotations.append(self.a, .{ .number = number, .rotation = .{ .from = from, .to = to } });
        }
        std.mem.sort(
            @TypeOf(rotations.items[0]),
            rotations.items,
            {},
            struct {
                fn less(_: void, left: @TypeOf(rotations.items[0]), right: @TypeOf(rotations.items[0])) bool {
                    return left.number > right.number;
                }
            }.less,
        );
        for (rotations.items) |rotation|
            try self.m.rotations.append(self.a, rotation.rotation);
        if (try self.m.root.inspect(destination, false) != null) {
            const to = try std.fmt.allocPrint(self.a, "{s}.1", .{destination});
            _ = try self.observe(to);
            try self.m.rotations.append(self.a, .{ .from = destination, .to = to });
        }
    }

    fn additions(self: *Builder, archive: Manifest.Archive) !void {
        for (archive.payload) |source| {
            self.current_package = archive.id;
            self.current_path = source.path;
            var entry = source;
            entry.before = try self.observe(entry.path);
            if (entry.file.kind == .symlink and backupHash(archive.package, entry.path) != .absent) {
                entry.new_hash = try self.hashLink(entry.path, entry.file.link_target.?, 0);
            }
            if (try self.matches(.no_extract, entry.file.name)) {
                entry.action = .no_extract;
            } else if (entry.before) |before| existing: {
                // Earlier removals determine whether extraction sees a file at
                // all. In particular an obsolete backup becomes pacsave, and
                // its replacement is installed without a second backup decision.
                if (self.cleared.contains(entry.path)) {
                    entry.action = .install;
                    break :existing;
                }
                entry.action = if (before.directory() and entry.file.kind == .directory)
                    .shared_directory
                else
                    .replace;
                if (entry.file.kind != .directory and !before.directory()) {
                    if (try self.matches(.no_upgrade, entry.file.name)) {
                        entry.action = .pacnew;
                    } else {
                        const old = if (self.oldOf(archive.id)) |id|
                            backupHash(self.local(id).*, entry.path)
                        else
                            .absent;
                        const new = backupHash(archive.package, entry.path);
                        if (old != .absent or new != .absent) {
                            var hash: [32]u8 = undefined;
                            _ = try self.m.remember(entry.path, true);
                            const local_hash: ?[]const u8 = if (try self.m.root.hash(
                                self.tx.io,
                                entry.path,
                                &hash,
                            ))
                                &hash
                            else
                                null;
                            entry.action = backupAction(
                                if (old == .hash) old.hash else null,
                                local_hash,
                                entry.new_hash,
                            );
                            if (entry.action == .preserve) {
                                const pacnew = try std.fmt.allocPrint(self.a, "{s}.pacnew", .{entry.path});
                                entry.refresh_existing_pacnew = try self.observe(pacnew) != null;
                                if (entry.refresh_existing_pacnew) entry.destination = pacnew;
                            }
                        }
                    }
                    if (entry.action == .pacnew)
                        entry.destination = try std.fmt.allocPrint(
                            self.a,
                            "{s}.pacnew",
                            .{entry.path},
                        );
                }
            }
            if (entry.destination) |destination| {
                if (try self.observe(destination)) |before|
                    if (before.directory()) {
                        var conflict = entry;
                        conflict.path = destination;
                        try self.addConflict(conflict, self.ownerOf(destination), false);
                        return error.FileConflicts;
                    };
            }
            if (entry.action == .install or entry.action == .replace or entry.action == .pacnew or
                entry.refresh_existing_pacnew)
            {
                var parents: std.ArrayList([]const u8) = .empty;
                var cursor: usize = 0;
                while (std.mem.indexOfScalarPos(u8, entry.path, cursor, '/')) |index| {
                    const prefix = entry.path[0..index];
                    if (!self.created_directories.contains(prefix) and
                        (self.cleared.contains(prefix) or
                            try self.m.root.inspect(prefix, true) == null))
                    {
                        try parents.append(self.a, prefix);
                        try self.created_directories.put(self.a, prefix, {});
                    }
                    cursor = index + 1;
                }
                entry.create_parents = parents.items;
                if (entry.file.kind == .directory) try self.created_directories.put(self.a, entry.path, {});
            }
            try self.m.entries.append(self.a, entry);
        }
        self.current_package = null;
        self.current_path = null;
    }

    fn databaseChanges(self: *Builder) !void {
        for (self.m.locals.items) |installed|
            _ = try LocalWriter.recordName(
                self.a,
                &installed.package,
            );
        for (self.plan.removals) |id|
            try self.m.database_changes.append(
                self.a,
                .{
                    .package = id,
                    .old = id,
                    .remove = true,
                    .files = &.{},
                    .backups = &.{},
                    .reason = null,
                    .installed_database = null,
                },
            );
        for (self.plan.additions, self.m.archives.items) |addition, archive| {
            const files = try self.a.alloc(File, archive.payload.len);
            for (files, archive.payload) |*file, entry|
                file.* = entry.file;
            std.mem.sort(File, files, {}, fileLess);
            const backups = try self.a.alloc(BackupFile, archive.package.backups.len);
            for (backups, archive.package.backups) |*backup, original| {
                backup.* = .{ .name = original.name, .hash = null };
                const entry = archive.find(original.name) orelse continue;
                if (!self.tx.flags.database_only and !try self.matches(.no_extract, entry.file.name))
                    backup.hash = entry.new_hash;
                if (entry.file.kind == .symlink)
                    for (self.m.entries.items) |effect| {
                        if (effect.package == archive.id and effect.archive_index != null and
                            std.mem.eql(u8, effect.path, original.name))
                            backup.hash = effect.new_hash;
                    };
            }
            try self.m.database_changes.append(
                self.a,
                .{
                    .package = addition.package,
                    .old = addition.old,
                    .remove = false,
                    .files = files,
                    .backups = backups,
                    .reason = addition.reason,
                    .installed_database = addition.installed_database,
                },
            );
        }
    }

    fn hashLink(self: *Builder, path: []const u8, link: []const u8, depth: usize) anyerror!?[]const u8 {
        if (depth >= 40) return error.UnsafeSymlink;
        const absolute = try std.fs.path.resolvePosix(
            self.a,
            &.{
                "/",
                std.fs.path.dirname(path) orelse ".",
                link,
            },
        );
        const target = if (absolute.len == 1) "." else absolute[1..];
        // Resolve against effects already preceding this archive header. Later
        // writes cannot change the hash recorded at the native extraction point.
        var index = self.m.entries.items.len;
        while (index != 0) {
            index -= 1;
            const entry = self.m.entries.items[index];
            if (!std.mem.eql(u8, entry.path, target)) continue;
            switch (entry.action) {
                .remove, .pacsave => return null,
                .install, .replace => {
                    if (entry.file.kind == .symlink)
                        return self.hashLink(
                            entry.path,
                            entry.file.link_target.?,
                            depth + 1,
                        );
                    return entry.new_hash;
                },
                .shared_directory => return null,
                else => {},
            }
        }
        _ = try self.observe(target);
        _ = try self.m.remember(target, true);
        var hash: [32]u8 = undefined;
        return if (try self.m.root.hash(self.tx.io, target, &hash)) try self.a.dupe(u8, &hash) else null;
    }

    fn space(self: *Builder) !void {
        for (self.m.entries.items) |entry| {
            self.current_package = entry.package;
            self.current_path = entry.path;
            if (entry.action == .no_extract or entry.action == .shared_directory or
                (entry.action == .preserve and
                    !entry.refresh_existing_pacnew))
                continue;
            for (entry.create_parents) |parent_path| {
                const ancestor = try self.m.root.ancestor(parent_path);
                defer _ = Root.c.close(ancestor);
                const cap = Root.capacity(ancestor) catch |err| {
                    try self.m.warnings.append(
                        self.a,
                        .{
                            .cause = err,
                            .package = entry.package,
                            .path = parent_path,
                        },
                    );
                    continue;
                };
                if (cap.read_only) return error.ReadOnlyFilesystem;
                const bucket = try self.spaceBucket(parent_path, false, cap);
                bucket.delta += 1;
                bucket.peak = @max(bucket.peak, @as(u64, @intCast(@max(0, bucket.delta))));
            }
            const path = entry.destination orelse entry.path;
            const fd = try self.m.root.ancestor(path);
            defer _ = Root.c.close(fd);
            try self.m.root.access(path);
            const cap = Root.capacity(fd) catch |err| {
                try self.m.warnings.append(self.a, .{
                    .cause = err,
                    .package = entry.package,
                    .path = path,
                });
                continue;
            };
            if (cap.read_only) return error.ReadOnlyFilesystem;
            const bucket = try self.spaceBucket(path, false, cap);
            if (entry.action == .remove) {
                if (entry.before) |before|
                    if (before.regular()) {
                        bucket.delta -= blocks(before.size, cap.block_size);
                    };
            } else if (entry.action != .pacsave) {
                const needed = if (entry.file.kind == .regular)
                    blocks(
                        entry.file.size orelse 0,
                        cap.block_size,
                    )
                else if (entry.file.kind == .directory or
                    entry.file.kind == .symlink)
                    @as(u64, 1)
                else
                    0;
                // Reserve the temporary output before crediting a replacement.
                bucket.peak = @max(bucket.peak, @as(u64, @intCast(@max(0, bucket.delta + needed))));
                bucket.delta += needed;
                if (entry.action == .replace) {
                    if (entry.before) |before|
                        if (before.regular()) {
                            bucket.delta -= blocks(before.size, cap.block_size);
                        };
                }
            }
        }
        for (self.m.rotations.items) |rotation| {
            try self.m.root.access(rotation.from);
            try self.m.root.access(rotation.to);
        }
        // Local records and staged record publication use the DB filesystem,
        // which may differ from the root. Reserve metadata plus inventory bytes.
        if (self.m.database_changes.items.len != 0) db_space: {
            try Root.writable(self.m.database.fd);
            const cap = Root.capacity(self.m.database.fd) catch |err| {
                try self.m.warnings.append(
                    self.a,
                    .{
                        .cause = err,
                        .path = self.tx.owner.configuration.database_path,
                    },
                );
                break :db_space;
            };
            const bucket = try self.spaceBucket("local/record", true, cap);
            if (cap.read_only) return error.ReadOnlyFilesystem;
            for (self.m.archives.items) |archive| {
                var package = archive.package;
                for (self.m.database_changes.items) |change|
                    if (change.package == archive.id) {
                        package.files = change.files;
                        package.backups = change.backups;
                        package.install_reason = change.reason;
                        package.installed_database = change.installed_database;
                    };
                package.install_date = @intCast(std.Io.Clock.real.now(self.tx.io).toSeconds());
                _ = try LocalWriter.recordName(self.a, &package);
                const desc = try LocalWriter.description(self.a, &package);
                const files = try LocalWriter.files(self.a, &package);
                // Actual serialized members, separately rounded blocks, plus
                // record/staging directories and the rollback journal.
                var size: u64 = 4 * cap.block_size;
                size = try std.math.add(
                    u64,
                    size,
                    (blocks(desc.len, cap.block_size) + blocks(files.len, cap.block_size)) * cap.block_size,
                );
                for (archive.metadata) |entry|
                    if (!std.mem.eql(u8, entry.path, ".PKGINFO")) {
                        size = try std.math.add(
                            u64,
                            size,
                            blocks(entry.file.size orelse 0, cap.block_size) * cap.block_size,
                        );
                    };
                bucket.delta += blocks(size, cap.block_size);
                bucket.peak = @max(bucket.peak, @as(u64, @intCast(@max(0, bucket.delta))));
            }
        }
        if (self.tx.owner.configuration.check_space)
            for (self.m.spaces.items) |space_info|
                try Manifest.checkCapacity(
                    space_info.capacity,
                    space_info.peak,
                );
        self.current_package = null;
        self.current_path = null;
    }

    fn spaceBucket(self: *Builder, path: []const u8, database: bool, cap: Root.Capacity) !*Manifest.Space {
        for (self.m.spaces.items) |*space_info|
            if (space_info.capacity.device == cap.device)
                return space_info;
        try self.m.spaces.append(self.a, .{
            .path = path,
            .database = database,
            .capacity = cap,
        });
        return &self.m.spaces.items[self.m.spaces.items.len - 1];
    }
};

fn blocks(size: u64, block: u64) u64 {
    return size / block + @intFromBool(size % block != 0);
}

fn fileLess(_: void, left: File, right: File) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}

const Backup = union(enum) { absent, unhashed, hash: []const u8 };

fn backupHash(package: Package, name: []const u8) Backup {
    for (package.backups) |backup|
        if (std.mem.eql(u8, backup.name, name))
            return if (backup.hash) |hash|
                .{ .hash = hash }
            else
                .unhashed;
    return .absent;
}

pub fn backupAction(old: ?[]const u8, local: ?[]const u8, new: ?[]const u8) Manifest.Action {
    if (equalOptional(local, new)) return .replace;
    if (equalOptional(old, new)) return .preserve;
    if (equalOptional(old, local)) return .replace;
    return .pacnew;
}

fn equalOptional(left: ?[]const u8, right: ?[]const u8) bool {
    return left != null and right != null and std.mem.eql(u8, left.?, right.?);
}

fn metadataMatches(expected: *const Package, actual: *const Package) !void {
    if (!std.mem.eql(u8, expected.name, actual.name) or
        !std.mem.eql(
            u8,
            expected.version.raw,
            actual.version.raw,
        ))
        return error.PackageIdentityMismatch;
    if (expected.installed_size != actual.installed_size or
        !optionalStringsEqual(
            expected.architecture,
            actual.architecture,
        ))
        return error.PackageMetadataMismatch;
    inline for (.{ "depends", "provides", "conflicts", "replaces" }) |field| {
        const left = @field(expected, field);
        const right = @field(actual, field);
        if (left.len != right.len) return error.PackageMetadataMismatch;
        for (left) |relation| {
            var wanted: usize = 0;
            var found: usize = 0;
            for (left) |other|
                if (relationsEqual(relation, other)) {
                    wanted += 1;
                };
            for (right) |other|
                if (relationsEqual(relation, other)) {
                    found += 1;
                };
            if (wanted != found) return error.PackageMetadataMismatch;
        }
    }
    if (expected.groups.len != actual.groups.len) return error.PackageMetadataMismatch;
    for (expected.groups) |group| {
        var wanted: usize = 0;
        var found: usize = 0;
        for (expected.groups) |other|
            if (std.mem.eql(u8, group, other)) {
                wanted += 1;
            };
        for (actual.groups) |other|
            if (std.mem.eql(u8, group, other)) {
                found += 1;
            };
        if (wanted != found) return error.PackageMetadataMismatch;
    }
}

fn optionalStringsEqual(left: ?[]const u8, right: ?[]const u8) bool {
    return (left == null and right == null) or equalOptional(left, right);
}

fn relationsEqual(
    left: PackageRelation,
    right: PackageRelation,
) bool {
    if (!std.mem.eql(u8, left.name, right.name) or
        std.meta.activeTag(left.constraint) != std.meta.activeTag(right.constraint))
        return false;
    return switch (left.constraint) {
        .any => true,
        inline else => |value, tag| std.mem.eql(u8, value, @field(right.constraint, @tagName(tag))),
    };
}
