const keybindings_view = @import("keybindings_view.zig");
const styles = @import("styles.zig");
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Border = @import("border.zig");
const preferences = @import("../models/settings.zig");
const Settings = preferences.Settings;
const diagnostics = @import("diagnostics");
const Allocator = std.mem.Allocator;

pub const Action = union(enum) { control: usize, header: usize };

pub const View = struct {
    settings: Settings,
    userdata: ?*anyopaque = null,
    on_action: ?*const fn (*anyopaque, *vxfw.EventContext, Action) anyerror!void = null,
    header_open: bool = false,
    header_selected: usize = 0,
    keybindings_open: bool = false,
    binding_selected: usize = 0,
    capturing: bool = false,
    binding_error: ?anyerror = null,
    dirty: bool = false,
    selected: usize,
    path: []const u8,
    failure: ?anyerror,
    flatpak_checked: bool,
    flatpak_available: bool,
    checking: bool,
    busy: bool,
    pane: enum { full, controls, details } = .full,

    pub fn appendContent(self: View, ctx: vxfw.DrawContext, children: *std.ArrayList(vxfw.SubSurface)) Allocator.Error!void {
        const size = ctx.max.size();
        const body = try ctx.arena.create(View);
        body.* = self;
        const content: vxfw.Widget = .{ .userdata = body, .drawFn = drawBody };
        const labels = [_]Border.BorderLabel{.{ .text = if (self.dirty) "Settings · Unsaved changes" else "Settings", .alignment = .top_left }};
        var border: Border = .{ .child = content, .labels = &labels, .style = styles.emphasis };
        const height = size.height -| 2;
        try children.append(ctx.arena, .{
            .origin = .{ .row = 1, .col = 0 },
            .surface = if (size.width >= 80 and height >= 10)
                try content.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = height }))
            else if (size.width >= 2 and height >= 2)
                try border.draw(ctx.withConstraints(.{ .width = size.width, .height = height }, .{ .width = size.width, .height = height }))
            else
                try content.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = height })),
        });
    }

    fn backendStatus(self: View) []const u8 {
        return if (self.checking) "Checking…" else if (!self.flatpak_checked) "Not checked" else if (self.flatpak_available) "Available" else "Unavailable or check failed";
    }

    fn drawBody(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *const View = @ptrCast(@alignCast(ptr));
        const size = ctx.max.size();
        if (self.pane == .full and size.width >= 80 and size.height >= 10) return self.drawSplit(ptr, ctx);
        if (self.pane == .details) return self.drawDetails(ptr, ctx);
        if (self.keybindings_open and self.pane != .controls) return keybindings_view.draw(.{ .config = self.settings.keybindings, .selected = self.binding_selected, .capturing = self.capturing, .failure = self.binding_error orelse self.failure, .busy = self.busy }, ctx);
        const widget: vxfw.Widget = .{ .userdata = ptr, .drawFn = drawBody };
        if (size.width == 0 or size.height == 0) return .{ .size = size, .widget = widget, .buffer = &.{}, .children = &.{} };
        const width = if (self.pane == .controls) size.width else @min(size.width, 72);
        const col = (size.width - width) / 2;
        const line_ctx = ctx.withConstraints(.{}, .{ .width = width, .height = 1 });
        var children: std.ArrayList(vxfw.SubSurface) = .empty;
        const path_height: u16 = if (self.pane == .full and size.height >= 14) 1 else 0;
        const description_height: u16 = if (self.pane == .controls) 0 else if (size.height >= 10) 2 else if (size.height >= 6) 1 else 0;
        const error_height: u16 = if (self.pane == .full and size.height >= 4 and (self.failure != null or self.busy)) 1 else 0;
        const action_height: u16 = if (self.pane == .controls) 0 else if (size.height >= 2) (if (width >= 38 or size.height < 4) 1 else 2) else if (self.selected >= preferences.save_index) 1 else 0;
        const actions_row = size.height - path_height - action_height;
        const description_row = actions_row - error_height - description_height;
        const form_height = description_row;

        var rows: std.ArrayList(Row) = .empty;
        const form = [_]struct { heading: ?[]const u8 = null, control: ?usize = null }{
            .{ .heading = "Package sources" }, .{ .control = 0 },                              .{ .control = 1 },                             .{ .control = preferences.atoll_index },
            .{ .heading = "" },                .{ .heading = "Appearance and accessibility" }, .{ .control = preferences.header_index },      .{ .control = preferences.screenshots_index },
            .{ .heading = "" },                .{ .heading = "Keyboard" },                     .{ .control = preferences.keybindings_index },
        };
        var selected_line: usize = 0;
        for (form) |item| {
            if (item.heading) |heading| {
                try rows.append(ctx.arena, .{ .text = heading, .emphasis = true });
                continue;
            }
            const index = item.control.?;
            const selected = self.selected == index and (!self.header_open or self.pane == .controls);
            if (selected) selected_line = rows.items.len;
            try rows.append(ctx.arena, .{ .text = try self.controlText(ctx.arena, index), .action = .{ .control = index }, .selected = selected });
            if (index == preferences.header_index and self.header_open and self.pane == .full) {
                for (preferences.header_styles, 0..) |style, option| {
                    if (option == self.header_selected) selected_line = rows.items.len;
                    try rows.append(ctx.arena, .{
                        .text = try std.fmt.allocPrint(ctx.arena, "    ({s}) {s}", .{ if (style == self.settings.header_icons) "x" else " ", style.title() }),
                        .action = .{ .header = option },
                        .selected = option == self.header_selected,
                    });
                }
            }
        }
        if (self.selected >= preferences.save_index) selected_line = rows.items.len - 1;
        const visible = @min(rows.items.len, form_height);
        const first = @min(selected_line -| (visible / 2), rows.items.len - visible);
        for (rows.items[first .. first + visible], 0..) |item, offset|
            try self.appendRow(line_ctx, &children, @intCast(offset), col, item);

        if (description_height > 0) {
            var detail_text: vxfw.Text = .{ .text = try self.description(ctx.arena), .softwrap = true, .overflow = .ellipsis, .width_basis = .parent, .style = styles.secondary };
            try children.append(ctx.arena, .{ .origin = .{ .row = @intCast(description_row), .col = @intCast(col) }, .surface = try detail_text.draw(ctx.withConstraints(.{}, .{ .width = width, .height = description_height })) });
        }
        if (error_height > 0) try self.appendRow(line_ctx, &children, actions_row - 1, col, .{ .text = if (self.busy) "Settings are locked while an operation is running." else try std.fmt.allocPrint(ctx.arena, "Settings error: {s}", .{@errorName(self.failure.?)}), .emphasis = true });
        if (action_height > 0) {
            if (width >= 38) {
                try self.appendRow(line_ctx.withConstraints(.{}, .{ .width = 16, .height = 1 }), &children, actions_row, col, self.actionRow(preferences.save_index));
                try self.appendRow(line_ctx.withConstraints(.{}, .{ .width = 19, .height = 1 }), &children, actions_row, col + 19, self.actionRow(preferences.discard_index));
            } else if (action_height == 2) {
                try self.appendRow(line_ctx, &children, actions_row, col, self.actionRow(preferences.save_index));
                try self.appendRow(line_ctx, &children, actions_row + 1, col, self.actionRow(preferences.discard_index));
            } else try self.appendRow(line_ctx, &children, actions_row, col, self.actionRow(if (self.selected == preferences.discard_index) preferences.discard_index else preferences.save_index));
        }
        if (path_height > 0) try self.appendRow(line_ctx, &children, size.height - 1, col, .{ .text = try std.fmt.allocPrint(ctx.arena, "File: {f}", .{diagnostics.safe(self.path)}) });
        return .{ .size = size, .widget = widget, .buffer = &.{}, .children = children.items };
    }

    fn drawSplit(self: *const View, ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        const path_height: u16 = if (size.height >= 14) 1 else 0;
        const actions_row = size.height - path_height - 1;
        const left_width = @min(@as(u16, 48), @import("split_layout.zig").listWidth(size.width, 40));
        var children: std.ArrayList(vxfw.SubSurface) = .empty;
        for ([_]bool{ false, true }) |right| {
            const pane = try ctx.arena.create(View);
            pane.* = self.*;
            pane.pane = if (right) .details else .controls;
            const labels = [_]Border.BorderLabel{.{ .text = if (!right) (if (self.dirty) "Settings · Unsaved changes" else "Settings") else if (self.keybindings_open) "Keybindings" else if (self.header_open) "Header icons" else "Setting details", .alignment = .top_left }};
            var border: Border = .{ .child = .{ .userdata = pane, .drawFn = drawBody }, .labels = &labels, .style = styles.emphasis };
            const width = if (right) size.width - left_width else left_width;
            try children.append(ctx.arena, .{ .origin = .{ .row = 0, .col = if (right) @intCast(left_width) else 0 }, .surface = try border.draw(ctx.withConstraints(.{ .width = width, .height = actions_row }, .{ .width = width, .height = actions_row })) });
        }
        const line_ctx = ctx.withConstraints(.{}, .{ .width = 16, .height = 1 });
        try self.appendRow(line_ctx, &children, actions_row, 1, self.actionRow(preferences.save_index));
        try self.appendRow(line_ctx.withConstraints(.{}, .{ .width = 19, .height = 1 }), &children, actions_row, 20, self.actionRow(preferences.discard_index));
        if (path_height > 0) try self.appendRow(ctx.withConstraints(.{}, .{ .width = size.width - 2, .height = 1 }), &children, size.height - 1, 1, .{ .text = try std.fmt.allocPrint(ctx.arena, "File: {f}", .{diagnostics.safe(self.path)}) });
        return .{ .size = size, .widget = .{ .userdata = ptr, .drawFn = drawBody }, .buffer = &.{}, .children = children.items };
    }

    fn drawDetails(self: *const View, ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        if (self.keybindings_open) return keybindings_view.draw(.{ .config = self.settings.keybindings, .selected = self.binding_selected, .capturing = self.capturing, .failure = self.binding_error orelse self.failure, .busy = self.busy }, ctx);
        const size = ctx.max.size();
        const error_height: u16 = if (size.height > 0 and (self.failure != null or self.busy)) 1 else 0;
        const available = size.height - error_height;
        var children: std.ArrayList(vxfw.SubSurface) = .empty;
        const text_height: u16 = if (self.header_open) @min(available -| 3, 2) else available;
        if (text_height > 0) {
            var text: vxfw.Text = .{ .text = try self.description(ctx.arena), .softwrap = true, .overflow = .ellipsis, .width_basis = .parent, .style = styles.secondary };
            try children.append(ctx.arena, .{ .origin = .{ .row = 0, .col = 0 }, .surface = try text.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = text_height })) });
        }
        if (self.header_open) for (preferences.header_styles, 0..) |style, index| {
            const row: u16 = @intCast(text_height + index);
            if (row >= available) break;
            try self.appendRow(ctx.withConstraints(.{}, .{ .width = size.width, .height = 1 }), &children, row, 0, .{ .text = try std.fmt.allocPrint(ctx.arena, "({s}) {s}", .{ if (style == self.settings.header_icons) "x" else " ", style.title() }), .action = .{ .header = index }, .selected = index == self.header_selected });
        };
        if (error_height > 0) try self.appendRow(ctx.withConstraints(.{}, .{ .width = size.width, .height = 1 }), &children, size.height - 1, 0, .{ .text = if (self.busy) "Settings are locked while an operation is running." else try std.fmt.allocPrint(ctx.arena, "Settings error: {s}", .{@errorName(self.failure.?)}), .emphasis = true });
        return .{ .size = size, .widget = .{ .userdata = ptr, .drawFn = drawBody }, .buffer = &.{}, .children = children.items };
    }

    fn actionRow(self: *const View, index: usize) Row {
        return .{ .text = if (index == preferences.save_index) "[ Save changes ]" else "[ Discard changes ]", .action = .{ .control = index }, .selected = self.selected == index, .emphasis = self.dirty };
    }

    fn controlText(self: *const View, arena: Allocator, index: usize) Allocator.Error![]const u8 {
        if (index == preferences.header_index) return std.fmt.allocPrint(arena, "Header icons       {s} {s}", .{ self.settings.header_icons.title(), if (self.header_open) "▴" else "▾" });
        if (index == preferences.keybindings_index) return "[ Configure keybindings… ]";
        const enabled = switch (index) {
            0 => self.settings.aur_enabled,
            1 => self.settings.flatpak_enabled,
            preferences.atoll_index => self.settings.atoll_aur_enabled,
            else => self.settings.show_flatpak_screenshots,
        };
        const title = switch (index) {
            0 => "Enable AUR",
            1 => "Enable Flatpak",
            preferences.atoll_index => "Use Atoll-backed AUR",
            else => "Show Flatpak screenshots",
        };
        return std.fmt.allocPrint(arena, "[{s}] {s}", .{ if (enabled) "x" else " ", title });
    }

    fn description(self: *const View, arena: Allocator) Allocator.Error![]const u8 {
        if (self.header_open) return switch (preferences.header_styles[self.header_selected]) {
            .none => "Show page names without icons.",
            .nerd_font => "Nerd Font icons require a compatible font in your terminal.",
            .ascii => "Use ASCII symbols alongside page names.",
        };
        return switch (self.selected) {
            0 => "Show AUR searches, installed packages, and updates.",
            1 => try std.fmt.allocPrint(arena, "Show Flatpak applications and updates. Backend: {s}.", .{self.backendStatus()}),
            preferences.atoll_index => "Use Shelly's shared AUR mirror and scan Atoll PKGBUILD previews.",
            preferences.header_index => "Choose text-only, Nerd Font, or ASCII page headers.",
            preferences.screenshots_index => "Show images in Flatpak details when the terminal supports them.",
            preferences.keybindings_index => "Configure shortcuts without changing navigation or authentication input.",
            preferences.save_index => "Save and apply all pending preferences and keybinding edits.",
            else => "Discard pending edits and return to the currently active settings.",
        };
    }

    fn appendRow(self: *const View, ctx: vxfw.DrawContext, children: *std.ArrayList(vxfw.SubSurface), row: u16, col: u16, item: Row) Allocator.Error!void {
        const control = try ctx.arena.create(Control);
        control.* = .{ .view = self, .row = item };
        try children.append(ctx.arena, .{ .origin = .{ .row = @intCast(row), .col = @intCast(col) }, .surface = try control.widget().draw(ctx) });
    }
};

const Row = struct { text: []const u8, action: ?Action = null, selected: bool = false, emphasis: bool = false };
const Control = struct {
    view: *const View,
    row: Row,
    fn widget(self: *Control) vxfw.Widget {
        return .{ .userdata = self, .eventHandler = handleEvent, .drawFn = draw };
    }
    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Control = @ptrCast(@alignCast(ptr));
        var text: vxfw.Text = .{ .text = self.row.text, .softwrap = false, .overflow = .ellipsis, .width_basis = .parent, .style = if (self.row.selected and !self.view.busy) styles.selected else if (self.row.emphasis) styles.emphasis else styles.secondary };
        var surface = try text.draw(ctx);
        surface.widget = self.widget();
        return surface;
    }
    fn handleEvent(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Control = @ptrCast(@alignCast(ptr));
        if (event != .mouse or self.view.busy) return;
        const mouse = event.mouse;
        if (mouse.button != .left or mouse.type != .press) return;
        const action = self.row.action orelse return;
        const callback = self.view.on_action orelse return;
        try callback(self.view.userdata orelse return, ctx, action);
    }
};

const LayoutTest = struct {
    fn check(surface: vxfw.Surface) !bool {
        var highlighted = false;
        for (surface.buffer) |cell| {
            try std.testing.expect(std.unicode.utf8ValidateSlice(cell.char.grapheme));
            highlighted = highlighted or cell.style.reverse;
        }
        for (surface.children) |child| {
            try std.testing.expect(child.origin.row >= 0 and child.origin.col >= 0);
            try std.testing.expect(child.origin.row + child.surface.size.height <= surface.size.height);
            try std.testing.expect(child.origin.col + child.surface.size.width <= surface.size.width);
            highlighted = try check(child.surface) or highlighted;
        }
        return highlighted;
    }
    fn contains(surface: vxfw.Surface, text: []const u8, arena: Allocator) !bool {
        var chars: std.ArrayList(u8) = .empty;
        for (surface.buffer) |cell| try chars.appendSlice(arena, cell.char.grapheme);
        if (std.mem.indexOf(u8, chars.items, text) != null) return true;
        for (surface.children) |child| if (try contains(child.surface, text, arena)) return true;
        return false;
    }
};

test "grouped form keeps focused controls and actions within small layouts" {
    vxfw.DrawContext.init(.unicode);
    for ([_]u16{ 0, 1, 20, 40, 80 }) |width| for ([_]u16{ 0, 1, 2, 4, 8, 18 }) |height| for (0..preferences.discard_index + 1) |selected| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var view: View = .{ .settings = .{}, .selected = selected, .header_open = selected == preferences.header_index, .header_selected = 2, .path = "/settings.json", .failure = error.InvalidSettings, .flatpak_checked = false, .flatpak_available = false, .checking = false, .busy = false };
        const surface = try View.drawBody(&view, .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = height }, .cell_size = .{ .width = 10, .height = 20 } });
        const highlighted = try LayoutTest.check(surface);
        if (width > 0 and height > 0) try std.testing.expect(highlighted);
    };
}

test "Save and Discard stay at the same position as form focus scrolls" {
    vxfw.DrawContext.init(.unicode);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for (0..preferences.save_index) |selected| {
        var view: View = .{ .settings = .{}, .selected = selected, .path = "settings.json", .failure = null, .flatpak_checked = false, .flatpak_available = false, .checking = false, .busy = false };
        const surface = try View.drawBody(&view, .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 10 }, .cell_size = .{ .width = 10, .height = 20 } });
        var found: usize = 0;
        for (surface.children) |child| {
            var text: std.ArrayList(u8) = .empty;
            for (child.surface.buffer) |cell| try text.appendSlice(arena.allocator(), cell.char.grapheme);
            if (std.mem.indexOf(u8, text.items, "[ Save changes ]") != null or std.mem.indexOf(u8, text.items, "[ Discard changes ]") != null) {
                try std.testing.expectEqual(@as(i17, 9), child.origin.row);
                found += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 2), found);
    }
}

test "wide settings keep controls left and expand editors only on the right" {
    vxfw.DrawContext.init(.unicode);
    const Mode = enum { details, header, bindings };
    for ([_]Mode{ .details, .header, .bindings }) |mode| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var view: View = .{ .settings = .{}, .selected = if (mode == .bindings) preferences.keybindings_index else preferences.header_index, .header_open = mode == .header, .header_selected = 1, .keybindings_open = mode == .bindings, .path = "settings.json", .failure = null, .flatpak_checked = false, .flatpak_available = false, .checking = false, .busy = false };
        const surface = try View.drawBody(&view, .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 120, .height = 24 }, .cell_size = .{ .width = 10, .height = 20 } });
        _ = try LayoutTest.check(surface);
        const left = surface.children[0];
        const right = surface.children[1];
        try std.testing.expectEqual(@as(i17, 0), left.origin.col);
        try std.testing.expectEqual(@as(i17, left.surface.size.width), right.origin.col);
        try std.testing.expectEqual(@as(u16, 120), left.surface.size.width + right.surface.size.width);
        try std.testing.expect(try LayoutTest.contains(left.surface, "Enable AUR", arena.allocator()));
        try std.testing.expect(try LayoutTest.contains(left.surface, "Configure keybindings", arena.allocator()));
        if (mode == .header) {
            try std.testing.expect(try LayoutTest.contains(right.surface, "Nerd Font", arena.allocator()));
            try std.testing.expect(try LayoutTest.contains(right.surface, "ASCII", arena.allocator()));
            try std.testing.expect(!try LayoutTest.contains(left.surface, "( ) Nerd Font", arena.allocator()));
        } else if (mode == .bindings) {
            try std.testing.expect(try LayoutTest.contains(right.surface, "Quit", arena.allocator()));
            try std.testing.expect(try LayoutTest.contains(right.surface, "Ctrl+C", arena.allocator()));
        } else try std.testing.expect(try LayoutTest.contains(right.surface, "Choose text-only", arena.allocator()));
        try std.testing.expect(try LayoutTest.contains(surface.children[2].surface, "Save changes", arena.allocator()));
        try std.testing.expect(try LayoutTest.contains(surface.children[3].surface, "Discard changes", arena.allocator()));
    }
}

test "expanded settings survive repeated wide and narrow draws" {
    vxfw.DrawContext.init(.unicode);
    var view: View = .{ .settings = .{}, .selected = preferences.keybindings_index, .keybindings_open = true, .binding_selected = keybindings_view.back_index, .path = "settings.json", .failure = null, .flatpak_checked = false, .flatpak_available = false, .checking = false, .busy = false };
    for ([_]u16{ 120, 40, 80, 1, 120 }) |width| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const surface = try View.drawBody(&view, .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 20 }, .cell_size = .{ .width = 10, .height = 20 } });
        try std.testing.expect(try LayoutTest.check(surface));
        try std.testing.expectEqual(keybindings_view.back_index, view.binding_selected);
        try std.testing.expect(view.keybindings_open);
        if (width >= 80) try std.testing.expect(try LayoutTest.contains(surface.children[0].surface, "Enable AUR", arena.allocator()));
    }
}
