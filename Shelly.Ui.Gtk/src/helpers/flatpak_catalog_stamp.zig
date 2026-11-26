const std = @import("std");
const Io = std.Io;

/// identifies the appstream commits deployed under the given
/// `flatpak/appstream` roots. flatpak points each `<remote>/<arch>/active`
/// link at the deployed commit, so the value changes only with the catalog.
/// `configs` are the repository configs holding the remotes.
pub fn read(io: Io, roots: []const []const u8, configs: []const []const u8) u64 {
    var stamp: u64 = 0;
    for (roots) |root| addRoot(io, root, &stamp);
    for (configs) |config| addConfig(io, config, &stamp);
    return stamp;
}

fn addConfig(io: Io, path: []const u8, stamp: *u64) void {
    var buffer: [64 * 1024]u8 = undefined;
    const bytes = Io.Dir.cwd().readFile(io, path, &buffer) catch return;
    var hasher: std.hash.Wyhash = .init(1);
    hasher.update(path);
    hasher.update(&.{0});
    hasher.update(bytes);
    stamp.* +%= hasher.final();
}

fn addRoot(io: Io, root: []const u8, stamp: *u64) void {
    var root_dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer root_dir.close(io);
    var remotes = root_dir.iterate();
    while (remotes.next(io) catch null) |remote| {
        // not every file system tells the kind, so let the open decide.
        var remote_dir = root_dir.openDir(io, remote.name, .{ .iterate = true }) catch continue;
        defer remote_dir.close(io);
        var arches = remote_dir.iterate();
        while (arches.next(io) catch null) |arch| {
            var arch_dir = remote_dir.openDir(io, arch.name, .{}) catch continue;
            defer arch_dir.close(io);
            var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
            const len = arch_dir.readLink(io, "active", &buffer) catch continue;

            var hasher: std.hash.Wyhash = .init(0);
            for ([_][]const u8{ root, remote.name, arch.name, buffer[0..len] }) |part| {
                hasher.update(part);
                hasher.update(&.{0});
            }
            // folders are listed in no fixed order, so combine commutatively.
            stamp.* +%= hasher.final();
        }
    }
}

/// the base folder of an installation, which `override` from the environment may move.
pub fn baseDir(override: ?[]const u8, default: []const u8) []const u8 {
    const path = override orelse return default;
    return if (path.len > 0) path else default;
}

const testing = std.testing;

fn rootPath(tmp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    return buffer[0..try tmp.dir.realPath(testing.io, buffer)];
}

fn deploy(tmp: *std.testing.TmpDir, remote_arch: []const u8, commit: []const u8) !void {
    try tmp.dir.createDirPath(testing.io, remote_arch);
    var dir = try tmp.dir.openDir(testing.io, remote_arch, .{});
    defer dir.close(testing.io);
    dir.deleteFile(testing.io, "active") catch {};
    try dir.symLink(testing.io, commit, "active", .{});
}

test "a newly deployed commit changes the stamp" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &buffer);

    try deploy(&tmp, "flathub/x86_64", "aaa");
    const before = read(testing.io, &.{root}, &.{});
    try deploy(&tmp, "flathub/x86_64", "bbb");
    try testing.expect(before != read(testing.io, &.{root}, &.{}));
}

test "a first catalog changes the stamp" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &buffer);

    const before = read(testing.io, &.{root}, &.{});
    try deploy(&tmp, "flathub/x86_64", "aaa");
    try testing.expect(before != read(testing.io, &.{root}, &.{}));
}

test "the stamp does not depend on the order remotes were deployed in" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &buffer);

    try deploy(&tmp, "flathub/x86_64", "aaa");
    try deploy(&tmp, "beta/x86_64", "bbb");
    const before = read(testing.io, &.{root}, &.{});
    try testing.expect(before != 0);

    try tmp.dir.deleteTree(testing.io, "flathub");
    try tmp.dir.deleteTree(testing.io, "beta");
    try deploy(&tmp, "beta/x86_64", "bbb");
    try deploy(&tmp, "flathub/x86_64", "aaa");
    try testing.expectEqual(before, read(testing.io, &.{root}, &.{}));
}

test "commits swapped between remotes change the stamp" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &buffer);

    try deploy(&tmp, "flathub/x86_64", "aaa");
    try deploy(&tmp, "beta/x86_64", "bbb");
    const before = read(testing.io, &.{root}, &.{});
    try deploy(&tmp, "flathub/x86_64", "bbb");
    try deploy(&tmp, "beta/x86_64", "aaa");
    try testing.expect(before != read(testing.io, &.{root}, &.{}));
}

test "missing roots are ignored" {
    try testing.expectEqual(read(testing.io, &.{}, &.{}), read(testing.io, &.{"/nonexistent/flatpak/appstream"}, &.{"/nonexistent/flatpak/repo/config"}));
}

test "a changed remote configuration changes the stamp" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &buffer);
    var path_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const config = try std.fmt.bufPrint(&path_buffer, "{s}/config", .{root});

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config", .data = "[remote \"flathub\"]" });
    const before = read(testing.io, &.{}, &.{config});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config", .data = "" });
    try testing.expect(before != read(testing.io, &.{}, &.{config}));
}

test "an environment variable moves an installation unless it is empty" {
    try testing.expectEqualStrings("/srv/flatpak", baseDir("/srv/flatpak", "/var/lib/flatpak"));
    try testing.expectEqualStrings("/var/lib/flatpak", baseDir("", "/var/lib/flatpak"));
    try testing.expectEqualStrings("/var/lib/flatpak", baseDir(null, "/var/lib/flatpak"));
}
