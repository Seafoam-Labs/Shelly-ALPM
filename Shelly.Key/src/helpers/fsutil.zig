const std = @import("std");
const Io = std.Io;

pub const mode = struct {
    /// `rw-------` (0o600): owner only
    pub const private: Io.File.Permissions = @enumFromInt(0o600);
    /// `rw-r--r--` (0o644): owner writable, world readable
    pub const readable: Io.File.Permissions = @enumFromInt(0o644);
    /// `rwxr-xr-x` (0o755): owner writable, world readable/executable
    pub const executable: Io.File.Permissions = @enumFromInt(0o755);
};

pub const FsUtilError = error{
    NotARegularFile,
} || std.Io.Dir.StatFileError ||
    std.Io.File.OpenError;

pub fn isRegularFile(dir: Io.Dir, io: Io, name: []const u8) FsUtilError!bool {
    const st = dir.statFile(io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return st.kind == .file;
}

pub fn ensureRegularFile(dir: Io.Dir, io: Io, name: []const u8) FsUtilError!void {
    if (try isRegularFile(dir, io, name)) return;

    var f = dir.createFile(io, name, .{}) catch |err| switch (err) {
        error.IsDir => return error.NotARegularFile,
        else => |e| return e,
    };
    f.close(io);
}

pub fn statMode(dir: Io.Dir, io: Io, sub_path: []const u8) !std.posix.mode_t {
    const st = try dir.statFile(io, sub_path, .{});
    return st.permissions.toMode() & 0o7777;
}

const testing = std.testing;

test "ensureRegularFile creates an empty file when absent and is idempotent" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try ensureRegularFile(tmp.dir, testing.io, "f");
    try ensureRegularFile(tmp.dir, testing.io, "f");

    const st = try tmp.dir.statFile(testing.io, "f", .{});
    try testing.expectEqual(@as(Io.File.Kind, .file), st.kind);
}

test "ensureRegularFile rejects an existing directory" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "d", .default_dir);
    try testing.expectError(error.NotARegularFile, ensureRegularFile(tmp.dir, testing.io, "d"));
}

test "isRegularFile distinguishes files, directories and missing entries" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try ensureRegularFile(tmp.dir, testing.io, "f");
    try tmp.dir.createDir(testing.io, "d", .default_dir);

    try testing.expect(try isRegularFile(tmp.dir, testing.io, "f"));
    try testing.expect(!try isRegularFile(tmp.dir, testing.io, "d"));
    try testing.expect(!try isRegularFile(tmp.dir, testing.io, "missing"));
}

test "statMode returns file permissions masked to 0o7777" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try ensureRegularFile(tmp.dir, testing.io, "f");

    // Default file mode is usually 0o644; mask ensures only permission bits.
    const mode_bits = try statMode(tmp.dir, testing.io, "f");
    try testing.expectEqual(mode_bits, mode_bits & 0o7777);
}

test "statMode reflects explicit file mode" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var f = try tmp.dir.createFile(testing.io, "f", .{ .permissions = mode.private });
    defer f.close(testing.io);

    const mode_bits = try statMode(tmp.dir, testing.io, "f");
    try testing.expectFmt("0600", "{o:0>4}", .{mode_bits});
}

test "statMode reflects directory permissions" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "d", mode.executable);

    const mode_bits = try statMode(tmp.dir, testing.io, "d");
    try testing.expectFmt("0755", "{o:0>4}", .{mode_bits});
}

test "statMode fails for missing entry" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try testing.expectError(error.FileNotFound, statMode(tmp.dir, testing.io, "missing"));
}
