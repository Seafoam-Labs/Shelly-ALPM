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
    const list_width = split_layout.listWidth(size.width, model.list_percent.utilities);
    const split = list_width < size.width;
    const action_height = if (split) height else @min(height -| 1, 3);
    if (action_height > 0) {
        const action = vxfw.Widget{ .userdata = model, .drawFn = drawAction };
        try appendPane(ctx, children, .{ .row = 1, .col = 0 }, .{ .width = list_width, .height = action_height }, "Utilities", action);
    }
    const result_height = if (split) height else height - action_height;
    const result_width = if (split) size.width - list_width else size.width;
    const results = vxfw.Widget{ .userdata = model, .drawFn = drawResults };
    try appendPane(ctx, children, .{ .row = if (split) 1 else 1 + action_height, .col = if (split) list_width else 0 }, .{ .width = result_width, .height = result_height }, "Configuration files", results);
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

fn drawAction(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const model: *Model = @ptrCast(@alignCast(ptr));
    const size = ctx.max.size();
    const line_ctx = ctx.withConstraints(.{}, .{ .width = size.width, .height = @min(size.height, 1) });
    if (model.settings_state.settings.expanded_mouse_support and model.utilities_state.job == null and size.width >= model.utilities_state.discover.label.len) {
        return model.utilities_state.discover.draw(line_ctx.withConstraints(.{}, .{ .width = @intCast(model.utilities_state.discover.label.len), .height = @min(size.height, 1) }));
    }
    const key = try commands.label(ctx.arena, .confirm);
    const label = try std.fmt.allocPrint(ctx.arena, "{s} Find pending configuration files", .{key});
    const text: vxfw.Text = .{ .text = label, .softwrap = false, .overflow = .ellipsis };
    return text.draw(line_ctx);
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
