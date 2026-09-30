//! Loopback server for queue overlap, callback timing, and cancellation tests.
const std = @import("std");

const io = std.testing.io;

server: std.Io.net.Server,
body: []const u8,
expected_path: ?[]const u8 = null,
active: std.atomic.Value(usize) = .init(0),
peak: std.atomic.Value(usize) = .init(0),
requests: std.atomic.Value(usize) = .init(0),
signatures: std.atomic.Value(usize) = .init(0),
gate_slow: bool = false,
unknown_length: bool = false,
fast_reported: std.atomic.Value(bool) = .init(false),
timed_out: std.atomic.Value(bool) = .init(false),
failed: std.atomic.Value(bool) = .init(false),

pub fn serve(self: *@This()) !void {
    var handlers: std.Io.Group = .init;
    defer handlers.cancel(io);
    while (true) {
        const stream = try self.server.accept(io);
        handlers.concurrent(io, respond, .{ self, stream }) catch |err| {
            stream.close(io);
            return err;
        };
    }
}

fn respond(self: *@This(), stream: std.Io.net.Stream) void {
    defer stream.close(io);
    self.respondInner(stream) catch |err| {
        if (err != error.Canceled) self.failed.store(true, .release);
    };
}

fn respondInner(self: *@This(), stream: std.Io.net.Stream) !void {
    var read_buffer: [2048]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    const line = try reader.interface.takeDelimiter('\n') orelse return error.EndOfStream;
    var parts = std.mem.tokenizeScalar(u8, line, ' ');
    _ = parts.next();
    const path = parts.next() orelse return error.InvalidRequest;
    const signature = std.mem.endsWith(u8, path, ".sig");
    const expected_path = if (self.expected_path) |expected|
        std.mem.eql(u8, if (signature) path[0 .. path.len - 4] else path, expected)
    else
        true;
    if (!expected_path) self.failed.store(true, .release);
    const missing = !expected_path or std.mem.startsWith(u8, path, "/missing/");
    const slow = std.mem.indexOf(u8, path, "/slow.") != null;
    while (try reader.interface.takeDelimiter('\n')) |header| {
        if (std.mem.eql(u8, header, "\r")) break;
    } else return error.EndOfStream;
    _ = self.requests.fetchAdd(1, .monotonic);
    if (signature) _ = self.signatures.fetchAdd(1, .monotonic);
    const active = self.active.fetchAdd(1, .acq_rel) + 1;
    _ = self.peak.fetchMax(active, .monotonic);
    {
        defer _ = self.active.fetchSub(1, .acq_rel);
        if (self.gate_slow and slow and !signature) {
            // A regression that defers callbacks until join must fail in
            // bounded time, rather than deadlock the fixture's server.
            const start = std.Io.Clock.awake.now(io);
            while (!self.fast_reported.load(.acquire)) {
                if (start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 3000) {
                    self.timed_out.store(true, .release);
                    break;
                }
                try io.sleep(.fromMilliseconds(5), .awake);
            }
        } else try io.sleep(.fromMilliseconds(30), .awake);
    }
    var write_buffer: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    if (missing or signature) {
        try writer.interface.writeAll(
            "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        );
    } else {
        if (self.unknown_length) {
            try writer.interface.writeAll("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n");
        } else try writer.interface.print(
            "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{self.body.len},
        );
        try writer.interface.writeAll(self.body);
    }
    try writer.interface.flush();
}
