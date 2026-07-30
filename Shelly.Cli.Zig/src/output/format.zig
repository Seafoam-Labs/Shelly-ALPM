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
