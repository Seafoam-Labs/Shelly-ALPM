//! Tab labels, centered layout, and mouse hit testing. Navigation policy belongs to the caller.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const styles = @import("styles.zig");
const HeaderIcons = @import("../models/settings.zig").HeaderIcons;
const Allocator = std.mem.Allocator;

pub const Tab = enum {
    packages,
    aur,
    flatpak,
    appimage,
    upgrade,
    settings,

    pub const always: []const Tab = &.{ .packages, .upgrade, .settings };

    pub const all: []const Tab = &.{ .packages, .aur, .flatpak, .appimage, .upgrade, .settings };

    pub fn title(self: Tab) []const u8 {
        return switch (self) {
            .packages => "Packages",
            .aur => "AUR",
            .upgrade => "Updates",
            .flatpak => "Flatpak",
            .appimage => "AppImage",
            .settings => "Settings",
        };
    }
    pub fn icon(self: Tab, style: HeaderIcons) []const u8 {
        return switch (style) {
            .none => "",
            // Nerd Fonts mappings: Octicons package/sync/gear, Font Logos Arch,
            // and Font Awesome cube. See nerd-fonts/bin/scripts/lib upstream.
            .nerd_font => switch (self) {
                .packages => "\u{f487}",
                .aur => "\u{f303}",
                .flatpak => "\u{f1b2}",
                .appimage => "\u{f085}",
                .upgrade => "\u{f46a}",
                .settings => "\u{f423}",
            },
            .ascii => switch (self) {
                .packages => "[#]",
                .aur => "[*]",
                .flatpak => "[F]",
                .appimage => "[A]",
                .upgrade => "[^]",
                .settings => "[=]",
            },
        };
    }
};

pub const Options = struct {
    tabs: []const Tab,
    active: Tab,
    header_icons: HeaderIcons = .none,
    userdata: *anyopaque,
    on_select: *const fn (*anyopaque, *vxfw.EventContext, Tab) anyerror!void,
};

pub fn create(arena: Allocator, options: Options) Allocator.Error!vxfw.Widget {
    const tabs = options.tabs;
    const spans = try arena.alloc(vxfw.RichText.TextSpan, tabs.len);
    for (tabs, 0..) |tab, i| {
        const icon = tab.icon(options.header_icons);
        const separator = if (options.header_icons == .nerd_font) "\u{2002}" else " ";
        spans[i] = .{
            .text = if (icon.len > 0) try std.fmt.allocPrint(arena, " {s}{s}{s} ", .{ icon, separator, tab.title() }) else try std.fmt.allocPrint(arena, " {s} ", .{tab.title()}),
            .style = if (tab == options.active)
                styles.selected
            else
                styles.secondary,
        };
    }
    const bar = try arena.create(TabBar);
    bar.* = .{
        .active = options.active,
        .userdata = options.userdata,
        .on_select = options.on_select,
        .tabs = try arena.dupe(Tab, tabs),
        .rich = .{ .text = spans, .softwrap = false },
    };
    return bar.widget();
}

/// A compact centered bar with a filled highlight for the selected tab.
pub const TabBar = struct {
    active: Tab,
    userdata: *anyopaque,
    on_select: *const fn (*anyopaque, *vxfw.EventContext, Tab) anyerror!void,
    tabs: []const Tab,
    rich: vxfw.RichText,
    first_visible: usize = 0,
    start_col: i16 = 0,
    label_row: i16 = 0,
    label_widths: []const u16 = &.{},

    pub fn widget(self: *TabBar) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = handleEvent,
            .drawFn = drawFn,
        };
    }

    pub fn drawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *TabBar = @ptrCast(@alignCast(ptr));
        const size = ctx.max.size();
        const framed = size.height >= 3 and size.width >= 8;
        const padding: usize = if (framed) 4 else 0;
        const width = size.width -| @as(u16, if (framed) 8 else 0);
        const caps: usize = 0;
        var active: usize = 0;
        for (self.tabs, 0..) |tab, index| {
            if (tab == self.active) active = index;
        }
        var first: usize = 0;
        var end = self.tabs.len;
        var total: usize = (self.tabs.len -| 1) + caps;
        for (self.rich.text) |span| total += ctx.stringWidth(span.text);
        while (total > width and end - first > 1) {
            if (active - first > end - 1 - active) {
                total -= ctx.stringWidth(self.rich.text[first].text) + 1;
                first += 1;
            } else {
                end -= 1;
                total -= ctx.stringWidth(self.rich.text[end].text) + 1;
            }
        }
        const spans = try ctx.arena.dupe(vxfw.RichText.TextSpan, self.rich.text[first..end]);
        const truncated = total > width;
        if (truncated) {
            const label = std.mem.trim(u8, spans[0].text, " ");
            var iterator = ctx.graphemeIterator(label);
            var bytes: usize = 0;
            var columns: usize = 0;
            while (iterator.next()) |grapheme| {
                const text = grapheme.bytes(label);
                const cells = ctx.stringWidth(text);
                if (columns + cells > width -| caps) break;
                bytes += text.len;
                columns += cells;
            }
            spans[0].text = label[0..bytes];
            total = columns + caps;
        }
        self.first_visible = first;
        self.rich.text = spans;
        const label_widths = try ctx.arena.alloc(u16, spans.len);
        for (spans, label_widths) |span, *label_width| label_width.* = @intCast(ctx.stringWidth(span.text));
        self.label_widths = label_widths;
        const island_width: u16 = @intCast(total + padding);
        const island_col = (size.width - island_width) / 2;
        self.start_col = @intCast(island_col + padding / 2);
        self.label_row = if (size.height >= 3) 1 else 0;
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        @memset(surface.buffer, .{});
        if (framed) {
            const edge = island_col + island_width - 1;
            surface.writeCell(island_col, 0, .{ .char = .{ .grapheme = "┌", .width = 1 } });
            surface.writeCell(edge, 0, .{ .char = .{ .grapheme = "┐", .width = 1 } });
            surface.writeCell(island_col, 2, .{ .char = .{ .grapheme = "└", .width = 1 } });
            surface.writeCell(edge, 2, .{ .char = .{ .grapheme = "┘", .width = 1 } });
            surface.writeCell(island_col, 1, .{ .char = .{ .grapheme = "│", .width = 1 } });
            surface.writeCell(edge, 1, .{ .char = .{ .grapheme = "│", .width = 1 } });
            for (island_col + 1..edge) |col| {
                for ([_]u16{ 0, 2 }) |row| surface.writeCell(@intCast(col), row, .{ .char = .{ .grapheme = "─", .width = 1 } });
            }
        }
        var col: u16 = @intCast(self.start_col);
        for (spans) |span| {
            var iterator = ctx.graphemeIterator(span.text);
            while (iterator.next()) |grapheme| {
                const text = grapheme.bytes(span.text);
                const cells: u8 = @intCast(ctx.stringWidth(text));
                surface.writeCell(col, @intCast(self.label_row), .{
                    .char = .{ .grapheme = text, .width = cells },
                    .style = span.style,
                });
                col += cells;
            }
            col +|= 1;
        }
        return surface;
    }

    pub fn handleEvent(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *TabBar = @ptrCast(@alignCast(ptr));
        switch (event) {
            // Mouse coordinates arrive local to this surface
            .mouse => |mouse| {
                if (mouse.button != .left or mouse.type != .press) return;
                if (mouse.row != self.label_row or mouse.col < self.start_col) return;
                var col = self.start_col;
                for (self.label_widths, 0..) |label_width, i| {
                    const width: i16 = @intCast(label_width);
                    if (mouse.col >= col and mouse.col < col + width) {
                        try self.on_select(self.userdata, ctx, self.tabs[self.first_visible + i]);
                        return ctx.consumeAndRedraw();
                    }
                    col += width + 1;
                }
            },
            else => {},
        }
    }
};

const Fixture = struct {
    tabs: []const Tab = Tab.always,
    active: Tab = .packages,
    header_icons: HeaderIcons = .none,

    fn drawTabBar(self: *Fixture, arena: Allocator) !vxfw.Widget {
        return create(arena, .{ .tabs = self.tabs, .active = self.active, .header_icons = self.header_icons, .userdata = self, .on_select = select });
    }

    fn select(ptr: *anyopaque, _: *vxfw.EventContext, selected: Tab) !void {
        const self: *Fixture = @ptrCast(@alignCast(ptr));
        self.active = selected;
    }
};

test "tab bar centers labels and retains the active tab on narrow terminals" {
    vxfw.DrawContext.init(.unicode);
    var fixture: Fixture = .{};
    const model = &fixture;
    model.tabs = Tab.all;
    model.active = .settings;
    for ([_]HeaderIcons{ .none, .nerd_font, .ascii }) |style| {
        model.header_icons = style;
        for ([_]u16{ 120, 80, 40, 18, 3, 1 }) |width| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const widget = try model.drawTabBar(arena.allocator());
            const surface = try widget.draw(.{
                .arena = arena.allocator(),
                .min = .{},
                .max = .{ .width = width, .height = 3 },
                .cell_size = .{ .width = 10, .height = 20 },
            });
            for (surface.buffer) |cell| {
                try std.testing.expect(std.unicode.utf8ValidateSlice(cell.char.grapheme));
                try std.testing.expect(cell.image == null);
            }
            try std.testing.expectEqual(width, surface.size.width);
            try std.testing.expectEqual(@as(u16, 3), surface.size.height);
            const bar: *TabBar = @ptrCast(@alignCast(widget.userdata));
            try std.testing.expect(bar.first_visible + bar.rich.text.len > 4);
            var total: usize = bar.rich.text.len -| 1;
            for (bar.label_widths) |label_width| total += label_width;
            const padding: usize = if (width >= 8) 4 else 0;
            try std.testing.expectEqual(@as(i16, @intCast((width - total - padding) / 2 + padding / 2)), bar.start_col);
            try std.testing.expect(bar.rich.text[bar.rich.text.len - 1].style.reverse);
            if (width >= 8) {
                var corners: usize = 0;
                var caps: usize = 0;
                for (surface.buffer) |cell| {
                    if (std.mem.eql(u8, cell.char.grapheme, "┌") or std.mem.eql(u8, cell.char.grapheme, "┐")) corners += 1;
                    if (std.mem.eql(u8, cell.char.grapheme, "◖") or std.mem.eql(u8, cell.char.grapheme, "◗")) caps += 1;
                }
                try std.testing.expectEqual(@as(usize, 2), corners);
                try std.testing.expectEqual(@as(usize, 0), caps);
            }
        }
    }
}

test "centered tab mouse targets exclude borders and padding" {
    vxfw.DrawContext.init(.unicode);
    var fixture: Fixture = .{};
    const model = &fixture;
    for ([_]HeaderIcons{ .none, .nerd_font, .ascii }) |style| {
        model.active = .packages;
        model.header_icons = style;
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const widget = try model.drawTabBar(arena.allocator());
        _ = try widget.draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 100, .height = 3 }, .cell_size = .{ .width = 10, .height = 20 } });
        const bar: *TabBar = @ptrCast(@alignCast(widget.userdata));
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
        defer ctx.cmds.deinit(std.testing.allocator);
        var col = bar.start_col;
        for (bar.label_widths[0 .. bar.label_widths.len - 1]) |label_width| col += @intCast(label_width + 1);
        try TabBar.handleEvent(bar, &ctx, .{ .mouse = .{ .button = .left, .type = .press, .col = @intCast(col), .row = 0, .mods = .{} } });
        try std.testing.expectEqual(Tab.packages, model.active);
        try TabBar.handleEvent(bar, &ctx, .{ .mouse = .{ .button = .left, .type = .press, .col = 0, .row = 1, .mods = .{} } });
        try std.testing.expectEqual(Tab.packages, model.active);
        try TabBar.handleEvent(bar, &ctx, .{ .mouse = .{ .button = .left, .type = .press, .col = @intCast(col), .row = 1, .mods = .{} } });
        try std.testing.expectEqual(Tab.settings, model.active);
    }
}

test "header labels default to raw text and use Nerd Font glyphs only when enabled" {
    vxfw.DrawContext.init(.unicode);
    var fixture: Fixture = .{};
    const model = &fixture;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const widget = try model.drawTabBar(arena.allocator());
    const bar: *TabBar = @ptrCast(@alignCast(widget.userdata));
    try std.testing.expectEqualStrings(" Packages ", bar.rich.text[0].text);
    try std.testing.expectEqualStrings(" Updates ", bar.rich.text[1].text);
    try std.testing.expectEqualStrings(" Settings ", bar.rich.text[2].text);
    model.header_icons = .nerd_font;
    const icons_widget = try model.drawTabBar(arena.allocator());
    const icons_bar: *TabBar = @ptrCast(@alignCast(icons_widget.userdata));
    try std.testing.expect(std.mem.indexOf(u8, icons_bar.rich.text[0].text, "\u{f487}") != null);
    try std.testing.expect(std.mem.indexOf(u8, icons_bar.rich.text[1].text, "\u{f46a}") != null);
    try std.testing.expect(std.mem.indexOf(u8, icons_bar.rich.text[2].text, "\u{f423}") != null);
}

test "Nerd Font icons have an explicit spacer on first draw and tab changes" {
    vxfw.DrawContext.init(.unicode);
    var fixture: Fixture = .{};
    const model = &fixture;
    model.tabs = Tab.all;
    model.header_icons = .nerd_font;
    for (Tab.all) |active| {
        model.active = active;
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const widget = try model.drawTabBar(arena.allocator());
        const surface = try widget.draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 120, .height = 3 }, .cell_size = .{ .width = 10, .height = 20 } });
        var icons: usize = 0;
        for (surface.buffer, 0..) |cell, index| {
            for (Tab.all) |tab| {
                if (!std.mem.eql(u8, cell.char.grapheme, tab.icon(.nerd_font))) continue;
                icons += 1;
                try std.testing.expectEqual(tab == active, cell.style.bold);
                try std.testing.expectEqual(tab == active, cell.style.reverse);
                const spacer = surface.buffer[index + cell.char.width];
                try std.testing.expectEqualStrings("\u{2002}", spacer.char.grapheme);
                try std.testing.expectEqual(@as(u8, 1), spacer.char.width);
                try std.testing.expect(vaxis.Style.eql(cell.style, spacer.style));
            }
        }
        try std.testing.expectEqual(Tab.all.len, icons);
        const bar: *TabBar = @ptrCast(@alignCast(widget.userdata));
        for (bar.rich.text, bar.tabs) |span, tab|
            try std.testing.expectEqual(tab == active, span.style.bold);
    }
}
