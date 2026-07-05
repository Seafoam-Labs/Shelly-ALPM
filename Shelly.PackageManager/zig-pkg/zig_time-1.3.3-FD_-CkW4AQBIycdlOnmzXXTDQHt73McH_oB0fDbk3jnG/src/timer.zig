const std = @import("std");
const Io = std.Io;
const math = std.math;
const time = std.time;
const testing = std.testing;

/// An Instant represents a timestamp with respect to the currently
/// executing program that ticks during suspend and can be used to
/// record elapsed time unlike `nanoTimestamp`.
///
/// It tries to sample the system's fastest and most precise timer available.
/// It also tries to be monotonic, but this is not a guarantee due to OS/hardware bugs.
/// If you need monotonic readings for elapsed time, consider `Timer` instead.
pub const Instant = struct {
    timestamp: i96,

    pub fn now(io: Io) !Instant {
        const ts = Io.Timestamp.now(io, .real).toNanoseconds();
        return .{ .timestamp = ts };
    }

    /// Quickly compares two instances between each other.
    pub fn order(self: Instant, other: Instant) std.math.Order {
        const ord = std.math.order(self.timestamp, other.timestamp);
        return ord;
    }

    /// Returns elapsed time in nanoseconds since the `earlier` Instant.
    pub fn since(self: Instant, earlier: Instant) i96 {
        return self.timestamp - earlier.timestamp;
    }
};

/// A monotonic, high performance timer.
///
/// Timer.start() is used to initialize the timer
/// and gives the caller an opportunity to check for the existence of a supported clock.
/// Once a supported clock is discovered,
/// it is assumed that it will be available for the duration of the Timer's use.
///
/// Monotonicity is ensured by saturating on the most previous sample.
/// This means that while timings reported are monotonic,
/// they're not guaranteed to tick at a steady rate as this is up to the underlying system.
pub const Timer = struct {
    started: Instant,
    previous: Instant,

    pub const Error = error{TimerUnsupported};

    /// Initialize the timer by querying for a supported clock.
    /// Returns `error.TimerUnsupported` when such a clock is unavailable.
    /// This should only fail in hostile environments such as linux seccomp misuse.
    pub fn start(io: Io) Error!Timer {
        const current = Instant.now(io) catch return error.TimerUnsupported;
        return Timer{ .started = current, .previous = current };
    }

    /// Reads the timer value since start or the last reset in nanoseconds.
    pub fn read(self: *Timer, io: Io) i96 {
        const current = self.sample(io);
        return current.since(self.started);
    }

    /// Resets the timer value to 0/now.
    pub fn reset(self: *Timer, io: Io) void {
        const current = self.sample(io);
        self.started = current;
    }

    /// Returns the current value of the timer in nanoseconds, then resets it.
    pub fn lap(self: *Timer, io: Io) i96 {
        const current = self.sample(io);
        defer self.started = current;
        return current.since(self.started);
    }

    /// Returns an Instant sampled at the callsite that is
    /// guaranteed to be monotonic with respect to the timer's starting point.
    fn sample(self: *Timer, io: Io) Instant {
        const current = Instant.now(io) catch unreachable;
        if (current.order(self.previous) == .gt) {
            self.previous = current;
        }
        return self.previous;
    }
};

test Timer {
    const io = testing.io;

    var timer = try Timer.start(io);

    try Io.sleep(io, .fromNanoseconds(10 * time.ns_per_ms), .awake);
    const time_0 = timer.read(io);
    try testing.expect(time_0 > 0);

    const time_1 = timer.lap(io);
    try testing.expect(time_1 >= time_0);
}
