const std = @import("std");
const vxfw = @import("vaxis").vxfw;
const Settings = @import("../models/settings.zig").Settings;
const diagnostics = @import("diagnostics");
const commands = @import("../commands.zig");

pub const View = struct {
    settings: Settings,
    selected: usize,
    path: []const u8,
    failure: ?anyerror,
    flatpak_checked: bool,
    flatpak_available: bool,
    checking: bool,
    busy: bool,

    pub fn appendContent(self: View, ctx: vxfw.DrawContext, children: *std.ArrayList(vxfw.SubSurface)) std.mem.Allocator.Error!void {
        const backend = if (self.checking) "checking…" else if (!self.flatpak_checked) "not checked" else if (self.flatpak_available) "available" else "unavailable or check failed";
        const failure = if (self.failure) |err| try std.fmt.allocPrint(ctx.arena, "\nSettings error: {s}. The saved file was left intact.\nR: reload after correcting the file.", .{@errorName(err)}) else "";
        const text = try std.fmt.allocPrint(ctx.arena, "Package sources\n\n{s} AUR:     {s}\n{s} Flatpak: {s} (backend: {s})\n\nSystem packages are always enabled.\nChanges are saved before being applied.\n\nSettings file: {f}\n{s}\n\n{s}", .{ if (self.selected == 0) ">" else " ", if (self.settings.aur_enabled) "enabled" else "disabled", if (self.selected == 1) ">" else " ", if (self.settings.flatpak_enabled) "enabled" else "disabled", backend, diagnostics.safe(self.path), failure, if (self.busy) "Settings are locked while an operation is running." else commands.settings_hint });
        var label: vxfw.Text = .{ .text = text };
        const size = ctx.max.size();
        try children.append(ctx.arena, .{ .origin = .{ .row = 1, .col = 0 }, .surface = try label.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height -| 2 })) });
    }
};
