const std = @import("std");
const vaxis = @import("vaxis");
const RepositoryField = @import("../models/utilities_model.zig").RepositoryField;
const RepositoryControl = @import("../models/utilities_model.zig").RepositoryControl;
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
    model.utilities_split_visible = true;
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
    const action_height = @min(9, @max(size.height -| 1, 1));
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
    var widget: vxfw.Widget = .{ .userdata = ptr, .drawFn = drawActions, .eventHandler = focusActions };
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
        .{ .task = .repair_database },
        .{ .task = .repository },
    };
    var children: std.ArrayList(vxfw.SubSurface) = .empty;
    if (size.height < rows.len) {
        widget.eventHandler = navigateCompactActions;
        var available: [std.enums.values(Task).len]Task = undefined;
        var count: usize = 0;
        var selected: usize = 0;
        for (std.enums.values(Task)) |task| {
            if (!task.available(model)) continue;
            if (task == model.utilities_state.selected) selected = count;
            available[count] = task;
            count += 1;
        }
        const visible = @min(count, size.height);
        const start = (selected + 1) -| visible;
        for (available[start..][0..visible], 0..) |task, row| {
            try children.append(ctx.arena, .{ .origin = .{ .row = @intCast(row), .col = 0 }, .surface = try drawAction(model, line_ctx, task) });
        }
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

fn navigateCompactActions(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    if (event == .mouse) switch (event.mouse.button) {
        .wheel_up, .wheel_down => return commands.Mouse.moveUtilityFocus(@ptrCast(@alignCast(ptr)), ctx, event.mouse.button == .wheel_up),
        else => {},
    };
    try focusActions(ptr, ctx, event);
}

fn focusActions(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    if (event == .mouse and commands.Mouse.primaryPress(event.mouse))
        commands.Mouse.focusUtilityPane(@ptrCast(@alignCast(ptr)), ctx, false);
}

fn focusResults(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    if (event == .mouse and commands.Mouse.primaryPress(event.mouse))
        commands.Mouse.focusUtilityPane(@ptrCast(@alignCast(ptr)), ctx, true);
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
        try styles.hoverLabel(ctx.arena, &surface);
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
        .repository => return drawRepositories(ptr, ctx),
        .cleanup, .flatpak_cleanup, .repair_permissions, .repair_database => {
            const description: vxfw.Text = .{
                .text = switch (state.selected) {
                    .cleanup => "Review orphaned packages and corrupted cache entries before removing them. Administrator authorization is required to build the cleanup plan.",
                    .flatpak_cleanup => "Review unused Flatpak dependencies in system and user installations before removing them.",
                    .repair_permissions => "Restore your ownership of Shelly’s configuration, cache, and data directories.",
                    .repair_database => "Remove leftover db.lck files from the configured system database and Shelly’s update-check cache.",
                    .pacfiles, .repository => unreachable,
                },
                .softwrap = true,
            };
            return description.draw(ctx);
        },
    }
    const size = ctx.max.size();
    const widget: vxfw.Widget = .{ .userdata = ptr, .drawFn = drawResults, .eventHandler = focusResults };
    if (size.width == 0 or size.height == 0) return .{ .widget = widget, .size = size, .buffer = &.{}, .children = &.{} };

    var children: std.ArrayList(vxfw.SubSurface) = .empty;
    var row: u16 = 0;
    if (size.height > 1) {
        const intro = try drawDescription(ctx, "Preview .pacnew, .pacsave, and .pacorig files left by package changes.");
        try children.append(ctx.arena, .{ .origin = .{ .row = 0, .col = 0 }, .surface = intro });
        row = intro.size.height;
        if (size.height - row >= 2) row += 1;
    }
    const message = state.message();
    const show_actions = model.settings_state.settings.expanded_mouse_support and size.height - row >= 2;
    const retry = show_actions and state.failed and state.job == null and size.width >= "[Retry]".len;
    const buttons = show_actions and message == null and size.width >= 16;
    const body_ctx = ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height - row - @as(u16, @intFromBool(buttons or retry)) });
    const body = if (message) |status_message| blk: {
        const status: vxfw.Text = .{ .text = status_message, .softwrap = true };
        break :blk try status.draw(body_ctx);
    } else try drawClickableResults(model, body_ctx, .pacfiles, &state.list);
    try children.append(ctx.arena, .{ .origin = .{ .row = row, .col = 0 }, .surface = body });
    if (retry) {
        try appendUtilityButton(model, ctx, &children, size.height - 1, 0, "[Retry]", .retry);
    } else if (buttons) {
        try appendUtilityButton(model, ctx, &children, size.height - 1, 0, "[Preview]", .{ .preview_diff = false });
        try appendUtilityButton(model, ctx, &children, size.height - 1, 10, "[Diff]", .{ .preview_diff = true });
    }
    return .{ .widget = widget, .size = size, .buffer = &.{}, .children = children.items };
}

fn drawDescription(ctx: vxfw.DrawContext, text: []const u8) Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    const description: vxfw.Text = .{ .text = text, .softwrap = true };
    return description.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = @min(size.height - 1, 3) }));
}

pub fn drawPath(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    return drawPacfilePath(ptr, ctx, false);
}

pub fn drawSelectedPath(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    return drawPacfilePath(ptr, ctx, true);
}

fn drawPacfilePath(ptr: *anyopaque, ctx: vxfw.DrawContext, selected: bool) Allocator.Error!vxfw.Surface {
    const path: *const []const u8 = @ptrCast(@alignCast(ptr));
    const text: vxfw.Text = .{ .text = try @import("diagnostics").sanitizeAlloc(ctx.arena, path.*), .softwrap = true, .width_basis = .parent, .style = if (selected) styles.selected else styles.secondary };
    var surface = try text.draw(ctx.withConstraints(ctx.min, .{ .width = ctx.max.width orelse ctx.min.width, .height = ctx.max.height }));
    surface.widget = .{ .userdata = ptr, .drawFn = if (selected) drawSelectedPath else drawPath };
    return surface;
}

const ResultRow = struct {
    model: *Model,
    task: Task,
    name: []const u8,

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *ResultRow = @ptrCast(@alignCast(ptr));
        return drawPath(@ptrCast(&self.name), ctx);
    }

    fn click(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        if (event != .mouse or !commands.Mouse.primaryPress(event.mouse)) return;
        const self: *ResultRow = @ptrCast(@alignCast(ptr));
        commands.Mouse.selectUtilityResult(self.model, ctx, self.task, self.name);
    }
};

fn drawClickableResults(model: *Model, ctx: vxfw.DrawContext, task: Task, list: *vxfw.ScrollView) Allocator.Error!vxfw.Surface {
    var surface = try list.draw(ctx);
    const children = try ctx.arena.dupe(vxfw.SubSurface, surface.children);
    for (children) |*child| {
        if (child.surface.widget.drawFn != drawPath and child.surface.widget.drawFn != drawSelectedPath) continue;
        const name: *const []const u8 = @ptrCast(@alignCast(child.surface.widget.userdata));
        const row = try ctx.arena.create(ResultRow);
        row.* = .{ .model = model, .task = task, .name = try ctx.arena.dupe(u8, name.*) };
        child.surface.widget = .{ .userdata = row, .drawFn = ResultRow.draw, .eventHandler = ResultRow.click };
        try styles.hoverLabel(ctx.arena, &child.surface);
    }
    surface.children = children;
    return surface;
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

test "utility result clicks select wrapped paths and return focus to the action pane" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.active = .utilities;
    model.utilities_state.result = try std.json.parseFromSlice([][]const u8, model.gpa,
        \\["/etc/first.pacnew","/etc/a-long-configuration-name.pacsave"]
    , .{ .allocate = .alloc_always });
    model.utilities_state.list.item_count = 2;
    var arena = std.heap.ArenaAllocator.init(model.gpa);
    defer arena.deinit();
    const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 20, .height = 6 }, .cell_size = .{ .width = 10, .height = 20 } };
    const surface = try drawClickableResults(model, draw_ctx, .pacfiles, &model.utilities_state.list);
    const second = surface.children[1];
    try std.testing.expect(second.surface.size.height > 1);
    var hits: std.ArrayList(vxfw.HitResult) = .empty;
    try surface.hitTest(arena.allocator(), &hits, .{ .row = @intCast(second.origin.row + 1), .col = 0 });
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    const click: vxfw.Event = .{ .mouse = .{ .row = 0, .col = 0, .button = .left, .type = .press, .mods = .{} } };
    try hits.items[hits.items.len - 1].widget.handleEvent(&events, click);
    try std.testing.expectEqual(@as(u32, 1), model.utilities_state.list.cursor);
    try std.testing.expect(model.utilities_state.results_focused);
    const actions = try drawActions(model, draw_ctx);
    try actions.widget.handleEvent(&events, click);
    try std.testing.expect(!model.utilities_state.results_focused);
}

fn drawRepositories(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const model: *Model = @ptrCast(@alignCast(ptr));
    const state = &model.utilities_state.repositories;
    const size = ctx.max.size();
    const widget: vxfw.Widget = .{ .userdata = ptr, .drawFn = drawRepositories, .eventHandler = focusResults };
    if (size.width == 0 or size.height == 0) return .{ .widget = widget, .size = size, .buffer = &.{}, .children = &.{} };
    var children: std.ArrayList(vxfw.SubSurface) = .empty;
    if (state.editing) |field| {
        const show_buttons = model.settings_state.settings.expanded_mouse_support and size.width >= 17 and size.height >= 3;
        const show_message = size.height > 2 and state.message.len != 0;
        const footer_height = @as(u16, @intFromBool(show_buttons)) + @as(u16, @intFromBool(show_message));
        const fields_height = size.height - footer_height;
        if (fields_height == 1) {
            try appendRepositoryField(model, ctx, &children, 0, field, true, 1);
        } else if (fields_height < 6) {
            try appendRepositoryField(model, ctx, &children, 0, field, true, 2);
        } else {
            try appendRepositoryField(model, ctx, &children, 0, .name, field == .name, 2);
            try appendRepositoryField(model, ctx, &children, 2, .url, field == .url, 2);
            try appendRepositoryField(model, ctx, &children, 4, .fingerprint, field == .fingerprint, 2);
        }
        if (show_message)
            try appendRepositoryLine(ctx, &children, fields_height, state.message, styles.emphasis);
        if (show_buttons) {
            try appendUtilityButton(model, ctx, &children, size.height - 1, 0, "[Review]", .{ .repository = .review });
            try appendUtilityButton(model, ctx, &children, size.height - 1, 9, "[Cancel]", .{ .repository = .back });
        }
    } else {
        var row: u16 = 0;
        if (size.height >= 2) {
            const intro = try drawDescription(ctx, "Manage repositories. Some require separate keyring setup; see Help.");
            try children.append(ctx.arena, .{ .origin = .{ .row = row, .col = 0 }, .surface = intro });
            row = intro.size.height;
            if (size.height - row >= 2) row += 1;
        }
        if (row < size.height and state.message.len != 0 and (size.height - row > 1 or state.selected() == null)) {
            try appendRepositoryLine(ctx, &children, row, state.message, styles.secondary);
            row += 1;
        }
        if (row < size.height and state.selected() != null) {
            const show_buttons = model.settings_state.settings.expanded_mouse_support and state.job == null and size.width >= 22 and size.height - row >= 2;
            const list_height = size.height - row - @as(u16, @intFromBool(show_buttons));
            try children.append(ctx.arena, .{ .origin = .{ .row = row, .col = 0 }, .surface = try drawClickableResults(model, ctx.withConstraints(.{}, .{ .width = size.width, .height = list_height }), .repository, &state.list) });
            if (show_buttons) {
                try appendUtilityButton(model, ctx, &children, size.height - 1, 0, "[Add]", .{ .repository = .add });
                try appendUtilityButton(model, ctx, &children, size.height - 1, 6, "[Remove]", .{ .repository = .remove });
            }
        } else if (row < size.height and model.settings_state.settings.expanded_mouse_support and state.job == null and size.width >= 5) {
            try appendUtilityButton(model, ctx, &children, size.height - 1, 0, "[Add]", .{ .repository = .add });
        }
    }
    return .{ .widget = widget, .size = size, .buffer = &.{}, .children = children.items };
}

const RepositoryInput = struct {
    model: *Model,
    field: RepositoryField,
    active: bool,

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *RepositoryInput = @ptrCast(@alignCast(ptr));
        const size = ctx.max.size();
        var children: std.ArrayList(vxfw.SubSurface) = .empty;
        if (size.height == 2) {
            const label = switch (self.field) {
                .name => "Repository name",
                .url => "Repository mirror URL",
                .fingerprint => "Key fingerprint (optional)",
            };
            try appendRepositoryLine(ctx, &children, 0, label, if (self.active) styles.selected else styles.emphasis);
        }
        const input = self.model.utilities_state.repositories.field(self.field);
        try children.append(ctx.arena, .{
            .origin = .{ .row = size.height - 1, .col = 0 },
            .surface = try input.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = 1 })),
        });
        return .{ .size = size, .widget = .{ .userdata = ptr, .drawFn = draw, .eventHandler = click }, .buffer = &.{}, .children = children.items };
    }

    fn click(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        if (event != .mouse or !commands.Mouse.primaryPress(event.mouse)) return;
        const self: *RepositoryInput = @ptrCast(@alignCast(ptr));
        try commands.Mouse.repositoryControl(self.model, ctx, .{ .focus_field = self.field });
    }
};

fn appendRepositoryField(model: *Model, ctx: vxfw.DrawContext, children: *std.ArrayList(vxfw.SubSurface), row: u16, field: RepositoryField, active: bool, height: u16) Allocator.Error!void {
    const input = try ctx.arena.create(RepositoryInput);
    input.* = .{ .model = model, .field = field, .active = active };
    try children.append(ctx.arena, .{
        .origin = .{ .row = row, .col = 0 },
        .surface = try RepositoryInput.draw(input, ctx.withConstraints(.{}, .{ .width = ctx.max.size().width, .height = height })),
    });
}

fn appendRepositoryLine(ctx: vxfw.DrawContext, children: *std.ArrayList(vxfw.SubSurface), row: u16, text: []const u8, style: vaxis.Style) Allocator.Error!void {
    const label: vxfw.Text = .{ .text = text, .style = style, .width_basis = .parent, .softwrap = false, .overflow = .ellipsis };
    try children.append(ctx.arena, .{
        .origin = .{ .row = row, .col = 0 },
        .surface = try label.draw(ctx.withConstraints(.{}, .{ .width = ctx.max.size().width, .height = 1 })),
    });
}

const UtilityButton = struct {
    const Action = union(enum) { repository: RepositoryControl, preview_diff: bool, retry };

    owner: *Model,
    label: []const u8,
    action: Action,

    fn drawWidget(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *UtilityButton = @ptrCast(@alignCast(ptr));
        const text: vxfw.Text = .{ .text = self.label, .style = styles.action, .softwrap = false };
        var surface = try text.draw(ctx);
        surface.widget = .{ .userdata = ptr, .drawFn = drawWidget, .eventHandler = click };
        try styles.hoverLabel(ctx.arena, &surface);
        return surface;
    }

    fn click(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        if (event != .mouse or !commands.Mouse.primaryPress(event.mouse)) return;
        const self: *UtilityButton = @ptrCast(@alignCast(ptr));
        switch (self.action) {
            .repository => |action| try commands.Mouse.repositoryControl(self.owner, ctx, action),
            .retry => try commands.Mouse.retryPacfiles(self.owner, ctx),
            .preview_diff => |diff| try commands.Mouse.previewPacfile(self.owner, ctx, diff),
        }
    }
};

fn appendUtilityButton(model: *Model, ctx: vxfw.DrawContext, children: *std.ArrayList(vxfw.SubSurface), row: u16, col: u16, label: []const u8, action: UtilityButton.Action) Allocator.Error!void {
    const button = try ctx.arena.create(UtilityButton);
    button.* = .{ .owner = model, .label = label, .action = action };
    try children.append(ctx.arena, .{
        .origin = .{ .row = row, .col = col },
        .surface = try UtilityButton.drawWidget(button, ctx.withConstraints(.{}, .{ .width = @intCast(label.len), .height = 1 })),
    });
}

test "repositories keep the Utilities split and render their description above the list" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.utilities_state.selected = .repository;
    model.utilities_state.repositories.names = try std.json.parseFromSlice([][]const u8, model.gpa, "[\"core\"]", .{ .allocate = .alloc_always });
    model.utilities_state.repositories.list.item_count = 1;
    var arena = std.heap.ArenaAllocator.init(model.gpa);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 100, .height = 24 }, .cell_size = .{ .width = 10, .height = 20 } };
    var panes: std.ArrayList(vxfw.SubSurface) = .empty;
    try appendContent(model, ctx, &panes);
    try std.testing.expectEqual(@as(usize, 2), panes.items.len);
    const details = try drawResults(model, ctx);
    try std.testing.expectEqual(@as(usize, 2), details.children.len);
    try std.testing.expect(details.children[1].origin.row > 0);
    try std.testing.expectEqualStrings("c", details.children[1].surface.children[0].surface.buffer[0].char.grapheme);
}
