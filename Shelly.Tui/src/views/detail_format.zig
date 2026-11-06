const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn appendDetailList(arena: Allocator, lines: *std.ArrayList([]const u8), comptime label: []const u8, items: []const []const u8) Allocator.Error!void {
    if (items.len == 0) return;
    try lines.append(arena, try std.fmt.allocPrint(arena, "{s}{s}", .{
        label, try std.mem.join(arena, ", ", items),
    }));
}

pub fn formatSize(arena: Allocator, bytes: i64) Allocator.Error![]const u8 {
    if (bytes <= 0) return "—";
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var value: f64 = @floatFromInt(bytes);
    var unit: usize = 0;
    while (value >= 1024.0 and unit < units.len - 1) {
        value /= 1024.0;
        unit += 1;
    }
    if (unit == 0) return try std.fmt.allocPrint(arena, "{d} B", .{bytes});
    return try std.fmt.allocPrint(arena, "{d:.1} {s}", .{ value, units[unit] });
}

pub fn formatEpoch(arena: Allocator, seconds: i64) Allocator.Error![]const u8 {
    if (seconds <= 0) return "—";
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return try std.fmt.allocPrint(arena, "{d}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
    });
}
