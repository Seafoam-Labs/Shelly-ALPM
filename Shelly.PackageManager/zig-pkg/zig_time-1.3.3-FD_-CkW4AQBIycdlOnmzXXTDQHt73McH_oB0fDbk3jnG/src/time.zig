const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const time = std.time;
const epoch = time.epoch;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Allocating = std.Io.Writer.Allocating;

const string = []const u8;

pub const timer = @import("timer.zig");

const ctx = @This();

// timezone struct
pub const Location = struct {
    offset: i32,
    name: []const u8,

    const Self = @This();

    pub fn init(offset: i32, name: []const u8) Location {
        return .{
            .offset = offset,
            .name = name,
        };
    }

    pub fn create(offset: i32, name: []const u8) Location {
        const new_offset = offset * time.s_per_min;
        return init(new_offset, name);
    }

    pub fn utc() Location {
        return init(0, "UTC");
    }

    // offset is minute
    pub fn fixed(offset: i32) Location {
        const new_offset = offset * time.s_per_min;
        return init(new_offset, "");
    }

    pub fn parse(str: []const u8) !Location {
        return parseWithName(str, "");
    }

    pub fn parseWithName(str: []const u8, name: []const u8) !Location {
        const offset = try parseName(str);
        const new_offset = offset * time.s_per_min;

        return init(new_offset, name);
    }

    /// if name.len > 0 return name, or return offset string
    pub fn string(self: Self, writer: *Io.Writer) !void {
        if (self.name.len > 0) {
            try writer.writeAll(self.name);
        } else {
            try self.offsetString(writer);
        }
    }

    /// if name.len > 0 return name, or return offset string
    pub fn stringAlloc(self: Self, alloc: Allocator) ![]const u8 {
        const initial_buf = try alloc.alloc(u8, 8);

        var aw: Allocating = .initOwnedSlice(alloc, initial_buf);
        defer aw.deinit();

        try self.string(&aw.writer);
        return alloc.dupe(u8, aw.writer.buffered());
    }

    /// eg: +0800
    pub fn offsetString(self: Self, writer: *Io.Writer) !void {
        const o = self.offset;
        try self.fixedName(o, false, writer);
    }

    /// eg: +0800
    pub fn offsetStringAlloc(self: Self, alloc: Allocator) ![]const u8 {
        const initial_buf = try alloc.alloc(u8, 8);

        var aw: Allocating = .initOwnedSlice(alloc, initial_buf);
        defer aw.deinit();

        try self.offsetString(&aw.writer);
        return alloc.dupe(u8, aw.writer.buffered());
    }

    /// eg: +08:00
    pub fn offsetFormatString(self: Self, writer: *Io.Writer) !void {
        const o = self.offset;
        try self.fixedName(o, true, writer);
    }

    /// eg: +08:00
    pub fn offsetFormatStringAlloc(self: Self, alloc: Allocator) ![]const u8 {
        const initial_buf = try alloc.alloc(u8, 8);

        var aw: Allocating = .initOwnedSlice(alloc, initial_buf);
        defer aw.deinit();

        try self.offsetFormatString(&aw.writer);
        return alloc.dupe(u8, aw.writer.buffered());
    }

    fn fixedName(self: Self, offset: i32, is_format: bool, writer: *Io.Writer) !void {
        _ = self;

        var new_offset: u64 = 0;
        if (offset > 0) {
            new_offset = @as(u64, @intCast(offset));
        } else {
            new_offset = @as(u64, @intCast(-offset));
        }

        const h = @divTrunc(@as(isize, @intCast(new_offset % time.s_per_day)), time.s_per_hour);
        const m = @divTrunc(@as(isize, @intCast(new_offset % time.s_per_hour)), time.s_per_min);

        var buf: [32]u8 = undefined;

        var w = buf.len;

        w = fmtInt(buf[0..w], @as(u64, @intCast(@abs(m))));
        if (m < 10) {
            w -= 1;
            buf[w] = '0';
        }

        if (is_format) {
            w -= 1;
            buf[w] = ':';
        }

        w = fmtInt(buf[0..w], @as(u64, @intCast(@abs(h))));
        if (h < 10) {
            w -= 1;
            buf[w] = '0';
        }

        w -= 1;
        if (offset < 0) {
            buf[w] = '-';
        } else {
            buf[w] = '+';
        }

        var wr = writer;
        try wr.writeAll(buf[w..]);
    }

    pub fn parseName(str: []const u8) !i32 {
        const num = try parseTimezone(str);

        return @as(i32, @intCast(num.value));
    }
};

pub const Time = struct {
    value: i128,
    loc: Location,

    const Self = @This();

    pub fn init(ns: i128, loc: Location) Time {
        return .{
            .value = ns,
            .loc = loc,
        };
    }

    pub fn fromNanoTimestamp(ns: i128) Time {
        const loc = Location.utc();

        return init(ns, loc);
    }

    pub fn fromMicroTimestamp(t: i64) Time {
        const loc = Location.utc();
        const ns = @as(i128, @intCast(t)) * time.ns_per_us;

        return init(ns, loc);
    }

    pub fn fromMilliTimestamp(t: i64) Time {
        const loc = Location.utc();
        const ns = @as(i128, @intCast(t)) * time.ns_per_ms;

        return init(ns, loc);
    }

    pub fn fromTimestamp(t: i64) Time {
        const loc = Location.utc();
        const ns = @as(i128, @intCast(t)) * time.ns_per_s;

        return init(ns, loc);
    }

    pub fn fromUnix(secs: i64, nsecs: i64) Time {
        var seconds = secs;
        var nseconds = nsecs;

        if (nseconds < 0 or nseconds >= 1_000_000_000) {
            const n = @divTrunc(nseconds, 1_000_000_000);

            seconds += n;
            nseconds -= n * 1_000_000_000;

            if (nseconds < 0) {
                nseconds += 1_000_000_000;
                seconds -= 1;
            }
        }

        const ns = @as(i128, @intCast(seconds)) * time.ns_per_s + @as(i128, @intCast(nseconds));

        return fromNanoTimestamp(ns);
    }

    pub fn fromDate(years: isize, months: isize, days: isize, loc: Location) Time {
        return fromDatetime(years, months, days, 0, 0, 0, 0, loc);
    }

    pub fn fromDatetime(
        years: isize,
        months: isize,
        days: isize,
        hours: isize,
        mins: isize,
        seces: isize,
        nseces: isize,
        loc: Location,
    ) Time {
        var v_year = years;
        var v_day = days;
        var v_hour = hours;
        var v_min = mins;
        var v_sec = seces;
        var v_nsec = nseces;

        // Normalize month, overflowing into year
        var m = months - 1;
        var r = norm(v_year, m, 12);
        v_year = r.hi;
        m = r.lo;
        const v_month = @as(epoch.Month, @enumFromInt(@as(usize, @intCast(m)) + 1));

        // Normalize nsec, sec, min, hour, overflowing into day.
        r = norm(v_sec, v_nsec, 1e9);
        v_sec = r.hi;
        v_nsec = r.lo;
        r = norm(v_min, v_sec, 60);
        v_min = r.hi;
        v_sec = r.lo;
        r = norm(v_hour, v_min, 60);
        v_hour = r.hi;
        v_min = r.lo;
        r = norm(v_day, v_hour, 24);
        v_day = r.hi;
        v_hour = r.lo;

        // Compute days since the absolute epoch.
        var d = daysSinceeEpoch(v_year);

        // Add in days before this month.
        d += @as(u64, @intCast(daysBefore[@intFromEnum(v_month) - 1]));
        if (epoch.isLeapYear(@as(epoch.Year, @intCast(v_year))) and @intFromEnum(v_month) >= @intFromEnum(epoch.Month.mar)) {
            d += 1; // February 29
        }

        // Add in days before today.
        d += @as(u64, @intCast(v_day - 1));

        // Add in time elapsed today.
        var abses = d * seconds_per_day;
        abses += @as(u64, @intCast(v_hour * seconds_per_hour + v_min * seconds_per_minute + v_sec));

        const ov = @addWithOverflow(@as(i64, @bitCast(abses)), (absolute_to_internal + internal_to_unix));
        var unix_value: i64 = ov[0];

        if (loc.offset != 0) {
            unix_value -= @as(i64, @intCast(loc.offset));
        }

        const uv: i128 = @as(i128, @intCast(unix_value)) * time.ns_per_s;
        const ns = @as(i128, @intCast(uv + @as(i128, @intCast(v_nsec))));

        return init(ns, loc);
    }

    pub fn now(io: Io) Time {
        const ts = Io.Timestamp.now(io, .real).toNanoseconds();
        return fromNanoTimestamp(@as(i128, @intCast(ts)));
    }

    // =====================

    pub fn utc(self: Self) Self {
        var cp = self;

        cp.value = self.value;
        cp.loc = Location.utc();
        return cp;
    }

    pub fn setLoc(self: Self, loc: Location) Self {
        var cp = self;

        cp.value = self.value;
        cp.loc = loc;
        return cp;
    }

    pub fn location(self: Self) Location {
        const loc = self.loc;
        return loc;
    }

    // =====================

    pub fn timestamp(self: Self) i64 {
        return @as(i64, @intCast(@divTrunc(self.value, time.ns_per_s)));
    }

    pub fn milliTimestamp(self: Self) i64 {
        return @as(i64, @intCast(@divTrunc(self.value, time.ns_per_ms)));
    }

    pub fn microTimestamp(self: Self) i64 {
        return @as(i64, @intCast(@divTrunc(self.value, time.ns_per_us)));
    }

    pub fn nanoTimestamp(self: Self) i128 {
        return self.value;
    }

    // =====================

    fn sec(self: Self) i64 {
        return @as(i64, @intCast(@divTrunc(self.value, @as(i128, @intCast(time.ns_per_s)))));
    }

    fn unixSec(self: Self) i64 {
        return self.sec();
    }

    fn nsec(self: Self) i32 {
        if (self.value == 0) {
            return 0;
        }

        return @as(i32, @intCast((self.value - (@as(i128, @intCast(self.unixSec())) * time.ns_per_s)) & nsec_mask));
    }

    pub fn unix(self: Self) i64 {
        return self.unixSec();
    }

    fn abs(self: Self) u64 {
        var usec = self.unixSec();
        usec += @as(i64, @intCast(self.loc.offset));

        const ov = @addWithOverflow(usec, unix_to_internal + internal_to_absolute);
        const result: i64 = ov[0];

        return @as(u64, @bitCast(result));
    }

    pub fn date(self: Self) DateDetail {
        return absDate(self.abs(), true);
    }

    pub fn year(self: Self) epoch.Year {
        const d = self.date();
        return @as(epoch.Year, @intCast(d.year));
    }

    pub fn month(self: Self) epoch.Month {
        const d = self.date();
        return d.month;
    }

    pub fn day(self: Self) u9 {
        const d = self.date();
        return @as(u9, @intCast(d.day));
    }

    pub fn yearDay(self: Self) u16 {
        const d = absDate(self.abs(), false);
        return @as(u16, @intCast(d.yday)) + 1;
    }

    /// clock returns the hour, minute, and second within the day specified by t.
    pub fn clock(self: Self) Clock {
        return Clock.absClock(self.abs());
    }

    pub fn hour(self: Self) u5 {
        const d = @divTrunc(@as(isize, @intCast(self.abs() % seconds_per_day)), seconds_per_hour);
        return @as(u5, @intCast(d));
    }

    pub fn minute(self: Self) u6 {
        const d = @divTrunc(@as(isize, @intCast(self.abs() % seconds_per_hour)), seconds_per_minute);
        return @as(u6, @intCast(d));
    }

    pub fn second(self: Self) u6 {
        const d = @as(isize, @intCast(self.abs() % seconds_per_minute));
        return @as(u6, @intCast(d));
    }

    // milliseconds returns the duration as an integer millisecond count.
    pub fn milliseconds(self: Self) i32 {
        return @divTrunc(self.nsec(), time.ns_per_ms);
    }

    // microseconds returns the duration as an integer microsecond count.
    pub fn microseconds(self: Self) i32 {
        return @divTrunc(self.nsec(), time.ns_per_us);
    }

    /// returns the nanosecond offset within the second specified by self,
    /// in the range [0, 999999999].
    pub fn nanosecond(self: Self) i32 {
        return self.nsec();
    }

    // =====================

    // compare a is isZero
    pub fn isZero(self: Self) bool {
        return self.nanoTimestamp() == 0;
    }

    // returns true if time self is after time u.
    pub fn after(self: Self, u: Self) bool {
        const ts = self.sec();
        const us = u.sec();
        return ts > us or (ts == us and self.nsec() > u.nsec());
    }

    // returns true if time self is before u.
    pub fn before(self: Self, u: Self) bool {
        const ts = self.sec();
        const us = u.sec();
        return (ts < us) or (ts == us and self.nsec() < u.nsec());
    }

    pub fn equal(self: Self, other: Self) bool {
        return self.nanoTimestamp() == other.nanoTimestamp();
    }

    // compare compares the time instant t with u. If t is before u, it returns -1;
    // if t is after u, it returns +1; if they're the same, it returns 0.
    pub fn compare(self: Self, other: Self) isize {
        if (self.value < other.value) {
            return -1;
        } else if (self.value > other.value) {
            return 1;
        } else {
            return 0;
        }
    }

    // =====================

    pub fn beginOfHour(self: Self) Self {
        const d = self.date();
        const c = self.clock();
        return fromDatetime(
            d.year,
            @as(isize, @intCast(@intFromEnum(d.month))),
            d.day,
            c.hour,
            0,
            0,
            0,
            self.loc,
        );
    }

    pub fn endOfHour(self: Self) Self {
        const d = self.date();
        const c = self.clock();
        return fromDatetime(
            d.year,
            @as(isize, @intCast(@intFromEnum(d.month))),
            d.day,
            c.hour,
            59,
            59,
            999999999,
            self.loc,
        );
    }

    pub fn beginOfDay(self: Self) Self {
        const d = self.date();
        return fromDatetime(
            d.year,
            @as(isize, @intCast(@intFromEnum(d.month))),
            d.day,
            0,
            0,
            0,
            0,
            self.loc,
        );
    }

    pub fn endOfDay(self: Self) Self {
        const d = self.date();
        return fromDatetime(
            d.year,
            @as(isize, @intCast(@intFromEnum(d.month))),
            d.day,
            23,
            59,
            59,
            999999999,
            self.loc,
        );
    }

    pub fn beginOfWeek(self: Self) Self {
        var week_day = @as(isize, @intCast(@intFromEnum(self.weekday())));
        if (week_day == 0) {
            week_day = 7;
        }

        const d = self.addDate(0, 0, -(week_day - 1)).date();

        return fromDatetime(
            d.year,
            @as(isize, @intCast(@intFromEnum(d.month))),
            d.day,
            0,
            0,
            0,
            0,
            self.loc,
        );
    }

    pub fn endOfWeek(self: Self) Self {
        const dd = self.beginOfWeek().addDate(0, 0, 6);
        const d = dd.date();
        return fromDatetime(
            d.year,
            @as(isize, @intCast(@intFromEnum(d.month))),
            d.day,
            23,
            59,
            59,
            999999999,
            self.loc,
        );
    }

    pub fn beginOfMonth(self: Self) Self {
        const d = self.date();
        return fromDatetime(
            d.year,
            @as(isize, @intCast(@intFromEnum(d.month))),
            1,
            0,
            0,
            0,
            0,
            self.loc,
        );
    }

    pub fn endOfMonth(self: Self) Self {
        return self.beginOfMonth().addDate(0, 1, 0)
            .add(Duration.init(-Duration.Second.value))
            .add(Duration.init(999999999 * Duration.Nanosecond.value));
    }

    // =====================

    /// returns the day of the week specified by self.
    pub fn weekday(self: Self) Weekday {
        return absWeekday(self.abs());
    }

    /// isoWeek returns the ISO 8601 year and week number in which self occurs.
    /// Week ranges from 1 to 53. Jan 01 to Jan 03 of year n might belong to
    /// week 52 or 53 of year n-1, and Dec 29 to Dec 31 might belong to week 1
    /// of year n+1.
    pub fn isoWeek(self: Self) ISOWeek {
        var d = self.date();
        const wday = @mod(@as(isize, @intCast(@intFromEnum(self.weekday()) + 8)), 7);
        const Mon: isize = 0;
        const Tue = Mon + 1;
        const Wed = Tue + 1;
        const Thu = Wed + 1;
        const Fri = Thu + 1;
        const Sat = Fri + 1;
        // const Sun = Sat + 1;

        // Calculate week as number of Mondays in year up to
        // and including today, plus 1 because the first week is week 0.
        // Putting the + 1 inside the numerator as a + 7 keeps the
        // numerator from being negative, which would cause it to
        // round incorrectly.
        var week = @divTrunc(d.yday - wday + 7, 7);

        // The week number is now correct under the assumption
        // that the first Monday of the year is in week 1.
        // If Jan 1 is a Tuesday, Wednesday, or Thursday, the first Monday
        // is actually in week 2.
        const jan1wday = @mod((wday - d.yday + 7 * 53), 7);

        if (Tue <= jan1wday and jan1wday <= Thu) {
            week += 1;
        }
        if (week == 0) {
            d.year -= 1;
            week = 52;
        }

        // A year has 53 weeks when Jan 1 or Dec 31 is a Thursday,
        // meaning Jan 1 of the next year is a Friday
        // or it was a leap year and Jan 1 of the next year is a Saturday.
        if (jan1wday == Fri or (jan1wday == Sat) and epoch.isLeapYear(@as(epoch.Year, @intCast(d.year)))) {
            week += 1;
        }

        // December 29 to 31 are in week 1 of next year if
        // they are after the last Thursday of the year and
        // December 31 is a Monday, Tuesday, or Wednesday.
        if (@intFromEnum(d.month) == @intFromEnum(epoch.Month.dec) and d.day >= 29 and wday < Thu) {
            const dec31wday = @mod((wday + 31 - d.day), 7);
            if (Mon <= dec31wday and dec31wday <= Wed) {
                d.year += 1;
                week = 1;
            }
        }

        return .{
            .year = d.year,
            .week = week,
        };
    }

    //// seconds since epoch Oct 1, 1970 at 12:00 AM
    pub fn epochSeconds(self: Self) epoch.EpochSeconds {
        return .{
            .secs = @as(u64, @intCast(self.sec())),
        };
    }

    // =====================

    pub fn add(self: Self, d: Duration) Self {
        var cp = self;
        cp.value += @as(i128, @intCast(d.value));

        return cp;
    }

    pub fn sub(self: Self, u: Self) Duration {
        const d = Duration.init(@as(i64, @intCast(self.value - u.value)));

        if (u.add(d).equal(self)) {
            return d;
        } else if (self.before(u)) {
            return Duration.MinDuration;
        } else {
            return Duration.MaxDuration;
        }
    }

    pub fn addDate(self: Self, years: isize, number_of_months: isize, number_of_days: isize) Self {
        const d = self.date();
        const c = self.clock();
        const m = @as(isize, @intCast(@intFromEnum(d.month))) + number_of_months;
        return fromDatetime(
            d.year + years,
            m,
            d.day + number_of_days,
            c.hour,
            c.min,
            c.sec,
            @as(isize, @intCast(self.nsec())),
            self.loc,
        );
    }

    // =====================

    /// this gt other
    pub fn gt(self: Self, other: Self) bool {
        return self.after(other);
    }

    /// this lt other
    pub fn lt(self: Self, other: Self) bool {
        return self.before(other);
    }

    /// this equal other
    pub fn eq(self: Self, other: Self) bool {
        return self.equal(other);
    }

    /// this not equal other
    pub fn ne(self: Self, other: Self) bool {
        return !self.eq(other);
    }

    pub fn gte(self: Self, other: Self) bool {
        return self.gt(other) or self.eq(other);
    }

    pub fn lte(self: Self, other: Self) bool {
        return self.lt(other) or self.eq(other);
    }

    pub fn between(self: Self, start: Self, end: Self) bool {
        if (self.gt(start) and self.lt(end)) {
            return true;
        }

        return false;
    }

    pub fn betweenIncluded(self: Self, start: Self, end: Self) bool {
        if (self.gte(start) and self.lte(end)) {
            return true;
        }

        return false;
    }

    pub fn betweenIncludedStart(self: Self, start: Self, end: Self) bool {
        if (self.gte(start) and self.lt(end)) {
            return true;
        }

        return false;
    }

    pub fn betweenIncludedEnd(self: Self, start: Self, end: Self) bool {
        if (self.gt(start) and self.lte(end)) {
            return true;
        }

        return false;
    }

    // =====================

    pub fn parse(comptime layout: []const u8, value: []const u8) !Time {
        const t = try parseInLocation(layout, value, Location.utc());

        return t;
    }

    pub fn parseInLocation(comptime layout: []const u8, value: []const u8, loction: Location) !Time {
        if (layout.len == 0) {
            @compileError("DateTime: layout string can't be empty");
        }

        @setEvalBranchQuota(100000);

        var am_set = false;
        var pm_set = false;

        var parsed_year: isize = 0;
        var parsed_month: isize = -1;
        var parsed_day: isize = -1;
        var parsed_hour: isize = 0;
        var parsed_min: isize = 0;
        var parsed_sec: isize = 0;
        var parsed_nsec: isize = 0;

        var parsed_loc: ?Location = null;

        var val = value;

        var next: ?FormatSeq = null;
        var newFmt = layout;

        while (newFmt.len > 0) {
            const fmtSeq = nextSeq(newFmt);

            newFmt = fmtSeq.last;
            next = fmtSeq.seq;

            if (next) |tag| {
                switch (tag) {
                    .M, .MM => {
                        const n = try getNum(val, fmtSeq.seq == .MM);
                        parsed_month = n.value;
                        val = n.string;
                    },
                    .Mo => {
                        const n = try getNumFromOrdinal(val);
                        parsed_month = n.value;
                        val = n.string;
                    },
                    .MMM => {
                        const idx = try lookup(short_month_names[0..], val);
                        parsed_month = @as(isize, @intCast(idx));
                        val = val[short_month_names[idx].len..];
                        parsed_month += 1;
                    },
                    .MMMM => {
                        const idx = try lookup(long_month_names[0..], val);
                        parsed_month = @as(isize, @intCast(idx));
                        val = val[long_month_names[idx].len..];
                        parsed_month += 1;
                    },

                    .D, .DD => {
                        const n = try getNum(val, fmtSeq.seq == .DD);
                        parsed_day = n.value;
                        val = n.string;
                    },
                    .Do => {
                        const n = try getNumFromOrdinal(val);
                        parsed_day = n.value;
                        val = n.string;
                    },

                    .Y => {
                        if (val.len < 5) {
                            return error.BadValue;
                        }

                        const p = val[0..5];
                        val = val[5..];

                        parsed_year = try std.fmt.parseInt(isize, p, 10);
                        parsed_year -= 10000;
                    },
                    .YY => {
                        if (val.len < 2) {
                            return error.BadValue;
                        }

                        const p = val[0..2];
                        val = val[2..];

                        parsed_year = try std.fmt.parseInt(isize, p, 10);
                        if (parsed_year >= 69) {
                            // Unix time starts Dec 31 1969 in some time zones
                            parsed_year += 1900;
                        } else {
                            parsed_year += 2000;
                        }
                    },
                    .YYYY => {
                        if (val.len < 4 or !isDigit(val, 0)) {
                            return error.BadValue;
                        }

                        const p = val[0..4];
                        val = val[4..];
                        parsed_year = try std.fmt.parseInt(isize, p, 10);
                    },

                    .A => {
                        if (val.len < 2) {
                            return error.BadValue;
                        }

                        const p = val[0..2];
                        val = val[2..];
                        if (mem.eql(u8, p, "PM")) {
                            pm_set = true;
                        } else if (mem.eql(u8, p, "AM")) {
                            am_set = true;
                        } else {
                            return error.BadValue;
                        }
                    },
                    .a => {
                        if (val.len < 2) {
                            return error.BadValue;
                        }

                        const p = val[0..2];
                        val = val[2..];
                        if (mem.eql(u8, p, "pm")) {
                            pm_set = true;
                        } else if (mem.eql(u8, p, "am")) {
                            am_set = true;
                        } else {
                            return error.BadValue;
                        }
                    },

                    .H, .HH => {
                        const n = try getNum(val, false);
                        parsed_hour = n.value;

                        val = n.string;
                        if (parsed_hour < 0 or 24 <= parsed_hour) {
                            return error.BadHourRange;
                        }
                    },
                    .h, .hh => {
                        const n = try getNum(val, fmtSeq.seq == .hh);
                        parsed_hour = n.value;
                        val = n.string;
                        if (parsed_hour < 0 or 12 <= parsed_hour) {
                            return error.BadHourRange;
                        }
                    },
                    .k, .kk => {
                        const n = try getNum(val, false);
                        parsed_hour = n.value;

                        val = n.string;
                        if (parsed_hour < 0 or 24 <= parsed_hour) {
                            return error.BadHourRange;
                        }
                    },

                    .m, .mm => {
                        const n = try getNum(val, fmtSeq.seq == .mm);
                        parsed_min = n.value;
                        val = n.string;
                        if (parsed_min < 0 or 60 <= parsed_min) {
                            return error.BadMinuteRange;
                        }
                    },

                    .s, .ss => {
                        const n = try getNum(val, fmtSeq.seq == .ss);
                        parsed_sec = n.value;
                        val = n.string;
                        if (parsed_sec < 0 or 60 <= parsed_sec) {
                            return error.BadSecondRange;
                        }
                    },

                    .S, .SS, .SSS => {
                        const n = try getNum3(val, false);
                        parsed_nsec = n.value;

                        val = n.string;
                    },

                    .SSSS, .SSSSS, .SSSSSS => {
                        const n = try getNumN(6, val, false);
                        parsed_nsec = n.value;

                        val = n.string;
                    },

                    .SSSSSSS, .SSSSSSSS, .SSSSSSSSS => {
                        const n = try getNumN(9, val, false);
                        parsed_nsec = n.value;

                        val = n.string;
                    },

                    .z => {
                        if (val.len < 3) {
                            return error.BadValue;
                        }

                        const p = val[0..3];
                        val = val[3..];

                        if (ctx.equal(p, "GMT")) {
                            parsed_loc = GMT;
                        } else if (ctx.equal(p, "UTC")) {
                            parsed_loc = UTC;
                        } else if (ctx.equal(p, "CET")) {
                            parsed_loc = CET;
                        } else if (ctx.equal(p, "EET")) {
                            parsed_loc = EET;
                        } else if (ctx.equal(p, "MET")) {
                            parsed_loc = MET;
                        } else if (ctx.equal(p, "CTT")) {
                            parsed_loc = CTT;
                        } else if (ctx.equal(p, "CAT")) {
                            parsed_loc = CAT;
                        } else if (ctx.equal(p, "EST")) {
                            parsed_loc = EST;
                        } else if (ctx.equal(p, "MST")) {
                            parsed_loc = MST;
                        } else if (ctx.equal(p, "CST")) {
                            parsed_loc = CST;
                        } else {
                            return error.BadValue;
                        }
                    },
                    .Z, .ZZ => {
                        const n = try parseTimezone(val);
                        parsed_loc = Location.create(@as(i32, @intCast(n.value)), "");
                        val = n.string;
                    },
                    else => {},
                }
                next = null;
            } else {
                val = val[fmtSeq.value.len..];
            }
        }

        var now_loc = loction;
        if (parsed_loc) |new_loc| {
            now_loc = new_loc;
        }

        if (pm_set) {
            parsed_hour = parsed_hour + 12;
        }

        return fromDatetime(
            parsed_year,
            parsed_month,
            parsed_day,
            parsed_hour,
            parsed_min,
            parsed_sec,
            parsed_nsec,
            now_loc,
        );
    }

    /// format datetime to output string
    pub fn format(self: Self, comptime fmt: string, options: std.fmt.Options, w: *Io.Writer) !void {
        _ = options;

        if (fmt.len == 0) {
            @compileError("DateTime: format string can't be empty");
        }

        @setEvalBranchQuota(100000);

        var writer = w;

        const tz = self.location();

        const d = self.date();

        const years = @as(u16, @intCast(d.year));
        const months = d.month.numeric() - 1;
        const days = @as(u8, @intCast(d.day));

        const hours = self.hour();
        const minutes = self.minute();
        const seconds = self.second();
        const ms = @as(u16, @intCast(@divTrunc(self.nanosecond(), time.ns_per_ms)));
        const us = @as(u32, @intCast(@divTrunc(self.nanosecond(), time.ns_per_us)));
        const ns = @as(u32, @intCast(self.nanosecond()));

        var next: ?FormatSeq = null;
        var newFmt = fmt;
        while (newFmt.len > 0) {
            const fmtSeq = nextSeq(newFmt);

            newFmt = fmtSeq.last;
            next = fmtSeq.seq;

            if (next) |tag| {
                switch (tag) {
                    .MM => try writer.print("{:0>2}", .{months + 1}),
                    .M => try writer.print("{}", .{months + 1}),
                    .Mo => try writeOrdinal(writer, months + 1),
                    .MMM => try writeLongName(writer, months, &short_month_names),
                    .MMMM => try writeLongName(writer, months, &long_month_names),

                    .Q => try writer.print("{}", .{months / 3 + 1}),
                    .Qo => try writeOrdinal(writer, months / 3 + 1),

                    .D => try writer.print("{}", .{days}),
                    .Do => try writeOrdinal(writer, days),
                    .DD => try writer.print("{:0>2}", .{days}),

                    .DDD => try writer.print("{}", .{self.yearDay()}),
                    .DDDo => try writeOrdinal(writer, self.yearDay()),
                    .DDDD => try writer.print("{:0>3}", .{self.yearDay()}),

                    .d => try writer.print("{}", .{@intFromEnum(self.weekday())}),
                    .do => try writeOrdinal(writer, @as(u16, @intCast(@intFromEnum(self.weekday())))),
                    .dd => try writer.writeAll(@tagName(self.weekday())[0..2]),
                    .ddd => try writeLongName(writer, @as(u16, @intCast(@intFromEnum(self.weekday()))), &short_day_names),
                    .dddd => try writer.writeAll(@tagName(self.weekday())),
                    .e => try writer.print("{}", .{@intFromEnum(self.weekday())}),
                    .E => try writer.print("{}", .{@intFromEnum(self.weekday()) + 1}),

                    .w => try writer.print("{}", .{self.yearDay() / 7}),
                    .wo => try writeOrdinal(writer, self.yearDay() / 7),
                    .ww => try writer.print("{:0>2}", .{self.yearDay() / 7}),

                    .Y => try writer.print("{}", .{years + 10000}),
                    .YY => try writer.print("{:0>2}", .{years % 100}),
                    .YYY => try writer.print("{}", .{years}),
                    .YYYY => try writer.print("{:0>4}", .{years}),

                    .A => try writeLongName(writer, hours / 12, &[_]string{ "AM", "PM" }),
                    .a => try writeLongName(writer, hours / 12, &[_]string{ "am", "pm" }),

                    .H => try writer.print("{}", .{hours}),
                    .HH => try writer.print("{:0>2}", .{hours}),
                    .h => try writer.print("{}", .{wrap(hours, 12)}),
                    .hh => try writer.print("{:0>2}", .{wrap(hours, 12)}),
                    .k => try writer.print("{}", .{wrap(hours, 24)}),
                    .kk => try writer.print("{:0>2}", .{wrap(hours, 24)}),

                    .m => try writer.print("{}", .{minutes}),
                    .mm => try writer.print("{:0>2}", .{minutes}),

                    .s => try writer.print("{}", .{seconds}),
                    .ss => try writer.print("{:0>2}", .{seconds}),

                    .S => try writer.print("{}", .{ms / 100}),
                    .SS => try writer.print("{:0>2}", .{ms / 10}),
                    .SSS => try writer.print("{:0>3}", .{ms}),
                    .SSSS => try writer.print("{d:0>4}", .{us / 100}),
                    .SSSSS => try writer.print("{d:0>5}", .{us / 10}),
                    .SSSSSS => try writer.print("{d:0>6}", .{us}),
                    .SSSSSSS => try writer.print("{d:0>7}", .{ns / 100}),
                    .SSSSSSSS => try writer.print("{d:0>8}", .{ns / 10}),
                    .SSSSSSSSS => try writer.print("{d:0>9}", .{ns}),

                    .z => {
                        try tz.string(writer);
                    },
                    .Z => {
                        try tz.offsetFormatString(writer);
                    },
                    .ZZ => {
                        try tz.offsetString(writer);
                    },

                    .x => try writer.print("{}", .{self.milliTimestamp()}),
                    .X => try writer.print("{}", .{self.timestamp()}),
                }
                next = null;
            } else {
                try writer.writeAll(fmtSeq.value);
            }
        }
    }

    pub fn formatAlloc(self: Self, alloc: Allocator, comptime fmt: string) !string {
        const initial_buf = try alloc.alloc(u8, 8);

        var aw: Allocating = .initOwnedSlice(alloc, initial_buf);
        defer aw.deinit();

        try self.format(fmt, .{}, &aw.writer);
        return alloc.dupe(u8, aw.writer.buffered());
    }
};

pub const FormatSeq = enum {
    M, // 1 2 ... 11 12
    Mo, // 1st 2nd ... 11th 12th
    MM, // 01 02 ... 11 12
    MMM, // Jan Feb ... Nov Dec
    MMMM, // January February ... November December
    Q, // 1 2 3 4
    Qo, // 1st 2nd 3rd 4th
    D, // 1 2 ... 30 31
    Do, // 1st 2nd ... 30th 31st
    DD, // 01 02 ... 30 31
    DDD, // 1 2 ... 364 365
    DDDo, // 1st 2nd ... 364th 365th
    DDDD, // 001 002 ... 364 365
    d, // 0 1 ... 5 6
    do, // 0th 1st ... 5th 6th
    dd, // Su Mo ... Fr Sa
    ddd, // Sun Mon ... Fri Sat
    dddd, // Sunday Monday ... Friday Saturday
    e, // 0 1 ... 5 6 (locale)
    E, // 1 2 ... 6 7 (ISO)
    w, // 1 2 ... 52 53
    wo, // 1st 2nd ... 52nd 53rd
    ww, // 01 02 ... 52 53
    Y, // 11970 11971 ... 19999 20000 20001 (Holocene calendar)
    YY, // 70 71 ... 29 30
    YYY, // 1 2 ... 1970 1971 ... 2029 2030
    YYYY, // 0001 0002 ... 1970 1971 ... 2029 2030
    A, // AM PM
    a, // am pm
    H, // 0 1 ... 22 23
    HH, // 00 01 ... 22 23
    h, // 1 2 ... 11 12
    hh, // 01 02 ... 11 12
    k, // 1 2 ... 23 24
    kk, // 01 02 ... 23 24
    m, // 0 1 ... 58 59
    mm, // 00 01 ... 58 59
    s, // 0 1 ... 58 59
    ss, // 00 01 ... 58 59
    S, // 0 1 ... 8 9 (second fraction)
    SS, // 00 01 ... 98 99
    SSS, // 000 001 ... 998 999
    SSSS, // 0000
    SSSSS, // 00000
    SSSSSS, // 000000
    SSSSSSS, // 0000000
    SSSSSSSS, // 00000000
    SSSSSSSSS, // 000000000
    z, // EST CST ... MST PST
    Z, // -07:00 -06:00 ... +06:00 +07:00
    ZZ, // -0700 -0600 ... +0600 +0700
    x, // unix milli
    X, // unix

    fn eql(self: FormatSeq, other: FormatSeq) bool {
        return @intFromEnum(self) == @intFromEnum(other);
    }
};

pub const Format = struct {
    pub const LT = "h:mm A";
    pub const LTS = "h:mm:ss A";
    pub const L = "MM/DD/YYYY";
    pub const l = "M/D/YYY";
    pub const LL = "MMMM D, YYYY";
    pub const ll = "MMM D, YYY";
    pub const LLL = LL ++ " " ++ LT;
    pub const lll = ll ++ " " ++ LT;
    pub const LLLL = "dddd, " ++ LLL;
    pub const llll = "ddd, " ++ lll;

    pub const date = "YYYY-MM-DD";
    pub const time = "HH:mm:ss";
    pub const date_time = "YYYY-MM-DD HH:mm:ss";
};

// timezone type list
pub const GMT = Location.create(0, "GMT");
pub const UTC = Location.create(0, "UTC");
pub const CET = Location.create(60, "CET");
pub const EET = Location.create(120, "EET");
pub const MET = Location.create(210, "MET");
pub const CTT = Location.create(480, "CTT");
pub const CAT = Location.create(-60, "CAT");
pub const EST = Location.create(-300, "EST");
pub const MST = Location.create(-420, "MST");
pub const CST = Location.create(-480, "CST");

// new Time from date data
pub fn date(
    year: isize,
    month: isize,
    day: isize,
    hour: isize,
    min: isize,
    sec: isize,
    nsec: isize,
    loc: Location,
) Time {
    return Time.fromDatetime(year, month, day, hour, min, sec, nsec, loc);
}

pub fn timeNanoseconds() i96 {
    const ts = Io.Timestamp.now(std.Options.debug_io, .real).toNanoseconds();
    return ts;
}

pub fn timeTimestamp() i64 {
    return @intCast(@divTrunc(timeNanoseconds(), std.time.ns_per_s));
}

pub fn timeMilliseconds() i64 {
    return @intCast(@divTrunc(timeNanoseconds(), std.time.ns_per_ms));
}

pub fn timeMicroseconds() i64 {
    return @intCast(@divTrunc(timeNanoseconds(), std.time.ns_per_us));
}

// now time
pub fn now(io: Io) Time {
    return Time.now(io);
}

// use unix date to Time
pub fn unix(sec: i64, nsec: i64) Time {
    return Time.fromUnix(sec, nsec);
}

// Since returns the time elapsed since t.
// It is shorthand for time.now().sub(t).
pub fn since(io: Io, t: Time) Duration {
    return now(io).sub(t);
}

// Until returns the duration until t.
// It is shorthand for t.sub(time.now()).
pub fn until(io: Io, t: Time) Duration {
    return t.sub(now(io));
}

fn daysSinceeEpoch(year: isize) u64 {
    var y = @as(u64, @intCast(@as(i64, @intCast(year)) - absolute_zero_year));

    // Add in days from 400-year cycles.
    var n = @divTrunc(y, 400);
    y -= (400 * n);
    var d = days_per_400_years * n;

    // Add in 100-year cycles.
    n = @divTrunc(y, 100);
    y -= 100 * n;
    d += days_per_100_years * n;

    // Add in 4-year cycles.
    n = @divTrunc(y, 4);
    y -= 4 * n;
    d += days_per_4_years * n;

    // Add in non-leap years.
    n = y;
    d += 365 * n;

    return d;
}

const long_day_names = [_][]const u8{
    "Sunday",
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
};

const short_day_names = [_]string{
    "Sun",
    "Mon",
    "Tue",
    "Wed",
    "Thu",
    "Fri",
    "Sat",
};

const short_month_names = [_]string{
    "Jan",
    "Feb",
    "Mar",
    "Apr",
    "May",
    "Jun",
    "Jul",
    "Aug",
    "Sep",
    "Oct",
    "Nov",
    "Dec",
};

const long_month_names = [_]string{
    "January",
    "February",
    "March",
    "April",
    "May",
    "June",
    "July",
    "August",
    "September",
    "October",
    "November",
    "December",
};

pub const Weekday = enum(usize) {
    Sunday,
    Monday,
    Tuesday,
    Wednesday,
    Thursday,
    Friday,
    Saturday,

    pub fn string(self: Weekday) []const u8 {
        const d = @intFromEnum(self);
        if (@intFromEnum(Weekday.Sunday) <= d and d <= @intFromEnum(Weekday.Saturday)) {
            return long_day_names[d];
        }

        unreachable;
    }
};

/// ISO 8601 year and week number
pub const ISOWeek = struct {
    year: isize,
    week: isize,
};

fn absWeekday(abs: u64) Weekday {
    const s = @mod(abs + @as(u64, @intCast(@intFromEnum(Weekday.Monday))) * seconds_per_day, seconds_per_week);
    const w = s / seconds_per_day;
    return @as(Weekday, @enumFromInt(@as(usize, @intCast(w))));
}

const FracRes = struct {
    nw: usize,
    nv: u64,
};

fn fmtFrac(buf: []u8, value: u64, prec: usize) FracRes {
    // Omit trailing zeros up to and including decimal point.
    var w = buf.len;
    var v = value;
    var i: usize = 0;
    var print: bool = false;

    while (i < prec) : (i += 1) {
        const digit = @mod(v, 10);
        print = print or digit != 0;
        if (print) {
            w -= 1;
            buf[w] = @as(u8, @intCast(digit)) + '0';
        }
        v /= 10;
    }

    if (print) {
        w -= 1;
        buf[w] = '.';
    }

    return .{
        .nw = w,
        .nv = v,
    };
}

fn fmtInt(buf: []u8, value: u64) usize {
    var w = buf.len;
    var v = value;
    if (v == 0) {
        w -= 1;
        buf[w] = '0';
    } else {
        while (v > 0) {
            w -= 1;
            buf[w] = @as(u8, @intCast(@mod(v, 10))) + '0';
            v /= 10;
        }
    }

    return w;
}

pub const Duration = struct {
    value: i64,

    const Self = @This();

    pub const Nanosecond = init(1);
    pub const Microsecond = init(1000 * Nanosecond.value);
    pub const Millisecond = init(1000 * Microsecond.value);
    pub const Second = init(1000 * Millisecond.value);
    pub const Minute = init(60 * Second.value);
    pub const Hour = init(60 * Minute.value);

    pub const MinDuration = init(-1 << 63);
    pub const MaxDuration = init((1 << 63) - 1);

    // fmtFrac formats the fraction of v/10**prec (e.g., ".12345") into the
    // tail of buf, omitting trailing zeros. It omits the decimal
    // point too when the fraction is 0. It returns the index where the
    // output bytes begin and the value v/10**prec.

    pub fn init(v: i64) Duration {
        return .{
            .value = v,
        };
    }

    pub fn string(self: Self, writer: *Io.Writer) !void {
        var buf: [32]u8 = undefined;
        var w = buf.len;
        var u: u64 = undefined;

        const neg = self.value < 0;
        if (neg) {
            u = @as(u64, @intCast(-self.value));
        } else {
            u = @as(u64, @intCast(self.value));
        }

        if (u < @as(u64, @intCast(Second.value))) {
            // Special case: if duration is smaller than a second,
            // use smaller units, like 1.2ms
            var prec: usize = 0;

            w -= 1;
            buf[w] = 's';

            w -= 1;
            if (u == 0) {
                const s = "0s";

                try writer.writeAll(s[0..]);
                return;
            } else if (u < @as(u64, @intCast(Microsecond.value))) {
                // print nanoseconds
                prec = 0;
                buf[w] = 'n';
            } else if (u < @as(u64, @intCast(Millisecond.value))) {
                // print microseconds
                prec = 3;
                // U+00B5 'µ' micro sign == 0xC2 0xB5
                w -= 1;
                @memcpy(buf[w..], "µ");
            } else {
                prec = 6;
                buf[w] = 'm';
            }

            const r = fmtFrac(buf[0..w], u, prec);
            w = r.nw;
            u = r.nv;
            w = fmtInt(buf[0..w], u);
        } else {
            w -= 1;
            buf[w] = 's';
            const r = fmtFrac(buf[0..w], u, 9);
            w = r.nw;
            u = r.nv;
            w = fmtInt(buf[0..w], @mod(u, 60));
            u /= 60;

            // u is now integer minutes
            if (u > 0) {
                w -= 1;
                buf[w] = 'm';
                w = fmtInt(buf[0..w], @mod(u, 60));
                u /= 60;
                // u is now integer hours
                // Stop at hours because days can be different lengths.
                if (u > 0) {
                    w -= 1;
                    buf[w] = 'h';
                    w = fmtInt(buf[0..w], u);
                }
            }
        }

        if (neg) {
            w -= 1;
            buf[w] = '-';
        }

        try writer.writeAll(buf[w..]);
    }

    pub fn stringAlloc(self: Self, alloc: Allocator) ![]const u8 {
        const initial_buf = try alloc.alloc(u8, 8);

        var aw: Allocating = .initOwnedSlice(alloc, initial_buf);
        defer aw.deinit();

        try self.string(&aw.writer);
        return alloc.dupe(u8, aw.writer.buffered());
    }

    /// nanoseconds returns the duration as an integer nanosecond count.
    pub fn nanoseconds(self: Self) i64 {
        return self.value;
    }

    /// microseconds returns the duration as an integer microsecond count.
    pub fn microseconds(self: Self) i64 {
        return @divTrunc(self.value, time.ns_per_us);
    }

    /// milliseconds returns the duration as an integer millisecond count.
    pub fn milliseconds(self: Self) i64 {
        return @divTrunc(self.value, time.ns_per_ms);
    }

    // These methods return float64 because the dominant
    // use case is for printing a floating point number like 1.5s, and
    // a truncation to integer would make them not useful in those cases.
    // Splitting the integer and fraction ourselves guarantees that
    // converting the returned float64 to an integer rounds the same
    // way that a pure integer conversion would have, even in cases
    // where, say, float64(d.Nanoseconds())/1e9 would have rounded
    // differently.

    /// Seconds returns the duration as a floating point number of seconds.
    pub fn seconds(self: Self) f64 {
        const sec = @divTrunc(self.value, Second.value);
        const nsec = @mod(self.value, Second.value);
        return @as(f64, @floatFromInt(sec)) + @as(f64, @floatFromInt(nsec)) / 1e9;
    }

    /// Minutes returns the duration as a floating point number of minutes.
    pub fn minutes(self: Self) f64 {
        const min = @divTrunc(self.value, Minute.value);
        const nsec = @mod(self.value, Minute.value);
        return @as(f64, @floatFromInt(min)) + @as(f64, @floatFromInt(nsec)) / (60 * 1e9);
    }

    /// Hours returns the duration as a floating point number of hours.
    pub fn hours(self: Self) f64 {
        const hour = @divTrunc(self.value, Hour.value);
        const nsec = @mod(self.value, Hour.value);
        return @as(f64, @floatFromInt(hour)) + @as(f64, @floatFromInt(nsec)) / (60 * 60 * 1e9);
    }

    /// Truncate returns the result of rounding d toward zero to a multiple of m.
    /// If m <= 0, Truncate returns d unchanged.
    pub fn truncate(self: Self, m: Self) Duration {
        if (m.value <= 0) {
            return self;
        }

        return init(self.value - @mod(self.value, m.value));
    }

    /// lessThanHalf reports whether x+x < y but avoids overflow,
    /// assuming x and y are both positive (Duration is signed).
    fn lessThanHalf(self: Self, m: Self) bool {
        const x = @as(u64, @intCast(self.value));
        return x + x < @as(u64, @intCast(m.value));
    }

    /// Round returns the result of rounding d to the nearest multiple of m.
    /// The rounding behavior for halfway values is to round away from zero.
    /// If the result exceeds the maximum (or minimum)
    /// value that can be stored in a Duration,
    /// Round returns the maximum (or minimum) duration.
    /// If m <= 0, Round returns d unchanged.
    pub fn round(self: Self, m: Self) Duration {
        if (m.value <= 0) {
            return self;
        }

        var r = init(@mod(self.value, m.value));
        if (self.value < 0) {
            r.value = -r.value;
            if (r.lessThanHalf(m)) {
                return init(self.value + r.value);
            }

            const d = self.value - m.value + r.value;
            if (d < self.value) {
                return init(d);
            }

            return MinDuration;
        }

        if (r.lessThanHalf(m)) {
            return init(self.value - r.value);
        }

        const d = self.value + m.value - r.value;
        if (d > self.value) {
            return init(d);
        }

        return MaxDuration;
    }

    pub fn abs(self: Self) Duration {
        if (self.value >= 0) {
            return self;
        } else if (self.value == MinDuration.value) {
            return MaxDuration;
        } else {
            return Duration.init(-self.value);
        }
    }
};

pub const Clock = struct {
    hour: isize,
    min: isize,
    sec: isize,

    fn absClock(abs: u64) Clock {
        var sec = @as(isize, @intCast(abs % seconds_per_day));
        const hour = @divTrunc(sec, seconds_per_hour);
        sec -= (hour * seconds_per_hour);
        const min = @divTrunc(sec, seconds_per_minute);
        sec -= (min * seconds_per_minute);

        return .{
            .hour = hour,
            .min = min,
            .sec = sec,
        };
    }
};

const NormRes = struct {
    hi: isize,
    lo: isize,
};

// norm returns nhi, nlo such that
//  hi * base + lo == nhi * base + nlo
//  0 <= nlo < base
fn norm(i: isize, o: isize, base: isize) NormRes {
    var hi = i;
    var lo = o;
    if (lo < 0) {
        const n = @divTrunc(-lo - 1, base) + 1;
        hi -= n;
        lo += (n * base);
    }

    if (lo >= base) {
        const n = @divTrunc(lo, base);
        hi += n;
        lo -= (n * base);
    }

    return .{
        .hi = hi,
        .lo = lo,
    };
}

const nsec_mask: u64 = (1 << 30) - 1;

const daysBefore = [_]isize{
    0,
    31,
    31 + 28,
    31 + 28 + 31,
    31 + 28 + 31 + 30,
    31 + 28 + 31 + 30 + 31,
    31 + 28 + 31 + 30 + 31 + 30,
    31 + 28 + 31 + 30 + 31 + 30 + 31,
    31 + 28 + 31 + 30 + 31 + 30 + 31 + 31,
    31 + 28 + 31 + 30 + 31 + 30 + 31 + 31 + 30,
    31 + 28 + 31 + 30 + 31 + 30 + 31 + 31 + 30 + 31,
    31 + 28 + 31 + 30 + 31 + 30 + 31 + 31 + 30 + 31 + 30,
    31 + 28 + 31 + 30 + 31 + 30 + 31 + 31 + 30 + 31 + 30 + 31,
};

const seconds_per_minute = 60;
const seconds_per_hour = 60 * seconds_per_minute;
const seconds_per_day = 24 * seconds_per_hour;
const seconds_per_week = 7 * seconds_per_day;
const days_per_400_years = 365 * 400 + 97;
const days_per_100_years = 365 * 100 + 24;
const days_per_4_years = 365 * 4 + 1;
const absolute_zero_year: i64 = -292277022399;

// The year of the zero Time.
// Assumed by the unix_to_internal computation below.
const internal_year: i64 = 1;

const unix_to_internal: i64 = (1969 * 365 + 1969 / 4 - 1969 / 100 + 1969 / 400) * seconds_per_day;
const internal_to_unix: i64 = -unix_to_internal;

// Offsets to convert between internal and absolute or Unix times.
const absolute_to_internal: i64 = (absolute_zero_year - internal_year) * @as(i64, @intFromFloat(365.2425 * @as(f64, @floatFromInt(seconds_per_day))));
const internal_to_absolute = -absolute_to_internal;

pub const DateDetail = struct {
    year: isize,
    month: epoch.Month,
    day: isize,
    yday: isize,
};

fn absDate(abs: u64, full: bool) DateDetail {
    var details: DateDetail = undefined;

    // Split into time and day.
    var d = abs / seconds_per_day;

    // Account for 400 year cycles.
    var n = d / days_per_400_years;
    var y = 400 * n;
    d -= days_per_400_years * n;

    // Cut off 100-year cycles.
    // The last cycle has one extra leap year, so on the last day
    // of that year, day / days_per_100_years will be 4 instead of 3.
    // Cut it back down to 3 by subtracting n>>2.
    n = d / days_per_100_years;
    n -= n >> 2;
    y += 100 * n;
    d -= days_per_100_years * n;

    // Cut off 4-year cycles.
    // The last cycle has a missing leap year, which does not
    // affect the computation.
    n = d / days_per_4_years;
    y += 4 * n;
    d -= days_per_4_years * n;

    // Cut off years within a 4-year cycle.
    // The last year is a leap year, so on the last day of that year,
    // day / 365 will be 4 instead of 3. Cut it back down to 3
    // by subtracting n>>2.
    n = d / 365;
    n -= n >> 2;
    y += n;
    d -= 365 * n;
    details.year = @as(isize, @intCast(@as(i64, @intCast(y)) + absolute_zero_year));
    details.yday = @as(isize, @intCast(d));
    if (!full) {
        return details;
    }

    details.day = details.yday;
    if (epoch.isLeapYear(@as(epoch.Year, @intCast(details.year)))) {
        if (details.day > (31 + 29 - 1)) {
            // After leap day; pretend it wasn't there.
            details.day -= 1;
        } else if (details.day == (31 + 29 - 1)) {
            // Leap day.
            details.month = epoch.Month.feb;
            details.day = 29;
            return details;
        }
    }

    // Estimate month on assumption that every month has 31 days.
    // The estimate may be too low by at most one month, so adjust.
    var month = @as(usize, @intCast(details.day)) / @as(usize, 31);
    const end = daysBefore[month + 1];
    var begin: isize = 0;
    if (details.day >= end) {
        month += 1;
        begin = end;
    } else {
        begin = daysBefore[month];
    }

    month += 1;
    details.day = details.day - begin + 1;
    details.month = @as(epoch.Month, @enumFromInt(month));
    return details;
}

fn writeOrdinal(writer: *Io.Writer, num: u16) !void {
    try writer.print("{}", .{num});
    try writer.writeAll(switch (num) {
        1 => "st",
        2 => "nd",
        3 => "rd",
        else => "th",
    });
}

fn writeLongName(writer: anytype, index: u16, names: []const string) !void {
    try writer.writeAll(names[index]);
}

const Number = struct {
    value: isize,
    string: []const u8,
};

fn getNumFromOrdinal(val: string) !Number {
    const n = try getNum3(val, false);
    const value = n.value;
    const last = n.string;

    const se = last[0..2];

    var res: bool = false;
    if (equal(se, "st") or equal(se, "nd") or equal(se, "rd") or equal(se, "th")) {
        res = true;
    }

    if (res) {
        return .{
            .value = value,
            .string = last[2..],
        };
    }

    return error.BadValue;
}

fn wrap(val: u16, at: u16) u16 {
    const tmp = val % at;
    return if (tmp == 0) at else tmp;
}

const SeqResut = struct {
    seq: ?FormatSeq,
    value: []const u8,
    last: []const u8,
};

fn nextSeq(fmt: []const u8) SeqResut {
    if (fmt.len > 6 and std.mem.eql(u8, fmt[0..6], "SSSSSS")) {
        return nextSeqN(fmt, 9);
    } else if (fmt.len > 3 and std.mem.eql(u8, fmt[0..3], "SSS")) {
        return nextSeqN(fmt, 6);
    } else {
        return nextSeqN(fmt, 4);
    }
}

fn nextSeqN(fmt: []const u8, n: usize) SeqResut {
    var next: ?FormatSeq = null;
    var maxLen: usize = 0;

    if (fmt.len < n) {
        maxLen = fmt.len;
    } else {
        maxLen = n;
    }

    var i: usize = 1;
    var lock: usize = 1;
    while (i <= maxLen) : (i += 1) {
        if (std.meta.stringToEnum(FormatSeq, fmt[0..i])) |tag| {
            next = tag;
            lock = i;
        }
    }

    if (next) |tag| {
        return .{
            .seq = tag,
            .value = fmt[0..lock],
            .last = fmt[lock..],
        };
    }

    return .{
        .seq = null,
        .value = fmt[0..1],
        .last = fmt[1..],
    };
}

fn isDigit(s: []const u8, i: usize) bool {
    if (s.len <= i) {
        return false;
    }

    const c = s[i];
    return '0' <= c and c <= '9';
}

// startsWithLowerCase reports whether the string has a lower-case letter at the beginning.
// Its purpose is to prevent matching strings like "Month" when looking for "Mon".
fn startsWithLowerCase(str: []const u8) bool {
    if (str.len == 0) {
        return false;
    }

    const c = str[0];
    return 'a' <= c and c <= 'z';
}

// if a == b, return true
fn equal(a: string, b: string) bool {
    if (mem.eql(u8, a, b)) {
        return true;
    }

    return false;
}

// match reports whether s1 and s2 match ignoring case.
// It is assumed s1 and s2 are the same length.
fn match(s1: []const u8, s2: []const u8) bool {
    if (s1.len != s2.len) {
        return false;
    }

    var i: usize = 0;
    while (i < s1.len) : (i += 1) {
        var c1 = s1[i];
        var c2 = s2[i];

        if (c1 != c2) {
            c1 |= ('a' - 'A');
            c2 |= ('a' - 'A');

            if (c1 != c2 or c1 < 'a' or c1 > 'z') {
                return false;
            }
        }
    }

    return true;
}

fn lookup(tab: []const []const u8, val: []const u8) !usize {
    for (tab, 0..) |v, i| {
        if (val.len >= v.len and match(val[0..v.len], v)) {
            return i;
        }
    }

    return error.BadValue;
}

// getnum parses s[0:1] or s[0:2] (fixed forces s[0:2])
// as a decimal integer and returns the integer and the
// remainder of the string.
fn getNum(s: []const u8, fixed: bool) !Number {
    if (!isDigit(s, 0)) {
        return error.BadData;
    }

    if (!isDigit(s, 1)) {
        if (fixed) {
            return error.BadData;
        }

        return .{
            .value = @as(isize, @intCast(s[0])) - '0',
            .string = s[1..],
        };
    }

    const n = (@as(isize, @intCast(s[0])) - '0') * 10 + (@as(isize, @intCast(s[1])) - '0');
    return .{
        .value = n,
        .string = s[2..],
    };
}

// getnum3 parses s[0:1], s[0:2], or s[0:3] (fixed forces s[0:3])
// as a decimal integer and returns the integer and the remainder
// of the string.
fn getNum3(s: []const u8, fixed: bool) !Number {
    var n: isize = 0;
    var i: usize = 0;
    while (i < 3 and isDigit(s, i)) : (i += 1) {
        n = n * 10 + @as(isize, @intCast(s[i] - '0'));
    }

    if (i == 0 or (fixed and i != 3)) {
        return error.BadData;
    }

    return .{
        .value = n,
        .string = s[i..],
    };
}

fn getNumN(num: usize, s: []const u8, fixed: bool) !Number {
    var n: isize = 0;
    var i: usize = 0;
    while (i < num and isDigit(s, i)) : (i += 1) {
        n = n * 10 + @as(isize, @intCast(s[i] - '0'));
    }

    if (i == 0 or (fixed and i != num)) {
        return error.BadData;
    }

    return .{
        .value = n,
        .string = s[i..],
    };
}

fn parseTimezone(s: []const u8) !Number {
    var is_neg: bool = false;
    var h: isize = 0;
    var m: isize = 0;

    var str = s;

    if (str.len < 5 or (str[0] != '-' and str[0] != '+')) {
        return error.BadData;
    }

    if (str[0] == '-') {
        is_neg = true;
    }
    str = str[1..];

    const hh = try getNum(str, true);
    h = hh.value;
    str = hh.string;

    if (str[0] == ':') {
        str = str[1..];

        if (str.len < 2) {
            return error.BadData;
        }
    }

    const mm = try getNum(str, true);
    m = mm.value;
    str = mm.string;

    var oo = h * 60 + m;
    if (is_neg) {
        oo = -oo;
    }

    return .{
        .value = oo,
        .string = str,
    };
}

fn parseNanoseconds(value: []const u8, nbytes: usize) !isize {
    if (value[0] != '.') {
        return error.BadData;
    }

    var ns = try std.fmt.parseInt(isize, value[1..nbytes], 10);
    const nf = @as(f64, @floatFromInt(ns));
    if (nf < 0 or 1e9 <= nf) {
        return error.BadFractionalRange;
    }

    const scale_digits = 10 - nbytes;
    var i: usize = 0;
    while (i < scale_digits) : (i += 1) {
        ns *= 10;
    }

    return ns;
}

test "now" {
    const io = testing.io;
    const margin = time.ns_per_ms * 50;

    // std.debug.print("{d}", .{now().milliTimestamp()});

    const time_0 = now(io).milliTimestamp();
    try Io.sleep(io, .fromNanoseconds(time.ns_per_ms), .awake);
    const time_1 = now(io).milliTimestamp();
    const interval = time_1 - time_0;

    try testing.expect(interval > 0);

    const now_t = now(io);
    try testing.expect(now_t.timestamp() > 0);
    try testing.expect(now_t.milliTimestamp() > 0);
    try testing.expect(now_t.microTimestamp() > 0);
    try testing.expect(now_t.nanoTimestamp() > 0);

    const now_1 = timeNanoseconds();
    const now_2 = timeTimestamp();
    const now_3 = timeMilliseconds();
    const now_4 = timeMicroseconds();
    try testing.expect(now_1 > 0);
    try testing.expect(now_2 > 0);
    try testing.expect(now_3 > 0);
    try testing.expect(now_4 > 0);

    // Tests should not depend on timings: skip test if outside margin.
    if (!(interval < margin)) return error.SkipZigTest;
}

test "equal" {
    const ii_0: i128 = 1691879007511594906;
    const ii_1: i128 = 1691879007511594907;

    const time_0 = Time.fromNanoTimestamp(ii_0);
    const time_1 = Time.fromNanoTimestamp(ii_0);
    const time_2 = Time.fromNanoTimestamp(ii_1);

    try testing.expect(time_0.equal(time_1));
    try testing.expect(!time_0.equal(time_2));
}

test "isZero" {
    const ii_0: i128 = 1691879007511594906;
    const ii_1: i128 = 0;

    const time_0 = Time.fromNanoTimestamp(ii_0);
    const time_1 = Time.fromNanoTimestamp(ii_1);

    try testing.expect(!time_0.isZero());
    try testing.expect(time_1.isZero());
}

test "format show" {
    const alloc = testing.allocator;

    const ii_0: i128 = 1691879007511594906;

    const time_0 = Time.fromNanoTimestamp(ii_0).setLoc(Location.fixed(480));

    try testing.expectFmt("1691879007", "{d}", .{time_0.timestamp()});
    try testing.expectFmt("1691879007511", "{d}", .{time_0.milliTimestamp()});
    try testing.expectFmt("1691879007511594", "{d}", .{time_0.microTimestamp()});
    try testing.expectFmt("1691879007511594906", "{d}", .{time_0.nanoTimestamp()});

    try testing.expectFmt("1691879007", "{d}", .{time_0.unix()});
    try testing.expectFmt("2023", "{d}", .{time_0.year()});
    try testing.expectFmt("8", "{d}", .{time_0.month().numeric()});
    try testing.expectFmt("13", "{d}", .{time_0.day()});
    try testing.expectFmt("6", "{d}", .{time_0.hour()});
    try testing.expectFmt("23", "{d}", .{time_0.minute()});
    try testing.expectFmt("27", "{d}", .{time_0.second()});
    try testing.expectFmt("511594906", "{d}", .{time_0.nanosecond()});
    try testing.expectFmt("511594", "{d}", .{time_0.microseconds()});
    try testing.expectFmt("511", "{d}", .{time_0.milliseconds()});
    try testing.expectFmt("225", "{d}", .{time_0.yearDay()});

    const os_str = try time_0.location().stringAlloc(alloc);
    defer alloc.free(os_str);
    try testing.expectFmt("+0800", "{s}", .{os_str});

    const os = try time_0.location().offsetStringAlloc(alloc);
    defer alloc.free(os);
    try testing.expectFmt("+0800", "{s}", .{os});
}

test "from time" {
    const ii_0: i64 = 1691879007511594;
    const time_0 = Time.fromMicroTimestamp(ii_0).setLoc(Location.fixed(480));
    try testing.expectFmt("1691879007511594000", "{d}", .{time_0.nanoTimestamp()});

    const ii_1: i64 = 1691879007511;
    const time_1 = Time.fromMilliTimestamp(ii_1).setLoc(Location.fixed(480));
    try testing.expectFmt("1691879007511000000", "{d}", .{time_1.nanoTimestamp()});

    const ii_2: i64 = 1691879007;
    const time_2 = Time.fromMilliTimestamp(ii_2).setLoc(Location.fixed(480));
    try testing.expectFmt("1691879007000000", "{d}", .{time_2.nanoTimestamp()});
}

test "fromDatetime" {
    const time_0 = Time.fromDatetime(2023, 8, 13, 6, 23, 27, 12, Location.fixed(480));
    try testing.expectFmt("1691879007000000012", "{d}", .{time_0.nanoTimestamp()});

    const time_1 = date(2023, 8, 15, 6, 23, 6, 122, Location.fixed(480));
    try testing.expectFmt("1692051786000000122", "{d}", .{time_1.nanoTimestamp()});
}

test "fromDate" {
    const time_0 = Time.fromDate(2023, 8, 13, Location.fixed(480));
    try testing.expectFmt("1691856000000000000", "{d}", .{time_0.nanoTimestamp()});
}

test "weekday" {
    const ii_0: i64 = 1691879007511594;
    const time_0 = Time.fromMicroTimestamp(ii_0).setLoc(Location.fixed(480));
    try testing.expectFmt("Sunday", "{s}", .{time_0.weekday().string()});
}

test "ISOWeek" {
    const ii_0: i64 = 1691879007511594;
    const time_0 = Time.fromMicroTimestamp(ii_0).setLoc(Location.fixed(480));
    try testing.expectFmt("2023", "{d}", .{time_0.isoWeek().year});
    try testing.expectFmt("33", "{d}", .{time_0.isoWeek().week});
}

fn testCase(comptime seed: i64, comptime fmt: string, comptime expected: string) type {
    return struct {
        test "format" {
            const alloc = std.testing.allocator;
            const instant = Time.fromMilliTimestamp(seed);
            const actual = try instant.formatAlloc(alloc, fmt);
            defer alloc.free(actual);
            std.testing.expectEqualStrings(expected, actual) catch return error.SkipZigTest;
        }
    };
}

fn testHarness(comptime seed: i64, comptime expects: []const [2]string) void {
    for (0..expects.len) |i| {
        const exp = expects[i];
        _ = testCase(seed, exp[0], exp[1]);
    }
}

fn expectFmt(instant: Time, comptime fmt: string, comptime expected: string) !void {
    const alloc = std.testing.allocator;
    const actual = try instant.formatAlloc(alloc, fmt);
    defer alloc.free(actual);
    std.testing.expectEqualStrings(expected, actual) catch return error.SkipZigTest;
}

comptime {
    testHarness(1691879007511, &.{
        .{ "YYYY-MM-DD HH:mm:ss", "2023-08-12 22:23:27" },
    });

    // test more format
    testHarness(1691879007511, &.{
        .{ "YYYY??MM??DD HH<>mm<>ss", "2023??08??12 22<>23<>27" },
    });

    testHarness(0, &.{.{ "YYYY-MM-DD HH:mm:ss", "1970-01-01 00:00:00" }});
    testHarness(1257894000000, &.{.{ "YYYY-MM-DD HH:mm:ss", "2009-11-10 23:00:00" }});
    testHarness(1634858430000, &.{.{ "YYYY-MM-DD HH:mm:ss", "2021-10-21 23:20:30" }});
    testHarness(1634858430023, &.{.{ "YYYY-MM-DD HH:mm:ss.SSS", "2021-10-21 23:20:30.023" }});
    testHarness(1144509852789, &.{.{ "YYYY-MM-DD HH:mm:ss.SSS", "2006-04-08 15:24:12.789" }});

    testHarness(1635033600000, &.{
        .{ "H", "0" },  .{ "HH", "00" },
        .{ "h", "12" }, .{ "hh", "12" },
        .{ "k", "24" }, .{ "kk", "24" },
    });

    testHarness(1635037200000, &.{
        .{ "H", "1" }, .{ "HH", "01" },
        .{ "h", "1" }, .{ "hh", "01" },
        .{ "k", "1" }, .{ "kk", "01" },
    });

    testHarness(1635076800000, &.{
        .{ "H", "12" }, .{ "HH", "12" },
        .{ "h", "12" }, .{ "hh", "12" },
        .{ "k", "12" }, .{ "kk", "12" },
    });
    testHarness(1635080400000, &.{
        .{ "H", "13" }, .{ "HH", "13" },
        .{ "h", "1" },  .{ "hh", "01" },
        .{ "k", "13" }, .{ "kk", "13" },
    });

    testHarness(1144509852789, &.{
        .{ "M", "4" },
        .{ "Mo", "4th" },
        .{ "MM", "04" },
        .{ "MMM", "Apr" },
        .{ "MMMM", "April" },

        .{ "Q", "2" },
        .{ "Qo", "2nd" },

        .{ "D", "8" },
        .{ "Do", "8th" },
        .{ "DD", "08" },

        .{ "DDD", "98" },
        .{ "DDDo", "98th" },
        .{ "DDDD", "098" },

        .{ "d", "6" },
        .{ "do", "6th" },
        .{ "dd", "Sa" },
        .{ "ddd", "Sat" },
        .{ "dddd", "Saturday" },
        .{ "e", "6" },
        .{ "E", "7" },

        .{ "w", "14" },
        .{ "wo", "14th" },
        .{ "ww", "14" },

        .{ "Y", "12006" },
        .{ "YY", "06" },
        .{ "YYY", "2006" },
        .{ "YYYY", "2006" },

        .{ "A", "PM" },
        .{ "a", "pm" },

        .{ "H", "15" },
        .{ "HH", "15" },
        .{ "h", "3" },
        .{ "hh", "03" },
        .{ "k", "15" },
        .{ "kk", "15" },

        .{ "m", "24" },
        .{ "mm", "24" },

        .{ "s", "12" },
        .{ "ss", "12" },

        .{ "S", "7" },
        .{ "SS", "78" },
        .{ "SSS", "789" },

        .{ "z", "UTC" },
        .{ "Z", "+00:00" },
        .{ "ZZ", "+0000" },

        .{ "x", "1144509852789" },
        .{ "X", "1144509852" },

        .{ Format.LT, "3:24 PM" },
        .{ Format.LTS, "3:24:12 PM" },
        .{ Format.L, "04/08/2006" },
        .{ Format.l, "4/8/2006" },
        .{ Format.LL, "April 8, 2006" },
        .{ Format.ll, "Apr 8, 2006" },
        .{ Format.LLL, "April 8, 2006 3:24 PM" },
        .{ Format.lll, "Apr 8, 2006 3:24 PM" },
        .{ Format.LLLL, "Saturday, April 8, 2006 3:24 PM" },
        .{ Format.llll, "Sat, Apr 8, 2006 3:24 PM" },

        .{ Format.date, "2006-04-08" },
        .{ Format.time, "15:24:12" },
        .{ Format.date_time, "2006-04-08 15:24:12" },
    });

    testHarness(1144509852789, &.{.{ "YYYYMM", "200604" }});
}

test "after and before" {
    const ii_0: i128 = 1691879007511594906;
    const ii_1: i128 = 1691879017511594906;

    const time_0 = Time.fromNanoTimestamp(ii_0);
    const time_1 = Time.fromNanoTimestamp(ii_1);

    try testing.expect(time_1.after(time_0));
    try testing.expect(time_0.before(time_1));

    try testing.expect(!time_0.after(time_1));
    try testing.expect(!time_1.before(time_0));
}

test "Clock show" {
    const ii_0: i128 = 1691879007511594906;

    const time_0 = Time.fromNanoTimestamp(ii_0).setLoc(Location.fixed(480));
    const clock_0 = time_0.clock();

    try testing.expectFmt("6", "{d}", .{clock_0.hour});
    try testing.expectFmt("23", "{d}", .{clock_0.min});
    try testing.expectFmt("27", "{d}", .{clock_0.sec});
}

test "add" {
    const ii_0: i128 = 1691879007511594906;
    var time_0 = Time.fromNanoTimestamp(ii_0).setLoc(Location.fixed(480));

    try expectFmt(time_0, "YYYY-MM-DD hh:mm:ss A z", "2023-08-13 06:23:27 AM +0800");

    time_0 = time_0.add(Duration.init(5 * Duration.Second.value));
    try expectFmt(time_0, "YYYY-MM-DD hh:mm:ss A z", "2023-08-13 06:23:32 AM +0800");
}

test "addDate" {
    const ii_0: i128 = 1691879007511594906;
    var time_0 = Time.fromNanoTimestamp(ii_0).setLoc(Location.fixed(480));

    try expectFmt(time_0, "YYYY-MM-DD hh:mm:ss A z", "2023-08-13 06:23:27 AM +0800");

    time_0 = time_0.addDate(1, 2, 5);
    try expectFmt(time_0, "YYYY-MM-DD hh:mm:ss A z", "2024-10-18 06:23:27 AM +0800");
}

test "Duration" {
    const alloc = testing.allocator;

    const dur = Duration.init(2 * Duration.Minute.value + 1 * Duration.Hour.value + 5 * Duration.Second.value);
    const dur2 = Duration.init(-dur.value);

    const dur_str = try dur.stringAlloc(alloc);
    defer alloc.free(dur_str);
    try testing.expectFmt("1h2m5s", "{s}", .{dur_str});

    const dur2_str = try dur2.stringAlloc(alloc);
    defer alloc.free(dur2_str);
    try testing.expectFmt("-1h2m5s", "{s}", .{dur2_str});
    try testing.expectFmt("3725000000000", "{d}", .{dur.nanoseconds()});
    try testing.expectFmt("3725000000", "{d}", .{dur.microseconds()});
    try testing.expectFmt("3725000", "{d}", .{dur.milliseconds()});
    try testing.expectFmt("3725", "{d}", .{dur.seconds()});
    try testing.expectFmt("62.083333333333336", "{d}", .{dur.minutes()});
    try testing.expectFmt("1.0347222222222223", "{d}", .{dur.hours()});

    const dur_2 = Duration.init(1 * Duration.Minute.value + 5 * Duration.Second.value);
    const dur_2_truncate = dur.truncate(dur_2);
    try testing.expectFmt("3705000000000", "{d}", .{dur_2_truncate.nanoseconds()});

    const dur_3 = Duration.init(5 * Duration.Minute.value + 5 * Duration.Second.value);
    const dur_3_round = dur.round(dur_3);
    try testing.expectFmt("3660000000000", "{d}", .{dur_3_round.nanoseconds()});

    const dur_5_1 = Duration.init(-2 * Duration.Minute.value);
    const dur_5_1_abs = dur_5_1.abs();
    try testing.expectFmt("120000000000", "{d}", .{dur_5_1_abs.nanoseconds()});

    const dur_5_2 = Duration.init(3 * Duration.Minute.value);
    const dur_5_2_abs = dur_5_2.abs();
    try testing.expectFmt("180000000000", "{d}", .{dur_5_2_abs.nanoseconds()});

    const dur_5_3 = Duration.MinDuration;
    const dur_5_3_abs = dur_5_3.abs();
    try testing.expectFmt("9223372036854775807", "{d}", .{dur_5_3_abs.nanoseconds()});
}

test "epochSeconds" {
    const ii_0: i128 = 1691879007511594906;
    var time_0 = Time.fromNanoTimestamp(ii_0).setLoc(Location.fixed(480));

    const es = time_0.epochSeconds();
    const epochDay = es.getEpochDay();
    const daySeconds = es.getDaySeconds();

    try testing.expectFmt("80607", "{d}", .{daySeconds.secs});
    try testing.expectFmt("22", "{d}", .{daySeconds.getHoursIntoDay()});
    try testing.expectFmt("23", "{d}", .{daySeconds.getMinutesIntoHour()});
    try testing.expectFmt("27", "{d}", .{daySeconds.getSecondsIntoMinute()});

    try testing.expectFmt("19581", "{d}", .{epochDay.day});

    const yearAndDay = epochDay.calculateYearDay();

    try testing.expectFmt("2023", "{d}", .{yearAndDay.year});
    try testing.expectFmt("223", "{d}", .{yearAndDay.day});

    const monthAndDay = yearAndDay.calculateMonthDay();

    try testing.expectFmt("8", "{d}", .{monthAndDay.month.numeric()});
    try testing.expectFmt("11", "{d}", .{monthAndDay.day_index});
}

test "Weekday show name string" {
    try testing.expectFmt("Sunday", "{s}", .{Weekday.Sunday.string()});
    try testing.expectFmt("Monday", "{s}", .{Weekday.Monday.string()});
    try testing.expectFmt("Tuesday", "{s}", .{Weekday.Tuesday.string()});
    try testing.expectFmt("Wednesday", "{s}", .{Weekday.Wednesday.string()});
    try testing.expectFmt("Thursday", "{s}", .{Weekday.Thursday.string()});
    try testing.expectFmt("Friday", "{s}", .{Weekday.Friday.string()});
    try testing.expectFmt("Saturday", "{s}", .{Weekday.Saturday.string()});
}

test "add Years" {
    var t = Time.fromTimestamp(1330502962);
    try expectFmt(t, "YYYY-MM-DD hh:mm:ss A z", "2012-02-29 08:09:22 AM UTC");
    t = t.addDate(1, 0, 0);
    try expectFmt(t, "YYYY-MM-DD hh:mm:ss A z", "2013-03-01 08:09:22 AM UTC");
}

test "compare" {
    const ii_0: i128 = 1691879007511594906;
    const time_0 = Time.fromNanoTimestamp(ii_0).setLoc(Location.fixed(480));

    const ii_1: i128 = 1691879007517594906;
    const time_1 = Time.fromNanoTimestamp(ii_1).setLoc(Location.fixed(480));

    try testing.expectFmt("-1", "{d}", .{time_0.compare(time_1)});
    try testing.expectFmt("1", "{d}", .{time_1.compare(time_0)});
    try testing.expectFmt("0", "{d}", .{time_1.compare(time_1)});
}

test "time sub" {
    const alloc = testing.allocator;

    const time_0 = Time.fromDatetime(2023, 8, 13, 6, 23, 27, 12, Location.fixed(480));
    const time_1 = Time.fromDatetime(2023, 8, 13, 6, 25, 27, 12, Location.fixed(480));

    const time_sub_1 = time_0.sub(time_1);
    const time_sub_1_str = try time_sub_1.stringAlloc(alloc);
    defer alloc.free(time_sub_1_str);
    try testing.expectFmt("-2m0s", "{s}", .{time_sub_1_str});

    const time_sub_2 = time_1.sub(time_0);
    const time_sub_2_str = try time_sub_2.stringAlloc(alloc);
    defer alloc.free(time_sub_2_str);
    try testing.expectFmt("2m0s", "{s}", .{time_sub_2_str});
}

test "time until and since" {
    const io = testing.io;

    const time_1 = Time.fromDatetime(2023, 8, 13, 6, 25, 27, 12, Location.fixed(480));

    const time_since = until(io, time_1);
    try testing.expect(time_since.nanoseconds() < 0);

    const week_day = @intFromEnum(time_1.weekday());
    try testing.expectFmt("0", "{d}", .{week_day});
}

test "Location fixed name" {
    const alloc = testing.allocator;

    const loc_8 = Location.fixed(480);
    const loc_fu8 = Location.fixed(-480);
    const loc_fu0 = Location.fixed(0);

    const loc_8_str = try loc_8.stringAlloc(alloc);
    defer alloc.free(loc_8_str);
    try testing.expectFmt("+0800", "{s}", .{loc_8_str});

    const loc_fu8_str = try loc_fu8.stringAlloc(alloc);
    defer alloc.free(loc_fu8_str);
    try testing.expectFmt("-0800", "{s}", .{loc_fu8_str});

    const loc_fu0_str = try loc_fu0.stringAlloc(alloc);
    defer alloc.free(loc_fu0_str);
    try testing.expectFmt("+0000", "{s}", .{loc_fu0_str});

    const loc_22 = Location.fixed(22 * 60);
    const loc_fu22 = Location.fixed(-22 * 60);

    const loc_22_str = try loc_22.stringAlloc(alloc);
    defer alloc.free(loc_22_str);
    try testing.expectFmt("+2200", "{s}", .{loc_22_str});

    const loc_fu22_str = try loc_fu22.stringAlloc(alloc);
    defer alloc.free(loc_fu22_str);
    try testing.expectFmt("-2200", "{s}", .{loc_fu22_str});

    const loc_utc = Location.utc();

    const loc_utc_str = try loc_utc.stringAlloc(alloc);
    defer alloc.free(loc_utc_str);
    try testing.expectFmt("UTC", "{s}", .{loc_utc_str});

    const loc_utc1 = Location.create(481, "UTC1");
    const loc_utc1_str = try loc_utc1.stringAlloc(alloc);
    defer alloc.free(loc_utc1_str);
    try testing.expectFmt("UTC1", "{s}", .{loc_utc1_str});
}

test "isDigit" {
    const data = "1ufiy8ki9k";

    try testing.expect(isDigit(data, 0));
    try testing.expect(!isDigit(data, 2));
    try testing.expect(isDigit(data, 5));
}

test "match" {
    const data_1 = "1ufiy8ki9k";
    const data_2 = "1ufiy8ki9k123";
    const data_3 = "1ufiy8ki93";
    const data_4 = "drtgyh";
    const data_5 = "tyujik";

    try testing.expect(!match(data_1, data_2));
    try testing.expect(!match(data_1, data_3));
    try testing.expect(!match(data_4, data_5));
}

test "lookup" {
    const data_1 = [_][]const u8{
        "drtgyh12356",
        "drtgyh123",
        "drtgyy",
    };

    const val = "drtgyh1237";

    const idx_1 = try lookup(data_1[0..], val);
    try testing.expectFmt("1", "{d}", .{idx_1});
}

test "getNum" {
    const val_1 = "35hy";
    const val_2 = "3r78j";

    const num_1 = try getNum(val_1, true);
    try testing.expectFmt("35", "{d}", .{num_1.value});
    try testing.expectFmt("hy", "{s}", .{num_1.string});

    const num_2 = try getNum(val_2, false);
    try testing.expectFmt("3", "{d}", .{num_2.value});
    try testing.expectFmt("r78j", "{s}", .{num_2.string});
}

test "getNum3" {
    const val_1 = "35hy";
    const val_2 = "3r78j";
    const val_3 = "3895kj";

    const num_1 = try getNum3(val_1, false);
    try testing.expectFmt("35", "{d}", .{num_1.value});
    try testing.expectFmt("hy", "{s}", .{num_1.string});

    const num_2 = try getNum3(val_2, false);
    try testing.expectFmt("3", "{d}", .{num_2.value});
    try testing.expectFmt("r78j", "{s}", .{num_2.string});

    const num_3 = try getNum3(val_3, true);
    try testing.expectFmt("389", "{d}", .{num_3.value});
    try testing.expectFmt("5kj", "{s}", .{num_3.string});
}

test "getNumN" {
    const val_1 = "35hy00";
    const val_2 = "378333j00";
    const val_3 = "38956kj00";

    const num_1 = try getNumN(5, val_1, false);
    try testing.expectFmt("35", "{d}", .{num_1.value});
    try testing.expectFmt("hy00", "{s}", .{num_1.string});

    const num_2 = try getNumN(5, val_2, false);
    try testing.expectFmt("37833", "{d}", .{num_2.value});
    try testing.expectFmt("3j00", "{s}", .{num_2.string});

    const num_3 = try getNumN(5, val_3, true);
    try testing.expectFmt("38956", "{d}", .{num_3.value});
    try testing.expectFmt("kj00", "{s}", .{num_3.string});
}

test "parseNanoseconds" {
    const val_1 = ".123456789";

    const num_1 = try parseNanoseconds(val_1, 4);
    try testing.expectFmt("123000000", "{d}", .{num_1});

    const num_2 = try parseNanoseconds(val_1, 7);
    try testing.expectFmt("123456000", "{d}", .{num_2});

    const num_3 = try parseNanoseconds(val_1, 10);
    try testing.expectFmt("123456789", "{d}", .{num_3});
}

test "startsWithLowerCase" {
    const val_1 = "rtf56y";
    try testing.expect(startsWithLowerCase(val_1));

    const val_2 = "Ytf56y";
    try testing.expect(!startsWithLowerCase(val_2));
}

test "nextSeq" {
    const val = "DDDD --==";
    const seq = nextSeq(val);

    try testing.expect(seq.seq.?.eql(FormatSeq.DDDD));

    try testing.expectFmt("DDDD", "{s}", .{seq.value});
    try testing.expectFmt(" --==", "{s}", .{seq.last});
}

comptime {
    const t = Time.fromDatetime(2023, 8, 13, 6, 23, 27, 12, Location.fixed(0));
    const time_2 = Time.fromDatetime(2023, 8, 16, 6, 23, 27, 12, Location.fixed(0));

    const t_1 = t.beginOfHour();
    testHarness(t_1.milliTimestamp(), &.{
        .{ "YYYY-MM-DD HH:mm:ss", "2023-08-13 06:00:00" },
    });

    const t_1_1 = t.endOfHour();
    testHarness(t_1_1.milliTimestamp(), &.{
        .{ "YYYY-MM-DD HH:mm:ss", "2023-08-13 06:59:59" },
    });

    const t_2 = t.beginOfDay();
    testHarness(t_2.milliTimestamp(), &.{
        .{ "YYYY-MM-DD HH:mm:ss", "2023-08-13 00:00:00" },
    });

    const t_2_1 = t.endOfDay();
    testHarness(t_2_1.milliTimestamp(), &.{
        .{ "YYYY-MM-DD HH:mm:ss", "2023-08-13 23:59:59" },
    });

    const t_3 = time_2.beginOfWeek();
    testHarness(t_3.milliTimestamp(), &.{
        .{ "YYYY-MM-DD HH:mm:ss", "2023-08-14 00:00:00" },
    });

    const t_3_1 = time_2.endOfWeek();
    testHarness(t_3_1.milliTimestamp(), &.{
        .{ "YYYY-MM-DD HH:mm:ss", "2023-08-20 23:59:59" },
    });

    const t_4 = time_2.beginOfMonth();
    testHarness(t_4.milliTimestamp(), &.{
        .{ "YYYY-MM-DD HH:mm:ss", "2023-08-01 00:00:00" },
    });

    const t_5 = time_2.endOfMonth();
    testHarness(t_5.milliTimestamp(), &.{
        .{ "YYYY-MM-DD HH:mm:ss", "2023-08-31 23:59:59" },
    });
}

test "time end nanosecond" {
    const time_2 = Time.fromDatetime(2023, 8, 16, 6, 23, 27, 12, Location.fixed(0));

    const t_1_1 = time_2.endOfHour();
    try testing.expectFmt("999999999", "{d}", .{t_1_1.nanosecond()});

    const t_2_1 = time_2.endOfDay();
    try testing.expectFmt("999999999", "{d}", .{t_2_1.nanosecond()});

    const t_3_1 = time_2.endOfWeek();
    try testing.expectFmt("999999999", "{d}", .{t_3_1.nanosecond()});

    const t_5 = time_2.endOfMonth();
    try testing.expectFmt("999999999", "{d}", .{t_5.nanosecond()});
}

test "time parse and setLoc" {
    const dd = try Time.parse("YYYY-MM-DD HH:mm:ss", "2023-08-12 22:23:27");
    try testing.expectFmt("1691879007", "{d}", .{dd.timestamp()});

    // ============

    const ii_1: i64 = 1691879007;

    const time_0 = Time.fromTimestamp(ii_1).setLoc(GMT);
    try expectFmt(time_0, "YYYY-MM-DD HH:mm:ss z", "2023-08-12 22:23:27 GMT");

    const time_1 = Time.fromTimestamp(ii_1).setLoc(UTC);
    try expectFmt(time_1, "YYYY-MM-DD HH:mm:ss z", "2023-08-12 22:23:27 UTC");

    const time_2 = Time.fromTimestamp(ii_1).setLoc(CET);
    try expectFmt(time_2, "YYYY-MM-DD HH:mm:ss z", "2023-08-12 23:23:27 CET");

    const time_3 = Time.fromTimestamp(ii_1).setLoc(EET);
    try expectFmt(time_3, "YYYY-MM-DD HH:mm:ss z", "2023-08-13 00:23:27 EET");

    const time_4 = Time.fromTimestamp(ii_1).setLoc(MET);
    try expectFmt(time_4, "YYYY-MM-DD HH:mm:ss z", "2023-08-13 01:53:27 MET");

    const time_5 = Time.fromTimestamp(ii_1).setLoc(CTT);
    try expectFmt(time_5, "YYYY-MM-DD HH:mm:ss z", "2023-08-13 06:23:27 CTT");

    const time_6 = Time.fromTimestamp(ii_1).setLoc(CAT);
    try expectFmt(time_6, "YYYY-MM-DD HH:mm:ss z", "2023-08-12 21:23:27 CAT");

    const time_7 = Time.fromTimestamp(ii_1).setLoc(EST);
    try expectFmt(time_7, "YYYY-MM-DD HH:mm:ss z", "2023-08-12 17:23:27 EST");

    const time_8 = Time.fromTimestamp(ii_1).setLoc(CST);
    try expectFmt(time_8, "YYYY-MM-DD HH:mm:ss z", "2023-08-12 14:23:27 CST");

    const time_9 = Time.fromTimestamp(ii_1).setLoc(MST);
    try expectFmt(time_9, "YYYY-MM-DD HH:mm:ss z", "2023-08-12 15:23:27 MST");

    // ============

    const dd_0 = try Time.parse("YYYY-MM-DD HH:mm:ss z", "2023-08-12 22:23:27 GMT");
    try testing.expectFmt("1691879007", "{d}", .{dd_0.timestamp()});

    const dd_1 = try Time.parse("YYYY-MM-DD HH:mm:ss z", "2023-08-12 22:23:27 UTC");
    try testing.expectFmt("1691879007", "{d}", .{dd_1.timestamp()});

    const dd_2 = try Time.parse("YYYY-MM-DD HH:mm:ss z", "2023-08-12 23:23:27 CET");
    try testing.expectFmt("1691879007", "{d}", .{dd_2.timestamp()});

    const dd_3 = try Time.parse("YYYY-MM-DD HH:mm:ss z", "2023-08-13 00:23:27 EET");
    try testing.expectFmt("1691879007", "{d}", .{dd_3.timestamp()});

    const dd_4 = try Time.parse("YYYY-MM-DD HH:mm:ss z", "2023-08-13 01:53:27 MET");
    try testing.expectFmt("1691879007", "{d}", .{dd_4.timestamp()});

    const dd_5 = try Time.parse("YYYY-MM-DD HH:mm:ss z", "2023-08-13 06:23:27 CTT");
    try testing.expectFmt("1691879007", "{d}", .{dd_5.timestamp()});

    const dd_6 = try Time.parse("YYYY-MM-DD HH:mm:ss z", "2023-08-12 21:23:27 CAT");
    try testing.expectFmt("1691879007", "{d}", .{dd_6.timestamp()});

    const dd_7 = try Time.parse("YYYY-MM-DD HH:mm:ss z", "2023-08-12 17:23:27 EST");
    try testing.expectFmt("1691879007", "{d}", .{dd_7.timestamp()});

    const dd_8 = try Time.parse("YYYY-MM-DD HH:mm:ss z", "2023-08-12 14:23:27 CST");
    try testing.expectFmt("1691879007", "{d}", .{dd_8.timestamp()});

    const dd_9 = try Time.parse("YYYY-MM-DD HH:mm:ss z", "2023-08-12 15:23:27 MST");
    try testing.expectFmt("1691879007", "{d}", .{dd_9.timestamp()});

    // ============

    const time_10 = Time.fromTimestamp(ii_1).setLoc(MST);
    try expectFmt(time_10, "YYYY-Mo-Do hh:m:s a z", "2023-8th-12th 03:23:27 pm MST");

    const dd_10 = try Time.parse("YYYY-Mo-Do hh:m:s a z", "2023-8th-12th 03:23:27 pm MST");
    try testing.expectFmt("1691879007", "{d}", .{dd_10.timestamp()});

    // ============

    const time_11 = Time.fromTimestamp(ii_1).setLoc(MST);
    try expectFmt(time_11, "Y-Mo-Do hh:m:s a z", "12023-8th-12th 03:23:27 pm MST");

    const dd_11 = try Time.parse("Y-Mo-Do hh:m:s a z", "12023-8th-12th 03:23:27 pm MST");
    try testing.expectFmt("1691879007", "{d}", .{dd_11.timestamp()});

    // ============

    const time_12 = Time.fromTimestamp(ii_1).setLoc(MST);
    try expectFmt(time_12, "YYYY-MMM-Do hh:m:s a z", "2023-Aug-12th 03:23:27 pm MST");

    const dd_12 = try Time.parse("YYYY-MMM-Do hh:m:s a z", "2023-Aug-12th 03:23:27 pm MST");
    try testing.expectFmt("1691879007", "{d}", .{dd_12.timestamp()});

    // ============

    const time_13 = Time.fromTimestamp(ii_1).setLoc(MST);
    try expectFmt(time_13, "YYYY-MMMM-Do hh:m:s a z", "2023-August-12th 03:23:27 pm MST");

    const dd_13 = try Time.parse("YYYY-MMMM-Do hh:m:s a z", "2023-August-12th 03:23:27 pm MST");
    try testing.expectFmt("1691879007", "{d}", .{dd_13.timestamp()});

    // ============

    const time_2_1 = Time.fromTimestamp(ii_1).setLoc(Location.fixed(480));
    try expectFmt(time_2_1, "YYYY-MM-DD HH:mm:ss Z", "2023-08-13 06:23:27 +08:00");

    const dd_2_1 = try Time.parse("YYYY-MM-DD HH:mm:ss Z", "2023-08-13 06:23:27 +08:00");
    try testing.expectFmt("1691879007", "{d}", .{dd_2_1.timestamp()});

    // ============

    const time_2_2 = Time.fromTimestamp(ii_1).setLoc(Location.fixed(-480));
    try expectFmt(time_2_2, "YYYY-MM-DD HH:mm:ss Z", "2023-08-12 14:23:27 -08:00");

    const dd_2_2 = try Time.parse("YYYY-MM-DD HH:mm:ss Z", "2023-08-12 14:23:27 -08:00");
    try testing.expectFmt("1691879007", "{d}", .{dd_2_2.timestamp()});

    // ============

    const time_2_3 = Time.fromTimestamp(ii_1).setLoc(Location.fixed(210));
    try expectFmt(time_2_3, "YYYY-MM-DD HH:mm:ss Z", "2023-08-13 01:53:27 +03:30");

    const dd_2_3 = try Time.parse("YYYY-MM-DD HH:mm:ss Z", "2023-08-13 01:53:27 +03:30");
    try testing.expectFmt("1691879007", "{d}", .{dd_2_3.timestamp()});

    // ============

    const time_3_1 = Time.fromTimestamp(ii_1).setLoc(Location.fixed(480));
    try expectFmt(time_3_1, "YYYY-MM-DD HH:mm:ss ZZ", "2023-08-13 06:23:27 +0800");

    const dd_3_1 = try Time.parse("YYYY-MM-DD HH:mm:ss ZZ", "2023-08-13 06:23:27 +0800");
    try testing.expectFmt("1691879007", "{d}", .{dd_3_1.timestamp()});

    // ============

    const time_3_2 = Time.fromTimestamp(ii_1).setLoc(Location.fixed(-480));
    try expectFmt(time_3_2, "YYYY-MM-DD HH:mm:ss ZZ", "2023-08-12 14:23:27 -0800");

    const dd_3_2 = try Time.parse("YYYY-MM-DD HH:mm:ss ZZ", "2023-08-12 14:23:27 -0800");
    try testing.expectFmt("1691879007", "{d}", .{dd_3_2.timestamp()});

    // ============

    const time_3_3 = Time.fromTimestamp(ii_1).setLoc(Location.fixed(210));
    try expectFmt(time_3_3, "YYYY-MM-DD HH:mm:ss ZZ", "2023-08-13 01:53:27 +0330");

    const dd_3_3 = try Time.parse("YYYY-MM-DD HH:mm:ss ZZ", "2023-08-13 01:53:27 +0330");
    try testing.expectFmt("1691879007", "{d}", .{dd_3_3.timestamp()});

    // ============

    const time_3_5 = Time.fromTimestamp(20000000000).utc();
    try expectFmt(time_3_5, "YYYY-MM-DD HH:mm:ss ZZ", "2603-10-11 11:33:20 +0000");

    // ============

    var time_unix = unix(1691879007, 16918790).utc();
    try expectFmt(time_unix, "YYYY-MM-DD HH:mm:ss.SSS ZZ", "2023-08-12 22:23:27.016 +0000");

    time_unix = unix(1691879007, 16918790000).utc();
    try expectFmt(time_unix, "YYYY-MM-DD HH:mm:ss.SSS ZZ", "2023-08-12 22:23:43.918 +0000");

    time_unix = unix(1691879007, 16918790112).utc();
    try expectFmt(time_unix, "YYYY-MM-DD HH:mm:ss.SSS ZZ", "2023-08-12 22:23:43.918 +0000");

    time_unix = unix(1691879007, 0).utc();
    try expectFmt(time_unix, "YYYY-MM-DD HH:mm:ss.SSS ZZ", "2023-08-12 22:23:27.000 +0000");

    const time_3_6 = Time.fromUnix(1691879007, 16918790).utc();
    try expectFmt(time_3_6, "YYYY-MM-DD HH:mm:ss.SSS ZZ", "2023-08-12 22:23:27.016 +0000");
    try expectFmt(time_3_6, "YYYY-MM-DD HH:mm:ss.S", "2023-08-12 22:23:27.0");
    try expectFmt(time_3_6, "YYYY-MM-DD HH:mm:ss.SS", "2023-08-12 22:23:27.01");
    try expectFmt(time_3_6, "YYYY-MM-DD HH:mm:ss.SSS", "2023-08-12 22:23:27.016");
    try expectFmt(time_3_6, "YYYY-MM-DD HH:mm:ss.SSSS", "2023-08-12 22:23:27.0169");
    try expectFmt(time_3_6, "YYYY-MM-DD HH:mm:ss.SSSSSS", "2023-08-12 22:23:27.016918");
    try expectFmt(time_3_6, "YYYY-MM-DD HH:mm:ss.SSSSSSS", "2023-08-12 22:23:27.0169187");
    try expectFmt(time_3_6, "YYYY-MM-DD HH:mm:ss.SSSSSSSS", "2023-08-12 22:23:27.01691879");
    try expectFmt(time_3_6, "YYYY-MM-DD HH:mm:ss.SSSSSSSSS", "2023-08-12 22:23:27.016918790");

    const time_3_61 = Time.fromUnix(1691879007, 16918790000).utc();
    try expectFmt(time_3_61, "YYYY-MM-DD HH:mm:ss.SSS ZZ", "2023-08-12 22:23:43.918 +0000");

    const time_3_62 = Time.fromUnix(1691879007, 16918790112).utc();
    try expectFmt(time_3_62, "YYYY-MM-DD HH:mm:ss.SSS ZZ", "2023-08-12 22:23:43.918 +0000");
    try expectFmt(time_3_62, "YYYY-MM-DD HH:mm:ss.SSSSSS", "2023-08-12 22:23:43.918790");
    try expectFmt(time_3_62, "YYYY-MM-DD HH:mm:ss.SSSSSSSSS", "2023-08-12 22:23:43.918790112");

    var dd22 = try Time.parse("YYYY-MM-DD HH:mm:ss.SSSSSSSSS", "2023-08-12 22:23:27.016918790");
    try testing.expectFmt("1691879007", "{d}", .{dd22.timestamp()});
    try testing.expectFmt("16918790", "{d}", .{dd22.nanosecond()});

    dd22 = try Time.parse("YYYY-MM-DD HH:mm:ss.SSSSSSSSS", "2023-08-12 22:23:27.918790112");
    try testing.expectFmt("1691879007", "{d}", .{dd22.timestamp()});
    try testing.expectFmt("918790112", "{d}", .{dd22.nanosecond()});

    dd22 = try Time.parse("YYYY-MM-DD HH:mm:ss.SSSSSSSS", "2023-08-12 22:23:27.91879011");
    try testing.expectFmt("91879011", "{d}", .{dd22.nanosecond()});
    dd22 = try Time.parse("YYYY-MM-DD HH:mm:ss.SSSSSSS", "2023-08-12 22:23:27.9187901");
    try testing.expectFmt("9187901", "{d}", .{dd22.nanosecond()});
    dd22 = try Time.parse("YYYY-MM-DD HH:mm:ss.SSSSSS", "2023-08-12 22:23:27.918790");
    try testing.expectFmt("918790", "{d}", .{dd22.nanosecond()});
    dd22 = try Time.parse("YYYY-MM-DD HH:mm:ss.SSSSS", "2023-08-12 22:23:27.91879");
    try testing.expectFmt("91879", "{d}", .{dd22.nanosecond()});
    dd22 = try Time.parse("YYYY-MM-DD HH:mm:ss.SSSS", "2023-08-12 22:23:27.9187");
    try testing.expectFmt("9187", "{d}", .{dd22.nanosecond()});
    dd22 = try Time.parse("YYYY-MM-DD HH:mm:ss.SSS", "2023-08-12 22:23:27.918");
    try testing.expectFmt("918", "{d}", .{dd22.nanosecond()});
    dd22 = try Time.parse("YYYY-MM-DD HH:mm:ss.SS", "2023-08-12 22:23:27.91");
    try testing.expectFmt("91", "{d}", .{dd22.nanosecond()});
    dd22 = try Time.parse("YYYY-MM-DD HH:mm:ss.S", "2023-08-12 22:23:27.9");
    try testing.expectFmt("9", "{d}", .{dd22.nanosecond()});
}

test "getNumFromOrdinal" {
    const val_1 = "1st dfg";
    const val_2 = "2nd tyuij";
    const val_3 = "3rd dfgd";
    const val_4 = "13th njm";
    const val_5 = "55th qqa";

    const num_1 = try getNumFromOrdinal(val_1);
    try testing.expectFmt("1", "{d}", .{num_1.value});
    try testing.expectFmt(" dfg", "{s}", .{num_1.string});

    const num_2 = try getNumFromOrdinal(val_2);
    try testing.expectFmt("2", "{d}", .{num_2.value});
    try testing.expectFmt(" tyuij", "{s}", .{num_2.string});

    const num_3 = try getNumFromOrdinal(val_3);
    try testing.expectFmt("3", "{d}", .{num_3.value});
    try testing.expectFmt(" dfgd", "{s}", .{num_3.string});

    const num_4 = try getNumFromOrdinal(val_4);
    try testing.expectFmt("13", "{d}", .{num_4.value});
    try testing.expectFmt(" njm", "{s}", .{num_4.string});

    const num_5 = try getNumFromOrdinal(val_5);
    try testing.expectFmt("55", "{d}", .{num_5.value});
    try testing.expectFmt(" qqa", "{s}", .{num_5.string});
}

test "Location parse" {
    const alloc = testing.allocator;

    const val_1 = "+0800";
    const val_2 = "-0930";

    const val_3 = "+0930 tyr";
    const val_4 = "-09302sry";
    const val_5 = "0930";

    const t_1 = try Location.parse(val_1);
    try testing.expectFmt("28800", "{d}", .{t_1.offset});

    const loc1 = try t_1.stringAlloc(alloc);
    defer alloc.free(loc1);
    try testing.expectFmt("+0800", "{s}", .{loc1});

    const os1 = try t_1.offsetFormatStringAlloc(alloc);
    defer alloc.free(os1);
    try testing.expectFmt("+08:00", "{s}", .{os1});

    const t_2 = try Location.parse(val_2);
    try testing.expectFmt("-34200", "{d}", .{t_2.offset});

    const loc2 = try t_2.stringAlloc(alloc);
    defer alloc.free(loc2);
    try testing.expectFmt("-0930", "{s}", .{loc2});

    const os2 = try t_2.offsetFormatStringAlloc(alloc);
    defer alloc.free(os2);
    try testing.expectFmt("-09:30", "{s}", .{os2});

    const num_3 = try parseTimezone(val_3);
    try testing.expectFmt("570", "{d}", .{num_3.value});
    try testing.expectFmt(" tyr", "{s}", .{num_3.string});

    const num_4 = try parseTimezone(val_4);
    try testing.expectFmt("-570", "{d}", .{num_4.value});
    try testing.expectFmt("2sry", "{s}", .{num_4.string});

    if (parseTimezone(val_5)) |_| {
        const data = "";
        try testing.expectFmt("error", "{s}", .{data});
    } else |_| {
        // todo
    }
}

test "switch" {
    const d = "test1";

    const res = switch (true) {
        equal(d, "test1") => true,
        else => false,
    };

    try testing.expect(res);
}

test "compare all" {
    const t_0 = Time.fromTimestamp(1330502962);
    const t_1 = Time.fromTimestamp(1330502962);
    const t_2 = Time.fromTimestamp(1330503962);
    const t_3 = Time.fromTimestamp(1330515962);

    try testing.expect(t_2.gt(t_0));
    try testing.expect(t_1.lt(t_2));
    try testing.expect(t_0.eq(t_1));
    try testing.expect(t_0.ne(t_2));

    try testing.expect(t_2.gte(t_0));
    try testing.expect(t_0.gte(t_1));

    try testing.expect(t_1.lte(t_2));
    try testing.expect(t_0.lte(t_1));

    try testing.expect(t_2.between(t_1, t_3));
    try testing.expect(!t_1.between(t_2, t_3));

    try testing.expect(t_2.betweenIncluded(t_1, t_3));
    try testing.expect(t_0.betweenIncluded(t_1, t_3));
    try testing.expect(t_3.betweenIncluded(t_1, t_3));
    try testing.expect(!t_1.betweenIncluded(t_2, t_3));

    try testing.expect(t_2.betweenIncludedStart(t_1, t_3));
    try testing.expect(t_1.betweenIncludedStart(t_1, t_3));
    try testing.expect(!t_3.betweenIncludedStart(t_1, t_3));

    try testing.expect(t_2.betweenIncludedEnd(t_1, t_3));
    try testing.expect(t_3.betweenIncludedEnd(t_1, t_3));
    try testing.expect(!t_1.betweenIncludedEnd(t_1, t_3));
}
