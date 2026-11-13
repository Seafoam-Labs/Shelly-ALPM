//! A window onto the editable commands.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const commands = @import("../commands.zig");
const keybindings = @import("../services/keybindings.zig");
const styles = @import("styles.zig");
const Allocator = std.mem.Allocator;

pub const row_count = keybindings.editable.len;

const Section = struct { name: []const u8, ids: []const commands.Id };
const sections = [_]Section{
    .{ .name = "General", .ids = &.{ .quit, .help, .next_tab, .previous_tab, .refresh, .narrow_view, .widen_view } },
    .{ .name = "Packages", .ids = &.{ .install, .remove, .refresh_list, .filter, .clear_selection } },
    .{ .name = "Updates", .ids = &.{ .upgrade_all, .upgrade_system, .upgrade_aur, .upgrade_flatpak } },
    .{ .name = "AUR catalog", .ids = &.{ .previous_catalog_page, .next_catalog_page } },
    .{ .name = "Flatpak details", .ids = &.{ .categories, .previous_screenshot, .next_screenshot } },
    .{ .name = "PKGBUILD", .ids = &.{ .preview, .toggle_wrap } },
    .{ .name = "AppImages", .ids = &.{.configure_updates} },
    .{ .name = "File picker", .ids = &.{.toggle_hidden} },
};

fn commandIndex(id: commands.Id) usize {
    for (keybindings.editable, 0..) |candidate, index| if (candidate == id) return index;
    unreachable;
}

pub fn displayPosition(selected: usize) usize {
    var offset: usize = 0;
    for (sections) |section| for (section.ids) |id| {
        if (commandIndex(id) == selected) return offset;
        offset += 1;
    };
    unreachable;
}

/// Keep navigation in the same order as the grouped display.
pub fn adjacent(selected: usize, forward: bool) ?usize {
    var order: [row_count]usize = undefined;
    var count: usize = 0;
    for (sections) |section| for (section.ids) |id| {
        order[count] = commandIndex(id);
        count += 1;
    };
    for (order, 0..) |index, position| if (index == selected) {
        if (forward) return if (position + 1 < order.len) order[position + 1] else null;
        return order[(position + order.len - 1) % order.len];
    };
    unreachable;
}

pub const View = struct {
    config: keybindings.Config,
    selected: usize,
    capturing: bool,
    failure: ?anyerror,
    busy: bool,
    focused: bool = true,
};

pub fn draw(view: View, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const owned = try ctx.arena.create(View);
    owned.* = view;
    return drawBody(owned, ctx);
}

fn drawBody(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const view: *const View = @ptrCast(@alignCast(ptr));
    const size = ctx.max.size();
    const widget: vxfw.Widget = .{ .userdata = ptr, .drawFn = drawBody };
    if (size.width == 0 or size.height == 0) return .{ .size = size, .widget = widget, .buffer = &.{}, .children = &.{} };
    const width = size.width;
    const col: u16 = 0;
    const line_ctx = ctx.withConstraints(.{}, .{ .width = width, .height = 1 });
    var children: std.ArrayList(vxfw.SubSurface) = .empty;
    var labels: [keybindings.editable.len][]const u8 = undefined;
    var key_width: u16 = 0;
    for (keybindings.editable, 0..) |id, index| {
        labels[index] = try commands.keyLabel(ctx.arena, view.config.get(id));
        key_width = @max(key_width, @as(u16, @intCast(ctx.stringWidth(labels[index]))));
    }
    const gap: u16 = 1;
    // Stack rows when columns would leave fewer than 12 cells for names.
    const stacked = width < key_width + gap + 12;
    const status: u16 = if (size.height >= 3 and (view.failure != null or view.busy)) 1 else 0;
    const available = size.height - status;
    const row_height: usize = if (stacked and available >= 2) 2 else 1;
    const DisplayRow = struct { section: usize, command: ?usize = null, continuation: bool = false };
    var rows: std.ArrayList(DisplayRow) = .empty;
    var selected_row: usize = 0;
    for (sections, 0..) |section, section_index| {
        try rows.append(ctx.arena, .{ .section = section_index });
        for (section.ids) |id| {
            const index = commandIndex(id);
            if (index == view.selected) selected_row = rows.items.len;
            try rows.append(ctx.arena, .{ .section = section_index, .command = index });
            if (row_height == 2) try rows.append(ctx.arena, .{ .section = section_index, .command = index, .continuation = true });
        }
    }
    var first = (selected_row + row_height) -| available;
    var sticky: usize = if (rows.items[first].command != null and available > row_height) 1 else 0;
    if (sticky > 0) first = (selected_row + row_height) -| (available - sticky);
    if (rows.items[first].command == null) sticky = 0;
    if (sticky > 0) try line(line_ctx, &children, 0, col, sections[rows.items[first].section].name, styles.emphasis);
    const visible = @min(rows.items.len - first, available - sticky);
    for (rows.items[first .. first + visible], 0..) |item, offset| {
        const row: u16 = @intCast(sticky + offset);
        const index = item.command orelse {
            try line(line_ctx, &children, row, col, sections[item.section].name, styles.emphasis);
            continue;
        };
        const selected = index == view.selected and view.focused and !view.busy;
        const style = if (selected) styles.selected else styles.secondary;
        const label = if (view.capturing and index == view.selected) "…" else labels[index];
        const name = title(keybindings.editable[index]);
        const binding_style = if (selected) styles.selected else styles.emphasis;
        if (stacked) {
            try line(line_ctx, &children, row, col, if (item.continuation or row_height == 1) label else name, if (item.continuation or row_height == 1) binding_style else style);
        } else {
            const name_width = @min(24, width - key_width - gap);
            try line(line_ctx.withConstraints(.{}, .{ .width = name_width, .height = 1 }), &children, row, col, name, style);
            try line(line_ctx.withConstraints(.{}, .{ .width = key_width, .height = 1 }), &children, row, col + name_width + gap, label, binding_style);
        }
    }
    if (status > 0) try line(line_ctx, &children, size.height - 1, col, if (view.failure) |err| errorText(err) else "Settings are locked while an operation is running.", styles.emphasis);
    return .{ .size = size, .widget = widget, .buffer = &.{}, .children = children.items };
}

fn line(ctx: vxfw.DrawContext, children: *std.ArrayList(vxfw.SubSurface), row: u16, col: u16, text: []const u8, style: vaxis.Style) Allocator.Error!void {
    var label: vxfw.Text = .{ .text = text, .style = style, .softwrap = false, .overflow = .ellipsis, .width_basis = .parent };
    try children.append(ctx.arena, .{ .origin = .{ .row = @intCast(row), .col = @intCast(col) }, .surface = try label.draw(ctx) });
}

fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.ReservedBinding => "Reserved for navigation, confirmation, or text editing. Try another key.",
        error.ConflictingBinding => "Already assigned to another action in this context. Try another key.",
        error.TextInputConflict => "Use Ctrl, Alt, or a function key for actions active in text fields.",
        error.InvalidKey => "Unsupported key. Use ASCII or function keys; Shift+letters is unsupported.",
        else => @errorName(err),
    };
}

fn title(id: commands.Id) []const u8 {
    return switch (id) {
        .quit => "Quit",
        .help => "Help",
        .next_tab => "Next tab",
        .previous_tab => "Previous tab",
        .configure_updates => "Configure update source",
        .install => "Install",
        .remove => "Remove",
        .preview => "PKGBUILD preview",
        .refresh => "Refresh / Reload",
        .refresh_list => "Refresh package list",
        .filter => "All / Installed",
        .upgrade_all => "Update all",
        .upgrade_system => "Update system",
        .upgrade_aur => "Update AUR",
        .upgrade_flatpak => "Update Flatpak",
        .categories => "Flatpak categories",
        .previous_catalog_page => "Previous AUR page",
        .next_catalog_page => "Next AUR page",
        .previous_screenshot => "Previous screenshot",
        .next_screenshot => "Next screenshot",
        .clear_selection => "Clear selections",
        .toggle_wrap => "Toggle source wrapping",
        .narrow_view => "Narrow left panel",
        .widen_view => "Widen left panel",
        .toggle_hidden => "Show hidden files",
        else => unreachable,
    };
}

test "editor keeps selected rows visible within tiny and scrolling layouts" {
    vxfw.DrawContext.init(.unicode);
    for ([_]u16{ 0, 1, 20, 80 }) |width| for ([_]u16{ 0, 1, 3, 8, 24 }) |height| for ([_]usize{ 0, 12, row_count - 1 }) |selected| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const surface = try draw(.{ .config = .{}, .selected = selected, .capturing = false, .failure = error.ConflictingBinding, .busy = false }, .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = height }, .cell_size = .{ .width = 10, .height = 20 } });
        var highlighted = false;
        for (surface.children) |child| {
            try std.testing.expect(child.origin.row >= 0 and child.origin.col >= 0);
            try std.testing.expect(child.origin.row + child.surface.size.height <= height);
            try std.testing.expect(child.origin.col + child.surface.size.width <= width);
            for (child.surface.buffer) |cell| {
                try std.testing.expect(std.unicode.utf8ValidateSlice(cell.char.grapheme));
                highlighted = highlighted or cell.style.reverse;
            }
        }
        if (width > 0 and height > 0) try std.testing.expect(highlighted);
    };
}

test "narrow editors show complete bindings and keep command names alongside them" {
    vxfw.DrawContext.init(.unicode);
    const config = try (keybindings.Config{}).withBinding(.help, .{ .codepoint = vaxis.Key.f35, .mods = .{ .ctrl = true, .alt = true, .shift = true } });
    for ([_]u16{ 20, 30, 40, 80 }) |width| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const surface = try draw(.{ .config = config, .selected = 1, .capturing = false, .failure = null, .busy = false }, .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 12 }, .cell_size = .{ .width = 10, .height = 20 } });
        var name_row: ?i17 = null;
        var binding_row: ?i17 = null;
        for (surface.children) |child| {
            var text: std.ArrayList(u8) = .empty;
            var selected = false;
            for (child.surface.buffer) |cell| {
                try text.appendSlice(arena.allocator(), cell.char.grapheme);
                selected = selected or cell.style.reverse;
            }
            if (!selected) continue;
            if (std.mem.indexOf(u8, text.items, "Help") != null) name_row = child.origin.row;
            if (std.mem.indexOf(u8, text.items, "Ctrl+Alt+Shift+F35") != null) binding_row = child.origin.row;
        }
        try std.testing.expect(name_row != null and binding_row != null);
        if (width <= 30) {
            try std.testing.expect(binding_row.? > name_row.?);
        } else try std.testing.expectEqual(name_row, binding_row);
    }
}

test "grouped navigation visits every editable command exactly once" {
    var visited: [row_count]bool = @splat(false);
    var current: ?usize = commandIndex(.quit);
    var count: usize = 0;
    while (current) |index| {
        try std.testing.expect(!visited[index]);
        visited[index] = true;
        try std.testing.expectEqual(count, displayPosition(index));
        count += 1;
        current = adjacent(index, true);
    }
    try std.testing.expectEqual(row_count, count);
}
