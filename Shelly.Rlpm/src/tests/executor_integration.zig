//! Opt-in user namespace integration. Every script and payload targets a fresh
//! disposable root; host binaries are copied only to provide a test shell.
const std = @import("std");
const rlpm = @import("Shelly_Rlpm");
const Fixture = @import("actions_fixture.zig");
const Archive = @import("archive_fixture.zig");

const io = std.testing.io;
const a = std.testing.allocator;
const c = @cImport({
    @cInclude("sys/stat.h");
    @cInclude("sys/xattr.h");
    @cInclude("unistd.h");
    @cInclude("errno.h");
});

fn commit(owner: *rlpm.Owner, archive: []const u8, flags: rlpm.TransactionFlags) !void {
    const tx = try owner.initializeTransaction(io, flags);
    defer owner.releaseTransaction() catch unreachable;
    try Fixture.add(tx, archive);
    try tx.prepare();
    try tx.commit();
}
test "actual commit replays native scripts hooks DBONLY and DOWNLOADONLY traces" {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, @embedFile("reference/actions.json"), .{});
    defer parsed.deinit();
    for (parsed.value.object.get("cases").?.array.items) |case| {
        const obj = case.object;
        errdefer std.debug.print("executor action case: {s}\n", .{obj.get("name").?.string});
        var f = try Fixture.init();
        defer f.deinit();
        try f.shell();
        try f.hook("fixture.hook", obj.get("hook").?.string);
        if (obj.get("old_version")) |old|
            try f.installed(
                "demo",
                old.string,
                "",
                "pre_remove() { exit 99; }\n",
            );
        var entries: std.ArrayList(Archive.Entry) = .empty;
        defer entries.deinit(a);
        try entries.append(
            a,
            .{
                .path = ".PKGINFO",
                .contents = "pkgname = demo\npkgver = 2-1\narch = any\n",
            },
        );
        if (obj.get("script")) |script|
            try entries.append(
                a,
                .{
                    .path = ".INSTALL",
                    .contents = script.string,
                },
            );
        var archive = try Archive.init(entries.items, .none);
        defer archive.deinit();
        var owner = try f.owner();
        defer owner.deinit() catch unreachable;
        const tx = try owner.initializeTransaction(
            io,
            try rlpm.TransactionFlags.fromBits(
                if (obj.get("flags")) |value|
                    @intCast(value.integer)
                else
                    0,
            ),
        );
        defer owner.releaseTransaction() catch unreachable;
        try Fixture.add(tx, archive.path);
        try tx.prepare();
        if (obj.get("success").?.bool) try tx.commit() else {
            if (tx.commit()) |_| return error.ExpectedNativeFailure else |_| {}
            try std.testing.expectEqual(.failed, tx.state);
        }
        const trace = f.read("root/trace") catch |err| switch (err) {
            error.FileNotFound => try a.dupe(u8, ""),
            else => return err,
        };
        defer a.free(trace);
        try std.testing.expectEqualStrings(obj.get("trace").?.string, trace);
    }
}

test "payload attributes hardlinks xattrs fifo and shared directory metadata" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("root/shared/keep", "untouched");
    const sparse = try a.alloc(u8, 8 * 1024 * 1024);
    defer a.free(sparse);
    @memset(sparse, 0);
    @memcpy(sparse[sparse.len - 4 ..], "tail");
    var archive = try Archive.init(&.{
        .{ .path = ".PKGINFO", .contents = "pkgname = attrs\npkgver = 1-1\narch = any\n" },
        .{
            .path = "shared/",
            .kind = .directory,
            .mode = 0o700,
            .mtime = 12,
        },
        .{
            .path = "private/",
            .kind = .directory,
            .mode = 0o750,
            .mtime = 13,
        },
        .{
            .path = "payload",
            .contents = "contents",
            .mode = 0o4751,
            .mtime = 123456789,
            .xattr = "fixture-value",
        },
        .{
            .path = "link",
            .kind = .hardlink,
            .target = "payload",
        },
        .{
            .path = "absolute",
            .kind = .symlink,
            .target = "/payload",
            .mtime = 12345,
        },
        .{
            .path = "pipe",
            .kind = .fifo,
            .mode = 0o620,
        },
        .{
            .path = "sparse",
            .contents = sparse,
            .sparse = true,
        },
        .{
            .path = "caps",
            .contents = "executable",
            .mode = 0o755,
            .capabilities = true,
        },
        .{
            .path = "acl",
            .contents = "acl",
            .acl = true,
        },
    }, .none);
    defer archive.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    try commit(&owner, archive.path, .{ .no_hooks = true, .no_scriptlets = true });
    const payload = try std.fmt.allocPrintSentinel(a, "{s}/payload", .{f.root}, 0);
    defer a.free(payload);
    const link = try std.fmt.allocPrintSentinel(a, "{s}/link", .{f.root}, 0);
    defer a.free(link);
    var stat: c.struct_stat = undefined;
    var hard: c.struct_stat = undefined;
    try std.testing.expectEqual(0, c.lstat(payload, &stat));
    try std.testing.expectEqual(0, c.lstat(link, &hard));
    try std.testing.expectEqual(stat.st_ino, hard.st_ino);
    try std.testing.expectEqual(0o4751, stat.st_mode & 0o7777);
    try std.testing.expectEqual(123456789, stat.st_mtim.tv_sec);
    try std.testing.expectEqual(0, stat.st_uid);
    try std.testing.expectEqual(0, stat.st_gid);
    var xattr: [32]u8 = undefined;
    const length = c.getxattr(payload, "user.rlpm", &xattr, xattr.len);
    try std.testing.expect(length > 0);
    try std.testing.expectEqualStrings("fixture-value", xattr[0..@intCast(length)]);
    const shared = try f.tmp.dir.statFile(io, "root/shared", .{});
    try std.testing.expectEqual(0o755, shared.permissions.toMode() & 0o777);
    const private = try f.tmp.dir.statFile(io, "root/private", .{});
    try std.testing.expectEqual(0o750, private.permissions.toMode() & 0o777);
    try std.testing.expectEqual(13, private.mtime.toSeconds());
    const pipe = try std.fmt.allocPrintSentinel(a, "{s}/pipe", .{f.root}, 0);
    defer a.free(pipe);
    try std.testing.expectEqual(0, c.lstat(pipe, &stat));
    try std.testing.expectEqual(@as(c_uint, c.S_IFIFO), stat.st_mode & c.S_IFMT);
    const sparse_path = try std.fmt.allocPrintSentinel(a, "{s}/sparse", .{f.root}, 0);
    defer a.free(sparse_path);
    try std.testing.expectEqual(0, c.stat(sparse_path, &stat));
    try std.testing.expectEqual(@as(c_long, @intCast(sparse.len)), stat.st_size);
    try std.testing.expect(stat.st_blocks * 512 < @divTrunc(stat.st_size, 2));
    const sparse_file = try f.tmp.dir.openFile(io, "root/sparse", .{});
    defer sparse_file.close(io);
    var tail: [4]u8 = undefined;
    try std.testing.expectEqual(4, try sparse_file.readPositional(io, &.{&tail}, sparse.len - 4));
    try std.testing.expectEqualStrings("tail", &tail);
    const caps_path = try std.fmt.allocPrintSentinel(a, "{s}/caps", .{f.root}, 0);
    defer a.free(caps_path);
    const caps_len = c.getxattr(caps_path, "security.capability", &xattr, xattr.len);
    try std.testing.expect(caps_len == 20 or caps_len == 24);
    try std.testing.expectEqual(4, xattr[5]);
    const acl_path = try std.fmt.allocPrintSentinel(a, "{s}/acl", .{f.root}, 0);
    defer a.free(acl_path);
    // Pinned add.c enables XATTR but not ACL. ACL headers do not create ACLs.
    try std.testing.expectEqual(-1, c.getxattr(acl_path, "system.posix_acl_access", &xattr, xattr.len));
}

test "hooks and scripts change backup inputs before extraction and post hooks see new dependencies" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.shell();
    try f.installed("demo", "1-1", "conf", null);
    try f.write(
        "db/local/demo-1-1/files",
        "%FILES%\nconf\n\n%BACKUP%\nconf\t149603e6c03516362a8da23f624db945\n\n",
    );
    try f.write("root/conf", "old");
    try f.hook(
        "post.hook",
        "[Trigger]\nOperation=Upgrade\nType=Package\nTarget=demo\n[Action]\nWhen=PostTransaction\nDepends=demo=2-1\nExec=/usr/bin/bash -c 'printf post >> /trace'\n",
    );
    var archive = try Archive.init(
        &.{
            .{ .path = ".PKGINFO", .contents = "pkgname = demo\npkgver = 2-1\narch = any\nbackup = conf\n" },
            .{
                .path = ".INSTALL",
                .contents = "pre_upgrade() { printf edited > /conf; }\npost_upgrade() { printf installed >> /trace; }\n",
            },
            .{ .path = "conf", .contents = "new" },
        },
        .none,
    );
    defer archive.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    try commit(&owner, archive.path, .{});
    try f.expect("root/conf", "edited");
    try f.expect("root/conf.pacnew", "new");
    try f.expect("root/trace", "installedpost");
}

test "out of space during extraction preserves coherent database and cleans staging" {
    const mount = @cImport({
        @cInclude("sys/mount.h");
    });
    var f = try Fixture.init();
    defer f.deinit();
    try std.testing.expectEqual(0, mount.mount("tmpfs", f.root, "tmpfs", 0, "size=4m"));
    defer _ = mount.umount2(f.root, mount.MNT_DETACH);
    const bytes = try a.alloc(u8, 8 * 1024 * 1024);
    defer a.free(bytes);
    @memset(bytes, 'x');
    var archive = try Archive.init(
        &.{
            .{
                .path = ".PKGINFO",
                .contents = "pkgname = full\npkgver = 1-1\narch = any\n",
            },
            .{ .path = "big", .contents = bytes },
        },
        .zstd,
    );
    defer archive.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    const tx = try owner.initializeTransaction(io, .{ .no_hooks = true, .no_scriptlets = true });
    defer owner.releaseTransaction() catch unreachable;
    try Fixture.add(tx, archive.path);
    try tx.prepare();
    try std.testing.expectError(error.NoSpaceLeft, tx.commit());
    try std.testing.expectEqual(.failed, tx.state);
    try std.testing.expectEqualStrings("big", tx.execution.path.?);
    try std.testing.expect(!tx.execution.database_published);
    var dir = try f.tmp.dir.openDir(io, "root", .{ .iterate = true });
    defer dir.close(io);
    var entries = dir.iterate();
    try std.testing.expect(try entries.next(io) == null);
    var fresh = try f.owner();
    defer fresh.deinit() catch unreachable;
    try std.testing.expectEqual(0, (try fresh.packageIds(fresh.localDatabase().?)).len);
}

test "supported device nodes are created only inside the disposable mount" {
    const mount = @cImport({
        @cInclude("sys/mount.h");
    });
    var f = try Fixture.init();
    defer f.deinit();
    try std.testing.expectEqual(0, mount.mount("tmpfs", f.root, "tmpfs", mount.MS_NODEV, "size=4m"));
    defer _ = mount.umount2(f.root, mount.MNT_DETACH);
    var archive = try Archive.init(
        &.{
            .{
                .path = ".PKGINFO",
                .contents = "pkgname = devices\npkgver = 1-1\narch = any\n",
            },
            .{
                .path = "character",
                .kind = .character,
                .mode = 0o600,
            },
            .{
                .path = "block",
                .kind = .block,
                .mode = 0o600,
            },
        },
        .none,
    );
    defer archive.deinit();
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    const probe = try std.fmt.allocPrintSentinel(a, "{s}/probe", .{f.root}, 0);
    defer a.free(probe);
    var denied: ?c_int = null;
    for ([_]c_uint{ @as(c_uint, c.S_IFCHR), @as(c_uint, c.S_IFBLK) }) |kind| {
        if (c.mknod(probe, kind | 0o600, 0) != 0) {
            denied = std.c._errno().*;
            break;
        }
        try std.testing.expectEqual(0, c.unlink(probe));
    }
    if (denied) |code| {
        // Device creation restrictions are tested as failures, never skipped.
        try std.testing.expect(code == c.EPERM or code == c.EACCES);
        const tx = try owner.initializeTransaction(io, .{ .no_hooks = true, .no_scriptlets = true });
        defer owner.releaseTransaction() catch unreachable;
        try Fixture.add(tx, archive.path);
        try tx.prepare();
        try std.testing.expectError(error.PathPermissionDenied, tx.commit());
        try std.testing.expectEqual(code, tx.execution.system_error.?);
        try std.testing.expect(tx.execution.detail != null);
        try std.testing.expect(!tx.execution.database_published);
        return;
    }
    try commit(&owner, archive.path, .{ .no_hooks = true, .no_scriptlets = true });
    inline for (.{ .{ "character", c.S_IFCHR }, .{ "block", c.S_IFBLK } }) |pair| {
        const path = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ f.root, pair[0] }, 0);
        defer a.free(path);
        var state: c.struct_stat = undefined;
        try std.testing.expectEqual(0, c.lstat(path, &state));
        try std.testing.expectEqual(@as(c_uint, pair[1]), state.st_mode & c.S_IFMT);
        try std.testing.expectEqual(0o600, state.st_mode & 0o777);
    }
}

test "pre-remove script can create a previously absent backup and it is saved" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.shell();
    try f.installed("demo", "1-1", "conf", "pre_remove() { printf edited > /conf; }\n");
    try f.write(
        "db/local/demo-1-1/files",
        "%FILES%\nconf\n\n%BACKUP%\nconf\t149603e6c03516362a8da23f624db945\n\n",
    );
    var owner = try f.owner();
    defer owner.deinit() catch unreachable;
    const tx = try owner.initializeTransaction(io, .{});
    defer owner.releaseTransaction() catch unreachable;
    try tx.remove("demo");
    try tx.prepare();
    try tx.commit();
    try f.expect("root/conf.pacsave", "edited");
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.access(io, "root/conf", .{}));
}

test "payload barrier covers nested and bind mounts before publishing on separate database filesystem" {
    const mount = @cImport({
        @cInclude("sys/mount.h");
    });
    const D = rlpm.Transaction.Executor.PayloadDurability;
    // Repeat with failure on the second target: the first successful flush
    // must not permit database publication for a partly durable package.
    for ([_]bool{ false, true }) |fail_second| {
        var f = try Fixture.init();
        defer f.deinit();
        try std.testing.expectEqual(0, mount.mount("tmpfs", f.root, "tmpfs", 0, "size=8m"));
        defer _ = mount.umount2(f.root, mount.MNT_DETACH);
        try f.tmp.dir.createDirPath(io, "root/boot");
        try f.tmp.dir.createDirPath(io, "root/shared");
        try f.tmp.dir.createDirPath(io, "root/usr");
        const boot = try std.fmt.allocPrintSentinel(a, "{s}/boot", .{f.root}, 0);
        defer a.free(boot);
        const shared = try std.fmt.allocPrintSentinel(a, "{s}/shared", .{f.root}, 0);
        defer a.free(shared);
        const usr = try std.fmt.allocPrintSentinel(a, "{s}/usr", .{f.root}, 0);
        defer a.free(usr);
        try std.testing.expectEqual(0, mount.mount("tmpfs", boot, "tmpfs", 0, "size=4m"));
        defer _ = mount.umount2(boot, mount.MNT_DETACH);
        try std.testing.expectEqual(0, mount.mount(shared, usr, null, mount.MS_BIND, null));
        defer _ = mount.umount2(usr, mount.MNT_DETACH);
        var archive = try Archive.init(&.{
            .{ .path = ".PKGINFO", .contents = "pkgname = mounts\npkgver = 1-1\narch = any\n" },
            .{ .path = "etc/config", .contents = "root filesystem" },
            .{ .path = "boot/image", .contents = "boot filesystem" },
            .{ .path = "usr/header", .contents = "bind mount" },
        }, .none);
        defer archive.deinit();
        var owner = try f.owner();
        defer owner.deinit() catch unreachable;
        const tx = try owner.initializeTransaction(io, .{ .no_hooks = true, .no_scriptlets = true });
        defer owner.releaseTransaction() catch unreachable;
        try Fixture.add(tx, archive.path);
        try tx.prepare();
        D.test_hooks = .{ .fail_flush_at = if (fail_second) 1 else null };
        defer D.test_hooks = .{};
        if (fail_second) {
            try std.testing.expectError(error.FilesystemWriteFailed, tx.commit());
            try std.testing.expectEqual(1, tx.execution.payload_sync_targets);
            try std.testing.expectEqual(.payload_sync, tx.execution.boundary);
            try std.testing.expect(std.mem.endsWith(u8, tx.execution.path.?, "/boot"));
            try std.testing.expect(!tx.execution.database_published);
            try std.testing.expectError(error.FileNotFound, f.tmp.dir.access(io, "db/local/mounts-1-1", .{}));
        } else {
            try tx.commit();
            try std.testing.expectEqual(3, tx.execution.payload_sync_targets);
            try f.expect("root/etc/config", "root filesystem");
            try f.expect("root/boot/image", "boot filesystem");
            try f.expect("root/shared/header", "bind mount");
            try std.testing.expect(tx.execution.database_published);
        }
        try std.testing.expectEqual(D.test_hooks.opened, D.test_hooks.closed);
    }
}
