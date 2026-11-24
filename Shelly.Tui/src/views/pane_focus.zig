const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const commands = @import("../commands.zig");
const coordinator = @import("../model.zig");

const Pane = struct {
    model: *coordinator.Model,
    tab: coordinator.Tab,
    target: commands.Mouse.FocusTarget,
    children: [1]vxfw.SubSurface,

    fn draw(ptr: *anyopaque, _: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Pane = @ptrCast(@alignCast(ptr));
        return .{
            .size = self.children[0].surface.size,
            .widget = .{ .userdata = self, .drawFn = draw, .captureHandler = press, .eventHandler = atTarget },
            .buffer = &.{},
            .children = &self.children,
        };
    }

    fn press(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        if (event != .mouse or !commands.Mouse.primaryPress(event.mouse)) return;
        const self: *Pane = @ptrCast(@alignCast(ptr));
        try commands.Mouse.focusPane(self.model, ctx, self.tab, self.target);
    }

    fn atTarget(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        if (ctx.phase == .at_target) try press(ptr, ctx, event);
    }
};

pub fn attach(ctx: vxfw.DrawContext, surface: *vxfw.Surface, model: ?*coordinator.Model, tab: coordinator.Tab, target: commands.Mouse.FocusTarget) std.mem.Allocator.Error!void {
    const owner = model orelse return;
    const pane = try ctx.arena.create(Pane);
    pane.* = .{
        .model = owner,
        .tab = tab,
        .target = target,
        .children = .{.{ .origin = .{ .row = 0, .col = 0 }, .surface = surface.* }},
    };
    surface.* = try Pane.draw(pane, ctx);
}

pub fn testClick(surface: vxfw.Surface, ctx: *vxfw.EventContext, target: commands.Mouse.FocusTarget) !void {
    const point = findPane(surface, target) orelse return error.MissingPane;
    var hits: std.ArrayList(vxfw.HitResult) = .empty;
    defer hits.deinit(ctx.alloc);
    try surface.hitTest(ctx.alloc, &hits, point);
    const last = hits.pop() orelse return error.MissingHit;
    ctx.consume_event = false;
    ctx.phase = .capturing;
    for (hits.items) |hit| {
        try hit.widget.captureEvent(ctx, mousePress(hit.local));
        if (ctx.consume_event) return;
    }
    ctx.phase = .at_target;
    try last.widget.handleEvent(ctx, mousePress(last.local));
}

fn findPane(surface: vxfw.Surface, target: commands.Mouse.FocusTarget) ?vxfw.Point {
    if (surface.widget.captureHandler == Pane.press) {
        const pane: *Pane = @ptrCast(@alignCast(surface.widget.userdata));
        if (pane.target == target) return .{ .row = 0, .col = 0 };
    }
    for (surface.children) |child| {
        if (findPane(child.surface, target)) |point| return .{
            .row = @intCast(child.origin.row + point.row),
            .col = @intCast(child.origin.col + point.col),
        };
    }
    return null;
}

fn mousePress(point: vxfw.Point) vxfw.Event {
    return .{ .mouse = .{ .row = @intCast(point.row), .col = @intCast(point.col), .button = .left, .type = .press, .mods = .{} } };
}

pub fn testContainsWidget(surface: vxfw.Surface, widget: vxfw.Widget) bool {
    if (surface.widget.eql(widget)) return true;
    for (surface.children) |child| {
        if (testContainsWidget(child.surface, widget)) return true;
    }
    return false;
}
