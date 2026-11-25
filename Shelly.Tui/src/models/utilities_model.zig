//! Read-only maintenance queries for the Utilities tab.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
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

pub const Task = enum {
    pacfiles,
    cleanup,
    flatpak_cleanup,

    pub fn label(self: Task) []const u8 {
        return switch (self) {
            .pacfiles => "Find pending files",
            .cleanup => "Clean standard packages",
            .flatpak_cleanup => "Clean unused Flatpaks",
        };
    }

    pub fn available(self: Task, model: *const Model) bool {
        return self != .flatpak_cleanup or (model.settings_state.settings.flatpak_enabled and model.flatpak_state.flatpak_available);
    }
};

pub const State = struct {
    selected: Task = .pacfiles,
    results_focused: bool = false,
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

pub fn activateFromMouse(model: *Model, ctx: *vxfw.EventContext, task: Task) !void {
    if (model.active != .utilities or model.help_open or model.overlay != null or !model.settings_state.settings.expanded_mouse_support or !task.available(model)) return;
    model.utilities_state.selected = task;
    try activate(model, ctx);
}

fn activate(model: *Model, ctx: *vxfw.EventContext) !void {
    const state = &model.utilities_state;
    switch (state.selected) {
        .pacfiles => {
            state.results_focused = true;
            try discover(model, ctx);
        },
        .cleanup, .flatpak_cleanup => {
            if (!state.selected.available(model)) return ctx.consumeEvent();
            try @import("operation_model.zig").startCleanup(model, ctx, if (state.selected == .cleanup) .standard else .flatpak);
        },
    }
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

pub fn handleKey(model: *Model, ctx: *vxfw.EventContext, key: vaxis.Key) !bool {
    const state = &model.utilities_state;
    if (commands.matches(key, .confirm) or (state.selected == .pacfiles and commands.matches(key, .refresh))) {
        try activate(model, ctx);
        return true;
    }
    const direction = commands.scrollKey(key) orelse return false;
    switch (direction.codepoint) {
        vaxis.Key.left => state.results_focused = false,
        vaxis.Key.right => state.results_focused = state.selected == .pacfiles,
        vaxis.Key.up, vaxis.Key.down => {
            if (state.results_focused) return false;
            const tasks = std.enums.values(Task);
            const index = @backingInt(state.selected);
            const next = if (direction.codepoint == vaxis.Key.up) index -| 1 else @min(index + 1, tasks.len - 1);
            if (tasks[next].available(model)) state.selected = tasks[next];
        },
        else => return false,
    }
    ctx.consumeAndRedraw();
    return true;
}

pub fn handleScroll(model: *Model, ctx: *vxfw.EventContext, event: vxfw.Event) !void {
    if (model.utilities_state.selected != .pacfiles or model.utilities_state.message() != null) return;
    const list = &model.utilities_state.list;
    if (event == .key_press) {
        if (!model.utilities_state.results_focused) return;
        const key = commands.scrollKey(event.key_press) orelse event.key_press;
        return list.handleEvent(ctx, .{ .key_press = key });
    }
    try list.handleEvent(ctx, event);
}

test "Utilities switches actions with keyboard and keeps results navigation separate" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.active = .utilities;
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(ctx.alloc);

    try model.captureEvent(&ctx, .{ .key_press = commands.bindings.next });
    try std.testing.expectEqual(Task.cleanup, model.utilities_state.selected);
    try std.testing.expectEqualStrings("Clean standard packages", model.commandContext().utilities_action);
    try model.captureEvent(&ctx, .{ .key_press = commands.bindings.previous });
    try model.captureEvent(&ctx, .{ .key_press = commands.bindings.details });
    try model.captureEvent(&ctx, .{ .key_press = commands.bindings.previous });
    try std.testing.expectEqual(Task.pacfiles, model.utilities_state.selected);
    try std.testing.expect(model.utilities_state.results_focused);
    try model.captureEvent(&ctx, .{ .key_press = commands.bindings.back });
    try model.captureEvent(&ctx, .{ .key_press = commands.bindings.previous });
    try std.testing.expectEqual(Task.pacfiles, model.utilities_state.selected);
    try std.testing.expectEqualStrings("Find pending files", model.commandContext().utilities_action);
}
