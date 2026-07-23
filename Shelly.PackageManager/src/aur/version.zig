const std = @import("std");

/// Port of PackageManager.Utilities.VersionComparer.  This intentionally keeps
/// the C# comparison rules rather than substituting semantic-version rules.
pub fn compare(allocator: std.mem.Allocator, lhs_opt: ?[]const u8, rhs_opt: ?[]const u8) !std.math.Order {
    const lhs = lhs_opt orelse "";
    const rhs = rhs_opt orelse "";
    if (lhs.len == 0 and rhs.len == 0) return .eq;
    if (lhs.len == 0) return .lt;
    if (rhs.len == 0) return .gt;

    const lhs_epoch = parseEpoch(lhs);
    const rhs_epoch = parseEpoch(rhs);
    if (std.math.order(lhs_epoch.value, rhs_epoch.value) != .eq)
        return std.math.order(lhs_epoch.value, rhs_epoch.value);

    const lhs_release = parseRelease(lhs_epoch.rest);
    const rhs_release = parseRelease(rhs_epoch.rest);
    const version_order = try compareParts(allocator, lhs_release.version, rhs_release.version);
    if (version_order != .eq) return version_order;
    return compareParts(allocator, lhs_release.release, rhs_release.release);
}

pub fn isNewer(allocator: std.mem.Allocator, candidate: ?[]const u8, installed: ?[]const u8) !bool {
    return try compare(allocator, candidate, installed) == .gt;
}

pub fn satisfies(
    allocator: std.mem.Allocator,
    installed: []const u8,
    operator: []const u8,
    required: []const u8,
) !bool {
    if (operator.len == 0) return true;
    const order = try compare(allocator, installed, required);
    if (std.mem.eql(u8, operator, ">=")) return order != .lt;
    if (std.mem.eql(u8, operator, "<=")) return order != .gt;
    if (std.mem.eql(u8, operator, ">")) return order == .gt;
    if (std.mem.eql(u8, operator, "<")) return order == .lt;
    if (std.mem.eql(u8, operator, "=")) return order == .eq;
    return true;
}

const Epoch = struct { value: i64, rest: []const u8 };

fn parseEpoch(version: []const u8) Epoch {
    const colon = std.mem.indexOfScalar(u8, version, ':') orelse return .{ .value = 0, .rest = version };
    if (colon == 0) return .{ .value = 0, .rest = version };
    const epoch = std.fmt.parseInt(i64, version[0..colon], 10) catch return .{ .value = 0, .rest = version };
    return .{ .value = epoch, .rest = version[colon + 1 ..] };
}

const Release = struct { version: []const u8, release: []const u8 };

fn parseRelease(version: []const u8) Release {
    const hyphen = std.mem.lastIndexOfScalar(u8, version, '-') orelse return .{ .version = version, .release = "0" };
    if (hyphen == 0) return .{ .version = version, .release = "0" };
    return .{ .version = version[0..hyphen], .release = version[hyphen + 1 ..] };
}

fn compareParts(allocator: std.mem.Allocator, lhs: []const u8, rhs: []const u8) !std.math.Order {
    var lhs_parts = try splitParts(allocator, lhs);
    defer lhs_parts.deinit(allocator);
    var rhs_parts = try splitParts(allocator, rhs);
    defer rhs_parts.deinit(allocator);

    const count = @max(lhs_parts.items.len, rhs_parts.items.len);
    for (0..count) |index| {
        const lhs_part = if (index < lhs_parts.items.len) lhs_parts.items[index] else "";
        const rhs_part = if (index < rhs_parts.items.len) rhs_parts.items[index] else "";
        const order = comparePart(lhs_part, rhs_part);
        if (order != .eq) return order;
    }
    return .eq;
}

fn splitParts(allocator: std.mem.Allocator, version: []const u8) !std.ArrayList([]const u8) {
    var parts: std.ArrayList([]const u8) = .empty;
    errdefer parts.deinit(allocator);
    var start: ?usize = null;
    var was_digit: ?bool = null;

    for (version, 0..) |char, index| {
        if (char == '.' or char == '-' or char == '_' or char == '+') {
            if (start) |s| try parts.append(allocator, version[s..index]);
            start = null;
            was_digit = null;
            continue;
        }

        const is_digit = std.ascii.isDigit(char);
        if (start) |s| {
            if (was_digit.? != is_digit) {
                try parts.append(allocator, version[s..index]);
                start = index;
            }
        } else start = index;
        was_digit = is_digit;
    }
    if (start) |s| try parts.append(allocator, version[s..]);
    return parts;
}

fn comparePart(lhs: []const u8, rhs: []const u8) std.math.Order {
    if (lhs.len == 0 and rhs.len == 0) return .eq;
    if (lhs.len == 0) return if (preReleaseOrder(rhs) != null) .gt else .lt;
    if (rhs.len == 0) return if (preReleaseOrder(lhs) != null) .lt else .gt;

    const lhs_number = std.fmt.parseInt(i64, lhs, 10) catch null;
    const rhs_number = std.fmt.parseInt(i64, rhs, 10) catch null;
    if (lhs_number != null and rhs_number != null) return std.math.order(lhs_number.?, rhs_number.?);

    const lhs_pre = preReleaseOrder(lhs);
    const rhs_pre = preReleaseOrder(rhs);
    if (lhs_pre != null and rhs_pre != null) return std.math.order(lhs_pre.?, rhs_pre.?);
    if (lhs_pre != null) return .lt;
    if (rhs_pre != null) return .gt;
    if (lhs_number != null) return .gt;
    if (rhs_number != null) return .lt;
    return std.ascii.orderIgnoreCase(lhs, rhs);
}

fn preReleaseOrder(part: []const u8) ?u8 {
    var end = part.len;
    while (end > 0 and std.ascii.isDigit(part[end - 1])) end -= 1;
    const tag = part[0..end];
    if (std.ascii.eqlIgnoreCase(tag, "dev")) return 0;
    if (std.ascii.eqlIgnoreCase(tag, "snapshot")) return 1;
    if (std.ascii.eqlIgnoreCase(tag, "git") or
        std.ascii.eqlIgnoreCase(tag, "svn") or
        std.ascii.eqlIgnoreCase(tag, "cvs") or
        std.ascii.eqlIgnoreCase(tag, "hg")) return 2;
    if (std.ascii.eqlIgnoreCase(tag, "alpha")) return 3;
    if (std.ascii.eqlIgnoreCase(tag, "beta")) return 4;
    if (std.ascii.eqlIgnoreCase(tag, "pre")) return 5;
    if (std.ascii.eqlIgnoreCase(tag, "rc")) return 6;
    return null;
}

test "version comparison replicates epochs releases and prereleases" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try isNewer(allocator, "2:1.0-1", "1:99.0-9"));
    try std.testing.expect(try isNewer(allocator, "1.0-2", "1.0-1"));
    try std.testing.expect(try isNewer(allocator, "1.0", "1.0rc1"));
    try std.testing.expectEqual(std.math.Order.eq, try compare(allocator, "1.2.0-1", "1.2.0-1"));
}

test "dependency constraints use the replicated version comparison" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try satisfies(allocator, "2.1-1", ">=", "2.0"));
    try std.testing.expect(!(try satisfies(allocator, "1.9", ">=", "2.0")));
    try std.testing.expect(try satisfies(allocator, "1.0rc2", "<", "1.0"));
}
