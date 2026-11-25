const std = @import("std");
const vxfw = @import("vaxis").vxfw;
const Model = @import("../model.zig").Model;
const commands = @import("../commands.zig");
const Border = @import("components/border.zig");
const styles = @import("components/styles.zig");
const split_layout = @import("components/split_layout.zig");
const Allocator = std.mem.Allocator;

pub fn appendContent(model: *Model, ctx: vxfw.DrawContext, children: *std.ArrayList(vxfw.SubSurface)) Allocator.Error!void {
    const size = ctx.max.size();
    const height = size.height -| 2;
    if (height == 0 or size.width == 0) return;
    if (size.width < 80 or height < 10) {
        try appendPane(ctx, children, .{ .row = 1, .col = 0 }, .{ .width = size.width, .height = height }, "Utilities", .{ .userdata = model, .drawFn = drawStacked });
        return;
    }
    const list_width = split_layout.listWidth(size.width, model.list_percent.utilities);
    try appendPane(ctx, children, .{ .row = 1, .col = 0 }, .{ .width = list_width, .height = height }, "Utilities", .{ .userdata = model, .drawFn = drawActions });
    try appendPane(ctx, children, .{ .row = 1, .col = list_width }, .{ .width = size.width - list_width, .height = height }, "Details", .{ .userdata = model, .drawFn = drawResults });
}

fn appendPane(ctx: vxfw.DrawContext, children: *std.ArrayList(vxfw.SubSurface), origin: vxfw.Point, size: vxfw.Size, title: []const u8, widget: vxfw.Widget) Allocator.Error!void {
    const pane_ctx = ctx.withConstraints(size, .{ .width = size.width, .height = size.height });
    const pane = try ctx.arena.create(vxfw.Widget);
    pane.* = widget;
    const content: vxfw.Widget = .{ .userdata = pane, .drawFn = drawPaneContent };
    const labels = try ctx.arena.alloc(Border.BorderLabel, 1);
    labels[0] = .{ .text = title, .alignment = .top_left };
    const border = try ctx.arena.create(Border);
    border.* = .{ .child = content, .labels = labels, .style = styles.emphasis };
    try children.append(ctx.arena, .{
        .origin = .{ .row = origin.row, .col = origin.col },
        .surface = if (size.width >= 3 and size.height >= 3) try border.draw(pane_ctx) else try content.draw(pane_ctx),
    });
}

// Keep the frame at its allocated size while its content keeps its own hit area.
fn drawPaneContent(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const widget: *const vxfw.Widget = @ptrCast(@alignCast(ptr));
    const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try widget.draw(ctx) };
    return .{ .size = ctx.max.size(), .widget = .{ .userdata = ptr, .drawFn = drawPaneContent }, .buffer = &.{}, .children = children };
}

fn drawStacked(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    const action_height = @min(2, @max(size.height -| 1, 1));
    const children = try ctx.arena.alloc(vxfw.SubSurface, if (size.height > action_height) 2 else 1);
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try drawActions(ptr, ctx.withConstraints(.{}, .{ .width = size.width, .height = action_height })) };
    if (children.len == 2) {
        const gap: u16 = @intFromBool(size.height > action_height + 1);
        const result_row = action_height + gap;
        children[1] = .{ .origin = .{ .row = result_row, .col = 0 }, .surface = try drawResults(ptr, ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height - result_row })) };
    }
    return .{ .size = size, .widget = .{ .userdata = ptr, .drawFn = drawStacked }, .buffer = &.{}, .children = children };
}

fn drawActions(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    const widget: vxfw.Widget = .{ .userdata = ptr, .drawFn = drawActions };
    if (size.width == 0 or size.height == 0) return .{ .size = size, .widget = widget, .buffer = &.{}, .children = &.{} };
    const line_ctx = ctx.withConstraints(.{}, .{ .width = size.width, .height = 1 });
    const children = try ctx.arena.alloc(vxfw.SubSurface, @min(size.height, 2));
    const action_row: u16 = @intCast(children.len - 1);
    if (action_row != 0) {
        const heading: vxfw.Text = .{ .text = "Configuration files", .softwrap = false, .overflow = .ellipsis, .style = styles.emphasis };
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try heading.draw(line_ctx) };
    }
    children[action_row] = .{ .origin = .{ .row = action_row, .col = 0 }, .surface = try drawAction(ptr, line_ctx) };
    return .{ .size = size, .widget = widget, .buffer = &.{}, .children = children };
}

fn drawAction(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const model: *Model = @ptrCast(@alignCast(ptr));
    const busy = model.utilities_state.job != null;
    const label: vxfw.Text = .{
        .text = "Find pending files",
        .softwrap = false,
        .overflow = .ellipsis,
        .width_basis = .parent,
        .style = if (busy) styles.secondary else styles.selected,
    };
    var surface = try label.draw(ctx);
    surface.widget = .{ .userdata = ptr, .drawFn = drawAction, .eventHandler = activate };
    if (model.settings_state.settings.expanded_mouse_support and !busy) try styles.hoverLabel(ctx.arena, &surface);
    return surface;
}

fn activate(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    if (event != .mouse or !commands.Mouse.primaryPress(event.mouse)) return;
    const model: *Model = @ptrCast(@alignCast(ptr));
    if (model.settings_state.settings.expanded_mouse_support) try commands.Mouse.discoverPacfiles(model, ctx);
}

fn drawResults(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const model: *Model = @ptrCast(@alignCast(ptr));
    if (model.utilities_state.message()) |message| {
        const text: vxfw.Text = .{ .text = message, .softwrap = true };
        return text.draw(ctx);
    }
    return model.utilities_state.list.draw(ctx);
}

pub fn drawPath(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const path: *const []const u8 = @ptrCast(@alignCast(ptr));
    const text: vxfw.Text = .{ .text = try @import("diagnostics").sanitizeAlloc(ctx.arena, path.*), .softwrap = true };
    return text.draw(ctx);
}

test "utilities frames fill their allocated panes before scanning" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var children: std.ArrayList(vxfw.SubSurface) = .empty;
    try appendContent(model, .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 100, .height = 24 }, .cell_size = .{ .width = 10, .height = 20 } }, &children);
    try std.testing.expectEqual(@as(usize, 2), children.items.len);
    try std.testing.expectEqual(vxfw.Size{ .width = 40, .height = 22 }, children.items[0].surface.size);
    try std.testing.expectEqual(vxfw.Size{ .width = 60, .height = 22 }, children.items[1].surface.size);
    try std.testing.expectEqual(@as(i17, 40), children.items[1].origin.col);
}
