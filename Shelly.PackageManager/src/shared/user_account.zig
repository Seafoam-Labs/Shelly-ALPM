//! Owned account records resolved through libc NSS, including systemd-homed.
const std = @import("std");
pub const caller_io = @import("caller_io.zig");

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
    const name = try allocator.dupeSentinel(u8, username, 0);
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

/// Elevation markers are meaningful only while actually running as root.
/// Invalid markers are errors, never permission to fall back to root.
pub fn caller(allocator: std.mem.Allocator, environ: std.process.Environ) !Account {
    return callerFor(allocator, std.c.geteuid(), environ.getPosix("SUDO_USER"), environ.getPosix("DOAS_USER"), environ.getPosix("PKEXEC_UID"));
}

pub fn callerFor(allocator: std.mem.Allocator, effective_uid: std.c.uid_t, sudo_user: ?[]const u8, doas_user: ?[]const u8, pkexec_uid: ?[]const u8) !Account {
    const account = if (effective_uid != 0)
        try byUid(allocator, effective_uid)
    else if (sudo_user) |name|
        try byName(allocator, name)
    else if (doas_user) |name|
        try byName(allocator, name)
    else if (pkexec_uid) |uid|
        try byUidText(allocator, uid)
    else
        try byUid(allocator, 0);
    const found = account orelse return error.InvokingUserUnavailable;
    if (found.username.len == 0 or !std.fs.path.isAbsolute(found.home)) {
        found.deinit(allocator);
        return error.InvokingUserUnavailable;
    }
    return found;
}

pub fn callerHome(allocator: std.mem.Allocator, environ: std.process.Environ) ![]u8 {
    const account = try caller(allocator, environ);
    defer account.deinit(allocator);
    // Ordinary user sessions may deliberately override HOME (including tests).
    if (std.c.geteuid() != 0) {
        if (environ.getPosix("HOME")) |home| {
            if (std.fs.path.isAbsolute(home)) return allocator.dupe(u8, home);
        }
    }
    return allocator.dupe(u8, account.home);
}

test "NSS caller distinguishes direct root, elevated callers and stale markers" {
    const a = std.testing.allocator;
    const nobody = (try byName(a, "nobody")) orelse return error.SkipZigTest;
    defer nobody.deinit(a);
    const uid = try std.fmt.allocPrint(a, "{d}", .{nobody.uid});
    defer a.free(uid);
    for ([_][3]?[]const u8{ .{ nobody.username, null, null }, .{ null, nobody.username, null }, .{ null, null, uid } }) |markers| {
        const found = try callerFor(a, 0, markers[0], markers[1], markers[2]);
        defer found.deinit(a);
        try std.testing.expectEqual(nobody.uid, found.uid);
        try std.testing.expectEqual(nobody.gid, found.gid);
    }
    for ([_][3]?[]const u8{ .{ null, null, null }, .{ "root", null, null }, .{ null, null, "0" } }) |markers| {
        const root = try callerFor(a, 0, markers[0], markers[1], markers[2]);
        defer root.deinit(a);
        try std.testing.expectEqual(0, root.uid);
    }
    try std.testing.expectError(error.InvokingUserUnavailable, callerFor(a, 0, "", null, null));
    try std.testing.expectError(error.InvokingUserUnavailable, callerFor(a, 0, "shelly-missing-caller-7419", null, null));
    try std.testing.expectError(error.InvokingUserUnavailable, callerFor(a, 0, null, null, "invalid"));
    const stale = try callerFor(a, nobody.uid, "root", null, "invalid");
    defer stale.deinit(a);
    try std.testing.expectEqual(nobody.uid, stale.uid);
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
        if (status == @backingInt(std.c.E.RANGE)) {
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
            if (query != .uid or query.uid != 60123) return @backingInt(std.c.E.IO);
            if (buffer.len < 2048) return @backingInt(std.c.E.RANGE);
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
            return if (query.uid == 1) 0 else @backingInt(std.c.E.IO);
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

test {
    std.testing.refAllDecls(caller_io);
}
