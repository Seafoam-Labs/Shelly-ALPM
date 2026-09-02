const Version = @This();
const std = @import("std");

pub const CompareResults = enum(i8) {
    lessThan = -1,
    equal = 0,
    greaterThan = 1,
};

raw: []const u8,
epoch: u64,
pkgver: []const u8,
pkgrel: ?[]const u8,

pub fn init(version: []const u8, allocator: std.mem.Allocator) !Version {
    if (version.len == 0) return error.InvalidVersion;

    var epoch_value: u64 = 0;
    var ver_rel = version;
    if (std.mem.find(u8, version, ":")) |epoch_index| {
        if (epoch_index == 0 or epoch_index + 1 == version.len) {
            return error.InvalidVersion;
        }
        epoch_value = try std.fmt.parseInt(u64, version[0..epoch_index], 10);
        ver_rel = version[epoch_index + 1 ..];
    }

    const last_index = std.mem.findLast(u8, ver_rel, "-") orelse ver_rel.len;
    const ver = ver_rel[0..last_index];
    const rel: ?[]const u8 = if (last_index != ver_rel.len) ver_rel[last_index + 1 ..] else null;

    if (ver.len == 0 or (rel != null and rel.?.len == 0)) {
        return error.InvalidVersion;
    }

    const raw = try allocator.dupe(u8, version);
    errdefer allocator.free(raw);
    const pkgver = try allocator.dupe(u8, ver);
    errdefer allocator.free(pkgver);
    const pkgrel: ?[]u8 = if (rel) |release| try allocator.dupe(u8, release) else null;

    return .{
        .raw = raw,
        .epoch = epoch_value,
        .pkgver = pkgver,
        .pkgrel = pkgrel,
    };
}

pub fn deinit(self: *Version, allocator: std.mem.Allocator) void {
    allocator.free(self.raw);
    allocator.free(self.pkgver);
    if (self.pkgrel) |r| allocator.free(r);
    self.* = undefined;
}

/// Compare two versions using the same ordering rules as alpm_pkg_vercmp.
pub fn compareVersions(v1: Version, v2: Version) CompareResults {
    if (v1.epoch < v2.epoch) return .lessThan;
    if (v1.epoch > v2.epoch) return .greaterThan;

    const pkgver_result = compareSegments(v1.pkgver, v2.pkgver);
    if (pkgver_result != .equal) return pkgver_result;

    if (v1.pkgrel != null and v2.pkgrel != null) {
        return compareSegments(v1.pkgrel.?, v2.pkgrel.?);
    }

    return .equal;
}

fn compareSegments(v1: []const u8, v2: []const u8) CompareResults {
    if (std.mem.eql(u8, v1, v2)) return .equal;

    var v1_index: usize = 0;
    var v2_index: usize = 0;

    while (v1_index < v1.len and v2_index < v2.len) {
        const v1_separator_start = v1_index;
        const v2_separator_start = v2_index;

        while (v1_index < v1.len and !isAlphanumeric(v1[v1_index])) {
            v1_index += 1;
        }
        while (v2_index < v2.len and !isAlphanumeric(v2[v2_index])) {
            v2_index += 1;
        }

        if (v1_index == v1.len or v2_index == v2.len) break;

        const v1_separator_length = v1_index - v1_separator_start;
        const v2_separator_length = v2_index - v2_separator_start;
        if (v1_separator_length < v2_separator_length) return .lessThan;
        if (v1_separator_length > v2_separator_length) return .greaterThan;

        const numeric = isDigit(v1[v1_index]);
        var v1_segment_end = v1_index;
        var v2_segment_end = v2_index;

        if (numeric) {
            while (v1_segment_end < v1.len and isDigit(v1[v1_segment_end])) {
                v1_segment_end += 1;
            }
            while (v2_segment_end < v2.len and isDigit(v2[v2_segment_end])) {
                v2_segment_end += 1;
            }
        } else {
            while (v1_segment_end < v1.len and isAlpha(v1[v1_segment_end])) {
                v1_segment_end += 1;
            }
            while (v2_segment_end < v2.len and isAlpha(v2[v2_segment_end])) {
                v2_segment_end += 1;
            }
        }

        // Numeric segments always sort after alphabetic segments.
        if (v2_segment_end == v2_index) {
            return if (numeric) .greaterThan else .lessThan;
        }

        var v1_significant_start = v1_index;
        var v2_significant_start = v2_index;
        if (numeric) {
            while (v1_significant_start < v1_segment_end and v1[v1_significant_start] == '0') {
                v1_significant_start += 1;
            }
            while (v2_significant_start < v2_segment_end and v2[v2_significant_start] == '0') {
                v2_significant_start += 1;
            }

            const v1_digits = v1_segment_end - v1_significant_start;
            const v2_digits = v2_segment_end - v2_significant_start;
            if (v1_digits < v2_digits) return .lessThan;
            if (v1_digits > v2_digits) return .greaterThan;
        }

        const segment_result = compareBytes(
            v1[v1_significant_start..v1_segment_end],
            v2[v2_significant_start..v2_segment_end],
        );
        if (segment_result != .equal) return segment_result;

        v1_index = v1_segment_end;
        v2_index = v2_segment_end;
    }

    if (v1_index == v1.len and v2_index == v2.len) return .equal;

    // A remaining alphabetic segment sorts before an empty string. Any other
    // remaining segment sorts after an empty string.
    if ((v1_index == v1.len and !isAlpha(v2[v2_index])) or
        (v1_index < v1.len and isAlpha(v1[v1_index])))
    {
        return .lessThan;
    }

    return .greaterThan;
}

fn compareBytes(v1: []const u8, v2: []const u8) CompareResults {
    var index: usize = 0;
    const shared_length = @min(v1.len, v2.len);
    while (index < shared_length) : (index += 1) {
        if (v1[index] < v2[index]) return .lessThan;
        if (v1[index] > v2[index]) return .greaterThan;
    }

    if (v1.len < v2.len) return .lessThan;
    if (v1.len > v2.len) return .greaterThan;
    return .equal;
}

fn isDigit(value: u8) bool {
    return value >= '0' and value <= '9';
}

fn isAlpha(value: u8) bool {
    return (value >= 'a' and value <= 'z') or
        (value >= 'A' and value <= 'Z');
}

fn isAlphanumeric(value: u8) bool {
    return isDigit(value) or isAlpha(value);
}

test "Version parses epoch, pkgver, and pkgrel" {
    var version = try Version.init("2:1.27.0-2", std.testing.allocator);
    defer version.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("2:1.27.0-2", version.raw);
    try std.testing.expectEqual(@as(u64, 2), version.epoch);
    try std.testing.expectEqualStrings("1.27.0", version.pkgver);
    try std.testing.expectEqualStrings("2", version.pkgrel.?);
}

test "Version treats a missing epoch as zero" {
    var version = try Version.init("1.27.0-2", std.testing.allocator);
    defer version.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 0), version.epoch);
    try std.testing.expectEqualStrings("1.27.0", version.pkgver);
    try std.testing.expectEqualStrings("2", version.pkgrel.?);
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

test "Version comparison result values match libalpm" {
    try std.testing.expectEqual(@as(i8, -1), @intFromEnum(CompareResults.lessThan));
    try std.testing.expectEqual(@as(i8, 0), @intFromEnum(CompareResults.equal));
    try std.testing.expectEqual(@as(i8, 1), @intFromEnum(CompareResults.greaterThan));
}

test "Version compareVersions matches libalpm ordering" {
    const cases = [_]struct {
        expected: CompareResults,
        v1: []const u8,
        v2: []const u8,
    }{
        .{ .expected = .equal, .v1 = "0:1.0-1", .v2 = "0:1.0-1" },
        .{ .expected = .greaterThan, .v1 = "2:1.0-1", .v2 = "1:99.0-9" },
        .{ .expected = .greaterThan, .v1 = "0:1.10-1", .v2 = "0:1.2-1" },
        .{ .expected = .equal, .v1 = "0:1.001-1", .v2 = "0:1.1-1" },
        .{ .expected = .greaterThan, .v1 = "0:1.99999999999999999999-1", .v2 = "0:1.10-1" },
        .{ .expected = .lessThan, .v1 = "0:1.0alpha-1", .v2 = "0:1.0-1" },
        .{ .expected = .lessThan, .v1 = "0:1.0-1", .v2 = "0:1.0.1-1" },
        .{ .expected = .greaterThan, .v1 = "0:1.1-1", .v2 = "0:1.a-1" },
        .{ .expected = .greaterThan, .v1 = "0:1..0-1", .v2 = "0:1.0-1" },
        .{ .expected = .equal, .v1 = "0:1_0-1", .v2 = "0:1.0-1" },
        .{ .expected = .greaterThan, .v1 = "0:1.0-2", .v2 = "0:1.0-1" },
        .{ .expected = .equal, .v1 = "0:1.0", .v2 = "0:1.0-99" },
        .{ .expected = .greaterThan, .v1 = "0:1.beta-1", .v2 = "0:1.alpha-1" },
    };

    for (cases) |case| {
        var v1 = try Version.init(case.v1, std.testing.allocator);
        defer v1.deinit(std.testing.allocator);

        var v2 = try Version.init(case.v2, std.testing.allocator);
        defer v2.deinit(std.testing.allocator);

        try std.testing.expectEqual(case.expected, Version.compareVersions(v1, v2));
    }
}
