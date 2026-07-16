const std = @import("std");
const Io = std.Io;

const fsutil = @import("../helpers/fsutil.zig");

pub const KeyfilesError = fsutil.FsUtilError ||
    std.Io.Dir.OpenError ||
    std.Io.Dir.SetFilePermissionsError;

pub fn trustdbExists(
    base: std.Io.Dir,
    io: Io,
    keyring_dir: []const u8,
) KeyfilesError!bool {
    var dir = base.openDir(io, keyring_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    defer dir.close(io);

    return fsutil.isRegularFile(dir, io, "trustdb.gpg");
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

pub const ResolveKeyringsError = error{
    NoKeyringsFound,
    MissingKeyringFile,
    PopulateFromMissing,
    OutOfMemory,
} || std.Io.Dir.OpenError ||
    std.Io.Dir.Iterator.Error ||
    fsutil.FsUtilError;

pub fn resolveKeyrings(
    allocator: std.mem.Allocator,
    base: std.Io.Dir,
    io: Io,
    import_dir: []const u8,
    requested: []const []const u8,
) ResolveKeyringsError![][]const u8 {
    if (requested.len == 0) {
        return discoverKeyrings(allocator, base, io, import_dir);
    }

    return validateRequestedKeyrings(allocator, base, io, import_dir, requested);
}

fn discoverKeyrings(
    allocator: std.mem.Allocator,
    base: std.Io.Dir,
    io: Io,
    import_dir: []const u8,
) ResolveKeyringsError![][]const u8 {
    var dir = base.openDir(io, import_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.PopulateFromMissing,
        else => |e| return e,
    };
    defer dir.close(io);

    var ids: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (ids.items) |id| allocator.free(id);
        ids.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".gpg")) continue;
        if (entry.name.len <= ".gpg".len) continue;

        const stem = entry.name[0 .. entry.name.len - ".gpg".len];
        const owned = try allocator.dupe(u8, stem);
        try ids.append(allocator, owned);
    }

    if (ids.items.len == 0) return error.NoKeyringsFound;

    return try ids.toOwnedSlice(allocator);
}

fn validateRequestedKeyrings(
    allocator: std.mem.Allocator,
    base: std.Io.Dir,
    io: Io,
    import_dir: []const u8,
    requested: []const []const u8,
) ResolveKeyringsError![][]const u8 {
    var dir = base.openDir(io, import_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.PopulateFromMissing,
        else => |e| return e,
    };
    defer dir.close(io);

    var is_missing = false;
    for (requested) |id| {
        if (!try keyringIdFileExists(dir, io, id)) is_missing = true;
    }

    if (is_missing) return error.MissingKeyringFile;

    var result = try allocator.alloc([]const u8, requested.len);
    errdefer allocator.free(result);
    for (requested, 0..) |id, i| {
        result[i] = try allocator.dupe(u8, id);
    }
    return result;
}

fn keyringIdFileExists(dir: Io.Dir, io: Io, id: []const u8) !bool {
    var name_buf: [256]u8 = undefined;
    const filename = std.fmt.bufPrint(&name_buf, "{s}.gpg", .{id}) catch return false;
    return fsutil.isRegularFile(dir, io, filename);
}

pub fn keyringFileExists(
    base: std.Io.Dir,
    io: Io,
    import_dir: []const u8,
    id: []const u8,
) !bool {
    var dir = try base.openDir(io, import_dir, .{});
    defer dir.close(io);
    return keyringIdFileExists(dir, io, id);
}

pub fn readTrustedFingerprints(
    allocator: std.mem.Allocator,
    base: std.Io.Dir,
    io: Io,
    import_dir: []const u8,
    keyring_id: []const u8,
) ![][]const u8 {
    return readFingerprintFile(allocator, base, io, import_dir, keyring_id, "-trusted");
}

pub fn readRevokedFingerprints(
    allocator: std.mem.Allocator,
    base: std.Io.Dir,
    io: Io,
    import_dir: []const u8,
    keyring_id: []const u8,
) ![][]const u8 {
    return readFingerprintFile(allocator, base, io, import_dir, keyring_id, "-revoked");
}

fn readFingerprintFile(
    allocator: std.mem.Allocator,
    base: std.Io.Dir,
    io: Io,
    import_dir: []const u8,
    keyring_id: []const u8,
    suffix: []const u8,
) ![][]const u8 {
    var dir = base.openDir(io, import_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => |e| return e,
    };
    defer dir.close(io);

    var name_buf: [256]u8 = undefined;
    const filename = std.fmt.bufPrint(&name_buf, "{s}{s}", .{ keyring_id, suffix }) catch
        return &.{};

    var file = dir.openFile(io, filename, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => |e| return e,
    };
    defer file.close(io);

    var read_buf: [16384]u8 = undefined;
    const n = try file.readPositionalAll(io, &read_buf, 0);
    if (n == read_buf.len) {
        const size = try file.length(io);
        if (size > n) return error.MetadataFileTooLarge;
    }
    const contents = read_buf[0..n];

    var fingerprints: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (fingerprints.items) |fp| allocator.free(fp);
        fingerprints.deinit(allocator);
    }

    var iter = std.mem.splitScalar(u8, contents, '\n');
    while (iter.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        const fp = if (std.mem.indexOfScalar(u8, line, ':')) |pos|
            line[0..pos]
        else
            line;
        if (fp.len == 0) continue;
        try fingerprints.append(allocator, try allocator.dupe(u8, fp));
    }

    return try fingerprints.toOwnedSlice(allocator);
}

pub fn trustedFileNonempty(
    base: std.Io.Dir,
    io: Io,
    import_dir: []const u8,
    keyring_id: []const u8,
) !bool {
    var dir = base.openDir(io, import_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    defer dir.close(io);

    var name_buf: [256]u8 = undefined;
    const filename = std.fmt.bufPrint(&name_buf, "{s}-trusted", .{keyring_id}) catch
        return false;

    const st = dir.statFile(io, filename, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return st.kind == .file and st.size > 0;
}

const testing = std.testing;

test "trustdbExists returns false when trustdb.gpg is absent" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "gnupg", .default_dir);

    try testing.expect(!try trustdbExists(tmp.dir, testing.io, "gnupg"));
}

test "trustdbExists returns true when trustdb.gpg exists as a regular file" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "gnupg", .default_dir);
    {
        var dir = try tmp.dir.openDir(testing.io, "gnupg", .{});
        defer dir.close(testing.io);
        var f = try dir.createFile(testing.io, "trustdb.gpg", .{});
        f.close(testing.io);
    }

    try testing.expect(try trustdbExists(tmp.dir, testing.io, "gnupg"));
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

    try testing.expectFmt("0644", "{o:0>4}", .{try fsutil.statMode(gnupg, testing.io, "trustdb.gpg")});
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

fn touch(dir: Io.Dir, io: Io, name: []const u8) !void {
    var f = try dir.createFile(io, name, .{});
    f.close(io);
}

test "trustdbExists returns false when trustdb.gpg is a directory" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "gnupg", .default_dir);
    {
        var dir = try tmp.dir.openDir(testing.io, "gnupg", .{});
        defer dir.close(testing.io);
        try dir.createDir(testing.io, "trustdb.gpg", .default_dir);
    }

    try testing.expect(!try trustdbExists(tmp.dir, testing.io, "gnupg"));
}

test "trustdbExists returns false when the keyring directory is absent" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try testing.expect(!try trustdbExists(tmp.dir, testing.io, "gnupg"));
}

test "resolveKeyrings discovers every .gpg file when no targets are given" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "keyrings", .default_dir);
    {
        var dir = try tmp.dir.openDir(testing.io, "keyrings", .{});
        defer dir.close(testing.io);
        try touch(dir, testing.io, "archlinux.gpg");
        try touch(dir, testing.io, "cachyos.gpg");
        try touch(dir, testing.io, "arch32.gpg");
        // Non-.gpg files must be ignored.
        try touch(dir, testing.io, "archlinux-trusted");
        try touch(dir, testing.io, "archlinux-revoked");
        try touch(dir, testing.io, "README");
    }

    const ids = try resolveKeyrings(
        testing.allocator,
        tmp.dir,
        testing.io,
        "keyrings",
        &.{},
    );
    defer {
        for (ids) |id| testing.allocator.free(id);
        testing.allocator.free(ids);
    }

    // Directory order is not guaranteed, so collect and compare as a set.
    var got = std.AutoHashMap(u64, void).init(testing.allocator);
    defer got.deinit();
    for (ids) |id| try got.put(std.hash_map.hashString(id), {});
    try testing.expectEqual(@as(usize, 3), ids.len);
    try testing.expect(got.contains(std.hash_map.hashString("archlinux")));
    try testing.expect(got.contains(std.hash_map.hashString("cachyos")));
    try testing.expect(got.contains(std.hash_map.hashString("arch32")));
}

test "resolveKeyrings fails when the import directory has no .gpg files" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "keyrings", .default_dir);
    {
        var dir = try tmp.dir.openDir(testing.io, "keyrings", .{});
        defer dir.close(testing.io);
        try touch(dir, testing.io, "README");
    }

    try testing.expectError(
        error.NoKeyringsFound,
        resolveKeyrings(testing.allocator, tmp.dir, testing.io, "keyrings", &.{}),
    );
}

test "resolveKeyrings fails when the import directory is empty" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "keyrings", .default_dir);

    try testing.expectError(
        error.NoKeyringsFound,
        resolveKeyrings(testing.allocator, tmp.dir, testing.io, "keyrings", &.{}),
    );
}

test "resolveKeyrings reports PopulateFromMissing when the directory is absent" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // No targets: discovery path.
    try testing.expectError(
        error.PopulateFromMissing,
        resolveKeyrings(testing.allocator, tmp.dir, testing.io, "does-not-exist", &.{}),
    );

    // Targets supplied: validation path.
    const requested: []const []const u8 = &.{"archlinux"};
    try testing.expectError(
        error.PopulateFromMissing,
        resolveKeyrings(testing.allocator, tmp.dir, testing.io, "does-not-exist", requested),
    );
}

test "resolveKeyrings accepts requested keyring IDs whose .gpg files exist" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "keyrings", .default_dir);
    {
        var dir = try tmp.dir.openDir(testing.io, "keyrings", .{});
        defer dir.close(testing.io);
        try touch(dir, testing.io, "archlinux.gpg");
        try touch(dir, testing.io, "cachyos.gpg");
    }

    const requested: []const []const u8 = &.{ "archlinux", "cachyos" };
    const ids = try resolveKeyrings(
        testing.allocator,
        tmp.dir,
        testing.io,
        "keyrings",
        requested,
    );
    defer {
        for (ids) |id| testing.allocator.free(id);
        testing.allocator.free(ids);
    }

    try testing.expectEqual(@as(usize, 2), ids.len);
    try testing.expectEqualStrings("archlinux", ids[0]);
    try testing.expectEqualStrings("cachyos", ids[1]);
}

test "resolveKeyrings reports all missing requested keyring files" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "keyrings", .default_dir);
    {
        var dir = try tmp.dir.openDir(testing.io, "keyrings", .{});
        defer dir.close(testing.io);
        try touch(dir, testing.io, "archlinux.gpg");
    }

    const requested: []const []const u8 = &.{ "archlinux", "missing1", "missing2" };
    try testing.expectError(
        error.MissingKeyringFile,
        resolveKeyrings(testing.allocator, tmp.dir, testing.io, "keyrings", requested),
    );
}

test "resolveKeyrings rejects a requested keyring that is a directory" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "keyrings", .default_dir);
    {
        var dir = try tmp.dir.openDir(testing.io, "keyrings", .{});
        defer dir.close(testing.io);
        try dir.createDir(testing.io, "weird.gpg", .default_dir);
    }

    const requested: []const []const u8 = &.{"weird"};
    try testing.expectError(
        error.MissingKeyringFile,
        resolveKeyrings(testing.allocator, tmp.dir, testing.io, "keyrings", requested),
    );
}

fn writeFile(dir: Io.Dir, io: Io, name: []const u8, content: []const u8) !void {
    var f = try dir.createFile(io, name, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, content);
}

test "readTrustedFingerprints returns an empty list when the file is absent" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "keyrings", .default_dir);

    const fps = try readTrustedFingerprints(
        testing.allocator,
        tmp.dir,
        testing.io,
        "keyrings",
        "archlinux",
    );
    defer testing.allocator.free(fps);

    try testing.expectEqual(@as(usize, 0), fps.len);
}

test "readTrustedFingerprints returns an empty list when the directory is absent" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const fps = try readTrustedFingerprints(
        testing.allocator,
        tmp.dir,
        testing.io,
        "nonexistent",
        "archlinux",
    );
    defer testing.allocator.free(fps);

    try testing.expectEqual(@as(usize, 0), fps.len);
}

test "readTrustedFingerprints extracts fingerprints before the first colon" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "keyrings", .default_dir);
    {
        var dir = try tmp.dir.openDir(testing.io, "keyrings", .{});
        defer dir.close(testing.io);
        try writeFile(dir, testing.io, "archlinux-trusted", "ABCD1234EFGH5678:4:\n" ++
            "IJKL9012MNOP3456:4:\n");
    }

    const fps = try readTrustedFingerprints(
        testing.allocator,
        tmp.dir,
        testing.io,
        "keyrings",
        "archlinux",
    );
    defer {
        for (fps) |fp| testing.allocator.free(fp);
        testing.allocator.free(fps);
    }

    try testing.expectEqual(@as(usize, 2), fps.len);
    try testing.expectEqualStrings("ABCD1234EFGH5678", fps[0]);
    try testing.expectEqualStrings("IJKL9012MNOP3456", fps[1]);
}

test "readTrustedFingerprints skips blank and comment lines" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "keyrings", .default_dir);
    {
        var dir = try tmp.dir.openDir(testing.io, "keyrings", .{});
        defer dir.close(testing.io);
        try writeFile(dir, testing.io, "archlinux-trusted", "# Trusted keys for archlinux\n" ++
            "\n" ++
            "ABCD1234EFGH5678:4:\n" ++
            "# another comment\n" ++
            "\n" ++
            "IJKL9012MNOP3456:4:\n");
    }

    const fps = try readTrustedFingerprints(
        testing.allocator,
        tmp.dir,
        testing.io,
        "keyrings",
        "archlinux",
    );
    defer {
        for (fps) |fp| testing.allocator.free(fp);
        testing.allocator.free(fps);
    }

    try testing.expectEqual(@as(usize, 2), fps.len);
    try testing.expectEqualStrings("ABCD1234EFGH5678", fps[0]);
    try testing.expectEqualStrings("IJKL9012MNOP3456", fps[1]);
}

test "readTrustedFingerprints accepts lines without a colon" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "keyrings", .default_dir);
    {
        var dir = try tmp.dir.openDir(testing.io, "keyrings", .{});
        defer dir.close(testing.io);
        try writeFile(dir, testing.io, "archlinux-trusted", "ABCD1234EFGH5678\n");
    }

    const fps = try readTrustedFingerprints(
        testing.allocator,
        tmp.dir,
        testing.io,
        "keyrings",
        "archlinux",
    );
    defer {
        for (fps) |fp| testing.allocator.free(fp);
        testing.allocator.free(fps);
    }

    try testing.expectEqual(@as(usize, 1), fps.len);
    try testing.expectEqualStrings("ABCD1234EFGH5678", fps[0]);
}

test "readTrustedFingerprints strips trailing carriage returns" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "keyrings", .default_dir);
    {
        var dir = try tmp.dir.openDir(testing.io, "keyrings", .{});
        defer dir.close(testing.io);
        try writeFile(dir, testing.io, "archlinux-trusted", "ABCD1234EFGH5678\r\n");
    }

    const fps = try readTrustedFingerprints(
        testing.allocator,
        tmp.dir,
        testing.io,
        "keyrings",
        "archlinux",
    );
    defer {
        for (fps) |fp| testing.allocator.free(fp);
        testing.allocator.free(fps);
    }

    try testing.expectEqual(@as(usize, 1), fps.len);
    try testing.expectEqualStrings("ABCD1234EFGH5678", fps[0]);
}

test "readTrustedFingerprints returns an empty list for an empty file" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "keyrings", .default_dir);
    {
        var dir = try tmp.dir.openDir(testing.io, "keyrings", .{});
        defer dir.close(testing.io);
        try touch(dir, testing.io, "archlinux-trusted");
    }

    const fps = try readTrustedFingerprints(
        testing.allocator,
        tmp.dir,
        testing.io,
        "keyrings",
        "archlinux",
    );
    defer testing.allocator.free(fps);

    try testing.expectEqual(@as(usize, 0), fps.len);
}

test "trustedFileNonempty returns true for a nonempty trusted file" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "keyrings", .default_dir);
    {
        var dir = try tmp.dir.openDir(testing.io, "keyrings", .{});
        defer dir.close(testing.io);
        try writeFile(dir, testing.io, "archlinux-trusted", "ABCD1234EFGH5678:f:\n");
    }

    try testing.expect(try trustedFileNonempty(
        tmp.dir,
        testing.io,
        "keyrings",
        "archlinux",
    ));
}

test "trustedFileNonempty returns false for an empty trusted file" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "keyrings", .default_dir);
    {
        var dir = try tmp.dir.openDir(testing.io, "keyrings", .{});
        defer dir.close(testing.io);
        try touch(dir, testing.io, "archlinux-trusted");
    }

    try testing.expect(!try trustedFileNonempty(
        tmp.dir,
        testing.io,
        "keyrings",
        "archlinux",
    ));
}

test "trustedFileNonempty returns false when the trusted file is absent" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "keyrings", .default_dir);

    try testing.expect(!try trustedFileNonempty(
        tmp.dir,
        testing.io,
        "keyrings",
        "archlinux",
    ));
}

test "trustedFileNonempty returns false when the import directory is absent" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try testing.expect(!try trustedFileNonempty(
        tmp.dir,
        testing.io,
        "keyrings",
        "archlinux",
    ));
}

test "readRevokedFingerprints reads fingerprints from the revoked file" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "keyrings", .default_dir);
    {
        var dir = try tmp.dir.openDir(testing.io, "keyrings", .{});
        defer dir.close(testing.io);
        try writeFile(dir, testing.io, "archlinux-revoked", "DEAD1111BEEF2222\n# revoked\n\nFEED3333CAFE4444:\n");
    }

    const fps = try readRevokedFingerprints(
        testing.allocator,
        tmp.dir,
        testing.io,
        "keyrings",
        "archlinux",
    );
    defer {
        for (fps) |fp| testing.allocator.free(fp);
        testing.allocator.free(fps);
    }

    try testing.expectEqual(@as(usize, 2), fps.len);
    try testing.expectEqualStrings("DEAD1111BEEF2222", fps[0]);
    try testing.expectEqualStrings("FEED3333CAFE4444", fps[1]);
}

test "readRevokedFingerprints returns an empty list when the revoked file is absent" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "keyrings", .default_dir);

    const fps = try readRevokedFingerprints(
        testing.allocator,
        tmp.dir,
        testing.io,
        "keyrings",
        "archlinux",
    );
    defer testing.allocator.free(fps);

    try testing.expectEqual(@as(usize, 0), fps.len);
}

test "readRevokedFingerprints ignores a similarly-named trusted file" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, "keyrings", .default_dir);
    {
        var dir = try tmp.dir.openDir(testing.io, "keyrings", .{});
        defer dir.close(testing.io);
        // Only the -trusted side exists; -revoked must not pick it up.
        try writeFile(dir, testing.io, "archlinux-trusted", "TRUSTED0000000000\n");
    }

    const fps = try readRevokedFingerprints(
        testing.allocator,
        tmp.dir,
        testing.io,
        "keyrings",
        "archlinux",
    );
    defer testing.allocator.free(fps);

    try testing.expectEqual(@as(usize, 0), fps.len);
}
