const std = @import("std");

pub const default_limit: u8 = 100;

pub fn normalizeLimit(limit: u8) u8 {
    return if (limit == 0) default_limit else limit;
}

/// Runs at most `limit` jobs at once, including the caller's worker. A job
/// owns its slot until all its requests, signatures and retries have finished.
/// Workers are joined before returning, even after failure or cancellation.
pub fn run(
    io: std.Io,
    limit: u8,
    count: usize,
    context: anytype,
    comptime execute: anytype,
) error{ DownloadFailed, Cancelled }!void {
    if (count == 0) return;
    const Queue = struct {
        context: @TypeOf(context),
        count: usize,
        next: std.atomic.Value(usize) = .init(0),
        failed: std.atomic.Value(bool) = .init(false),
        cancelled: std.atomic.Value(bool) = .init(false),

        fn worker(self: *@This()) void {
            while (!self.cancelled.load(.acquire)) {
                const index = self.next.fetchAdd(1, .monotonic);
                if (index >= self.count) return;
                execute(self.context, index) catch |err| {
                    if (err == error.Cancelled) {
                        self.cancelled.store(true, .release);
                        return;
                    }
                    self.failed.store(true, .release);
                };
            }
        }
    };
    var queue: Queue = .{ .context = context, .count = count };
    const workers = @min(@as(usize, normalizeLimit(limit)), count);
    var futures: [std.math.maxInt(u8) - 1]std.Io.Future(void) = undefined;
    var spawned: usize = 0;
    while (spawned < workers - 1) : (spawned += 1) {
        // Resource exhaustion reduces concurrency. The caller still drains
        // the queue without introducing an extra job outside the limit.
        futures[spawned] = io.concurrent(Queue.worker, .{&queue}) catch break;
    }
    queue.worker();
    for (futures[0..spawned]) |*future| future.await(io);
    if (queue.cancelled.load(.acquire)) return error.Cancelled;
    if (queue.failed.load(.acquire)) return error.DownloadFailed;
}

const TestJobs = struct {
    io: std.Io,
    active: std.atomic.Value(usize) = .init(0),
    peak: std.atomic.Value(usize) = .init(0),
    completed: std.atomic.Value(usize) = .init(0),
    seen: [12]std.atomic.Value(usize) = @splat(.init(0)),
    started: std.Io.Semaphore = .{},
    release: std.Io.Event = .unset,
    failure: ?usize = null,
    cancellation: ?usize = null,

    fn execute(self: *TestJobs, index: usize) !void {
        _ = self.seen[index].fetchAdd(1, .monotonic);
        const active = self.active.fetchAdd(1, .monotonic) + 1;
        _ = self.peak.fetchMax(active, .monotonic);
        defer _ = self.active.fetchSub(1, .monotonic);
        defer _ = self.completed.fetchAdd(1, .monotonic);
        self.started.post(self.io);
        try self.release.wait(self.io);
        if (self.cancellation == index) return error.Cancelled;
        if (self.failure == index) return error.TestDownloadFailed;
    }

    fn runBatch(self: *TestJobs, limit: u8, count: usize) !void {
        try run(self.io, limit, count, self, execute);
    }
};

test "download queue bounds active jobs and drains every job once" {
    for ([_]u8{ 1, 3, 100 }) |limit| {
        const io = std.testing.io;
        var jobs: TestJobs = .{ .io = io };
        var future = try io.concurrent(TestJobs.runBatch, .{ &jobs, limit, jobs.seen.len });
        defer {
            jobs.release.set(io);
            _ = future.cancel(io) catch {};
        }
        const expected = @min(limit, jobs.seen.len);
        for (0..expected) |_| try jobs.started.wait(io);
        jobs.release.set(io);
        try future.await(io);
        try std.testing.expectEqual(expected, jobs.peak.load(.acquire));
        try std.testing.expectEqual(jobs.seen.len, jobs.completed.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), jobs.active.load(.acquire));
        for (&jobs.seen) |*seen| try std.testing.expectEqual(@as(usize, 1), seen.load(.acquire));
    }
}

test "download queue joins workers after failures" {
    var jobs: TestJobs = .{ .io = std.testing.io, .failure = 0, .release = .is_set };
    try std.testing.expectError(error.DownloadFailed, jobs.runBatch(3, jobs.seen.len));
    try std.testing.expectEqual(jobs.seen.len, jobs.completed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), jobs.active.load(.acquire));
}

test "download queue stops queued work after cancellation" {
    var jobs: TestJobs = .{ .io = std.testing.io, .cancellation = 0, .release = .is_set };
    try std.testing.expectError(error.Cancelled, jobs.runBatch(1, jobs.seen.len));
    try std.testing.expectEqual(@as(usize, 1), jobs.completed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), jobs.active.load(.acquire));
}

test "download queue falls back to caller when concurrency is unavailable" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .nothing });
    defer threaded.deinit();
    var jobs: TestJobs = .{ .io = threaded.io(), .release = .is_set };
    try jobs.runBatch(3, jobs.seen.len);
    try std.testing.expectEqual(@as(usize, 1), jobs.peak.load(.acquire));
    try std.testing.expectEqual(jobs.seen.len, jobs.completed.load(.acquire));
}

test "download queue accepts empty work and normalizes zero" {
    var jobs: TestJobs = .{ .io = std.testing.io, .release = .is_set };
    try jobs.runBatch(1, 0);
    try std.testing.expectEqual(@as(usize, 0), jobs.completed.load(.acquire));
    try std.testing.expectEqual(default_limit, normalizeLimit(0));
    try jobs.runBatch(0, jobs.seen.len);
    try std.testing.expectEqual(jobs.seen.len, jobs.completed.load(.acquire));
}
