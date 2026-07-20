const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const glib = bindings.glib;
const JsonPackFrame = @import("../helpers/ui_decode.zig").JsonPackFrame;
const builtin = @import("builtin");

pub const Event = union(enum) {
    info: struct {
        event_type: []const u8,
        message: []const u8,
        current: ?i64,
        total: ?i64,
    },
    err: struct {
        message: []const u8,
    },
    //stub of others for now
    unknown: void,
};

const AlpmInfo = struct {
    @"$kind": []const u8 = "",
    EventType: []const u8 = "",
    Message: []const u8 = "",
    PackageName: ?[]const u8 = null,
    CurrentIndex: ?i64 = null,
    TotalCount: ?i64 = null,
};

const AlpmError = struct {
    @"$kind": []const u8 = "",
    ErrorMessage: []const u8 = "",
};

const Envelope = struct {
    @"$kind": []const u8 = "",
};

pub const ShellyOperation = struct {
    allocator: std.mem.Allocator,
    threaded: std.Io.Threaded,
    io: std.Io,
    child: std.process.Child,

    reader: ?std.Thread = null,

    on_event: *const fn (ctx: *anyopaque, event: Event) void,
    ctx: *anyopaque,
    on_done: *const fn (ctx: *anyopaque, exit_code: u8) void,

    pub fn init(allocator: std.mem.Allocator, on_event: *const fn (ctx: *anyopaque, event: Event) void, on_done: *const fn (ctx: *anyopaque, exit_code: u8) void, ctx: *anyopaque) ShellyOperation {
        return .{
            .allocator = allocator,
            .threaded = std.Io.Threaded.init(allocator, .{}),
            .io = undefined,
            .child = undefined,
            .on_event = on_event,
            .on_done = on_done,
            .ctx = ctx,
        };
    }

    pub fn install(self: *ShellyOperation, names: []const []const u8) !void {
        const shelly_bin = if (builtin.mode == .Debug)
            "../Shelly.Cli.Zig/zig-out/bin/shelly"
        else
            "shelly";

        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        try argv.append(self.allocator, shelly_bin);
        try argv.append(self.allocator, "-Is");
        for (names) |n| try argv.append(self.allocator, n);
        try argv.append(self.allocator, "--ui-mode");
        try self.startPrivileged(argv.items);
    }

    fn start(self: *ShellyOperation, argv: []const []const u8) !void {
        try self.spawn_and_read(argv);
    }

    fn startPrivileged(self: *ShellyOperation, argv: []const []const u8) !void {
        var full = try self.allocator.alloc([]const u8, argv.len + 1);
        defer self.allocator.free(full);
        full[0] = "pkexec";
        @memcpy(full[1..], argv);
        try self.spawn_and_read(full);
    }

    fn spawn_and_read(self: *ShellyOperation, argv: []const []const u8) !void {
        self.child = try std.process.spawn(self.io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        self.reader = try std.Thread.spawn(.{}, reader_loop, .{self});
    }

    pub fn answer(self: *ShellyOperation, response: []const u8) !void {
        const stdin = self.child.stdin orelse return error.NoStdin;
        try stdin.writeStreamingAll(self.io, response);
        try stdin.writeStreamingAll(self.io, "\n");
    }

    fn cancel(self: *ShellyOperation) void {
        self.child.kill(self.io);
    }

    fn reader_loop(self: *ShellyOperation) void {
        const stdout = self.child.stdout orelse return;

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);

        var read_buf: [8192]u8 = undefined;
        while (true) {
            const n = stdout.readStreaming(self.io, &.{&read_buf}) catch break;
            if (n == 0) break;

            buf.appendSlice(self.allocator, read_buf[0..n]) catch break;

            while (JsonPackFrame.nextFrame(buf.items)) |frame| {
                post_event(self, frame.payload);
                const remaining = buf.items.len - frame.consumed;
                std.mem.copyForwards(u8, buf.items[0..remaining], buf.items[frame.consumed..]);
                buf.shrinkRetainingCapacity(remaining);
            }
        }

        const term = self.child.wait(self.io) catch {
            post_done(self, 255);
            return;
        };
        const code: u8 = switch (term) {
            .exited => |c| @intCast(c),
            else => 255,
        };
        post_done(self, code);
    }

    fn post_event(self: *ShellyOperation, base64_payload: []const u8) void {
        const json = JsonPackFrame.decodeBase64(self.allocator, base64_payload) catch return;

        const msg = self.allocator.create(EventMsg) catch {
            self.allocator.free(json);
            return;
        };
        msg.* = .{ .op = self, .json = json };
        _ = glib.idleAdd(&onEventIdle, msg);
    }

    fn post_done(self: *ShellyOperation, exit_code: u8) void {
        const msg = self.allocator.create(DoneMsg) catch return;
        msg.* = .{ .op = self, .exit_code = exit_code };
        _ = glib.idleAdd(&onDoneIdle, msg);
    }
};

const EventMsg = struct { op: *ShellyOperation, json: []u8 };

const DoneMsg = struct { op: *ShellyOperation, exit_code: u8 };

fn onEventIdle(data: ?*anyopaque) callconv(.c) c_int {
    const msg: *EventMsg = @ptrCast(@alignCast(data.?));
    defer {
        msg.op.allocator.free(msg.json);
        msg.op.allocator.destroy(msg);
    }

    const op = msg.op;
    const alloc = op.allocator;

    const env = std.json.parseFromSlice(Envelope, alloc, msg.json, .{ .ignore_unknown_fields = true }) catch return 0;
    defer env.deinit();

    const kind = env.value.@"$kind";

    if (std.mem.eql(u8, kind, "alpm.info")) {
        const e = std.json.parseFromSlice(AlpmInfo, alloc, msg.json, .{ .ignore_unknown_fields = true }) catch return 0;
        defer e.deinit();
        op.on_event(op.ctx, .{ .info = .{ .event_type = e.value.EventType, .message = e.value.Message, .current = e.value.CurrentIndex, .total = e.value.TotalCount } });
    } else if (std.mem.eql(u8, kind, "alpm.error")) {
        const e = std.json.parseFromSlice(AlpmError, alloc, msg.json, .{ .ignore_unknown_fields = true }) catch return 0;
        defer e.deinit();
        op.on_event(op.ctx, .{ .err = .{ .message = e.value.ErrorMessage } });
    } else {
        op.on_event(op.ctx, .unknown);
    }

    return 0;
}

fn onDoneIdle(data: ?*anyopaque) callconv(.c) c_int {
    const msg: *DoneMsg = @ptrCast(@alignCast(data.?));
    const alloc = msg.op.allocator;
    const op = msg.op;
    const code = msg.exit_code;
    alloc.destroy(msg);
    op.on_done(op.ctx, code);
    return 0;
}
