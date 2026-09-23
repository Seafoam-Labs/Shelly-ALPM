const Version = @This();
const std = @import("std");

pub const CompareResults = enum(i8) {
    lessThan = -1,
    equal = 0,
    greaterThan = 1,
};

raw: []const u8,
/// Digit string, preserving leading zeros; absent epochs use the static "0".
epoch: []const u8,
pkgver: []const u8,
pkgrel: ?[]const u8,

const Parts = struct {
    epoch: []const u8,
    pkgver: []const u8,
    pkgrel: ?[]const u8,
};

/// Check metadata structure, not the complete PKGBUILD version grammar.
/// Unlike compareStrings, this rejects empty components and bad epoch prefixes.
pub fn validate(version: []const u8) error{ InvalidVersion, InvalidCharacter }!void {
    if (version.len == 0) return error.InvalidVersion;

    var ver_rel = version;
    if (std.mem.find(u8, version, ":")) |epoch_index| {
        if (epoch_index == 0 or epoch_index + 1 == version.len) {
            return error.InvalidVersion;
        }
        for (version[0..epoch_index]) |byte| {
            if (!isDigit(byte)) return error.InvalidCharacter;
        }
        ver_rel = version[epoch_index + 1 ..];
    }

    const last_index = std.mem.findLast(u8, ver_rel, "-") orelse ver_rel.len;
    const ver = ver_rel[0..last_index];
    const rel: ?[]const u8 = if (last_index != ver_rel.len) ver_rel[last_index + 1 ..] else null;

    if (ver.len == 0 or (rel != null and rel.?.len == 0)) {
        return error.InvalidVersion;
    }
}

/// Own one copy of the input. Components borrow from raw (or the static "0").
/// Shallow copies share ownership: call deinit only once for each init.
pub fn init(version: []const u8, allocator: std.mem.Allocator) !Version {
    try validate(version);
    const raw = try allocator.dupe(u8, version);
    const parts = parseParts(raw);
    return .{
        .raw = raw,
        .epoch = parts.epoch,
        .pkgver = parts.pkgver,
        .pkgrel = parts.pkgrel,
    };
}

pub fn deinit(self: *Version, allocator: std.mem.Allocator) void {
    allocator.free(self.raw);
    self.* = undefined;
}

/// Compare two versions using the same ordering rules as alpm_pkg_vercmp.
pub fn compareVersions(v1: Version, v2: Version) CompareResults {
    return compareParts(
        .{ .epoch = v1.epoch, .pkgver = v1.pkgver, .pkgrel = v1.pkgrel },
        .{ .epoch = v2.epoch, .pkgver = v2.pkgver, .pkgrel = v2.pkgrel },
    );
}

/// Allocation-free alpm_pkg_vercmp ordering for ASCII, NUL-free strings.
/// Empty/unusual inputs are comparable without passing metadata validation.
/// Non-ASCII, embedded NUL, and nullable C pointer semantics are outside this
/// compatibility contract. Equality need not be transitive when pkgrel is absent.
pub fn compareStrings(v1: []const u8, v2: []const u8) CompareResults {
    return compareParts(parseParts(v1), parseParts(v2));
}

// Follow parseEVR: only an initial digit sequence followed by ':' is an epoch.
// An initial ':' is the special empty epoch (zero); other colons stay in pkgver.
fn parseParts(version: []const u8) Parts {
    var digits_end: usize = 0;
    while (digits_end < version.len and isDigit(version[digits_end])) : (digits_end += 1) {}

    const has_epoch = digits_end < version.len and version[digits_end] == ':';
    const version_start = if (has_epoch) digits_end + 1 else 0;
    const release_separator = if (std.mem.findLast(u8, version[digits_end..], "-")) |index|
        digits_end + index
    else
        null;
    return .{
        .epoch = if (has_epoch and digits_end != 0) version[0..digits_end] else "0",
        .pkgver = version[version_start .. release_separator orelse version.len],
        .pkgrel = if (release_separator) |index| version[index + 1 ..] else null,
    };
}

fn compareParts(v1: Parts, v2: Parts) CompareResults {
    const epoch_result = compareSegments(v1.epoch, v2.epoch);
    if (epoch_result != .equal) return epoch_result;

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
    try std.testing.expectEqualStrings("2", version.epoch);
    try std.testing.expectEqualStrings("1.27.0", version.pkgver);
    try std.testing.expectEqualStrings("2", version.pkgrel.?);
}

test "Version treats a missing epoch as zero" {
    var version = try Version.init("1.27.0-2", std.testing.allocator);
    defer version.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("0", version.epoch);
    try std.testing.expectEqualStrings("1.27.0", version.pkgver);
    try std.testing.expectEqualStrings("2", version.pkgrel.?);
}

test "Version permits a missing pkgrel" {
    var version = try Version.init("0:1.27.0", std.testing.allocator);
    defer version.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("0", version.epoch);
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
    try std.testing.expectEqualStrings("2", version.epoch);
    try std.testing.expectEqualStrings("1.0", version.pkgver);
    try std.testing.expectEqualStrings("3", version.pkgrel.?);
    try std.testing.expect(version.epoch.ptr == version.raw.ptr);
    try std.testing.expect(version.pkgver.ptr == version.raw[2..].ptr);
    try std.testing.expect(version.pkgrel.?.ptr == version.raw[6..].ptr);
}

test "Version owns and compares epochs larger than u64" {
    var version = try Version.init("0018446744073709551616:1.0-1", std.testing.allocator);
    defer version.deinit(std.testing.allocator);
    var older = try Version.init("18446744073709551615:99.0-9", std.testing.allocator);
    defer older.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("0018446744073709551616", version.epoch);
    try std.testing.expectEqual(.greaterThan, Version.compareVersions(version, older));
    try std.testing.expectEqual(.equal, Version.compareStrings(version.raw, "18446744073709551616:1.0-1"));
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

test "Version splits permissive inputs without losing empty components" {
    const cases = [_]struct { raw: []const u8, expected: Parts }{
        .{ .raw = "2:1.0-3", .expected = .{ .epoch = "2", .pkgver = "1.0", .pkgrel = "3" } },
        .{ .raw = "", .expected = .{ .epoch = "0", .pkgver = "", .pkgrel = null } },
        .{ .raw = ":1.0", .expected = .{ .epoch = "0", .pkgver = "1.0", .pkgrel = null } },
        .{ .raw = "1:", .expected = .{ .epoch = "1", .pkgver = "", .pkgrel = null } },
        .{ .raw = "1:-", .expected = .{ .epoch = "1", .pkgver = "", .pkgrel = "" } },
        .{ .raw = "-", .expected = .{ .epoch = "0", .pkgver = "", .pkgrel = "" } },
        .{ .raw = "1.0-", .expected = .{ .epoch = "0", .pkgver = "1.0", .pkgrel = "" } },
        .{ .raw = "alpha:1.0", .expected = .{ .epoch = "0", .pkgver = "alpha:1.0", .pkgrel = null } },
        .{ .raw = "+1:1.0", .expected = .{ .epoch = "0", .pkgver = "+1:1.0", .pkgrel = null } },
        .{ .raw = "1_0:1.0", .expected = .{ .epoch = "0", .pkgver = "1_0:1.0", .pkgrel = null } },
        .{ .raw = "01:2:3-a-b", .expected = .{ .epoch = "01", .pkgver = "2:3-a", .pkgrel = "b" } },
        .{ .raw = "18446744073709551616:1", .expected = .{ .epoch = "18446744073709551616", .pkgver = "1", .pkgrel = null } },
    };
    for (cases) |case| {
        const actual = parseParts(case.raw);
        try std.testing.expectEqualStrings(case.expected.epoch, actual.epoch);
        try std.testing.expectEqualStrings(case.expected.pkgver, actual.pkgver);
        if (case.expected.pkgrel) |release| {
            try std.testing.expectEqualStrings(release, actual.pkgrel orelse return error.TestUnexpectedResult);
        } else {
            try std.testing.expect(actual.pkgrel == null);
        }
    }
}

test "Version metadata validation remains separate from comparison" {
    for ([_][]const u8{ "", ":1", "1:", "1-", "-1", "1:-2" }) |invalid| {
        try std.testing.expectError(error.InvalidVersion, validate(invalid));
        try std.testing.expectError(error.InvalidVersion, init(invalid, std.testing.allocator));
        try std.testing.expectEqual(.equal, compareStrings(invalid, invalid));
    }
    for ([_][]const u8{ "alpha:1", "+1:1", "1_0:1", "-1:1" }) |invalid| {
        try std.testing.expectError(error.InvalidCharacter, validate(invalid));
        try std.testing.expectError(error.InvalidCharacter, init(invalid, std.testing.allocator));
        try std.testing.expectEqual(.equal, compareStrings(invalid, invalid));
    }
    for ([_][]const u8{ "1", "0:1", "01:1-beta-3", "1:2:3", "18446744073709551616:1" }) |valid| {
        try validate(valid);
    }
}

test "Version matches frozen libalpm comparison fixtures" {
    for (@import("fixtures/version_comparisons.zig").cases) |case| {
        try std.testing.expectEqual(case.expected, @intFromEnum(compareStrings(case.left, case.right)));
        try std.testing.expectEqual(-case.expected, @intFromEnum(compareStrings(case.right, case.left)));
        try std.testing.expectEqual(.equal, compareStrings(case.left, case.left));
        // The same ordering must be available through validated, owned values.
        validate(case.left) catch continue;
        validate(case.right) catch continue;
        var left = try init(case.left, std.testing.allocator);
        defer left.deinit(std.testing.allocator);
        var right = try init(case.right, std.testing.allocator);
        defer right.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected, @intFromEnum(compareVersions(left, right)));
    }
}

test "Version releases storage after successful and failed allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationLifecycle, .{});
}

fn allocationLifecycle(allocator: std.mem.Allocator) !void {
    for ([_][]const u8{ "0018446744073709551616:1.0-1", "1.0" }) |raw| {
        var version = try init(raw, allocator);
        defer version.deinit(allocator);
        try std.testing.expectEqualStrings(raw, version.raw);
    }
}
