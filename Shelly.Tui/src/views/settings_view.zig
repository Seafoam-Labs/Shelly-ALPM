const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Border = @import("border.zig");
const Settings = @import("../models/settings.zig").Settings;
const diagnostics = @import("diagnostics");
const Allocator = std.mem.Allocator;

pub const View = struct {
    settings: Settings,
    selected: usize,
    path: []const u8,
    failure: ?anyerror,
    flatpak_checked: bool,
    flatpak_available: bool,
    checking: bool,
    busy: bool,

    pub fn appendContent(self: View, ctx: vxfw.DrawContext, children: *std.ArrayList(vxfw.SubSurface)) Allocator.Error!void {
        const size = ctx.max.size();
        const body = try ctx.arena.create(View);
        body.* = self;
        const content: vxfw.Widget = .{ .userdata = body, .drawFn = drawBody };
        const labels = [_]Border.BorderLabel{.{ .text = "Settings", .alignment = .top_left }};
        var border: Border = .{ .child = content, .labels = &labels, .style = .{ .fg = .{ .index = 7 }, .bold = true } };
        const height = size.height -| 2;
        try children.append(ctx.arena, .{
            .origin = .{ .row = 1, .col = 0 },
            .surface = if (size.width >= 2 and height >= 2)
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
        const widget: vxfw.Widget = .{ .userdata = ptr, .drawFn = drawBody };
        if (size.width == 0 or size.height == 0) return .{ .size = size, .widget = widget, .buffer = &.{}, .children = &.{} };
        const width = @min(size.width, 72);
        const col = (size.width - width) / 2;
        const content_ctx = ctx.withConstraints(.{}, .{ .width = width, .height = size.height });
        var children: std.ArrayList(vxfw.SubSurface) = .empty;
        var row: u16 = 0;
        const detailed = size.height >= 14;
        const bright: vaxis.Style = .{ .fg = .{ .index = 7 }, .bold = true };
        const muted: vaxis.Style = .{ .fg = .{ .index = 250 } };
        if (detailed) {
            row += 1;
            try appendText(content_ctx, &children, &row, col, "Package sources", bright);
            row += 1;
        }
        for (0..2) |index| {
            // Even a one-line viewport retains the active setting.
            if (size.height == 1 and index != self.selected) continue;
            const enabled = if (index == 0) self.settings.aur_enabled else self.settings.flatpak_enabled;
            const title = try std.fmt.allocPrint(ctx.arena, "[{s}] {s}", .{ if (enabled) "x" else " ", if (index == 0) "AUR" else "Flatpak" });
            try appendText(content_ctx, &children, &row, col, title, .{ .fg = .{ .index = 7 }, .bold = true, .reverse = self.selected == index and !self.busy });
            if (detailed) {
                try appendText(content_ctx, &children, &row, col, if (index == 0) "Show AUR searches, installed packages, and updates." else "Show Flatpak applications, installed packages, and updates.", muted);
                row += 1;
            }
        }
        // Errors and operation locks take precedence over secondary information.
        if (self.failure) |err| {
            if (detailed) row += 1;
            try appendText(content_ctx, &children, &row, col, try std.fmt.allocPrint(ctx.arena, "Settings error: {s}. The saved file was left intact.", .{@errorName(err)}), bright);
        }
        if (self.busy) try appendText(content_ctx, &children, &row, col, "Settings are locked while an operation is running.", bright);
        try appendText(content_ctx, &children, &row, col, try std.fmt.allocPrint(ctx.arena, "Flatpak backend: {s}", .{self.backendStatus()}), muted);
        if (detailed) row += 1;
        try appendText(content_ctx, &children, &row, col, "Changes are saved automatically.", muted);
        if (detailed) {
            row += 1;
            try appendText(content_ctx, &children, &row, col, "Configuration file", bright);
            try appendText(content_ctx, &children, &row, col, try std.fmt.allocPrint(ctx.arena, "{f}", .{diagnostics.safe(self.path)}), muted);
        }
        return .{ .size = size, .widget = widget, .buffer = &.{}, .children = children.items };
    }
};

fn appendText(ctx: vxfw.DrawContext, children: *std.ArrayList(vxfw.SubSurface), row: *u16, col: u16, text: []const u8, style: vaxis.Style) Allocator.Error!void {
    const size = ctx.max.size();
    if (row.* >= size.height) return;
    var label: vxfw.Text = .{ .text = text, .softwrap = true, .width_basis = .parent, .style = style };
    const surface = try label.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height - row.* }));
    try children.append(ctx.arena, .{ .origin = .{ .row = @intCast(row.*), .col = @intCast(col) }, .surface = surface });
    row.* += surface.size.height;
}
