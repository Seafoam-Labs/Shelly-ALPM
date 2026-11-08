const styles = @import("styles.zig");
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Border = @import("border.zig");
const preferences = @import("../models/settings.zig");
const Settings = preferences.Settings;
const diagnostics = @import("diagnostics");
const Allocator = std.mem.Allocator;

pub const View = struct {
    settings: Settings,
    dirty: bool = false,
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
        const labels = [_]Border.BorderLabel{.{ .text = if (self.dirty) "Settings · Unsaved changes" else "Settings", .alignment = .top_left }};
        var border: Border = .{ .child = content, .labels = &labels, .style = styles.emphasis };
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
        const show_path = size.height >= 8;
        const form_height = size.height - @as(u16, if (show_path) 2 else 0);
        const content_ctx = ctx.withConstraints(.{}, .{ .width = width, .height = form_height });
        var children: std.ArrayList(vxfw.SubSurface) = .empty;
        var row: u16 = 0;
        const detailed = form_height >= 17;
        if (detailed) {
            row += 1;
            try appendText(content_ctx, &children, &row, col, "Preferences", styles.emphasis);
            row += 1;
        }
        for (0..preferences.save_index) |index| {
            // Retain the active control in compact layouts, including Save.
            if (form_height < preferences.save_index + 1 and index != self.selected) continue;
            if (index == preferences.header_style_start and form_height >= preferences.save_index + 2) try appendText(content_ctx, &children, &row, col, "Header icons", styles.secondary);
            const is_style = index >= preferences.header_style_start and index < preferences.screenshots_index;
            const enabled = switch (index) {
                0 => self.settings.aur_enabled,
                1 => self.settings.flatpak_enabled,
                preferences.atoll_index => self.settings.atoll_aur_enabled,
                else => self.settings.show_flatpak_screenshots,
            };
            const title = if (is_style)
                try std.fmt.allocPrint(ctx.arena, "  ({s}) {s}", .{ if (self.settings.header_icons == preferences.header_styles[index - preferences.header_style_start]) "x" else " ", preferences.header_styles[index - preferences.header_style_start].title() })
            else
                try std.fmt.allocPrint(ctx.arena, "[{s}] {s}", .{ if (enabled) "x" else " ", if (index == 0) "AUR" else if (index == 1) "Flatpak" else if (index == preferences.atoll_index) "Enable Atoll-backed AUR" else "Show Flatpak screenshots" });
            try appendText(content_ctx, &children, &row, col, title, .{ .bold = true, .reverse = self.selected == index and !self.busy });
            if (detailed and (!is_style or index == 3)) {
                try appendText(content_ctx, &children, &row, col, switch (index) {
                    0 => "Show AUR searches, installed packages, and updates.",
                    1 => "Show Flatpak applications, installed packages, and updates.",
                    preferences.atoll_index => "Use the shared CLI AUR source and scan Atoll PKGBUILD previews.",
                    3 => "Nerd Font icons require a compatible terminal font.",
                    else => "Display images in Flatpak details when supported.",
                }, styles.secondary);
                if (form_height >= 23) row += 1;
            }
        }
        try appendText(content_ctx, &children, &row, col, "[ Save changes ]", .{
            .bold = self.dirty,
            .reverse = self.selected == preferences.save_index and !self.busy,
        });
        if (self.failure) |err| {
            try appendText(content_ctx, &children, &row, col, try std.fmt.allocPrint(ctx.arena, "Settings error: {s}. Review your changes and retry.", .{@errorName(err)}), styles.emphasis);
        }
        if (self.busy) try appendText(content_ctx, &children, &row, col, "Settings are locked while an operation is running.", styles.emphasis);
        if (self.settings.flatpak_enabled) {
            if (detailed) row += 1;
            try appendText(content_ctx, &children, &row, col, try std.fmt.allocPrint(ctx.arena, "Flatpak backend: {s}", .{self.backendStatus()}), styles.secondary);
        }
        if (show_path) {
            var path: vxfw.Text = .{
                .text = try std.fmt.allocPrint(ctx.arena, "File: {f}", .{diagnostics.safe(self.path)}),
                .style = styles.secondary,
                .text_align = .center,
                .width_basis = .parent,
                .softwrap = false,
                .overflow = .ellipsis,
            };
            try children.append(ctx.arena, .{
                .origin = .{ .row = @intCast(size.height - 1), .col = 0 },
                .surface = try path.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = 1 })),
            });
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
