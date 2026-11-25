//! Read-only maintenance queries for the Utilities tab.
const std = @import("std");
const vxfw = @import("vaxis").vxfw;
const Model = @import("../model.zig").Model;
const commands = @import("../commands.zig");
const ShellyCli = @import("../services/shelly_cli.zig").ShellyCli;
const utilities_view = @import("../views/utilities_view.zig");

const Pacfiles = std.json.Parsed([][]const u8);
const Job = struct {
    thread: std.Thread,
    result: ?Pacfiles = null,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *Job) void {
        const allocator = std.heap.page_allocator;
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const cli: ShellyCli = .{ .allocator = allocator, .io = threaded.io() };
        self.result = cli.get_pacfiles() catch null;
        self.done.store(true, .release);
    }
};

pub const State = struct {
    job: ?*Job = null,
    result: ?Pacfiles = null,
    failed: bool = false,
    list: vxfw.ScrollView,

    pub fn init(model: *Model) State {
        return .{
            .list = .{ .children = .{ .builder = .{ .userdata = model, .buildFn = buildRow } } },
        };
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.job) |job| {
            job.thread.join();
            if (job.result) |*result| result.deinit();
            allocator.destroy(job);
        }
        if (self.result) |*result| result.deinit();
    }

    pub fn poll(self: *State, allocator: std.mem.Allocator) void {
        const job = self.job orelse return;
        if (!job.done.load(.acquire)) return;
        job.thread.join();
        self.job = null;
        defer allocator.destroy(job);
        if (self.result) |*result| result.deinit();
        self.result = job.result;
        self.failed = job.result == null;
        self.list.item_count = if (self.result) |result| @intCast(result.value.len) else 0;
        self.list.scroll = .{};
    }

    pub fn message(self: *const State) ?[]const u8 {
        if (self.job != null) return "Looking for pending configuration files…";
        if (self.failed) return "Could not list pending configuration files. Try again.";
        if (self.result) |result| return if (result.value.len == 0) "No pending configuration files." else null;
        return "Find pending .pacnew, .pacsave, and .pacorig files.";
    }
};

fn buildRow(ptr: *const anyopaque, index: usize, _: usize) ?vxfw.Widget {
    const model: *const Model = @ptrCast(@alignCast(ptr));
    const result = model.utilities_state.result orelse return null;
    if (index >= result.value.len) return null;
    return .{ .userdata = @ptrCast(&result.value[index]), .drawFn = utilities_view.drawPath };
}

pub fn discoverFromMouse(ptr: *anyopaque, ctx: *vxfw.EventContext) !void {
    const model: *Model = @ptrCast(@alignCast(ptr));
    if (model.active != .utilities or model.help_open or model.overlay != null) return;
    try discover(model, ctx);
}

pub fn discover(model: *Model, ctx: *vxfw.EventContext) !void {
    const state = &model.utilities_state;
    if (state.job != null) return ctx.consumeEvent();
    try ctx.tick(100, model.widget());
    const job = try model.gpa.create(Job);
    errdefer model.gpa.destroy(job);
    job.* = .{ .thread = undefined };
    job.thread = try std.Thread.spawn(.{}, Job.run, .{job});
    state.job = job;
    ctx.consumeAndRedraw();
}

pub fn handleKey(model: *Model, ctx: *vxfw.EventContext, key: @import("vaxis").Key) !bool {
    if (commands.matches(key, .confirm) or commands.matches(key, .refresh)) {
        try discover(model, ctx);
        return true;
    }
    return false;
}

pub fn handleScroll(model: *Model, ctx: *vxfw.EventContext, event: vxfw.Event) !void {
    const state = &model.utilities_state;
    if (state.message() != null) return;
    if (event == .key_press) {
        const key = commands.scrollKey(event.key_press) orelse event.key_press;
        return state.list.handleEvent(ctx, .{ .key_press = key });
    }
    try state.list.handleEvent(ctx, event);
}
