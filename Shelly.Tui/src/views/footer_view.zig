const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const commands = @import("../commands.zig");
const Allocator = std.mem.Allocator;

/// Render current key labels rather than embedding shortcuts in status strings.
pub fn draw(ctx: vxfw.DrawContext, context: commands.Context, status: ?[]const u8) Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    const help_label = try std.fmt.allocPrint(ctx.arena, "{s} {s}", .{ try commands.label(ctx.arena, .help), if (context.mode == .help) "Back" else "Help" });
    const help_width: u16 = @intCast(@min(size.width, ctx.stringWidth(help_label)));
    const main_width = size.width -| (help_width + 2);
    var spans: std.ArrayList(vxfw.RichText.TextSpan) = .empty;
    var used: usize = 0;
    const prefix = status orelse if (context.selected_count > 0)
        try std.fmt.allocPrint(ctx.arena, "{d} selected · {d} installed · {d} available  ", .{ context.selected_count, context.selected_installed, context.selected_count - context.selected_installed })
    else
        "";
    if (prefix.len > 0) {
        try spans.append(ctx.arena, .{ .text = prefix, .style = .{ .fg = .{ .index = 250 } } });
        used = ctx.stringWidth(prefix);
    }
    for (try commands.entries(ctx.arena, context)) |entry| {
        if (entry.id == .mark or (context.mode == .search and (entry.id == .install or entry.id == .remove))) continue;
        if (entry.id == .next) continue;
        const key = if (entry.id == .previous)
            try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ try commands.label(ctx.arena, .previous), try commands.label(ctx.arena, .next) })
        else
            try commands.label(ctx.arena, entry.id);
        const short = if (entry.id == .previous) switch (context.mode) {
            .search, .packages, .aur, .flatpak, .updates => "Browse",
            .settings, .choice => "Select",
            else => "Scroll",
        } else entry.short;
        const description = try std.fmt.allocPrint(ctx.arena, " {s}  ", .{short});
        const width = ctx.stringWidth(key) + ctx.stringWidth(description);
        if (used + width > main_width) continue;
        try spans.append(ctx.arena, .{ .text = key, .style = .{ .fg = .{ .index = 7 }, .bold = true } });
        try spans.append(ctx.arena, .{ .text = description, .style = .{ .fg = .{ .index = 250 } } });
        used += width;
    }
    var main: vxfw.RichText = .{ .text = spans.items, .softwrap = false, .overflow = .ellipsis };
    var help: vxfw.Text = .{ .text = help_label, .softwrap = false, .style = .{ .fg = .{ .index = 7 }, .bold = true } };
    const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try main.draw(ctx.withConstraints(.{}, .{ .width = main_width, .height = 1 })) };
    children[1] = .{ .origin = .{ .row = 0, .col = @intCast(size.width - help_width) }, .surface = try help.draw(ctx.withConstraints(.{}, .{ .width = help_width, .height = 1 })) };
    return .{ .size = size, .widget = help.widget(), .buffer = &.{}, .children = children };
}
