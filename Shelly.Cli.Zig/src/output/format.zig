const std = @import("std");

const config_manager = @import("../config/manager.zig");
const runtime = @import("../runtime/context.zig");

const DateTime = struct {
    year: u32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

pub const SizeDisplay = enum { bytes, megabytes, gigabytes };

pub fn parseSizeDisplay(value: []const u8) SizeDisplay {
    if (std.ascii.eqlIgnoreCase(value, "Bytes")) return .bytes;
    if (std.ascii.eqlIgnoreCase(value, "Gigabytes")) return .gigabytes;
    return .megabytes;
}

pub fn loadSizeDisplay(context: *runtime.RuntimeContext) !SizeDisplay {
    const manager = config_manager.Manager.init(context);
    const config = manager.read() catch return .megabytes;
    const value = config.values.get("FileSizeDisplay") orelse return .megabytes;
    if (value != .string) return .megabytes;
    return parseSizeDisplay(value.string);
}

pub fn formatSize(allocator: std.mem.Allocator, display: SizeDisplay, bytes: u64) ![]const u8 {
    return switch (display) {
        .bytes => std.fmt.allocPrint(allocator, "{d} B", .{bytes}),
        .megabytes => std.fmt.allocPrint(allocator, "{d:.2} MiB", .{@as(f64, @floatFromInt(bytes)) / 1048576.0}),
        .gigabytes => std.fmt.allocPrint(allocator, "{d:.2} GiB", .{@as(f64, @floatFromInt(bytes)) / 1073741824.0}),
    };
}

/// Formats a signed byte count (e.g. a net size change, which may be negative).
pub fn formatSignedSize(allocator: std.mem.Allocator, display: SizeDisplay, bytes: anytype) ![]const u8 {
    return switch (display) {
        .bytes => std.fmt.allocPrint(allocator, "{d} B", .{bytes}),
        .megabytes => std.fmt.allocPrint(allocator, "{d:.2} MiB", .{@as(f64, @floatFromInt(bytes)) / 1048576.0}),
        .gigabytes => std.fmt.allocPrint(allocator, "{d:.2} GiB", .{@as(f64, @floatFromInt(bytes)) / 1073741824.0}),
    };
}

pub fn nonNegative(value: i64) u64 {
    return if (value <= 0) 0 else @intCast(value);
}

pub fn joined(allocator: std.mem.Allocator, values: []const []const u8) ![]const u8 {
    return std.mem.join(allocator, ", ", values);
}

pub fn truncate(value: []const u8, maximum: usize) []const u8 {
    if (value.len <= maximum) return value;
    var end = maximum;
    while (end > 0 and value[end] & 0xc0 == 0x80) end -= 1;
    return value[0..end];
}

test "truncate preserves UTF-8 boundaries" {
    try std.testing.expectEqualStrings("pkg-", truncate("pkg-éclair", 5));
    try std.testing.expectEqualStrings("pkg-é", truncate("pkg-éclair", 6));
}

pub fn formatIsoDateTimeUtc(allocator: std.mem.Allocator, seconds: i64) ![]const u8 {
    if (seconds < 0) return allocator.dupe(u8, "1970-01-01T00:00:00+00:00");
    const parts = dateTimeParts(seconds);
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}+00:00",
        .{ parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second },
    );
}

pub fn formatCompactDateTime(allocator: std.mem.Allocator, seconds: i64) ![]const u8 {
    if (seconds < 0) return allocator.dupe(u8, "19700101000000");
    const parts = dateTimeParts(seconds);
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}",
        .{ parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second },
    );
}

pub fn formatDateTime(allocator: std.mem.Allocator, seconds: i64) ![]const u8 {
    if (seconds < 0) return allocator.dupe(u8, "1970-01-01 00:00:00");
    const parts = dateTimeParts(seconds);
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}",
        .{ parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second },
    );
}

pub fn formatLongDate(allocator: std.mem.Allocator, seconds: i64) ![]const u8 {
    if (seconds < 0) return allocator.dupe(u8, "Thursday, January 1, 1970");
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
    const epoch_day = epoch.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const weekdays = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
    const months = [_][]const u8{
        "January", "February", "March",     "April",   "May",      "June",
        "July",    "August",   "September", "October", "November", "December",
    };
    return std.fmt.allocPrint(
        allocator,
        "{s}, {s} {d}, {d}",
        .{
            weekdays[(epoch_day.day + 4) % 7],
            months[month_day.month.numeric() - 1],
            month_day.day_index + 1,
            year_day.year,
        },
    );
}

pub fn formatIsoDateTime(buffer: []u8, seconds: i64) ![]const u8 {
    if (seconds < 0) return std.fmt.bufPrint(buffer, "1970-01-01T00:00:00", .{});
    const parts = dateTimeParts(seconds);
    return std.fmt.bufPrint(
        buffer,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}",
        .{ parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second },
    );
}

fn dateTimeParts(seconds: i64) DateTime {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return .{
        .year = year_day.year,
        .month = @intCast(month_day.month.numeric()),
        .day = @intCast(month_day.day_index + 1),
        .hour = @intCast(day_seconds.getHoursIntoDay()),
        .minute = @intCast(day_seconds.getMinutesIntoHour()),
        .second = @intCast(day_seconds.getSecondsIntoMinute()),
    };
}

test "parseSizeDisplay matches canonical names case-insensitively" {
    try std.testing.expectEqual(SizeDisplay.bytes, parseSizeDisplay("Bytes"));
    try std.testing.expectEqual(SizeDisplay.bytes, parseSizeDisplay("bytes"));
    try std.testing.expectEqual(SizeDisplay.bytes, parseSizeDisplay("BYTES"));
    try std.testing.expectEqual(SizeDisplay.gigabytes, parseSizeDisplay("Gigabytes"));
    try std.testing.expectEqual(SizeDisplay.gigabytes, parseSizeDisplay("gigabytes"));
}

test "parseSizeDisplay falls back to megabytes for unknown input" {
    try std.testing.expectEqual(SizeDisplay.megabytes, parseSizeDisplay("Megabytes"));
    try std.testing.expectEqual(SizeDisplay.megabytes, parseSizeDisplay(""));
    try std.testing.expectEqual(SizeDisplay.megabytes, parseSizeDisplay("kilobytes"));
    try std.testing.expectEqual(SizeDisplay.megabytes, parseSizeDisplay("anything"));
}

test "formatSize renders bytes literally" {
    const allocator = std.testing.allocator;

    {
        const got = try formatSize(allocator, .bytes, 0);
        defer allocator.free(got);
        try std.testing.expectEqualStrings("0 B", got);
    }
    {
        const got = try formatSize(allocator, .bytes, 1024);
        defer allocator.free(got);
        try std.testing.expectEqualStrings("1024 B", got);
    }
}

test "formatSize renders megabytes with two decimals" {
    const allocator = std.testing.allocator;

    {
        const got = try formatSize(allocator, .megabytes, 0);
        defer allocator.free(got);
        try std.testing.expectEqualStrings("0.00 MiB", got);
    }
    {
        const got = try formatSize(allocator, .megabytes, 1048576);
        defer allocator.free(got);
        try std.testing.expectEqualStrings("1.00 MiB", got);
    }
    {
        const got = try formatSize(allocator, .megabytes, 1572864);
        defer allocator.free(got);
        try std.testing.expectEqualStrings("1.50 MiB", got);
    }
}

test "formatSize renders gigabytes with two decimals" {
    const allocator = std.testing.allocator;

    {
        const got = try formatSize(allocator, .gigabytes, 1073741824);
        defer allocator.free(got);
        try std.testing.expectEqualStrings("1.00 GiB", got);
    }
    {
        const got = try formatSize(allocator, .gigabytes, 0);
        defer allocator.free(got);
        try std.testing.expectEqualStrings("0.00 GiB", got);
    }
}

test "formatSignedSize preserves the sign of the byte count" {
    const allocator = std.testing.allocator;

    {
        const got = try formatSignedSize(allocator, .bytes, @as(i64, -512));
        defer allocator.free(got);
        try std.testing.expectEqualStrings("-512 B", got);
    }
    {
        const got = try formatSignedSize(allocator, .bytes, @as(i64, 512));
        defer allocator.free(got);
        try std.testing.expectEqualStrings("512 B", got);
    }
    {
        const got = try formatSignedSize(allocator, .megabytes, @as(i64, -1048576));
        defer allocator.free(got);
        try std.testing.expectEqualStrings("-1.00 MiB", got);
    }
    {
        const got = try formatSignedSize(allocator, .gigabytes, @as(i64, 1073741824));
        defer allocator.free(got);
        try std.testing.expectEqualStrings("1.00 GiB", got);
    }
}

test "nonNegative clamps non-positive values to zero" {
    try std.testing.expectEqual(@as(u64, 0), nonNegative(0));
    try std.testing.expectEqual(@as(u64, 0), nonNegative(-1));
    try std.testing.expectEqual(@as(u64, 0), nonNegative(-1000));
    try std.testing.expectEqual(@as(u64, 7), nonNegative(7));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(i64)), nonNegative(std.math.maxInt(i64)));
}

test "joined concatenates values with a comma separator" {
    const allocator = std.testing.allocator;

    {
        const got = try joined(allocator, &[_][]const u8{});
        defer allocator.free(got);
        try std.testing.expectEqualStrings("", got);
    }
    {
        const got = try joined(allocator, &[_][]const u8{"single"});
        defer allocator.free(got);
        try std.testing.expectEqualStrings("single", got);
    }
    {
        const got = try joined(allocator, &[_][]const u8{ "a", "b", "c" });
        defer allocator.free(got);
        try std.testing.expectEqualStrings("a, b, c", got);
    }
}

test "truncate returns the original slice when it fits within the limit" {
    const value = "hello";

    // Shorter than the limit: no truncation.
    try std.testing.expectEqualStrings("hello", truncate(value, 10));
    // Exactly the limit: no truncation either.
    try std.testing.expectEqualStrings("hello", truncate(value, 5));
    // The returned slice should be the same underlying memory, not a copy.
    try std.testing.expect(value.ptr == truncate(value, 10).ptr);
}

test "truncate clips longer values to the maximum byte length" {
    const value = "abcdefghij";

    try std.testing.expectEqualStrings("abcde", truncate(value, 5));
    try std.testing.expectEqualStrings("a", truncate(value, 1));
}

test "truncate handles empty values and a zero limit" {
    try std.testing.expectEqualStrings("", truncate("", 5));
    try std.testing.expectEqualStrings("", truncate("abcdefghij", 0));
}

test "formatIsoDateTimeUtc formats the epoch and a known timestamp" {
    const allocator = std.testing.allocator;

    {
        const got = try formatIsoDateTimeUtc(allocator, 0);
        defer allocator.free(got);
        try std.testing.expectEqualStrings("1970-01-01T00:00:00+00:00", got);
    }
    {
        const got = try formatIsoDateTimeUtc(allocator, 1_600_000_000);
        defer allocator.free(got);
        try std.testing.expectEqualStrings("2020-09-13T12:26:40+00:00", got);
    }
}

test "formatIsoDateTimeUtc returns the epoch sentinel for negative seconds" {
    const allocator = std.testing.allocator;

    const got = try formatIsoDateTimeUtc(allocator, -1);
    defer allocator.free(got);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00+00:00", got);
}

test "formatCompactDateTime pads all fields to fixed width" {
    const allocator = std.testing.allocator;

    {
        const got = try formatCompactDateTime(allocator, 0);
        defer allocator.free(got);
        try std.testing.expectEqualStrings("19700101000000", got);
    }
    {
        const got = try formatCompactDateTime(allocator, 1_600_000_000);
        defer allocator.free(got);
        try std.testing.expectEqualStrings("20200913122640", got);
    }
}

test "formatCompactDateTime returns the epoch sentinel for negative seconds" {
    const allocator = std.testing.allocator;

    const got = try formatCompactDateTime(allocator, -100);
    defer allocator.free(got);
    try std.testing.expectEqualStrings("19700101000000", got);
}

test "formatDateTime formats the epoch and a known timestamp" {
    const allocator = std.testing.allocator;

    {
        const got = try formatDateTime(allocator, 0);
        defer allocator.free(got);
        try std.testing.expectEqualStrings("1970-01-01 00:00:00", got);
    }
    {
        const got = try formatDateTime(allocator, 1_600_000_000);
        defer allocator.free(got);
        try std.testing.expectEqualStrings("2020-09-13 12:26:40", got);
    }
}

test "formatDateTime returns the epoch sentinel for negative seconds" {
    const allocator = std.testing.allocator;

    const got = try formatDateTime(allocator, -1);
    defer allocator.free(got);
    try std.testing.expectEqualStrings("1970-01-01 00:00:00", got);
}

test "formatLongDate formats weekday, month name, day and year" {
    const allocator = std.testing.allocator;

    {
        const got = try formatLongDate(allocator, 0);
        defer allocator.free(got);
        try std.testing.expectEqualStrings("Thursday, January 1, 1970", got);
    }
    // 2020-09-13 was a Sunday.
    {
        const got = try formatLongDate(allocator, 1_600_000_000);
        defer allocator.free(got);
        try std.testing.expectEqualStrings("Sunday, September 13, 2020", got);
    }
}

test "formatLongDate returns the epoch sentinel for negative seconds" {
    const allocator = std.testing.allocator;

    const got = try formatLongDate(allocator, -1);
    defer allocator.free(got);
    try std.testing.expectEqualStrings("Thursday, January 1, 1970", got);
}

test "formatIsoDateTime writes into a caller-provided buffer" {
    var buffer: [32]u8 = undefined;

    {
        const got = try formatIsoDateTime(&buffer, 0);
        try std.testing.expectEqualStrings("1970-01-01T00:00:00", got);
    }
    {
        const got = try formatIsoDateTime(&buffer, 1_600_000_000);
        try std.testing.expectEqualStrings("2020-09-13T12:26:40", got);
    }
}

test "formatIsoDateTime returns the epoch sentinel for negative seconds" {
    var buffer: [32]u8 = undefined;

    const got = try formatIsoDateTime(&buffer, -1);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00", got);
}
