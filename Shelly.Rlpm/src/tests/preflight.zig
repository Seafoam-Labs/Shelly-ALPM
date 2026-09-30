//! Hermetic preflight fixtures. Only the fixture builder writes the private roots;
//! RLPM preflight must never mutate installed payloads or local records.
const std = @import("std");
const rlpm = @import("Shelly_Rlpm");
const Archive = @import("archive_fixture.zig");

const a = std.testing.allocator;
const io = std.testing.io;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: [:0]u8,
    db: [:0]u8,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io, "root");
        try tmp.dir.createDirPath(io, "db/local");
        try tmp.dir.writeFile(io, .{ .sub_path = "db/local/ALPM_DB_VERSION", .data = "9\n" });
        const root = try tmp.dir.realPathFileAlloc(io, "root", a);
        errdefer a.free(root);
        return .{
            .tmp = tmp,
            .root = root,
            .db = try tmp.dir.realPathFileAlloc(io, "db", a),
        };
    }

    fn deinit(self: *Fixture) void {
        a.free(self.root);
        a.free(self.db);
        self.tmp.cleanup();
    }

    fn owner(self: *Fixture, allocator: std.mem.Allocator) !rlpm.Owner {
        return rlpm.Owner.init(io, allocator, .{ .root = self.root, .database_path = self.db }, &.{});
    }

    fn installed(self: *Fixture, name: []const u8, files: []const u8, backups: []const u8) !void {
        const dir = try std.fmt.allocPrint(a, "db/local/{s}-1-1", .{name});
        defer a.free(dir);
        try self.tmp.dir.createDirPath(io, dir);
        const desc_path = try std.fmt.allocPrint(a, "{s}/desc", .{dir});
        defer a.free(desc_path);
        const desc = try std.fmt.allocPrint(a, "%NAME%\n{s}\n\n%VERSION%\n1-1\n\n%REASON%\n0\n\n", .{name});
        defer a.free(desc);
        try self.tmp.dir.writeFile(io, .{ .sub_path = desc_path, .data = desc });
        const file_path = try std.fmt.allocPrint(a, "{s}/files", .{dir});
        defer a.free(file_path);
        const data = try std.fmt.allocPrint(a, "%FILES%\n{s}\n\n%BACKUP%\n{s}\n\n", .{ files, backups });
        defer a.free(data);
        try self.tmp.dir.writeFile(io, .{ .sub_path = file_path, .data = data });
    }

    fn write(self: *Fixture, name: []const u8, bytes: []const u8) !void {
        const path = try std.fmt.allocPrint(a, "root/{s}", .{name});
        defer a.free(path);
        if (std.fs.path.dirname(path)) |parent| try self.tmp.dir.createDirPath(io, parent);
        try self.tmp.dir.writeFile(io, .{ .sub_path = path, .data = bytes });
    }
};

fn add(tx: *rlpm.Transaction, path: []const u8) !void {
    var package: ?rlpm.Package = try tx.owner.loadPackage(io, path, .local_file, .{});
    defer if (package) |*value| value.deinit();
    try tx.takeArchive(&package);
}

fn effect(manifest: *const rlpm.ExecutionManifest, path: []const u8, addition: bool) !rlpm.ExecutionManifest.Entry {
    for (manifest.entries.items) |entry|
        if ((entry.archive_index != null) == addition and
            std.mem.eql(u8, path, entry.path))
            return entry;
    return error.MissingEffect;
}
const info = "pkgname = demo\npkgver = 2-1\narch = any\n";

test "full sealed stream creates payload metadata database and link manifests without mutation" {
    var f = try Fixture.init();
    defer f.deinit();
    var archive = try Archive.init(&.{
        .{ .path = ".PKGINFO", .contents = info },
        .{
            .path = ".INSTALL",
            .contents = "post_install() { :; }",
        },
        .{ .path = "usr/", .kind = .directory },
        .{
            .path = "usr/data",
            .contents = "payload",
        },
        .{
            .path = "usr/link",
            .kind = .symlink,
            .target = "/usr/data",
        },
        .{
            .path = "usr/hard",
            .kind = .hardlink,
            .target = "usr/data",
        },
    }, .zstd);
    defer archive.deinit();
    var owner = try f.owner(a);
    defer owner.deinit() catch unreachable;
    const tx = try owner.initializeTransaction(io, .{});
    defer owner.releaseTransaction() catch unreachable;
    try add(tx, archive.path);
    try tx.prepare();
    // A replacement pathname must not replace the bytes selected by prepare.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = archive.path, .data = "changed after verification" });
    try tx.preflight();
    const manifest = tx.manifest().?;
    try std.testing.expect(manifest.complete);
    try std.testing.expectEqual(4, manifest.entries.items.len);
    try std.testing.expectEqual(2, manifest.archives.items[0].metadata.len);
    try std.testing.expectEqualStrings(
        "/usr/data",
        (try effect(manifest, "usr/link", true)).file.link_target.?,
    );
    try std.testing.expectEqualStrings(
        (try effect(manifest, "usr/data", true)).new_hash.?,
        (try effect(manifest, "usr/hard", true)).new_hash.?,
    );
    try std.testing.expectEqual(4, manifest.database_changes.items[0].files.len);
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.access(io, "root/usr/data", .{}));
    try tx.revalidatePreflight();
    try std.testing.expectEqual(.prepared, tx.state); // Read-only preflight boundary.
}

test "ordered patterns match native slash dot negation escaping and directory behavior" {
    const cases = [_]struct {
        patterns: []const []const u8,
        path: []const u8,
        result: rlpm.PathPatterns.Match,
    }{
        .{
            .patterns = &.{"usr/*"},
            .path = "usr/share/.hidden",
            .result = .matched,
        },
        .{
            .patterns = &.{ "*", "!etc/*", "etc/keep" },
            .path = "etc/keep",
            .result = .matched,
        },
        .{
            .patterns = &.{ "*", "!etc/*" },
            .path = "etc/conf",
            .result = .excluded,
        },
        .{
            .patterns = &.{"\\!literal"},
            .path = "!literal",
            .result = .matched,
        },
        .{
            .patterns = &.{"usr"},
            .path = "usr/",
            .result = .unmatched,
        },
        .{
            .patterns = &.{"etc/[ab]?"},
            .path = "etc/a1",
            .result = .matched,
        },
    };
    for (cases) |case|
        try std.testing.expectEqual(
            case.result,
            try rlpm.PathPatterns.match(
                a,
                case.patterns,
                case.path,
            ),
        );
    var f = try Fixture.init();
    defer f.deinit();
    var owner = try f.owner(a);
    defer owner.deinit() catch unreachable;
    try owner.setList(io, .no_extract, &.{ "etc/*", "!etc/keep" });
    try owner.setList(io, .no_upgrade, &.{"*.conf"});
    try std.testing.expectEqual(.excluded, try owner.matchNoExtract("etc/keep"));
    try std.testing.expectEqual(.matched, try owner.matchNoUpgrade("etc/app.conf"));
}

test "unowned and target conflicts survive NOCONFLICTS and NoExtract; overwrite resolves files" {
    for ([_]bool{ false, true }) |overwrite| {
        var f = try Fixture.init();
        defer f.deinit();
        try f.write("same", "unowned");
        var first = try Archive.init(
            &.{
                .{ .path = ".PKGINFO", .contents = info },
                .{ .path = "same", .contents = "one" },
            },
            .none,
        );
        defer first.deinit();
        var second = try Archive.init(
            &.{
                .{
                    .path = ".PKGINFO",
                    .contents = "pkgname = other\npkgver = 1-1\narch = any\n",
                },
                .{ .path = "same", .contents = "two" },
            },
            .none,
        );
        defer second.deinit();
        var owner = try f.owner(a);
        defer owner.deinit() catch unreachable;
        try owner.setList(io, .no_extract, &.{"same"});
        if (overwrite) try owner.setList(io, .overwrite_files, &.{"same"});
        const tx = try owner.initializeTransaction(io, .{ .no_conflicts = true });
        defer owner.releaseTransaction() catch unreachable;
        try add(tx, first.path);
        try add(tx, second.path);
        try tx.prepare();
        if (overwrite) {
            try tx.preflight();
            try std.testing.expectEqual(.no_extract, (try effect(tx.manifest().?, "same", true)).action);
            try std.testing.expectEqualStrings(
                "same",
                tx.manifest().?.database_changes.items[0].files[0].name,
            );
        } else {
            try std.testing.expectError(error.FileConflicts, tx.preflight());
            try std.testing.expectEqual(.file_conflict, owner.diagnostic().?.category);
            try std.testing.expect(tx.manifest().?.conflicts.items.len >= 2);
            for (tx.manifest().?.conflicts.items) |conflict|
                try std.testing.expectEqualStrings(
                    "same",
                    conflict.path,
                );
        }
    }
}

test "backups compare original local new contents and NoUpgrade always creates pacnew" {
    const cases = [_]struct {
        old: []const u8,
        local: []const u8,
        new: []const u8,
        noupgrade: bool = false,
        expected: rlpm.ExecutionManifest.Action,
    }{
        .{
            .old = "old",
            .local = "old",
            .new = "new",
            .expected = .replace,
        },
        .{
            .old = "old",
            .local = "edited",
            .new = "old",
            .expected = .preserve,
        },
        .{
            .old = "old",
            .local = "new",
            .new = "new",
            .expected = .replace,
        },
        .{
            .old = "old",
            .local = "edited",
            .new = "new",
            .expected = .pacnew,
        },
        .{
            .old = "old",
            .local = "old",
            .new = "old",
            .noupgrade = true,
            .expected = .pacnew,
        },
    };
    for (cases) |case| {
        var f = try Fixture.init();
        defer f.deinit();
        const backup = try std.fmt.allocPrint(a, "etc/conf\t{s}", .{rlpm.Checksum.bytes(.md5, case.old)});
        defer a.free(backup);
        try f.installed("demo", "etc/\netc/conf", backup);
        try f.write("etc/conf", case.local);
        var archive = try Archive.init(
            &.{
                .{ .path = ".PKGINFO", .contents = info ++ "backup = etc/conf\n" },
                .{ .path = "etc/", .kind = .directory },
                .{ .path = "etc/conf", .contents = case.new },
            },
            .none,
        );
        defer archive.deinit();
        var owner = try f.owner(a);
        defer owner.deinit() catch unreachable;
        if (case.noupgrade) try owner.setList(io, .no_upgrade, &.{"etc/conf"});
        const tx = try owner.initializeTransaction(io, .{});
        defer owner.releaseTransaction() catch unreachable;
        try add(tx, archive.path);
        try tx.prepare();
        try tx.preflight();
        try std.testing.expectEqual(case.expected, (try effect(tx.manifest().?, "etc/conf", true)).action);
        try std.testing.expectEqualStrings(
            &rlpm.Checksum.bytes(.md5, case.new),
            tx.manifest().?.database_changes.items[0].backups[0].hash.?,
        );
        const unchanged = try f.tmp.dir.readFileAlloc(io, "root/etc/conf", a, .limited(100));
        defer a.free(unchanged);
        try std.testing.expectEqualStrings(case.local, unchanged);
    }
}

test "removal pacsave rotation NOSAVE and file transfers preserve the new owner" {
    for ([_]bool{ false, true }) |no_save| {
        var f = try Fixture.init();
        defer f.deinit();
        try f.installed("old", "conf\ntransfer", "conf\t149603e6c03516362a8da23f624db945");
        try f.write("conf", "edited");
        try f.write("conf.pacsave", "prior");
        try f.write("conf.pacsave.2", "older");
        try f.write("transfer", "old");
        var archive = try Archive.init(
            &.{
                .{ .path = ".PKGINFO", .contents = info },
                .{ .path = "transfer", .contents = "new" },
            },
            .none,
        );
        defer archive.deinit();
        var owner = try f.owner(a);
        defer owner.deinit() catch unreachable;
        const tx = try owner.initializeTransaction(io, .{ .no_save = no_save });
        defer owner.releaseTransaction() catch unreachable;
        try tx.remove("old");
        try add(tx, archive.path);
        try tx.prepare();
        try tx.preflight();
        try std.testing.expectEqual(
            if (no_save) rlpm.ExecutionManifest.Action.remove else .pacsave,
            (try effect(tx.manifest().?, "conf", false)).action,
        );
        try std.testing.expectEqual(if (no_save) @as(usize, 0) else 2, tx.manifest().?.rotations.items.len);
        try std.testing.expectEqual(.preserve, (try effect(tx.manifest().?, "transfer", false)).action);
    }
}

test "directory transitions reject unowned descendants and allow owned tree removal" {
    for ([_]bool{ false, true }) |unowned| {
        var f = try Fixture.init();
        defer f.deinit();
        try f.installed("demo", "node/\nnode/owned", "");
        try f.write("node/owned", "old");
        if (unowned) try f.write("node/unowned", "keep");
        var archive = try Archive.init(
            &.{
                .{ .path = ".PKGINFO", .contents = info },
                .{
                    .path = "node",
                    .contents = "replacement",
                },
            },
            .none,
        );
        defer archive.deinit();
        var owner = try f.owner(a);
        defer owner.deinit() catch unreachable;
        try owner.setList(io, .overwrite_files, &.{"*"});
        const tx = try owner.initializeTransaction(io, .{});
        defer owner.releaseTransaction() catch unreachable;
        try add(tx, archive.path);
        try tx.prepare();
        if (unowned)
            try std.testing.expectError(error.FileConflicts, tx.preflight())
        else
            try tx.preflight();
    }
    var f = try Fixture.init();
    defer f.deinit();
    try f.installed("demo", "node", "");
    try f.write("node", "old");
    var archive = try Archive.init(
        &.{
            .{ .path = ".PKGINFO", .contents = info }, .{ .path = "node/", .kind = .directory },
            .{
                .path = "node/new",
                .contents = "payload",
            },
        },
        .none,
    );
    defer archive.deinit();
    var owner = try f.owner(a);
    defer owner.deinit() catch unreachable;
    const tx = try owner.initializeTransaction(io, .{});
    defer owner.releaseTransaction() catch unreachable;
    try add(tx, archive.path);
    try tx.prepare();
    try tx.preflight();
}

test "missing backup members retain unhashed metadata without inventing payloads" {
    for ([_]bool{ false, true }) |database_only| {
        var f = try Fixture.init();
        defer f.deinit();
        try f.write("etc/missing", "unowned configuration");
        var archive = try Archive.init(
            &.{
                .{ .path = ".PKGINFO", .contents = info ++ "backup = etc/missing\nbackup = etc/present\n" },
                .{ .path = ".MTREE", .contents = "#mtree\n./etc/present type=file\n" },
                .{ .path = "etc/present", .contents = "configuration" },
            },
            .zstd,
        );
        defer archive.deinit();
        var owner = try f.owner(a);
        defer owner.deinit() catch unreachable;
        const tx = try owner.initializeTransaction(io, .{ .database_only = database_only });
        defer owner.releaseTransaction() catch unreachable;
        try add(tx, archive.path);
        try tx.prepare();
        try tx.preflight();
        const manifest = tx.manifest().?;
        const change = manifest.database_changes.items[0];
        try std.testing.expectEqual(1, change.files.len);
        try std.testing.expectEqual(2, change.backups.len);
        try std.testing.expectEqualStrings("etc/missing", change.backups[0].name);
        try std.testing.expect(change.backups[0].hash == null);
        try std.testing.expectEqual(database_only, change.backups[1].hash == null);
        try std.testing.expectError(error.MissingEffect, effect(manifest, "etc/missing", true));
        const untouched = try f.tmp.dir.readFileAlloc(io, "root/etc/missing", a, .limited(100));
        defer a.free(untouched);
        try std.testing.expectEqualStrings("unowned configuration", untouched);
    }
}

test "absent backup paths still reject traversal" {
    var f = try Fixture.init();
    defer f.deinit();
    var archive = try Archive.init(
        &.{.{ .path = ".PKGINFO", .contents = info ++ "backup = ../outside\n" }},
        .none,
    );
    defer archive.deinit();
    var owner = try f.owner(a);
    defer owner.deinit() catch unreachable;
    const tx = try owner.initializeTransaction(io, .{});
    defer owner.releaseTransaction() catch unreachable;
    try add(tx, archive.path);
    try tx.prepare();
    try std.testing.expectError(error.UnsafeArchivePath, tx.preflight());
    try std.testing.expectEqualStrings("../outside", tx.manifest().?.failure.?.path.?);
}

test "archive traversal hardlink escape duplicate entries and lying mtree are rejected" {
    const cases = [_]struct {
        entry: Archive.Entry,
        expected: anyerror,
    }{
        .{ .entry = .{ .path = "../escape", .contents = "bad" }, .expected = error.UnsafeArchivePath },
        .{ .entry = .{ .path = "/absolute", .contents = "bad" }, .expected = error.UnsafeArchivePath },
        .{ .entry = .{ .path = "usr/../escape", .contents = "bad" }, .expected = error.UnsafeArchivePath },
        .{
            .entry = .{
                .path = "hard",
                .kind = .hardlink,
                .target = "../outside",
            },
            .expected = error.UnsafeArchivePath,
        },
        .{
            .entry = .{
                .path = "hard",
                .kind = .hardlink,
                .target = "absent",
            },
            .expected = error.UnsafeHardlink,
        },
        .{ .entry = .{ .path = "data", .contents = "duplicate" }, .expected = error.DuplicateArchivePath },
        .{
            .entry = .{ .path = ".MTREE", .contents = "#mtree\n./ghost type=file size=4 mode=644\n" },
            .expected = error.ArchiveInventoryMismatch,
        },
    };
    for (cases) |case| {
        var f = try Fixture.init();
        defer f.deinit();
        var archive = try Archive.init(
            &.{
                .{ .path = ".PKGINFO", .contents = info },
                .{ .path = "data", .contents = "okay" },
                case.entry,
            },
            .none,
        );
        defer archive.deinit();
        var owner = try f.owner(a);
        defer owner.deinit() catch unreachable;
        const tx = try owner.initializeTransaction(io, .{});
        defer owner.releaseTransaction() catch unreachable;
        try add(tx, archive.path);
        try tx.prepare();
        try std.testing.expectError(case.expected, tx.preflight());
        try std.testing.expect(tx.manifest().?.failure.?.package != null);
    }
}

test "existing absolute directory links are confined and filesystem changes invalidate review" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.createDirPath(io, "root/usr/bin");
    try f.tmp.dir.symLink(io, "/usr/bin", "root/bin", .{});
    var archive = try Archive.init(
        &.{
            .{ .path = ".PKGINFO", .contents = info },
            .{
                .path = "bin/rlpm-hermetic-only",
                .contents = "new",
            },
        },
        .none,
    );
    defer archive.deinit();
    var owner = try f.owner(a);
    defer owner.deinit() catch unreachable;
    const tx = try owner.initializeTransaction(io, .{});
    defer owner.releaseTransaction() catch unreachable;
    try add(tx, archive.path);
    try tx.prepare();
    try tx.preflight();
    try tx.revalidatePreflight();
    try f.tmp.dir.deleteFile(io, "root/bin");
    try f.tmp.dir.symLink(io, "/tmp", "root/bin", .{});
    try std.testing.expectError(error.StaleFilesystemState, tx.revalidatePreflight());
    try std.testing.expectError(error.StaleFilesystemState, tx.manifest().?.check());
}

test "DBONLY keeps file inventory but bypasses payload conflicts and effects" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("data", "unowned");
    var archive = try Archive.init(
        &.{
            .{ .path = ".PKGINFO", .contents = info },
            .{ .path = "data", .contents = "new" },
        },
        .none,
    );
    defer archive.deinit();
    var owner = try f.owner(a);
    defer owner.deinit() catch unreachable;
    const tx = try owner.initializeTransaction(io, .{ .database_only = true });
    defer owner.releaseTransaction() catch unreachable;
    try add(tx, archive.path);
    try tx.prepare();
    try tx.preflight();
    try std.testing.expectEqual(0, tx.manifest().?.entries.items.len);
    try std.testing.expectEqual(1, tx.manifest().?.database_changes.items[0].files.len);
}

test "check-space cushion boundary and read-only filesystems" {
    const cap: rlpm.ExecutionManifest.Capacity = .{
        .device = 1,
        .block_size = 4096,
        .available = 60,
        .total = 1000,
        .read_only = false,
    };
    try rlpm.ExecutionManifest.checkCapacity(cap, 9);
    try std.testing.expectError(error.DiskSpaceInsufficient, rlpm.ExecutionManifest.checkCapacity(cap, 10));
    var read_only = cap;
    read_only.read_only = true;
    try std.testing.expectError(
        error.ReadOnlyFilesystem,
        rlpm.ExecutionManifest.checkCapacity(read_only, 0),
    );
}

test "pinned libalpm oracle replays backup pattern conflict and installed inventory decisions" {
    const Case = struct {
        name: []const u8,
        old: ?[]const u8 = null,
        local: ?[]const u8 = null,
        new: []const u8,
        backup: bool = false,
        oldbackup: bool = false,
        pacnew: ?[]const u8 = null,
        noupgrade: []const []const u8 = &.{},
        noextract: []const []const u8 = &.{},
        overwrite: []const []const u8 = &.{},
        noconflicts: bool = false,
        @"error": ?[]const u8,
        contents: struct {
            conf: ?[]const u8,
            @"conf.pacnew": ?[]const u8,
            @"conf.pacsave": ?[]const u8,
        },
        inventory: ?[]const u8,
    };
    const oracle = try std.json.parseFromSlice(
        struct {
            library_sha256: []const u8,
            cases: []const Case,
        },
        a,
        @embedFile("reference/preflight.json"),
        .{},
    );
    defer oracle.deinit();
    try std.testing.expectEqualStrings(
        "da30edd45277cf4b1000485658976042f8106fe0b97378d1e6c4e81a9d7c4888",
        oracle.value.library_sha256,
    );
    for (oracle.value.cases) |case| {
        var f = try Fixture.init();
        defer f.deinit();
        if (case.old) |old| {
            const backup = if (case.backup or case.oldbackup)
                try std.fmt.allocPrint(
                    a,
                    "conf\t{s}",
                    .{rlpm.Checksum.bytes(.md5, old)},
                )
            else
                try a.dupe(u8, "");
            defer a.free(backup);
            try f.installed("demo", "conf", backup);
        }
        if (case.local) |bytes| try f.write("conf", bytes);
        if (case.pacnew) |bytes| try f.write("conf.pacnew", bytes);
        var archive = try Archive.init(
            &.{
                .{
                    .path = ".PKGINFO",
                    .contents = if (case.backup)
                        info ++ "backup = conf\n"
                    else
                        info,
                },
                .{ .path = "conf", .contents = case.new },
            },
            .none,
        );
        defer archive.deinit();
        var owner = try f.owner(a);
        defer owner.deinit() catch unreachable;
        try owner.setList(io, .no_extract, case.noextract);
        try owner.setList(io, .no_upgrade, case.noupgrade);
        try owner.setList(io, .overwrite_files, case.overwrite);
        const tx = try owner.initializeTransaction(io, .{ .no_conflicts = case.noconflicts });
        defer owner.releaseTransaction() catch unreachable;
        try add(tx, archive.path);
        try tx.prepare();
        if (case.@"error" != null) {
            try std.testing.expectError(error.FileConflicts, tx.preflight());
            continue;
        }
        try tx.preflight();
        const entry = try effect(tx.manifest().?, "conf", true);
        // Project manifest decisions into values; no payload executor is used.
        var final = case.local;
        var pacnew = case.pacnew;
        var pacsave: ?[]const u8 = null;
        if (case.old != null) {
            const removal = try effect(tx.manifest().?, "conf", false);
            if (removal.action == .remove or removal.action == .pacsave) final = null;
            if (removal.action == .pacsave) pacsave = case.local;
        }
        switch (entry.action) {
            .install, .replace => final = case.new,
            .pacnew => pacnew = case.new,
            .preserve => if (entry.refresh_existing_pacnew) {
                pacnew = case.new;
            },
            .no_extract => {},
            else => return error.UnexpectedAction,
        }
        try std.testing.expectEqualDeep(case.contents.conf, final);
        try std.testing.expectEqualDeep(case.contents.@"conf.pacnew", pacnew);
        try std.testing.expectEqualDeep(case.contents.@"conf.pacsave", pacsave);
        const change = tx.manifest().?.database_changes.items[0];
        try std.testing.expectEqualStrings("conf", change.files[0].name);
        if (case.backup)
            try std.testing.expect(
                std.mem.indexOf(
                    u8,
                    case.inventory.?,
                    change.backups[0].hash.?,
                ) != null,
            );
    }
}

fn allocationPreflight(allocator: std.mem.Allocator, fixture: *Fixture, path: []const u8) !void {
    var owner = try fixture.owner(allocator);
    defer owner.deinit() catch unreachable;
    const tx = try owner.initializeTransaction(io, .{});
    defer owner.releaseTransaction() catch unreachable;
    try add(tx, path);
    try tx.prepare();
    try tx.preflight();
}
test "every allocation failure releases archives root descriptors manifest and lock" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.installed("demo", "conf", "conf\t149603e6c03516362a8da23f624db945");
    try f.write("conf", "edited");
    var archive = try Archive.init(
        &.{
            .{ .path = ".PKGINFO", .contents = info ++ "backup = conf\n" },
            .{ .path = "conf", .contents = "new" },
        },
        .none,
    );
    defer archive.deinit();
    try std.testing.checkAllAllocationFailures(a, allocationPreflight, .{ &f, archive.path });
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.access(io, "db/db.lck", .{}));
}

test "metadata-only targets are reloaded and cannot change identity dependencies or source policy" {
    const cases = [_]struct {
        original: []const u8 = info,
        replacement: []const u8,
        expected: anyerror,
        required: bool = false,
    }{
        .{
            .replacement = "pkgname = other\npkgver = 2-1\narch = any\n",
            .expected = error.PackageIdentityMismatch,
        },
        .{ .replacement = info ++ "depend = injected\n", .expected = error.PackageMetadataMismatch },
        .{
            .replacement = info,
            .expected = error.SignatureMissing,
            .required = true,
        },
        .{
            .original = info ++ "depend = one\ndepend = one\n",
            .replacement = info ++ "depend = one\ndepend = two\n",
            .expected = error.PackageMetadataMismatch,
        },
    };
    for (cases) |case| {
        var f = try Fixture.init();
        defer f.deinit();
        var archive = try Archive.init(
            &.{
                .{ .path = ".PKGINFO", .contents = case.original },
                .{ .path = "data", .contents = "one" },
            },
            .none,
        );
        defer archive.deinit();
        var replacement = try Archive.init(
            &.{
                .{ .path = ".PKGINFO", .contents = case.replacement },
                .{ .path = "data", .contents = "two" },
            },
            .none,
        );
        defer replacement.deinit();
        var owner = try f.owner(a);
        defer owner.deinit() catch unreachable;
        if (case.required) {
            var config = owner.options();
            config.local_file_signature_policy = .{ .package = .required };
            try owner.setOptions(io, config);
        }
        const tx = try owner.initializeTransaction(io, .{ .no_dependencies = true });
        defer owner.releaseTransaction() catch unreachable;
        var raw: ?rlpm.Package = try rlpm.Package.loadArchive(a, archive.path, .{});
        defer if (raw) |*pkg| pkg.deinit();
        try tx.takeArchive(&raw);
        try tx.prepare();
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, replacement.path, a, .limited(1024 * 1024));
        defer a.free(bytes);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = archive.path, .data = bytes });
        try std.testing.expectError(case.expected, tx.preflight());
        try std.testing.expectEqual(.failed, tx.result().state);
        try std.testing.expectError(error.FileNotFound, f.tmp.dir.access(io, "root/data", .{}));
    }
}

test "cancellation callbacks cannot reenter preflight and retain failed phase diagnostics" {
    var f = try Fixture.init();
    defer f.deinit();
    var archive = try Archive.init(
        &.{
            .{ .path = ".PKGINFO", .contents = info },
            .{ .path = "data", .contents = "new" },
        },
        .none,
    );
    defer archive.deinit();
    var owner = try f.owner(a);
    defer owner.deinit() catch unreachable;

    const Capture = struct {
        owner: *rlpm.Owner,
        cancelled: bool = false,
        reentry: bool = false,
        failed: bool = false,

        fn event(context: ?*anyopaque, value: rlpm.Callbacks.Event) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (value != .phase or value.phase.phase != .load_packages) return;
            if (value.phase.boundary == .start) {
                self.owner.active_transaction.?.preflight() catch |err| {
                    self.reentry = err == error.CallbackReentry;
                };
                self.owner.requestCancellation();
                self.cancelled = true;
            }
            if (value.phase.boundary == .failed) self.failed = true;
        }
    };
    var capture: Capture = .{ .owner = &owner };
    try owner.setCallbacks(.{ .event = Capture.event, .event_context = &capture });
    const tx = try owner.initializeTransaction(io, .{});
    defer owner.releaseTransaction() catch unreachable;
    try add(tx, archive.path);
    try tx.prepare();
    try std.testing.expectError(error.Cancelled, tx.preflight());
    try std.testing.expectEqual(.interrupted, tx.result().state);
    try std.testing.expect(capture.cancelled and capture.reentry and capture.failed);
}

test "detects permission changes and symlink loops before payload mutation" {
    for ([_]bool{ false, true }) |loop| {
        var f = try Fixture.init();
        defer f.deinit();
        try f.tmp.dir.createDirPath(io, "root/parent");
        if (loop) {
            try f.tmp.dir.symLink(io, "loop", "root/parent/loop", .{});
        }
        var archive = try Archive.init(
            &.{
                .{ .path = ".PKGINFO", .contents = info },
                .{
                    .path = if (loop)
                        "parent/loop/data"
                    else
                        "parent/data",
                    .contents = "new",
                },
            },
            .none,
        );
        defer archive.deinit();
        var owner = try f.owner(a);
        defer owner.deinit() catch unreachable;
        const tx = try owner.initializeTransaction(io, .{});
        defer owner.releaseTransaction() catch unreachable;
        try add(tx, archive.path);
        try tx.prepare();
        if (loop) {
            try std.testing.expectError(error.UnsafeSymlink, tx.preflight());
            continue;
        }
        try tx.preflight();
        const parent = try f.tmp.dir.openFile(io, "root/parent", .{});
        defer parent.close(io);
        try parent.setPermissions(io, .fromMode(0o500));
        defer parent.setPermissions(io, .fromMode(0o700)) catch unreachable;
        try std.testing.expectError(error.StaleFilesystemState, tx.revalidatePreflight());
    }
}

test "large inventory uses indexed ownership and includes database staging in space estimate" {
    var f = try Fixture.init();
    defer f.deinit();
    const entries = try a.alloc(Archive.Entry, 2049);
    defer a.free(entries);
    entries[0] = .{ .path = ".PKGINFO", .contents = info };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    for (entries[1..], 0..) |*entry, i|
        entry.* = .{
            .path = try std.fmt.allocPrint(
                arena.allocator(),
                "data/{d}",
                .{i},
            ),
            .contents = "payload",
        };
    var archive = try Archive.init(entries, .none);
    defer archive.deinit();
    var owner = try f.owner(a);
    defer owner.deinit() catch unreachable;
    var config = owner.options();
    config.check_space = true;
    try owner.setOptions(io, config);
    const tx = try owner.initializeTransaction(io, .{});
    defer owner.releaseTransaction() catch unreachable;
    try add(tx, archive.path);
    try tx.prepare();
    try tx.preflight();
    try std.testing.expectEqual(2048, tx.manifest().?.entries.items.len);
    try std.testing.expectEqualStrings("data", tx.manifest().?.entries.items[0].create_parents[0]);
    var blocks: u64 = 0;
    for (tx.manifest().?.spaces.items) |space|
        blocks += space.peak;
    try std.testing.expect(blocks > 2048);
}

test "sync preflight verifies cached bytes metadata and CachyOS database provenance" {
    for ([_]bool{ false, true }) |mismatch| {
        var f = try Fixture.init();
        defer f.deinit();
        var archive = try Archive.init(
            &.{
                .{ .path = ".PKGINFO", .contents = info ++ "size = 5\n" },
                .{ .path = "data", .contents = "bytes" },
            },
            .none,
        );
        defer archive.deinit();
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, archive.path, a, .limited(1024 * 1024));
        defer a.free(bytes);
        try f.tmp.dir.createDirPath(io, "cache");
        try f.tmp.dir.createDirPath(io, "db/sync");
        try f.tmp.dir.writeFile(io, .{ .sub_path = "cache/demo.pkg.tar", .data = bytes });
        const cache = try f.tmp.dir.realPathFileAlloc(io, "cache", a);
        defer a.free(cache);
        const description = try std.fmt.allocPrint(
            a,
            "%NAME%\ndemo\n\n%VERSION%\n2-1\n\n%ARCH%\nany\n\n%ISIZE%\n5\n\n%FILENAME%\ndemo.pkg.tar\n\n%CSIZE%\n{d}\n\n%SHA256SUM%\n{s}\n\n{s}",
            .{
                bytes.len, rlpm.Checksum.bytes(.sha256, bytes),
                if (mismatch)
                    "%DEPENDS%\nchanged\n\n"
                else
                    "",
            },
        );
        defer a.free(description);
        var database = try Archive.init(&.{.{ .path = "demo-2-1/desc", .contents = description }}, .none);
        defer database.deinit();
        const dbbytes = try std.Io.Dir.cwd().readFileAlloc(io, database.path, a, .limited(1024 * 1024));
        defer a.free(dbbytes);
        try f.tmp.dir.writeFile(io, .{ .sub_path = "db/sync/cachyos.db", .data = dbbytes });
        var owner = try f.owner(a);
        defer owner.deinit() catch unreachable;
        try owner.setList(io, .cache_directories, &.{cache});
        const repository = try owner.registerDatabase(.{ .database_name = "cachyos" });
        if (!mismatch) {
            const reference = (try owner.queryPackage(io, repository, "demo")).?;
            var imported: ?rlpm.Package = try owner.loadPackage(
                io,
                archive.path,
                .{ .repository = reference },
                .{},
            );
            defer if (imported) |*pkg| pkg.deinit();
            const imported_tx = try owner.initializeTransaction(io, .{});
            defer owner.releaseTransaction() catch unreachable;
            try imported_tx.takeArchive(&imported);
            try imported_tx.prepare();
            try imported_tx.preflight();
            try std.testing.expect(imported_tx.manifest().?.archives.items[0].package.validation.sha256);
            try std.testing.expectEqualStrings(
                "cachyos",
                imported_tx.manifest().?.database_changes.items[0].installed_database.?,
            );
        }
        const tx = try owner.initializeTransaction(io, .{ .no_dependencies = true });
        defer owner.releaseTransaction() catch unreachable;
        try tx.addTarget("demo");
        try tx.prepare();
        if (mismatch) {
            try std.testing.expectError(error.PackageMetadataMismatch, tx.preflight());
            continue;
        }
        try tx.preflight();
        try tx.revalidatePreflight();
        try std.testing.expect(tx.manifest().?.archives.items[0].package.validation.sha256);
        try std.testing.expectEqualStrings(
            "cachyos",
            tx.manifest().?.database_changes.items[0].installed_database.?,
        );
    }
}

test "backup symlink hashes prior payload without rewriting its absolute target" {
    var f = try Fixture.init();
    defer f.deinit();
    var archive = try Archive.init(&.{
        .{ .path = ".PKGINFO", .contents = info ++ "backup = conf\n" },
        .{ .path = "data", .contents = "new" },
        .{
            .path = "conf",
            .kind = .symlink,
            .target = "/data",
        },
    }, .none);
    defer archive.deinit();
    var owner = try f.owner(a);
    defer owner.deinit() catch unreachable;
    const tx = try owner.initializeTransaction(io, .{});
    defer owner.releaseTransaction() catch unreachable;
    try add(tx, archive.path);
    try tx.prepare();
    try tx.preflight();
    const entry = try effect(tx.manifest().?, "conf", true);
    try std.testing.expectEqualStrings("/data", entry.file.link_target.?);
    try std.testing.expectEqualStrings(&rlpm.Checksum.bytes(.md5, "new"), entry.new_hash.?);
    try std.testing.expectEqualStrings(
        entry.new_hash.?,
        tx.manifest().?.database_changes.items[0].backups[0].hash.?,
    );
}

test "packages loaded before a stricter policy cannot bypass current preflight verification" {
    var f = try Fixture.init();
    defer f.deinit();
    var archive = try Archive.init(
        &.{
            .{ .path = ".PKGINFO", .contents = info },
            .{ .path = "data", .contents = "new" },
        },
        .none,
    );
    defer archive.deinit();
    var owner = try f.owner(a);
    defer owner.deinit() catch unreachable;
    var package: ?rlpm.Package = try owner.loadPackage(io, archive.path, .remote_file, .{});
    defer if (package) |*pkg| pkg.deinit();
    var config = owner.options();
    config.remote_file_signature_policy = .{ .package = .required };
    try owner.setOptions(io, config);
    const tx = try owner.initializeTransaction(io, .{});
    defer owner.releaseTransaction() catch unreachable;
    try tx.takeArchive(&package);
    try tx.prepare();
    try std.testing.expectError(error.SignatureMissing, tx.preflight());
}
