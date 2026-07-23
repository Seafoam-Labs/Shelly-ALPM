const std = @import("std");

pub fn parseTime(time: ?[]const u8) struct { hour: i32, minute: i32 } {
    const raw = time orelse return .{ .hour = 0, .minute = 0 };
    const sep = std.mem.indexOfScalar(u8, raw, ':') orelse return .{ .hour = 0, .minute = 0 };
    if (sep == 0 or sep + 1 >= raw.len) return .{ .hour = 0, .minute = 0 };

    const hour = std.fmt.parseInt(i32, raw[0..sep], 10) catch return .{ .hour = 0, .minute = 0 };
    const minute = std.fmt.parseInt(i32, raw[sep + 1 ..], 10) catch return .{ .hour = 0, .minute = 0 };

    return .{
        .hour = std.math.clamp(hour, 0, 23),
        .minute = std.math.clamp(minute, 0, 59),
    };
}

pub fn formatTime(allocator: std.mem.Allocator, hour: i32, minute: i32) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{d:0>2}:{d:0>2}",
        .{
            @as(u32, @intCast(std.math.clamp(hour, 0, 23))),
            @as(u32, @intCast(std.math.clamp(minute, 0, 59))),
        },
    );
}

test "parseTime ignores extra content after minutes" {
    const testing = std.testing;

    // multiple colons — minute slice becomes "30:45" which parseInt rejects
    const t = parseTime("12:30:45");
    try testing.expectEqual(@as(i32, 0), t.hour);
    try testing.expectEqual(@as(i32, 0), t.minute);
}

test "parseTime rejects whitespace in values" {
    const testing = std.testing;

    var t = parseTime("12 :30");
    try testing.expectEqual(@as(i32, 0), t.hour);
    try testing.expectEqual(@as(i32, 0), t.minute);

    t = parseTime("12: 30");
    try testing.expectEqual(@as(i32, 0), t.hour);
    try testing.expectEqual(@as(i32, 0), t.minute);
}

test "parseTime handles leading zeros and extra digits" {
    const testing = std.testing;

    var t = parseTime("08:09");
    try testing.expectEqual(@as(i32, 8), t.hour);
    try testing.expectEqual(@as(i32, 9), t.minute);

    t = parseTime("007:007");
    try testing.expectEqual(@as(i32, 7), t.hour);
    try testing.expectEqual(@as(i32, 7), t.minute);
}

test "parseTime parses valid time strings" {
    const testing = std.testing;

    const t1 = parseTime("12:30");
    try testing.expectEqual(@as(i32, 12), t1.hour);
    try testing.expectEqual(@as(i32, 30), t1.minute);

    const t2 = parseTime("0:0");
    try testing.expectEqual(@as(i32, 0), t2.hour);
    try testing.expectEqual(@as(i32, 0), t2.minute);

    const t3 = parseTime("23:59");
    try testing.expectEqual(@as(i32, 23), t3.hour);
    try testing.expectEqual(@as(i32, 59), t3.minute);

    const t4 = parseTime("12:00");
    try testing.expectEqual(@as(i32, 12), t4.hour);
    try testing.expectEqual(@as(i32, 0), t4.minute);
}

test "parseTime clamps out of range values" {
    const testing = std.testing;

    const t1 = parseTime("25:61");
    try testing.expectEqual(@as(i32, 23), t1.hour);
    try testing.expectEqual(@as(i32, 59), t1.minute);

    const t2 = parseTime("-5:-10");
    try testing.expectEqual(@as(i32, 0), t2.hour);
    try testing.expectEqual(@as(i32, 0), t2.minute);
}

test "parseTime handles invalid and edge cases by returning zeros" {
    const testing = std.testing;

    // null input
    var t = parseTime(null);
    try testing.expectEqual(@as(i32, 0), t.hour);
    try testing.expectEqual(@as(i32, 0), t.minute);

    // empty string
    t = parseTime("");
    try testing.expectEqual(@as(i32, 0), t.hour);
    try testing.expectEqual(@as(i32, 0), t.minute);

    // no colon
    t = parseTime("1230");
    try testing.expectEqual(@as(i32, 0), t.hour);
    try testing.expectEqual(@as(i32, 0), t.minute);

    // colon at start
    t = parseTime(":30");
    try testing.expectEqual(@as(i32, 0), t.hour);
    try testing.expectEqual(@as(i32, 0), t.minute);

    // colon at end
    t = parseTime("12:");
    try testing.expectEqual(@as(i32, 0), t.hour);
    try testing.expectEqual(@as(i32, 0), t.minute);

    // non-numeric values
    t = parseTime("ab:cd");
    try testing.expectEqual(@as(i32, 0), t.hour);
    try testing.expectEqual(@as(i32, 0), t.minute);

    // only colon
    t = parseTime(":");
    try testing.expectEqual(@as(i32, 0), t.hour);
    try testing.expectEqual(@as(i32, 0), t.minute);
}

test "formatTime parses valid times" {
    const testing = std.testing;
    var alloc = std.testing.allocator;

    const s1 = try formatTime(alloc, 12, 30);
    defer alloc.free(s1);
    try testing.expectEqualStrings("12:30", s1);

    const s2 = try formatTime(alloc, 0, 0);
    defer alloc.free(s2);
    try testing.expectEqualStrings("00:00", s2);

    const s3 = try formatTime(alloc, 23, 59);
    defer alloc.free(s3);
    try testing.expectEqualStrings("23:59", s3);

    const s4 = try formatTime(alloc, 9, 5);
    defer alloc.free(s4);
    try testing.expectEqualStrings("09:05", s4);
}

test "formatTime clamps out of range values" {
    const testing = std.testing;
    var alloc = std.testing.allocator;

    const s1 = try formatTime(alloc, 25, 61);
    defer alloc.free(s1);
    try testing.expectEqualStrings("23:59", s1);

    const s2 = try formatTime(alloc, -5, -10);
    defer alloc.free(s2);
    try testing.expectEqualStrings("00:00", s2);
}

test "formatTime fails on allocation error" {
    const testing = std.testing;
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, formatTime(failing.allocator(), 12, 30));
}

test "formatTime produces zero-padded output" {
    const testing = std.testing;
    var alloc = std.testing.allocator;

    const s = try formatTime(alloc, 1, 2);
    defer alloc.free(s);
    try testing.expectEqualStrings("01:02", s);
}
