//! Shared UI roles inherit the terminal's foreground and background.
const Style = @import("vaxis").Style;

// Keep secondary text readable on both light and dark themes.
pub const secondary: Style = .{};
pub const emphasis: Style = .{ .bold = true };
pub const selected: Style = .{ .bold = true, .reverse = true };
pub const button: Style = .{ .reverse = true };

pub const action: Style = .{};
pub const action_button: @TypeOf(@as(@import("vaxis").vxfw.Button, undefined).style) = .{
    .default = action,
    .hover = emphasis,
    .focus = emphasis,
    .mouse_down = emphasis,
};

const std = @import("std");
const vxfw = @import("vaxis").vxfw;

pub fn hoverLabel(arena: std.mem.Allocator, surface: *vxfw.Surface) std.mem.Allocator.Error!void {
    const label = try arena.create(HoverLabel);
    label.* = .{ .surface = surface.* };
    surface.widget = .{ .userdata = label, .drawFn = HoverLabel.draw, .eventHandler = HoverLabel.handleEvent };
}

const HoverLabel = struct {
    surface: vxfw.Surface,

    fn draw(ptr: *anyopaque, _: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *HoverLabel = @ptrCast(@alignCast(ptr));
        return self.surface;
    }

    fn highlight(self: *const HoverLabel) void {
        for (self.surface.buffer) |*cell| {
            cell.style.bold = true;
        }
    }

    fn handleEvent(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        if (event == .mouse_leave) return ctx.setMouseShape(.default);
        const self: *HoverLabel = @ptrCast(@alignCast(ptr));
        if (event == .mouse_enter) {
            self.highlight();
            return ctx.setMouseShape(.pointer);
        }
        try self.surface.widget.handleEvent(ctx, event);
    }
};

pub fn paintHover(surface: vxfw.Surface, arena: std.mem.Allocator, point: vxfw.Point) std.mem.Allocator.Error!void {
    if (point.row >= surface.size.height or point.col >= surface.size.width) return;
    var hits: std.ArrayList(vxfw.HitResult) = .empty;
    try surface.hitTest(arena, &hits, point);
    const hit = hits.pop() orelse return;
    if (hit.widget.eventHandler == HoverLabel.handleEvent) {
        const label: *const HoverLabel = @ptrCast(@alignCast(hit.widget.userdata));
        label.highlight();
    }
}
