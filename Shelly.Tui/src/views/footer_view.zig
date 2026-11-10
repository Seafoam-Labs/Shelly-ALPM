const styles = @import("styles.zig");
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const commands = @import("../commands.zig");
const Allocator = std.mem.Allocator;

const Shortcut = struct {
    key: []const u8,
    description: []const u8,
    width: usize,
};

/// Render current key labels rather than embedding shortcuts in status strings.
pub fn draw(ctx: vxfw.DrawContext, context: commands.Context, status: ?[]const u8) Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    const help_label = if (context.settings_capture) "" else try std.fmt.allocPrint(ctx.arena, "{s} {s}", .{ try commands.label(ctx.arena, .help), if (context.mode == .help) "Back" else "Help" });
    const help_width: u16 = @intCast(@min(size.width, ctx.stringWidth(help_label)));
    const main_width = size.width -| (help_width + @as(u16, if (help_width > 0) 2 else 0));
    var shortcuts: std.ArrayList(Shortcut) = .empty;
    for (try commands.entries(ctx.arena, context)) |entry| {
        // Resizing stays discoverable in help without crowding the footer.
        if (entry.id == .narrow_view or entry.id == .widen_view) continue;
        if ((entry.id == .mark and context.mode != .answers) or (context.mode == .search and (entry.id == .install or entry.id == .remove))) continue;
        if (entry.id == .next) continue;
        if (entry.id == .save_settings and context.mode == .settings and context.settings_save_selected) continue;
        // Keep alternative bindings in help instead of repeating actions.
        if (entry.id == .close and (context.mode == .review or context.mode == .result or context.mode == .confirmation)) continue;
        const key = if (entry.id == .previous)
            try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ try commands.label(ctx.arena, .previous), try commands.label(ctx.arena, .next) })
        else
            try commands.label(ctx.arena, entry.id);
        const short = if (entry.id == .previous) switch (context.mode) {
            .search, .packages, .aur, .flatpak => "Browse",
            .settings, .choice, .answers => "Select",
            else => "Scroll",
        } else entry.short;
        const description = try std.fmt.allocPrint(ctx.arena, " {s}  ", .{short});
        try shortcuts.append(ctx.arena, .{
            .key = key,
            .description = description,
            .width = ctx.stringWidth(key) + ctx.stringWidth(description),
        });
    }
    if (!context.quit_blocked and !context.settings_capture) {
        const quit_key = try commands.label(ctx.arena, .quit);
        try shortcuts.append(ctx.arena, .{
            .key = quit_key,
            .description = " Quit",
            .width = ctx.stringWidth(quit_key) + ctx.stringWidth(" Quit"),
        });
    }
    var shortcut_width: usize = 0;
    for (shortcuts.items) |shortcut| shortcut_width += shortcut.width;

    // Notices take priority over shortcuts. Selection summaries use leftover space.
    var summary: []const u8 = "";
    if (status) |notice| {
        if (notice.len > 0) summary = notice;
    }
    if (summary.len == 0 and context.selected_count > 0) {
        const full_summary = try std.fmt.allocPrint(ctx.arena, "{d} selected · {d} installed · {d} available  ", .{ context.selected_count, context.selected_installed, context.selected_count - context.selected_installed });
        if (ctx.stringWidth(full_summary) + shortcut_width <= main_width) {
            summary = full_summary;
        } else {
            const brief_summary = try std.fmt.allocPrint(ctx.arena, "{d} selected  ", .{context.selected_count});
            if (ctx.stringWidth(brief_summary) + shortcut_width <= main_width) summary = brief_summary;
        }
    }

    var spans: std.ArrayList(vxfw.RichText.TextSpan) = .empty;
    if (summary.len > 0) try spans.append(ctx.arena, .{ .text = summary, .style = styles.secondary });
    var used: usize = ctx.stringWidth(summary);
    for (shortcuts.items) |shortcut| {
        if (used + shortcut.width > main_width) continue;
        try spans.append(ctx.arena, .{ .text = shortcut.key, .style = styles.emphasis });
        try spans.append(ctx.arena, .{ .text = shortcut.description, .style = styles.secondary });
        used += shortcut.width;
    }
    var main: vxfw.RichText = .{ .text = spans.items, .softwrap = false, .overflow = .ellipsis };
    var help: vxfw.Text = .{ .text = help_label, .softwrap = false, .style = styles.emphasis };
    const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try main.draw(ctx.withConstraints(.{}, .{ .width = main_width, .height = 1 })) };
    children[1] = .{ .origin = .{ .row = 0, .col = @intCast(size.width - help_width) }, .surface = try help.draw(ctx.withConstraints(.{}, .{ .width = help_width, .height = 1 })) };
    return .{ .size = size, .widget = help.widget(), .buffer = &.{}, .children = children };
}

test "footer reflects operation context and live wrapping state" {
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const contexts = [_]commands.Context{
        .{ .mode = .preview_document, .source_wrap = true },
        .{ .mode = .preview_document, .source_wrap = false },
        .{ .mode = .authentication },
        .{ .mode = .answers, .multiple_choices = true },
        .{ .mode = .review },
        .{ .mode = .running },
        .{ .mode = .running, .quit_blocked = true },
    };
    for (contexts, [_][]const u8{ "Unwrap", "Wrap", "Run", "Toggle", "Approve", "Quit", "Help" }) |context, expected| {
        const surface = try draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 140, .height = 1 }, .cell_size = .{ .width = 10, .height = 20 } }, context, null);
        var text: std.ArrayList(u8) = .empty;
        for (surface.children) |child| for (child.surface.buffer) |cell| try text.appendSlice(arena.allocator(), cell.char.grapheme);
        try std.testing.expect(std.mem.indexOf(u8, text.items, expected) != null);
        try std.testing.expect(std.mem.indexOf(u8, text.items, "F1 Help") != null);
        if (context.quit_blocked) try std.testing.expect(std.mem.indexOf(u8, text.items, "Quit") == null);
        if (context.mode == .review) try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text.items, "Decline"));
    }
}

test "footer keeps a status notice visible when shortcuts crowd the line" {
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const surface = try draw(.{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 80, .height = 1 },
        .cell_size = .{ .width = 10, .height = 20 },
    }, .{ .mode = .search }, "The system is locked by another operation");
    var text: std.ArrayList(u8) = .empty;
    for (surface.children) |child| for (child.surface.buffer) |cell| try text.appendSlice(arena.allocator(), cell.char.grapheme);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "locked by another operation") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "F1 Help") != null);
}

const FooterTest = struct {
    fn visible_text(allocator: Allocator, surface: vxfw.Surface) Allocator.Error![]const u8 {
        var text: std.ArrayList(u8) = .empty;
        for (surface.children) |child| {
            for (child.surface.buffer) |cell| try text.appendSlice(allocator, cell.char.grapheme);
        }
        return text.items;
    }
    fn draw_footer(allocator: Allocator, context: commands.Context, status: ?[]const u8, width: usize) Allocator.Error!vxfw.Surface {
        vxfw.DrawContext.init(.unicode);
        return draw(.{
            .arena = allocator,
            .min = .{},
            .max = .{ .width = @intCast(width), .height = 1 },
            .cell_size = .{ .width = 10, .height = 20 },
        }, context, status);
    }
    fn check_bounds(surface: vxfw.Surface, width: usize) void {
        const surface_width: usize = @intCast(surface.size.width);
        const surface_height: usize = @intCast(surface.size.height);
        std.debug.assert(surface_width == width);
        std.debug.assert(surface_height == 1);
        for (surface.children) |child| {
            const col: usize = @intCast(child.origin.col);
            const row: usize = @intCast(child.origin.row);
            const child_width: usize = @intCast(child.surface.size.width);
            const child_height: usize = @intCast(child.surface.size.height);
            std.debug.assert(col + child_width <= width);
            std.debug.assert(row == 0);
            std.debug.assert(child_height <= 1);
        }
    }
};

test "footer selection summary never displaces shortcuts that fit unselected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const baseline_context: commands.Context = .{ .mode = .details, .installable = true, .removable = true };
    var selected_context = baseline_context;
    selected_context.selected_count = 2;
    selected_context.selected_installed = 1;
    for ([_]usize{ 32, 48, 70, 100 }) |width| {
        const baseline = try FooterTest.visible_text(allocator, try FooterTest.draw_footer(allocator, baseline_context, null, width));
        const selected = try FooterTest.visible_text(allocator, try FooterTest.draw_footer(allocator, selected_context, null, width));
        const actions = [_]struct { id: commands.Id, description: []const u8 }{
            .{ .id = .install, .description = "Install" },
            .{ .id = .remove, .description = "Remove" },
            .{ .id = .close, .description = "Back" },
            .{ .id = .quit, .description = "Quit" },
        };
        for (actions) |action| {
            const shortcut = try std.fmt.allocPrint(allocator, "{s} {s}", .{ try commands.label(allocator, action.id), action.description });
            if (std.mem.indexOf(u8, baseline, shortcut) != null)
                try std.testing.expect(std.mem.indexOf(u8, selected, shortcut) != null);
            if (action.id == .install or action.id == .remove)
                try std.testing.expect(std.mem.indexOf(u8, baseline, shortcut) != null);
        }
        try std.testing.expect(std.mem.indexOf(u8, selected, "F1 Help") != null);
    }
}

test "footer selection summary scales down with the available width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const context = commands.Context{
        .mode = .search,
        .selected_count = 2,
        .selected_installed = 1,
    };
    const full = try FooterTest.draw_footer(arena.allocator(), context, null, 120);
    const full_text = try FooterTest.visible_text(arena.allocator(), full);
    try std.testing.expect(std.mem.indexOf(u8, full_text, " · ") != null);
    try std.testing.expect(std.mem.indexOf(u8, full_text, "available") != null);

    const brief = try FooterTest.draw_footer(arena.allocator(), context, null, 100);
    const brief_text = try FooterTest.visible_text(arena.allocator(), brief);
    try std.testing.expect(std.mem.indexOf(u8, brief_text, "selected") != null);
    try std.testing.expect(std.mem.indexOf(u8, brief_text, "available") == null);

    const omitted = try FooterTest.draw_footer(arena.allocator(), context, null, 74);
    const omitted_text = try FooterTest.visible_text(arena.allocator(), omitted);
    try std.testing.expect(std.mem.indexOf(u8, omitted_text, "selected") == null);
}

test "footer renders safely at zero and tiny widths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const context = commands.Context{
        .mode = .search,
        .selected_count = 2,
        .selected_installed = 1,
    };
    for ([_]usize{ 0, 1, 4, 8 }) |width| {
        const surface = try FooterTest.draw_footer(arena.allocator(), context, null, width);
        FooterTest.check_bounds(surface, width);
    }
}

test "footer status notice survives when shortcuts would consume the full width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const context = commands.Context{
        .mode = .search,
        .selected_count = 2,
        .selected_installed = 1,
    };
    const surface = try FooterTest.draw_footer(arena.allocator(), context, "The system is locked by another operation", 70);
    const text = try FooterTest.visible_text(arena.allocator(), surface);
    try std.testing.expect(std.mem.indexOf(u8, text, "locked by another operation") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "F1 Help") != null);
}

test "footer treats an empty status like a missing status" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for ([_]usize{ 0, 2 }) |count| {
        const context: commands.Context = .{
            .mode = .search,
            .selected_count = count,
            .selected_installed = count / 2,
        };
        for ([_]usize{ 0, 1, 4, 8, 74, 100, 120 }) |width| {
            const empty = try FooterTest.draw_footer(allocator, context, "", width);
            const missing = try FooterTest.draw_footer(allocator, context, null, width);
            try std.testing.expectEqualStrings(
                try FooterTest.visible_text(allocator, missing),
                try FooterTest.visible_text(allocator, empty),
            );
            if (count > 0 and width == 120)
                try std.testing.expect(std.mem.indexOf(u8, try FooterTest.visible_text(allocator, empty), "2 selected") != null);
        }
    }
}

test "footer reflects live command bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const approve_binding = commands.bindings.approve;
    defer commands.bindings.approve = approve_binding;
    commands.bindings.approve = .{ .codepoint = vaxis.Key.f2 };

    const surface = try FooterTest.draw_footer(arena.allocator(), commands.Context{ .mode = .review }, null, 40);
    const text = try FooterTest.visible_text(arena.allocator(), surface);
    try std.testing.expect(std.mem.indexOf(u8, text, "F2") != null);
}

test "key capture footer advertises only Escape instead of intercepted global actions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const surface = try FooterTest.draw_footer(arena.allocator(), .{ .mode = .settings, .settings_capture = true }, null, 80);
    const text = try FooterTest.visible_text(arena.allocator(), surface);
    try std.testing.expect(std.mem.indexOf(u8, text, "Esc Cancel") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Quit") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Help") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Save") == null);
}
