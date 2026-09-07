const std = @import("std");
const zeit = @import("zeit");

const ShellyConfig = @import("../models/shelly_config.zig").ShellyConfig;
const DayOfWeek = @import("../models/shelly_config.zig").DayOfWeek;

pub const NowInfo = struct {
    weekday: i32,
    seconds_of_day: i32,
};

pub fn isCronMode(config: *const ShellyConfig) bool {
    return config.TrayRunAsCron and
        config.UseWeeklySchedule and
        config.DaysOfWeek.len > 0 and
        !std.mem.eql(u8, config.Time, "");
}

pub fn computeNextSeconds(now: NowInfo, config: *const ShellyConfig) u32 {
    const fallback: u32 = config.TrayCheckIntervalHours * 3600;

    if (!config.UseWeeklySchedule or
        config.DaysOfWeek.len == 0 or
        std.mem.eql(u8, config.Time, ""))
    {
        return fallback;
    }

    const today = now.weekday;
    const now_of_day = now.seconds_of_day;
    const hour_idx = std.ascii.findIgnoreCase(config.Time, ":");
    if (hour_idx) |hour_unwrapped| {
        const hour = std.fmt.parseInt(i32, config.Time[0..hour_unwrapped], 10) catch return fallback;
        const minute = std.fmt.parseInt(i32, config.Time[hour_unwrapped + 1 ..], 10) catch return fallback;
        const sched_of_day: i32 = hour * 3600 + minute * 60;

        if (hour < 0 or hour > 23 or minute < 0 or minute > 59)
            return fallback;

        if (dayInSchedule(today, config.DaysOfWeek)) {
            const remaining = sched_of_day - now_of_day;
            if (remaining > 0) return @intCast(remaining);
        }

        var i: i32 = 1;
        while (i <= 7) : (i += 1) {
            const candidate = @mod(today + i, 7);
            if (dayInSchedule(candidate, config.DaysOfWeek)) {
                const secs: i32 = (86400 - now_of_day) + (i - 1) * 86400 + sched_of_day;
                return @intCast(secs);
            }
        }
    }

    return fallback;
}

fn dayInSchedule(day: i32, scheduled: []const DayOfWeek) bool {
    for (scheduled) |d| {
        switch (d) {
            .monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday => {
                if (@intFromEnum(d) == day) return true;
            },
        }
    }
    return false;
}

pub fn getNextSeconds(gpa: std.mem.Allocator, io: std.Io, config: *const ShellyConfig) !u32 {
    const now = zeit.instant(.{ .now = io }, &zeit.utc);
    const local = try zeit.local(gpa, io, .{});
    defer local.deinit();
    const dt = now.in(&local).time();

    const local_secs = dt.instant().unixTimestamp();
    const days = zeit.daysSinceEpoch(local_secs);
    const wd = zeit.weekdayFromDays(days);

    const info = NowInfo{
        .weekday = @intCast(@intFromEnum(wd)),
        .seconds_of_day = @as(i32, @intCast(dt.hour)) * 3600 +
            @as(i32, @intCast(dt.minute)) * 60 +
            @as(i32, @intCast(dt.second)),
    };
    return computeNextSeconds(info, config);
}

fn mapWeekday(wd: zeit.Weekday) i32 {
    return @intCast(@intFromEnum(wd));
}

const testing = std.testing;
fn testConfig(
    use_weekly: bool,
    days: ?[]const DayOfWeek,
    time: []const u8,
    fallback_hours: u32,
) ShellyConfig {
    return .{
        .UseWeeklySchedule = use_weekly,
        .DaysOfWeek = days orelse &.{},
        .Time = time,
        .TrayCheckIntervalHours = fallback_hours,
    };
}

test "no weekly schedule -> fallback interval" {
    const cfg = testConfig(false, null, "9:00", 4.0);
    const now = NowInfo{ .weekday = 2, .seconds_of_day = 12 * 3600 };
    try testing.expectEqual(@as(u32, 14400), computeNextSeconds(now, &cfg));
}

test "empty scheduled days -> fallback" {
    const cfg = testConfig(true, null, "9:00", 2.0);
    const now = NowInfo{ .weekday = 0, .seconds_of_day = 0 };
    try testing.expectEqual(@as(u32, 7200), computeNextSeconds(now, &cfg));
}

test "negative scheduled hour -> fallback" {
    const cfg = testConfig(true, &[_]DayOfWeek{ .monday, .wednesday }, "-27:00", 1.0);
    const now = NowInfo{ .weekday = 1, .seconds_of_day = 0 };
    try testing.expectEqual(@as(u32, 3600), computeNextSeconds(now, &cfg));
}

test "scheduled today, time still ahead -> remaining today" {
    const cfg = testConfig(true, &[_]DayOfWeek{.wednesday}, "9:00", 24.0);
    const now = NowInfo{ .weekday = 3, .seconds_of_day = 6 * 3600 };
    try testing.expectEqual(@as(u32, 3 * 3600), computeNextSeconds(now, &cfg));
}

test "scheduled today but time passed -> next occurrence next week" {
    const cfg = testConfig(true, &[_]DayOfWeek{.wednesday}, "9:00", 24.0);
    const now = NowInfo{ .weekday = 3, .seconds_of_day = 10 * 3600 };
    const expected: u32 = @intCast((86400 - 10 * 3600) + 6 * 86400 + 9 * 3600);
    try testing.expectEqual(expected, computeNextSeconds(now, &cfg));
}

test "scheduled tomorrow" {
    const cfg = testConfig(true, &[_]DayOfWeek{.tuesday}, "9:00", 24.0);
    const now = NowInfo{ .weekday = 1, .seconds_of_day = 12 * 3600 };
    const expected: u32 = @intCast((86400 - 12 * 3600) + 9 * 3600);
    try testing.expectEqual(expected, computeNextSeconds(now, &cfg));
}

test "multiple scheduled days picks nearest upcoming" {
    const cfg = testConfig(true, &[_]DayOfWeek{ .monday, .thursday }, "9:00", 24.0);
    const now = NowInfo{ .weekday = 2, .seconds_of_day = 12 * 3600 };
    const expected: u32 = @intCast((86400 - 12 * 3600) + 1 * 86400 + 9 * 3600);
    try testing.expectEqual(expected, computeNextSeconds(now, &cfg));
}

test "scheduled today exactly now -> not >0, rolls to next week" {
    const cfg = testConfig(true, &[_]DayOfWeek{.wednesday}, "9:00", 24.0);
    const now = NowInfo{ .weekday = 3, .seconds_of_day = 9 * 3600 };

    const expected: u32 = @intCast((86400 - 9 * 3600) + 6 * 86400 + 9 * 3600);
    try testing.expectEqual(expected, computeNextSeconds(now, &cfg));
}

test "dayInSchedule basic" {
    try testing.expect(dayInSchedule(@intFromEnum(DayOfWeek.thursday), &.{.thursday}));
    try testing.expect(!dayInSchedule(2, &.{ .monday, .thursday, .friday }));
    try testing.expect(!dayInSchedule(0, &.{}));
}

test "cron mode requires cron flag and a complete weekly schedule" {
    var cfg = testConfig(true, &[_]DayOfWeek{.monday}, "9:00", 24.0);
    try testing.expect(!isCronMode(&cfg));

    cfg.TrayRunAsCron = true;
    try testing.expect(isCronMode(&cfg));

    cfg.UseWeeklySchedule = false;
    try testing.expect(!isCronMode(&cfg));
    cfg.UseWeeklySchedule = true;

    cfg.DaysOfWeek = &.{};
    try testing.expect(!isCronMode(&cfg));

    cfg.DaysOfWeek = &[_]DayOfWeek{.monday};
    cfg.Time = "";
    try testing.expect(!isCronMode(&cfg));
}
