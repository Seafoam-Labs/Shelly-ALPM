const std = @import("std");
const vxfw = @import("vaxis").vxfw;
const Model = @import("../model.zig").Model;
const Task = @import("../models/utilities_model.zig").Task;
const commands = @import("../commands.zig");
const Border = @import("components/border.zig");
const styles = @import("components/styles.zig");
const split_layout = @import("components/split_layout.zig");
const Allocator = std.mem.Allocator;

pub fn appendContent(model: *Model, ctx: vxfw.DrawContext, children: *std.ArrayList(vxfw.SubSurface)) Allocator.Error!void {
    const size = ctx.max.size();
    const height = size.height -| 2;
    if (height == 0 or size.width == 0) return;
    if (model.utilities_state.preview_open) {
        try children.append(ctx.arena, .{
            .origin = .{ .row = 1, .col = 0 },
            .surface = try @import("../models/utilities_model.zig").previewView(model).drawInPane(ctx.withConstraints(.{}, .{ .width = size.width, .height = height })),
        });
        return;
    }
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
    const action_height = @min(7, @max(size.height -| 1, 1));
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
    const model: *Model = @ptrCast(@alignCast(ptr));
    const rows = [_]union(enum) { heading: []const u8, task: Task }{
        .{ .heading = "Configuration files" },
        .{ .task = .pacfiles },
        .{ .heading = "Cleanup" },
        .{ .task = .cleanup },
        .{ .task = .flatpak_cleanup },
        .{ .heading = "Repair" },
        .{ .task = .repair_permissions },
    };
    var children: std.ArrayList(vxfw.SubSurface) = .empty;
    if (size.height < rows.len) {
        try children.append(ctx.arena, .{ .origin = .{ .row = 0, .col = 0 }, .surface = try drawAction(model, line_ctx, model.utilities_state.selected) });
    } else {
        for (rows) |row| {
            const surface = switch (row) {
                .heading => |label| blk: {
                    const heading: vxfw.Text = .{ .text = label, .softwrap = false, .overflow = .ellipsis, .style = styles.emphasis };
                    break :blk try heading.draw(line_ctx);
                },
                .task => |task| if (task.available(model)) try drawAction(model, line_ctx, task) else continue,
            };
            try children.append(ctx.arena, .{ .origin = .{ .row = @intCast(children.items.len), .col = 0 }, .surface = surface });
        }
    }
    return .{ .size = size, .widget = widget, .buffer = &.{}, .children = children.items };
}

const ActionRow = struct {
    model: *Model,
    task: Task,

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *ActionRow = @ptrCast(@alignCast(ptr));
        const label: vxfw.Text = .{
            .text = self.task.label(),
            .softwrap = false,
            .overflow = .ellipsis,
            .width_basis = .parent,
            .style = if (self.model.utilities_state.selected == self.task) styles.selected else styles.secondary,
        };
        var surface = try label.draw(ctx);
        surface.widget = .{ .userdata = ptr, .drawFn = draw, .eventHandler = activate };
        if (self.model.settings_state.settings.expanded_mouse_support) try styles.hoverLabel(ctx.arena, &surface);
        return surface;
    }

    fn activate(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        if (event != .mouse or !commands.Mouse.primaryPress(event.mouse)) return;
        const self: *ActionRow = @ptrCast(@alignCast(ptr));
        try commands.Mouse.activateUtility(self.model, ctx, self.task);
    }
};

fn drawAction(model: *Model, ctx: vxfw.DrawContext, task: Task) Allocator.Error!vxfw.Surface {
    const row = try ctx.arena.create(ActionRow);
    row.* = .{ .model = model, .task = task };
    return ActionRow.draw(row, ctx);
}

fn drawResults(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const model: *Model = @ptrCast(@alignCast(ptr));
    const state = &model.utilities_state;
    switch (state.selected) {
        .pacfiles => {},
        .cleanup, .flatpak_cleanup, .repair_permissions => {
            const description: vxfw.Text = .{
                .text = switch (state.selected) {
                    .cleanup => "Review orphaned packages and corrupted cache entries before removing them. Administrator authorization is required to build the cleanup plan.",
                    .flatpak_cleanup => "Review unused Flatpak dependencies in system and user installations before removing them.",
                    .repair_permissions => "Restore your ownership of Shelly’s configuration, cache, and data directories.",
                    .pacfiles => unreachable,
                },
                .softwrap = true,
            };
            return description.draw(ctx);
        },
    }
    const size = ctx.max.size();
    const widget: vxfw.Widget = .{ .userdata = ptr, .drawFn = drawResults };
    if (size.width == 0 or size.height == 0) return .{ .widget = widget, .size = size, .buffer = &.{}, .children = &.{} };

    const children = try ctx.arena.alloc(vxfw.SubSurface, if (size.height > 1) 2 else 1);
    var row: u16 = 0;
    if (children.len == 2) {
        const description: vxfw.Text = .{ .text = "Preview .pacnew, .pacsave, and .pacorig files left by package changes.", .softwrap = true };
        const intro = try description.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = @min(size.height - 1, 3) }));
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = intro };
        row = intro.size.height;
        if (size.height - row >= 2) row += 1;
    }
    const body_ctx = ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height - row });
    const body = if (state.message()) |message| blk: {
        const status: vxfw.Text = .{ .text = message, .softwrap = true };
        break :blk try status.draw(body_ctx);
    } else try state.list.draw(body_ctx);
    children[children.len - 1] = .{ .origin = .{ .row = row, .col = 0 }, .surface = body };
    return .{ .widget = widget, .size = size, .buffer = &.{}, .children = children };
}

pub fn drawPath(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    return drawPacfilePath(ptr, ctx, styles.secondary);
}

pub fn drawSelectedPath(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    return drawPacfilePath(ptr, ctx, styles.selected);
}

fn drawPacfilePath(ptr: *anyopaque, ctx: vxfw.DrawContext, style: @import("vaxis").Style) Allocator.Error!vxfw.Surface {
    const path: *const []const u8 = @ptrCast(@alignCast(ptr));
    const text: vxfw.Text = .{ .text = try @import("diagnostics").sanitizeAlloc(ctx.arena, path.*), .softwrap = true, .width_basis = .parent, .style = style };
    return text.draw(ctx.withConstraints(ctx.min, .{ .width = ctx.max.width orelse ctx.min.width, .height = ctx.max.height }));
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

test "pacfile description stays above the full-width selected result" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.utilities_state.result = try std.json.parseFromSlice([][]const u8, std.testing.allocator, "[\"/etc/test.pacnew\"]", .{ .allocate = .alloc_always });
    model.utilities_state.list.item_count = 1;
    model.utilities_state.results_focused = true;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const surface = try drawResults(model, .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 40, .height = 6 }, .cell_size = .{ .width = 10, .height = 20 } });
    try std.testing.expect(surface.children[1].origin.row > 0);
    const row = surface.children[1].surface.children[0].surface;
    try std.testing.expectEqualStrings("/", row.buffer[0].char.grapheme);
    try std.testing.expectEqual(styles.selected, row.buffer[0].style);
    try std.testing.expectEqual(@as(u16, 40), row.size.width);
}
