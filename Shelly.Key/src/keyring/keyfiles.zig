const std = @import("std");
const Io = std.Io;

const fsutil = @import("../helpers/fsutil.zig");

pub const KeyfilesError = fsutil.FsUtilError ||
    std.Io.Dir.OpenError ||
    std.Io.Dir.SetFilePermissionsError;

pub fn trustdbNeedsInit(
    base: std.Io.Dir,
    io: Io,
    keyring_dir: []const u8,
) KeyfilesError!bool {
    var dir = try base.openDir(io, keyring_dir, .{});
    defer dir.close(io);

    return !try fsutil.isRegularFile(dir, io, "trustdb.gpg");
}

pub fn applyKeyringPermissions(
    base: std.Io.Dir,
    io: Io,
    keyring_dir: []const u8,
) KeyfilesError!void {
    var dir = try base.openDir(io, keyring_dir, .{});
    defer dir.close(io);

    try dir.setFilePermissions(io, "trustdb.gpg", fsutil.mode.readable, .{});
}

const testing = std.testing;

fn statMode(dir: Io.Dir, io: Io, sub_path: []const u8) !std.posix.mode_t {
    const st = try dir.statFile(io, sub_path, .{});
    // Mask with 0o7777 to keep only permission bits.
    return st.permissions.toMode() & 0o7777;
}

test "trustdbNeedsInit returns true when trustdb.gpg is absent" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "gnupg", .default_dir);

    try testing.expect(try trustdbNeedsInit(tmp.dir, testing.io, "gnupg"));
}

test "trustdbNeedsInit returns false when trustdb.gpg exists as a regular file" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "gnupg", .default_dir);
    {
        var dir = try tmp.dir.openDir(testing.io, "gnupg", .{});
        defer dir.close(testing.io);
        var f = try dir.createFile(testing.io, "trustdb.gpg", .{});
        f.close(testing.io);
    }

    try testing.expect(!try trustdbNeedsInit(tmp.dir, testing.io, "gnupg"));
}

test "applyKeyringPermissions sets the canonical mode on trustdb.gpg" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "gnupg", .default_dir);
    {
        var dir = try tmp.dir.openDir(testing.io, "gnupg", .{});
        defer dir.close(testing.io);
        var f = try dir.createFile(testing.io, "trustdb.gpg", .{});
        f.close(testing.io);
        // Set deliberately wrong mode.
        try dir.setFilePermissions(testing.io, "trustdb.gpg", @enumFromInt(0o600), .{});
    }

    try applyKeyringPermissions(tmp.dir, testing.io, "gnupg");

    var gnupg = try tmp.dir.openDir(testing.io, "gnupg", .{});
    defer gnupg.close(testing.io);

    try testing.expectFmt("0644", "{o:0>4}", .{try statMode(gnupg, testing.io, "trustdb.gpg")});
}

test "applyKeyringPermissions reports missing trustdb.gpg" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "gnupg", .default_dir);

    try testing.expectError(
        error.FileNotFound,
        applyKeyringPermissions(tmp.dir, testing.io, "gnupg"),
    );
}
