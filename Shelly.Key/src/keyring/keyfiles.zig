const std = @import("std");
const Io = std.Io;

const fsutil = @import("../helpers/fsutil.zig");

pub const KeyfilesError = fsutil.FsUtilError ||
    std.Io.Dir.OpenError ||
    std.Io.Dir.SetFilePermissionsError;

// Old GnuPG keyring format for parity with older setups / `gpg1` interop.
// TODO: No longer needed? Modern GnuPG commonly uses `pubring.kbx` and private-key storage under `private-keys-v1.d`.
pub fn ensureKeyringFilesCreated(
    base: std.Io.Dir,
    io: Io,
    keyring_dir: []const u8,
) KeyfilesError!void {
    var dir = try base.openDir(io, keyring_dir, .{});
    defer dir.close(io);

    try fsutil.ensureRegularFile(dir, io, "pubring.gpg");
    try fsutil.ensureRegularFile(dir, io, "secring.gpg");
}

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

    try dir.setFilePermissions(io, "pubring.gpg", fsutil.mode.readable, .{});
    try dir.setFilePermissions(io, "trustdb.gpg", fsutil.mode.readable, .{});
    try dir.setFilePermissions(io, "secring.gpg", fsutil.mode.private, .{});
}

const testing = std.testing;

fn statMode(dir: Io.Dir, io: Io, sub_path: []const u8) !std.posix.mode_t {
    const st = try dir.statFile(io, sub_path, .{});
    // Mask with 0o7777 to keep only permission bits.
    return st.permissions.toMode() & 0o7777;
}

fn statSize(dir: Io.Dir, io: Io, sub_path: []const u8) !u64 {
    const st = try dir.statFile(io, sub_path, .{});
    return st.size;
}

test "ensureLegacyKeyringFilesCreated creates pubring.gpg and secring.gpg when absent" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "gnupg", .default_dir);

    try ensureKeyringFilesCreated(tmp.dir, testing.io, "gnupg");

    var gnupg = try tmp.dir.openDir(testing.io, "gnupg", .{});
    defer gnupg.close(testing.io);

    const pub_st = try gnupg.statFile(testing.io, "pubring.gpg", .{});
    try testing.expectEqual(@as(Io.File.Kind, .file), pub_st.kind);
    try testing.expectEqual(@as(u64, 0), try statSize(gnupg, testing.io, "pubring.gpg"));

    const sec_st = try gnupg.statFile(testing.io, "secring.gpg", .{});
    try testing.expectEqual(@as(Io.File.Kind, .file), sec_st.kind);
    try testing.expectEqual(@as(u64, 0), try statSize(gnupg, testing.io, "secring.gpg"));
}

test "ensureLegacyKeyringFilesCreated is idempotent and preserves existing content" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "gnupg", .default_dir);
    {
        var dir = try tmp.dir.openDir(testing.io, "gnupg", .{});
        defer dir.close(testing.io);
        var f = try dir.createFile(testing.io, "pubring.gpg", .{});
        try f.writeStreamingAll(testing.io, "preserved");
        f.close(testing.io);
    }

    try ensureKeyringFilesCreated(tmp.dir, testing.io, "gnupg");
    try ensureKeyringFilesCreated(tmp.dir, testing.io, "gnupg");

    var gnupg = try tmp.dir.openDir(testing.io, "gnupg", .{});
    defer gnupg.close(testing.io);

    try testing.expectEqual(
        @as(u64, "preserved".len),
        try statSize(gnupg, testing.io, "pubring.gpg"),
    );
    try testing.expectEqual(@as(u64, 0), try statSize(gnupg, testing.io, "secring.gpg"));
}

test "ensureLegacyKeyringFilesCreated fails when pubring.gpg is a directory" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "gnupg", .default_dir);
    try tmp.dir.createDir(testing.io, "gnupg/pubring.gpg", .default_dir);

    try testing.expectError(
        error.NotARegularFile,
        ensureKeyringFilesCreated(tmp.dir, testing.io, "gnupg"),
    );
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

test "applyLegacyKeyringPermissions sets the canonical modes on all three files" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "gnupg", .default_dir);
    {
        var dir = try tmp.dir.openDir(testing.io, "gnupg", .{});
        defer dir.close(testing.io);
        for ([_][]const u8{ "pubring.gpg", "secring.gpg", "trustdb.gpg" }) |name| {
            var f = try dir.createFile(testing.io, name, .{});
            f.close(testing.io);
            // Set deliberately wrong modes.
            try dir.setFilePermissions(testing.io, name, @enumFromInt(0o600), .{});
        }
    }

    try applyKeyringPermissions(tmp.dir, testing.io, "gnupg");

    var gnupg = try tmp.dir.openDir(testing.io, "gnupg", .{});
    defer gnupg.close(testing.io);

    try testing.expectEqual(@as(std.posix.mode_t, 0o644), try statMode(gnupg, testing.io, "pubring.gpg"));
    try testing.expectEqual(@as(std.posix.mode_t, 0o644), try statMode(gnupg, testing.io, "trustdb.gpg"));
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), try statMode(gnupg, testing.io, "secring.gpg"));
}

test "applyLegacyKeyringPermissions reports missing trustdb.gpg" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "gnupg", .default_dir);
    {
        var dir = try tmp.dir.openDir(testing.io, "gnupg", .{});
        defer dir.close(testing.io);
        var f = try dir.createFile(testing.io, "pubring.gpg", .{});
        f.close(testing.io);
        var g = try dir.createFile(testing.io, "secring.gpg", .{});
        g.close(testing.io);
    }

    try testing.expectError(
        error.FileNotFound,
        applyKeyringPermissions(tmp.dir, testing.io, "gnupg"),
    );
}
