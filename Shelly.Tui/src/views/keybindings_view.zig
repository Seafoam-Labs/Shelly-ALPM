//! A window onto the editable commands.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const commands = @import("../commands.zig");
const keybindings = @import("../services/keybindings.zig");
const styles = @import("styles.zig");
const Allocator = std.mem.Allocator;

pub const restore_index = keybindings.editable.len;
pub const save_index = restore_index + 1;
pub const back_index = save_index + 1;
pub const row_count = back_index + 1;

pub const View = struct {
    config: keybindings.Config,
    selected: usize,
    capturing: bool,
    failure: ?anyerror,
    busy: bool,
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
    const width = @min(size.width, 80);
    const col = (size.width - width) / 2;
    const line_ctx = ctx.withConstraints(.{}, .{ .width = width, .height = 1 });
    var children: std.ArrayList(vxfw.SubSurface) = .empty;
    const header: u16 = if (size.height >= 4) 2 else 0;
    const status: u16 = if (size.height >= 3 and (view.failure != null or view.busy)) 1 else 0;
    if (header > 0) {
        try line(line_ctx, &children, 0, col, try std.fmt.allocPrint(ctx.arena, "Keybindings · {d}/{d}", .{ view.selected + 1, row_count }), styles.emphasis);
        try line(line_ctx, &children, 1, col, if (view.capturing) "Press a replacement key." else "Changes take effect when saved.", styles.secondary);
    }
    const visible = @min(row_count, size.height - header - status);
    var first = view.selected -| (visible / 2);
    first = @min(first, row_count - visible);
    for (first..first + visible) |index| {
        const text = if (index < keybindings.editable.len) blk: {
            const id = keybindings.editable[index];
            const label = if (view.capturing and index == view.selected) "…" else try commands.keyLabel(ctx.arena, view.config.get(id));
            break :blk try std.fmt.allocPrint(ctx.arena, "{s:<24} {s}", .{ title(id), label });
        } else switch (index) {
            restore_index => "[ Restore all defaults ]",
            save_index => "[ Save changes ]",
            back_index => "[ Back to preferences ]",
            else => unreachable,
        };
        try line(line_ctx, &children, @intCast(header + index - first), col, text, if (index == view.selected and !view.busy) styles.selected else styles.secondary);
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
        .narrow_view => "Narrow package list",
        .widen_view => "Widen package list",
        else => unreachable,
    };
}

test "editor keeps selected rows visible within tiny and scrolling layouts" {
    vxfw.DrawContext.init(.unicode);
    for ([_]u16{ 0, 1, 20, 80 }) |width| for ([_]u16{ 0, 1, 3, 8, 24 }) |height| for ([_]usize{ 0, 12, back_index }) |selected| {
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
