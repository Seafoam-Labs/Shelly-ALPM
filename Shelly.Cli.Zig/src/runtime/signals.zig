const std = @import("std");
const builtin = @import("builtin");
const Zigalpm = @import("Zigalpm");

var received_signal = std.atomic.Value(u8).init(0);
var received_signal_count = std.atomic.Value(u8).init(0);
var graceful_cancellation = std.atomic.Value(bool).init(false);

pub fn installInterruptHandler(graceful: bool) void {
    if (builtin.os.tag != .linux) return;
    received_signal.store(0, .release);
    received_signal_count.store(0, .release);
    graceful_cancellation.store(graceful, .release);
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = handleInterrupt },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
}

fn handleInterrupt(signal: std.posix.SIG) callconv(.c) void {
    received_signal.store(@intCast(@intFromEnum(signal)), .release);
    _ = received_signal_count.fetchAdd(1, .acq_rel);
    if (!graceful_cancellation.load(.acquire)) {
        const message = "\nOperation cancelled.\n";
        _ = std.os.linux.write(std.posix.STDERR_FILENO, message.ptr, message.len);
        std.os.linux.exit_group(130);
    }
}

pub fn wasInterrupted() bool {
    return received_signal.load(.acquire) != 0;
}

pub fn receivedSignal() ?std.posix.SIG {
    const value = received_signal.load(.acquire);
    return if (value == 0) null else @enumFromInt(value);
}

pub fn interruptionCount() u8 {
    return received_signal_count.load(.acquire);
}

pub fn argumentsRequestGracefulCancellation(arguments: []const []const u8) bool {
    const long_form_build = argumentsSelectLongFormBuild(arguments);
    for (arguments, 0..) |argument, index| {
        if (std.mem.eql(u8, argument, "--isolated") or
            (long_form_build and std.mem.eql(u8, argument, "-i")))
        {
            if (index + 1 >= arguments.len or !isBooleanValue(arguments[index + 1])) return true;
            if (std.ascii.eqlIgnoreCase(arguments[index + 1], "true")) return true;
        }
        if (std.ascii.eqlIgnoreCase(argument, "--isolated=true")) return true;
        // Signal setup precedes shortcode translation. The standalone build
        // shortcode is `-A`, with local option aliases appended as modifier
        // bytes, so recognize its isolated `i` modifier here without treating
        // another command's unrelated `-i` option as an isolated build.
        if (argument.len > 2 and argument[0] == '-' and argument[1] == 'A' and
            std.mem.indexOfScalar(u8, argument[2..], 'i') != null)
        {
            if (index + 1 >= arguments.len or !isBooleanValue(arguments[index + 1])) return true;
            if (std.ascii.eqlIgnoreCase(arguments[index + 1], "true")) return true;
        }
    }
    return false;
}

fn argumentsSelectLongFormBuild(arguments: []const []const u8) bool {
    var index: usize = 0;
    while (index < arguments.len) {
        const argument = arguments[index];
        if (std.mem.eql(u8, argument, "--aur-url")) {
            index += 2;
            continue;
        }
        if (std.mem.startsWith(u8, argument, "--aur-url=")) {
            index += 1;
            continue;
        }
        if (isGlobalBooleanOption(argument)) {
            index += 1;
            if (index < arguments.len and isBooleanValue(arguments[index])) index += 1;
            continue;
        }
        if (isAssignedGlobalBooleanOption(argument)) {
            index += 1;
            continue;
        }
        return std.mem.eql(u8, argument, "build");
    }
    return false;
}

fn isGlobalBooleanOption(argument: []const u8) bool {
    return std.mem.eql(u8, argument, "--json") or
        std.mem.eql(u8, argument, "-j") or
        std.mem.eql(u8, argument, "--no-confirm") or
        std.mem.eql(u8, argument, "-n") or
        std.mem.eql(u8, argument, "--ui-mode") or
        std.mem.eql(u8, argument, "-U") or
        std.mem.eql(u8, argument, "--auto-confirm-cache-clean") or
        std.mem.eql(u8, argument, "--disable-cache-clean");
}

fn isAssignedGlobalBooleanOption(argument: []const u8) bool {
    return std.mem.startsWith(u8, argument, "--json=") or
        std.mem.startsWith(u8, argument, "-j=") or
        std.mem.startsWith(u8, argument, "--no-confirm=") or
        std.mem.startsWith(u8, argument, "-n=") or
        std.mem.startsWith(u8, argument, "--ui-mode=") or
        std.mem.startsWith(u8, argument, "-U=") or
        std.mem.startsWith(u8, argument, "--auto-confirm-cache-clean=") or
        std.mem.startsWith(u8, argument, "--disable-cache-clean=");
}

fn isBooleanValue(argument: []const u8) bool {
    return std.ascii.eqlIgnoreCase(argument, "true") or
        std.ascii.eqlIgnoreCase(argument, "false");
}

/// Bridges the async-signal-safe flag into the ordinary cancellation API.
/// The watcher runs in normal execution context, where OperationContext is
/// allowed to allocate, lock, and invoke cancellation subscribers.
pub const CancellationWatcher = struct {
    io: std.Io = undefined,
    operation_context: *Zigalpm.OperationContext = undefined,
    stopped: std.atomic.Value(bool) = .init(false),
    future: ?std.Io.Future(void) = null,

    pub fn start(
        self: *CancellationWatcher,
        io: std.Io,
        operation_context: *Zigalpm.OperationContext,
    ) !void {
        self.io = io;
        self.operation_context = operation_context;
        self.stopped.store(false, .release);
        if (wasInterrupted()) operation_context.cancel();
        self.future = try io.concurrent(watch, .{self});
    }

    pub fn deinit(self: *CancellationWatcher) void {
        self.stopped.store(true, .release);
        if (self.future) |*future| future.await(self.io);
        self.future = null;
    }

    fn watch(self: *CancellationWatcher) void {
        while (!self.stopped.load(.acquire)) {
            if (wasInterrupted()) {
                self.operation_context.cancel();
                return;
            }
            self.io.sleep(.fromMilliseconds(25), .awake) catch return;
        }
    }
};

test "signal handler records cancellation without exiting or writing" {
    received_signal.store(0, .release);
    received_signal_count.store(0, .release);
    defer received_signal.store(0, .release);
    defer received_signal_count.store(0, .release);
    graceful_cancellation.store(true, .release);
    defer graceful_cancellation.store(false, .release);
    handleInterrupt(.TERM);
    try std.testing.expect(wasInterrupted());
    try std.testing.expectEqual(std.posix.SIG.TERM, receivedSignal().?);
    try std.testing.expectEqual(@as(u8, 1), interruptionCount());
}

test "cancellation watcher translates a signal into OperationContext cancellation" {
    received_signal.store(0, .release);
    received_signal_count.store(0, .release);
    defer received_signal.store(0, .release);
    defer received_signal_count.store(0, .release);
    graceful_cancellation.store(true, .release);
    defer graceful_cancellation.store(false, .release);

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var operation_context = Zigalpm.OperationContext.init(std.testing.allocator, io);
    defer operation_context.deinit();
    var watcher: CancellationWatcher = .{};
    try watcher.start(io, &operation_context);
    defer watcher.deinit();

    handleInterrupt(.INT);
    var attempts: usize = 0;
    while (!operation_context.isCancelled() and attempts < 50) : (attempts += 1)
        io.sleep(.fromMilliseconds(5), .awake) catch break;
    try std.testing.expect(operation_context.isCancelled());
}

test "all public isolated spellings request graceful cancellation" {
    try std.testing.expect(argumentsRequestGracefulCancellation(&.{ "build", "--isolated" }));
    try std.testing.expect(argumentsRequestGracefulCancellation(&.{ "build", "--isolated=true" }));
    try std.testing.expect(argumentsRequestGracefulCancellation(&.{ "build", "--isolated", "true" }));
    try std.testing.expect(argumentsRequestGracefulCancellation(&.{ "build", "-i" }));
    try std.testing.expect(argumentsRequestGracefulCancellation(&.{ "--json", "build", "-i" }));
    try std.testing.expect(argumentsRequestGracefulCancellation(&.{ "--disable-cache-clean", "build", "-i" }));
    try std.testing.expect(argumentsRequestGracefulCancellation(&.{ "--disable-cache-clean=false", "build", "-i" }));
    try std.testing.expect(argumentsRequestGracefulCancellation(&.{ "--json", "true", "--aur-url", "https://aur.example", "build", "-i" }));
    try std.testing.expect(argumentsRequestGracefulCancellation(&.{"-Ai"}));
    try std.testing.expect(argumentsRequestGracefulCancellation(&.{ "-Air", "PKGBUILD" }));
    try std.testing.expect(!argumentsRequestGracefulCancellation(&.{ "build", "--isolated=false" }));
    try std.testing.expect(!argumentsRequestGracefulCancellation(&.{ "build", "--isolated", "false" }));
    try std.testing.expect(!argumentsRequestGracefulCancellation(&.{ "build", "-i", "false" }));
    try std.testing.expect(!argumentsRequestGracefulCancellation(&.{ "-Ai", "false" }));
    try std.testing.expect(!argumentsRequestGracefulCancellation(&.{"-A"}));
    try std.testing.expect(!argumentsRequestGracefulCancellation(&.{ "search", "-i" }));
    try std.testing.expect(!argumentsRequestGracefulCancellation(&.{"build"}));
}
