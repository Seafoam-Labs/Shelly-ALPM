//! Owned account records resolved through libc NSS, including systemd-homed.
const std = @import("std");

pub const Account = struct {
    username: []u8,
    home: []u8,
    uid: std.c.uid_t,
    gid: std.c.gid_t,

    pub fn deinit(self: Account, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
        allocator.free(self.home);
    }
};

pub fn byName(allocator: std.mem.Allocator, username: []const u8) !?Account {
    if (username.len == 0 or std.mem.indexOfScalar(u8, username, 0) != null) return null;
    const name = try allocator.dupeZ(u8, username);
    defer allocator.free(name);
    return lookup(allocator, .{ .name = name }, resolve);
}

pub fn byUid(allocator: std.mem.Allocator, uid: std.c.uid_t) !?Account {
    return lookup(allocator, .{ .uid = uid }, resolve);
}

pub fn byUidText(allocator: std.mem.Allocator, text: []const u8) !?Account {
    if (text.len == 0) return null;
    for (text) |character| if (!std.ascii.isDigit(character)) return null;
    const uid = std.fmt.parseUnsigned(std.c.uid_t, text, 10) catch return null;
    return byUid(allocator, uid);
}

const Query = union(enum) { name: [:0]const u8, uid: std.c.uid_t };

fn resolve(query: Query, record: *std.c.passwd, buffer: []u8, result: *?*std.c.passwd) c_int {
    return switch (query) {
        .name => |name| std.c.getpwnam_r(name, record, buffer.ptr, buffer.len, result),
        .uid => |uid| std.c.getpwuid_r(uid, record, buffer.ptr, buffer.len, result),
    };
}

fn lookup(allocator: std.mem.Allocator, query: Query, comptime resolver: anytype) !?Account {
    var buffer = try allocator.alloc(u8, 1024);
    defer allocator.free(buffer);
    while (true) {
        var record: std.c.passwd = undefined;
        var result: ?*std.c.passwd = null;
        const status = resolver(query, &record, buffer, &result);
        if (status == @intFromEnum(std.c.E.RANGE)) {
            // Bound memory use even if an NSS backend repeatedly requests more.
            if (buffer.len >= 4 * 1024 * 1024) return error.AccountRecordTooLarge;
            buffer = try allocator.realloc(buffer, buffer.len * 2);
            continue;
        }
        if (status != 0) return error.AccountLookupFailed;
        const found = result orelse return null;
        const username = try allocator.dupe(u8, std.mem.span(found.name orelse return error.InvalidAccountRecord));
        errdefer allocator.free(username);
        const home = try allocator.dupe(u8, std.mem.span(found.dir orelse return error.InvalidAccountRecord));
        return .{ .username = username, .home = home, .uid = found.uid, .gid = found.gid };
    }
}

test "NSS account lookup retries ERANGE and owns returned strings" {
    const Fake = struct {
        fn resolve(query: Query, record: *std.c.passwd, buffer: []u8, result: *?*std.c.passwd) c_int {
            if (query != .uid or query.uid != 60123) return @intFromEnum(std.c.E.IO);
            if (buffer.len < 2048) return @intFromEnum(std.c.E.RANGE);
            const name = "homed-only";
            const home = "/home/custom-home";
            @memcpy(buffer[0 .. name.len + 1], name ++ "\x00");
            @memcpy(buffer[64 .. 64 + home.len + 1], home ++ "\x00");
            record.* = std.mem.zeroes(std.c.passwd);
            record.name = @ptrCast(buffer.ptr);
            record.dir = @ptrCast(buffer[64..].ptr);
            record.uid = 60123;
            record.gid = 60124;
            result.* = record;
            return 0;
        }
    };
    const account = (try lookup(std.testing.allocator, .{ .uid = 60123 }, Fake.resolve)).?;
    defer account.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("homed-only", account.username);
    try std.testing.expectEqualStrings("/home/custom-home", account.home);
    try std.testing.expectEqual(60123, account.uid);
    try std.testing.expectEqual(60124, account.gid);
}

test "NSS account lookup distinguishes missing accounts and backend failures" {
    const Fake = struct {
        fn resolve(query: Query, _: *std.c.passwd, _: []u8, result: *?*std.c.passwd) c_int {
            result.* = null;
            return if (query.uid == 1) 0 else @intFromEnum(std.c.E.IO);
        }
    };
    try std.testing.expect(try lookup(std.testing.allocator, .{ .uid = 1 }, Fake.resolve) == null);
    try std.testing.expectError(error.AccountLookupFailed, lookup(std.testing.allocator, .{ .uid = 2 }, Fake.resolve));
}

test "NSS account lookup rejects malformed names and UIDs" {
    for ([_][]const u8{ "", "-1", "+1", "1_000", " 1000", "4294967296" }) |uid|
        try std.testing.expect(try byUidText(std.testing.allocator, uid) == null);
    try std.testing.expect(try byName(std.testing.allocator, "") == null);
    try std.testing.expect(try byName(std.testing.allocator, "root\x00other") == null);
}

test "NSS account lookup resolves a local account by name and UID" {
    const root = (try byUid(std.testing.allocator, 0)) orelse return error.MissingRootAccount;
    defer root.deinit(std.testing.allocator);
    const named = (try byName(std.testing.allocator, root.username)).?;
    defer named.deinit(std.testing.allocator);
    try std.testing.expectEqual(root.uid, named.uid);
    try std.testing.expectEqual(root.gid, named.gid);
    try std.testing.expectEqualStrings(root.home, named.home);
}
