const std = @import("std");
const Io = std.Io;

const magic = "shelly-list 1";
const max_bytes = 256 * 1024 * 1024;

pub const Cached = struct {
    /// identifies what the list was made from; the caller picks its meaning.
    stamp: u64,
    json: []const u8,
    bytes: []u8,

    pub fn deinit(self: Cached, alloc: std.mem.Allocator) void {
        alloc.free(self.bytes);
    }
};

/// returns the saved list, or null when there is none this version can use.
pub fn read(alloc: std.mem.Allocator, io: Io, path: []const u8, kind: []const u8, version: std.SemanticVersion) ?Cached {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(max_bytes)) catch return null;
    return parse(bytes, kind, version) orelse {
        alloc.free(bytes);
        return null;
    };
}

fn parse(bytes: []u8, kind: []const u8, version: std.SemanticVersion) ?Cached {
    const end = std.mem.indexOfScalar(u8, bytes, '\n') orelse return null;
    const json = bytes[end + 1 ..];

    var prefix_buffer: [128]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buffer, magic ++ " {s} {f} ", .{ kind, version }) catch return null;
    if (!std.mem.startsWith(u8, bytes[0..end], prefix)) return null;

    var fields = std.mem.tokenizeScalar(u8, bytes[prefix.len..end], ' ');
    const stamp = std.fmt.parseInt(u64, fields.next() orelse return null, 16) catch return null;
    const length = std.fmt.parseInt(usize, fields.next() orelse return null, 10) catch return null;
    if (json.len != length) return null;
    return .{ .stamp = stamp, .json = json, .bytes = bytes };
}

pub fn write(io: Io, path: []const u8, kind: []const u8, version: std.SemanticVersion, stamp: u64, json: []const u8) !void {
    var staged = try Io.Dir.cwd().createFileAtomic(io, path, .{ .make_path = true, .replace = true });
    defer staged.deinit(io);

    var buffer: [4096]u8 = undefined;
    var writer = staged.file.writer(io, &buffer);
    try writer.interface.print(magic ++ " {s} {f} {x} {d}\n", .{ kind, version, stamp, json.len });
    try writer.interface.writeAll(json);
    try writer.flush();
    try staged.replace(io);
}

const testing = std.testing;
const test_version: std.SemanticVersion = .{ .major = 3, .minor = 4, .patch = 1 };

const TestPath = struct {
    tmp: testing.TmpDir,
    buffer: [Io.Dir.max_path_bytes]u8 = undefined,

    fn path(self: *TestPath) ![]const u8 {
        const len = try self.tmp.dir.realPath(testing.io, &self.buffer);
        const tail = "/shelly/catalog.json";
        @memcpy(self.buffer[len..][0..tail.len], tail);
        return self.buffer[0 .. len + tail.len];
    }
};

test "a saved list is read back with its stamp" {
    var t: TestPath = .{ .tmp = testing.tmpDir(.{}) };
    defer t.tmp.cleanup();
    const path = try t.path();

    try write(testing.io, path, "test", test_version, 0xabc, "[{\"Id\":\"org.a.A\"}]");
    const cached = read(testing.allocator, testing.io, path, "test", test_version) orelse return error.NotCached;
    defer cached.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 0xabc), cached.stamp);
    try testing.expectEqualStrings("[{\"Id\":\"org.a.A\"}]", cached.json);
}

test "saving again replaces the list" {
    var t: TestPath = .{ .tmp = testing.tmpDir(.{}) };
    defer t.tmp.cleanup();
    const path = try t.path();

    try write(testing.io, path, "test", test_version, 1, "[1,2,3,4,5,6]");
    try write(testing.io, path, "test", test_version, 2, "[]");
    const cached = read(testing.allocator, testing.io, path, "test", test_version) orelse return error.NotCached;
    defer cached.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 2), cached.stamp);
    try testing.expectEqualStrings("[]", cached.json);
}

test "a list saved by another version is not used" {
    var t: TestPath = .{ .tmp = testing.tmpDir(.{}) };
    defer t.tmp.cleanup();
    const path = try t.path();

    try write(testing.io, path, "test", test_version, 1, "[]");
    try testing.expect(read(testing.allocator, testing.io, path, "test", .{ .major = 3, .minor = 4, .patch = 2 }) == null);
    const same = read(testing.allocator, testing.io, path, "test", test_version) orelse return error.NotCached;
    same.deinit(testing.allocator);
}

test "a truncated list is not used" {
    var t: TestPath = .{ .tmp = testing.tmpDir(.{}) };
    defer t.tmp.cleanup();
    const path = try t.path();

    try write(testing.io, path, "test", test_version, 1, "[{\"Id\":\"org.a.A\"}]");
    const whole = read(testing.allocator, testing.io, path, "test", test_version) orelse return error.NotCached;
    defer whole.deinit(testing.allocator);
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = whole.bytes[0 .. whole.bytes.len - 4] });
    try testing.expect(read(testing.allocator, testing.io, path, "test", test_version) == null);
}

test "a missing list is not used" {
    try testing.expect(read(testing.allocator, testing.io, "/nonexistent/catalog.json", "test", test_version) == null);
}

test "a list of another kind is not used" {
    var t: TestPath = .{ .tmp = testing.tmpDir(.{}) };
    defer t.tmp.cleanup();
    const path = try t.path();

    try write(testing.io, path, "packages", test_version, 1, "[]");
    try testing.expect(read(testing.allocator, testing.io, path, "flatpak", test_version) == null);
    const same = read(testing.allocator, testing.io, path, "packages", test_version) orelse return error.NotCached;
    same.deinit(testing.allocator);
}
