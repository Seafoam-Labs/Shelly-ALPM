const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const commands = @import("../commands.zig");
const Border = @import("border.zig");
const Allocator = std.mem.Allocator;

pub const Panel = struct {
    context: commands.Context = .{},
    scroll: vxfw.ScrollView = .{ .children = .{ .slice = &.{} } },
    initialized: bool = false,

    pub fn handleKey(self: *Panel, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        if (commands.scrollKey(key)) |canonical| try self.scroll.handleEvent(ctx, .{ .key_press = canonical });
    }

    pub fn draw(self: *Panel, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        if (!self.initialized) {
            self.scroll = .{ .item_count = 1, .children = .{ .builder = .{ .userdata = self, .buildFn = buildBody } } };
            self.initialized = true;
        }
        const size = ctx.max.size();
        if (size.width < 2 or size.height < 2) {
            var tiny: vxfw.Text = .{ .text = "Help" };
            return tiny.draw(ctx);
        }
        const labels = [_]Border.BorderLabel{.{ .text = "Help", .alignment = .top_left }};
        var border: Border = .{ .child = self.scroll.widget(), .labels = &labels, .style = .{ .fg = .{ .index = 7 }, .bold = true } };
        return border.draw(ctx.withConstraints(size, .{ .width = size.width, .height = size.height }));
    }

    fn buildBody(ptr: *const anyopaque, index: usize, _: usize) ?vxfw.Widget {
        if (index != 0) return null;
        return .{ .userdata = @constCast(ptr), .drawFn = drawBody };
    }

    pub fn text(self: *const Panel, arena: Allocator) Allocator.Error![]const u8 {
        var lines: std.ArrayList([]const u8) = .empty;
        const heading: []const u8 = switch (self.context.mode) {
            .search => "Packages — search",
            .packages => "Packages — list",
            .details => "Package details",
            .aur => "AUR browsing",
            .flatpak => "Flatpak browsing",
            .updates => "Updates",
            .settings => "Settings",
            .authentication => "Authentication",
            .confirmation => "Confirmation",
            .running => "Operation progress",
            .result => "Operation result",
            .review => "Operation review",
            .preview_document => "PKGBUILD preview",
            .answers => "Operation choices",
            .choice => "Remote and scope",
            .help => "Help",
        };
        try lines.appendSlice(arena, &.{ heading, "" });
        if (self.context.mode == .running) try lines.append(arena, "The operation continues while help is open.");
        for (try commands.entries(arena, self.context)) |entry| {
            try lines.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ try commands.label(arena, entry.id), entry.description }));
        }
        if (self.context.mode == .search) try lines.append(arena, "While editing search, letters and Left/Right edit the text.");
        if (self.context.mode == .authentication) try lines.append(arena, "Ordinary text enters the password. Help never submits or clears it.");
        try lines.appendSlice(arena, &.{ "", "Application", "" });
        const globals = [_]struct { id: commands.Id, description: []const u8 }{
            .{ .id = .help, .description = "Open/close help; return to the previous focus" },
            .{ .id = .next_tab, .description = "Next enabled page (while browsing)" },
            .{ .id = .previous_tab, .description = "Previous enabled page (while browsing)" },
            .{ .id = .quit, .description = "Quit the application" },
            .{ .id = .interrupt, .description = "Quit the application" },
        };
        for (globals) |entry| try lines.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ try commands.label(arena, entry.id), entry.description }));
        if (self.context.tab_count > 0) try lines.append(arena, try std.fmt.allocPrint(arena, "Alt+1…Alt+{d}: Select an enabled page (while browsing)", .{self.context.tab_count}));
        return std.mem.join(arena, "\n", lines.items);
    }

    fn drawBody(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *const Panel = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse ctx.min.width;
        var spans: std.ArrayList(vxfw.RichText.TextSpan) = .empty;
        var lines = std.mem.splitScalar(u8, try self.text(ctx.arena), '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, ": ")) |separator| {
                try spans.append(ctx.arena, .{ .text = line[0 .. separator + 1], .style = .{ .bold = true, .fg = .{ .index = 7 } } });
                try spans.append(ctx.arena, .{ .text = line[separator + 1 ..], .style = .{ .fg = .{ .index = 250 } } });
            } else try spans.append(ctx.arena, .{ .text = line, .style = .{ .bold = true, .fg = .{ .index = 7 } } });
            try spans.append(ctx.arena, .{ .text = "\n" });
        }
        var rich: vxfw.RichText = .{ .text = spans.items, .softwrap = true };
        return rich.draw(ctx.withConstraints(.{ .width = width }, .{ .width = width, .height = null }));
    }
};
