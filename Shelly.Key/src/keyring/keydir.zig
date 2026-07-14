const std = @import("std");
const Io = std.Io;

const fsutil = @import("../helpers/fsutil.zig");

pub const KeydirError = error{
    NotADirectory,
    DanglingSymlink,
} || std.Io.Dir.CreateDirPathError ||
    std.Io.Dir.StatFileError ||
    std.Io.Dir.SetFilePermissionsError;

pub fn createKeyringDir(base: std.Io.Dir, io: Io, sub_path: []const u8) KeydirError!void {
    // Check if already exists (including symlinks).
    if (base.statFile(io, sub_path, .{})) |st| {
        if (st.kind == .directory) {
            return;
        }
        return error.NotADirectory;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    // Verify no dangling symlink exists at the path.
    if (base.statFile(io, sub_path, .{ .follow_symlinks = false })) |st| {
        return switch (st.kind) {
            .sym_link => error.DanglingSymlink,
            else => error.NotADirectory,
        };
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const status = base.createDirPathStatus(io, sub_path, .default_dir) catch |err| switch (err) {
        error.NotDir => return error.NotADirectory,
        else => return err,
    };
    if (status == .created) {
        base.setFilePermissions(io, sub_path, fsutil.mode.executable, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
    }
}

const testing = std.testing;

test "createKeyringDir creates a fresh directory with mode 0755" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try createKeyringDir(tmp.dir, testing.io, "gnupg");

    const st = try tmp.dir.statFile(testing.io, "gnupg", .{});
    try testing.expectEqual(@as(std.Io.File.Kind, .directory), st.kind);

    const mode = try fsutil.statMode(tmp.dir, testing.io, "gnupg");
    try testing.expectFmt("0755", "{o:0>4}", .{mode});
}

test "createKeyringDir leaves an existing directory's mode untouched" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "gnupg", @enumFromInt(0o700));

    try createKeyringDir(tmp.dir, testing.io, "gnupg");

    const mode = try fsutil.statMode(tmp.dir, testing.io, "gnupg");
    try testing.expectFmt("0700", "{o:0>4}", .{mode});
}

test "createKeyringDir accepts a symlink to a directory" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "real", .default_dir);
    try tmp.dir.symLink(testing.io, "real", "gnupg", .{});

    try createKeyringDir(tmp.dir, testing.io, "gnupg");

    const st = try tmp.dir.statFile(testing.io, "gnupg", .{});
    try testing.expectEqual(@as(std.Io.File.Kind, .directory), st.kind);
}

test "createKeyringDir fails on an existing regular file" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var f = try tmp.dir.createFile(testing.io, "gnupg", .{});
    f.close(testing.io);

    try testing.expectError(error.NotADirectory, createKeyringDir(tmp.dir, testing.io, "gnupg"));
}

test "createKeyringDir fails on a dangling symlink" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.symLink(testing.io, "does-not-exist", "gnupg", .{});

    try testing.expectError(error.DanglingSymlink, createKeyringDir(tmp.dir, testing.io, "gnupg"));
}

test "createKeyringDir creates missing parent directories" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try createKeyringDir(tmp.dir, testing.io, "a/b/gnupg");

    const st = try tmp.dir.statFile(testing.io, "a/b/gnupg", .{});
    try testing.expectEqual(@as(std.Io.File.Kind, .directory), st.kind);
    const mode = try fsutil.statMode(tmp.dir, testing.io, "a/b/gnupg");
    try testing.expectFmt("0755", "{o:0>4}", .{mode});
}

test "createKeyringDir is idempotent" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try createKeyringDir(tmp.dir, testing.io, "gnupg");
    try createKeyringDir(tmp.dir, testing.io, "gnupg");
    try createKeyringDir(tmp.dir, testing.io, "gnupg");

    const mode = try fsutil.statMode(tmp.dir, testing.io, "gnupg");
    try testing.expectFmt("0755", "{o:0>4}", .{mode});
}
