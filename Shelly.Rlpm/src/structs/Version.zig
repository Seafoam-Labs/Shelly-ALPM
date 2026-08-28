const Version = @This();
const std = @import("std");

raw: []const u8,
epoch: u64,
pkgver: []const u8,
pkgrel: ?[]const u8,

pub fn init(version: []const u8, allocator: std.mem.Allocator) !Version {
    const epoch_index = std.mem.find(u8, version, ":") orelse 0;
    const epoch: []const u8 = version[0..epoch_index];
    const ver_rel: []const u8 = version[epoch_index + 1 ..];
    const last_index = std.mem.findLast(u8, ver_rel, "-") orelse ver_rel.len;
    const ver = ver_rel[0..last_index];
    const rel: ?[]const u8 = if (last_index != ver_rel.len) ver_rel[last_index + 1 ..] else null;
    return .{
        .raw = try allocator.dupe(u8, version),
        .epoch = try std.fmt.parseInt(u64, epoch, 10),
        .pkgver = try allocator.dupe(u8, ver),
        .pkgrel = if (rel) |r| try allocator.dupe(u8, r) else null,
    };
}

pub fn deinit(self: *Version, allocator: std.mem.Allocator) void {
    allocator.free(self.raw);
    allocator.free(self.pkgver);
    if (self.pkgrel) |r| allocator.free(r);
    self.* = undefined;
}

test "Version parses epoch, pkgver, and pkgrel" {
    var version = try Version.init("2:1.27.0-2", std.testing.allocator);
    defer version.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("2:1.27.0-2", version.raw);
    try std.testing.expectEqual(@as(u64, 2), version.epoch);
    try std.testing.expectEqualStrings("1.27.0", version.pkgver);
    try std.testing.expectEqualStrings("2", version.pkgrel.?);
}

test "Version rejects a missing epoch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.InvalidCharacter,
        Version.init("1.27.0-2", arena.allocator()),
    );
}

test "Version permits a missing pkgrel" {
    var version = try Version.init("0:1.27.0", std.testing.allocator);
    defer version.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 0), version.epoch);
    try std.testing.expectEqualStrings("1.27.0", version.pkgver);
    try std.testing.expect(version.pkgrel == null);
}

test "Version uses only the last hyphen as the pkgrel separator" {
    var version = try Version.init("0:1.0-beta-3", std.testing.allocator);
    defer version.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("1.0-beta", version.pkgver);
    try std.testing.expectEqualStrings("3", version.pkgrel.?);
}

test "Version rejects a nonnumeric epoch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.InvalidCharacter,
        Version.init("alpha:1.0-1", arena.allocator()),
    );
}

test "Version owns its string fields" {
    var source = [_]u8{ '2', ':', '1', '.', '0', '-', '3' };
    var version = try Version.init(&source, std.testing.allocator);
    defer version.deinit(std.testing.allocator);

    @memset(&source, 'x');

    try std.testing.expectEqualStrings("2:1.0-3", version.raw);
    try std.testing.expectEqualStrings("1.0", version.pkgver);
    try std.testing.expectEqualStrings("3", version.pkgrel.?);
}

test "Version reports an overflowing epoch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.Overflow,
        Version.init("18446744073709551616:1.0-1", arena.allocator()),
    );
}
