//! Integration fixture launched by test-caller-cache-ownership.sh.
const std = @import("std");
const pm = @import("PackageManager");

test "caller cache ownership through AUR initialization and AppImage extraction" {
    const stage = std.testing.environ.getPosix("SHELLY_TEST_CALLER_IO_DIRECTORY") orelse return error.SkipZigTest;
    try std.testing.expectEqual(0, std.c.geteuid());
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const user = (try pm.user_account.byName(a, "nobody")).?;
    const cache = try std.fs.path.join(a, &.{ user.home, "manager cache" });
    const data = try std.fs.path.join(a, &.{ user.home, "data" });
    var map = std.process.Environ.Map.init(a);
    try map.put("SUDO_USER", user.username);
    try map.put("XDG_CACHE_HOME", cache);
    try map.put("XDG_DATA_HOME", data);
    const environ: std.process.Environ = .{ .block = try map.createPosixBlock(a, .{}) };
    const native_root = try std.fs.path.join(a, &.{ stage, "native" });
    const db = try std.fs.path.join(a, &.{ native_root, "db" });
    const packages = try std.fs.path.join(a, &.{ native_root, "packages" });
    for ([_][]const u8{ native_root, db, packages }) |path| try std.Io.Dir.cwd().createDirPath(io, path);
    const config = try std.fs.path.join(a, &.{ stage, "native.conf" });
    const config_bytes = try std.fmt.allocPrint(a, "[options]\nArchitecture = auto\nSigLevel = Never\nRootDir = {s}\nDBPath = {s}\nCacheDir = {s}\nLogFile = {s}/transaction.log\n", .{ native_root, db, packages, native_root });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = config, .data = config_bytes });
    const missing = try std.fs.path.join(a, &.{ stage, "missing.conf" });
    const aur = try pm.AurManager.init(a, environ, .{
        .config_path = config,
        .shellybuild_configuration_paths = .{ .system = missing, .user = missing },
    });
    aur.deinit();
    try expectOwner(a, io, try std.fs.path.join(a, &.{ cache, "Shelly" }), user.uid);
    try expectOwner(a, io, try std.fs.path.join(a, &.{ data, "Shelly", "vcs.json" }), user.uid);

    const app = try std.fs.path.join(a, &.{ stage, "Fixture.AppImage" });
    const body =
        \\#!/bin/sh
        \\set -eu
        \\test "$(id -u)" = "$(id -u nobody)"
        \\if [ "$1" = --appimage-extract ]; then
        \\  mkdir squashfs-root
        \\  printf '[Desktop Entry]\nName=Fixture\nExec=fixture\n' > squashfs-root/fixture.desktop
        \\elif [ "$1" = --appimage-updateinfo ]; then
        \\  printf caller-update-info
        \\fi
    ;
    var file = try std.Io.Dir.cwd().createFile(io, app, .{ .permissions = .fromMode(0o755) });
    try file.writeStreamingAll(io, body);
    file.close(io);
    var manager: pm.AppImageManager = .{
        .allocator = a,
        .io = io,
        .environ = environ,
        .install_directory = user.home,
        .local_db_path = missing,
    };
    defer manager.deinit();
    var content = (try manager.extractMetadataPure(app, null, null)) orelse return error.ExtractionFailed;
    const work = try a.dupe(u8, content.working_dir);
    try expectOwner(a, io, work, user.uid);
    try expectOwner(a, io, content.source_desktop_path.?, user.uid);
    try std.testing.expectEqualStrings("caller-update-info", content.metadata.raw_update_info);
    content.deinit();
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, work, .{}));
    try std.testing.expectEqual(0, std.c.geteuid());
}

fn expectOwner(a: std.mem.Allocator, io: std.Io, path: []const u8, uid: std.c.uid_t) !void {
    const result = try std.process.run(a, io, .{ .argv = &.{ "/usr/bin/stat", "-c", "%u", "--", path } });
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    try std.testing.expectEqual(uid, try std.fmt.parseInt(std.c.uid_t, std.mem.trim(u8, result.stdout, "\n"), 10));
}
