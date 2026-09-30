//! HTTP-date parsing without a transport-library dependency. Accepts IMF-fixdate
//! and the obsolete RFC 850/asctime forms still allowed in HTTP responses.
const std = @import("std");
const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

fn number(text: []const u8) ?u16 {
    if (text.len == 0) return null;
    for (text) |byte| if (!std.ascii.isDigit(byte)) return null;
    return std.fmt.parseInt(u16, text, 10) catch null;
}
fn monthNumber(text: []const u8) ?u4 {
    for (months, 1..) |name, index| if (std.ascii.eqlIgnoreCase(name, text)) return @intCast(index);
    return null;
}
fn weekday(text: []const u8, long: bool) bool {
    const short_names = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
    const long_names = [_][]const u8{ "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" };
    for (if (long) long_names else short_names) |name| if (std.ascii.eqlIgnoreCase(name, text)) return true;
    return false;
}
fn daysBeforeYear(year: u16) i64 {
    const previous: i64 = @as(i64, year) - 1;
    return 365 * previous + @divFloor(previous, 4) - @divFloor(previous, 100) + @divFloor(previous, 400);
}
pub fn parse(value: []const u8, current_year: u16) ?std.Io.Timestamp {
    if (value.len > 128) return null;
    const text = std.mem.trim(u8, value, " \t");
    var year: u16 = undefined;
    var month: u4 = undefined;
    var day: u16 = undefined;
    var clock: []const u8 = undefined;
    if (std.mem.indexOfScalar(u8, text, ',')) |comma| {
        var fields = std.mem.tokenizeScalar(u8, text[comma + 1 ..], ' ');
        const first = fields.next() orelse return null;
        if (std.mem.indexOfScalar(u8, first, '-') != null) {
            if (!weekday(text[0..comma], true) or first.len != 9 or first[2] != '-' or first[6] != '-') return null;
            day = number(first[0..2]) orelse return null;
            month = monthNumber(first[3..6]) orelse return null;
            const short_year = number(first[7..9]) orelse return null;
            const limit = @as(u32, current_year) + 50;
            var candidate = limit / 100 * 100 + short_year;
            if (candidate > limit) candidate -= 100;
            year = std.math.cast(u16, candidate) orelse return null;
        } else {
            if (!weekday(text[0..comma], false) or first.len != 2) return null;
            day = number(first) orelse return null;
            month = monthNumber(fields.next() orelse return null) orelse return null;
            const year_text = fields.next() orelse return null;
            if (year_text.len != 4) return null;
            year = number(year_text) orelse return null;
        }
        clock = fields.next() orelse return null;
        if (!std.ascii.eqlIgnoreCase(fields.next() orelse return null, "GMT") or fields.next() != null) return null;
    } else {
        var fields = std.mem.tokenizeScalar(u8, text, ' ');
        if (!weekday(fields.next() orelse return null, false)) return null;
        month = monthNumber(fields.next() orelse return null) orelse return null;
        const day_text = fields.next() orelse return null;
        if (day_text.len > 2) return null;
        day = number(day_text) orelse return null;
        clock = fields.next() orelse return null;
        const year_text = fields.next() orelse return null;
        if (year_text.len != 4 or fields.next() != null) return null;
        year = number(year_text) orelse return null;
    }
    if (year < 1970 or clock.len != 8 or clock[2] != ':' or clock[5] != ':') return null;
    const hours = number(clock[0..2]) orelse return null;
    const minutes = number(clock[3..5]) orelse return null;
    const seconds = number(clock[6..8]) orelse return null;
    if (hours > 23 or minutes > 59 or seconds > 60 or day == 0 or day > std.time.epoch.getDaysInMonth(year, @enumFromInt(month))) return null;
    var days = daysBeforeYear(year) - daysBeforeYear(1970);
    var index: u4 = 1;
    while (index < month) : (index += 1) days += std.time.epoch.getDaysInMonth(year, @enumFromInt(index));
    days += day - 1;
    return .{ .nanoseconds = (@as(i96, days) * 86400 + @as(i96, hours) * 3600 + @as(i96, minutes) * 60 + seconds) * std.time.ns_per_s };
}

test "HTTP dates support standard and obsolete wire formats" {
    for ([_][]const u8{ "Sun, 06 Nov 1994 08:49:37 GMT", "Sunday, 06-Nov-94 08:49:37 GMT", "Sun Nov  6 08:49:37 1994" }) |date|
        try std.testing.expectEqual(784111777000000000, parse(date, 2026).?.nanoseconds);
    try std.testing.expectEqual(0, parse("Thu, 01 Jan 1970 00:00:00 GMT", 2026).?.nanoseconds);
    try std.testing.expectEqual(951782400000000000, parse("Tue, 29 Feb 2000 00:00:00 GMT", 2026).?.nanoseconds);
    try std.testing.expectEqual(parse("Wed, 01 Jan 1975 00:00:00 GMT", 2024).?.nanoseconds, parse("Wednesday, 01-Jan-75 00:00:00 GMT", 2024).?.nanoseconds);
}
test "invalid HTTP dates never change the destination timestamp" {
    for ([_][]const u8{ "", "junk", "Fri, 31 Feb 2024 01:00:00 GMT", "Fri, 29 Feb 2100 01:00:00 GMT", "Fri, 01 Jan 2024 24:00:00 GMT", "Fri, 01 Jan 2024 00:60:00 GMT", "Fri, 01 Jan 2024 00:00:61 GMT", "Fri, 01 Jan 2024 00:00:00 PST", "Fri, 01 Jan 2024 00:00:00 GMT extra", "Fri, 01 Jan 1960 00:00:00 GMT", "Friday, 01-Jan-+1 00:00:00 GMT", "xxx Jan  1 00:00:00 2024" }) |date|
        try std.testing.expectEqual(null, parse(date, 2026));
}
