const std = @import("std");
const commands = @import("../commands.zig");
const diagnostics = @import("diagnostics");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const sync = @import("../models/sync.zig");
const Allocator = std.mem.Allocator;

/// Borrows query results and the list widget; Model owns their lifetimes.
pub const View = struct {
    list: *vxfw.ListView,
    data: ?*const sync.CheckUpdates,
    loading: bool,
    failed: bool,
    checked: bool,
    flatpak_available: bool = false,
    aur_enabled: bool = true,

    /// A full upgrade synchronizes sources again, even when the cached check is empty.
    pub fn canUpgradeAll(self: View) bool {
        return !self.loading and !self.failed and self.data != null;
    }

    pub fn canUpgrade(self: View) bool {
        return !self.loading and !self.failed and self.data != null and self.data.?.Packages.len > 0;
    }

    pub fn canUpgradeAur(self: View) bool {
        return self.aur_enabled and !self.loading and !self.failed and self.data != null and self.data.?.Aur.len > 0;
    }

    pub fn canUpgradeFlatpak(self: View) bool {
        return self.flatpak_available and !self.loading and !self.failed and self.data != null and self.data.?.Flatpak.len > 0;
    }

    pub fn handleKey(self: View, key: vaxis.Key) ?commands.Updates {
        const action = commands.updates(key) orelse return null;
        if (action == .upgrade_all and !self.canUpgradeAll()) return null;
        if (action == .upgrade_system and !self.canUpgrade()) return null;
        if (action == .upgrade_aur and !self.canUpgradeAur()) return null;
        if (action == .upgrade_flatpak and !self.canUpgradeFlatpak()) return null;
        return action;
    }

    pub fn statusText(self: View, arena: Allocator) Allocator.Error![]const u8 {
        if (self.loading) return "Checking for updates…";
        if (self.failed) return "Update check failed — R: retry";
        const hints = if (self.aur_enabled)
            if (self.flatpak_available) commands.flatpak_updates_hint else commands.updates_hint
        else if (self.flatpak_available) "G: all    U: system    F: Flatpak    R: refresh" else "G: all    U: system    R: refresh";
        if (self.data) |data| return std.fmt.allocPrint(arena, "{d} updates ({d} system, {d} AUR, {d} Flatpak) — {s}", .{
            data.count(), data.Packages.len, data.Aur.len, data.Flatpak.len, if (self.canUpgradeAll()) hints else "R: refresh",
        });
        return "R: check for updates";
    }

    pub fn appendContent(self: View, ctx: vxfw.DrawContext, children: *std.ArrayList(vxfw.SubSurface)) Allocator.Error!void {
        const max = ctx.max.size();
        var header: vxfw.Text = .{ .text = "Available updates — System / AUR / Flatpak / AppImage" };
        try children.append(ctx.arena, .{
            .origin = .{ .row = 1, .col = 0 },
            .surface = try header.draw(ctx.withConstraints(.{}, .{ .width = max.width, .height = 1 })),
        });
        const message: ?[]const u8 = if (self.loading)
            "Checking for updates…"
        else if (self.failed)
            "Could not check for updates. Press R to retry."
        else if (self.data) |data|
            if (data.count() == 0) "No updates reported." else null
        else if (!self.checked)
            "Press R to check for updates."
        else
            "No update data received.";
        if (message) |text| {
            var label: vxfw.Text = .{ .text = text };
            try children.append(ctx.arena, .{
                .origin = .{ .row = 2, .col = 0 },
                .surface = try label.draw(ctx.withConstraints(.{}, .{ .width = max.width, .height = max.height -| 3 })),
            });
        } else {
            try children.append(ctx.arena, .{
                .origin = .{ .row = 2, .col = 0 },
                .surface = try self.list.draw(ctx.withConstraints(.{}, .{ .width = max.width, .height = max.height -| 3 })),
            });
        }
    }
};

pub fn row(data: *const sync.CheckUpdates, index: usize) ?vxfw.Widget {
    if (index < data.Packages.len) return .{ .userdata = @constCast(&data.Packages[index]), .drawFn = drawNative };
    const aur_index = index - data.Packages.len;
    if (aur_index < data.Aur.len) return .{ .userdata = @constCast(&data.Aur[aur_index]), .drawFn = drawAur };
    const flatpak_index = aur_index - data.Aur.len;
    if (flatpak_index < data.Flatpak.len) return .{ .userdata = @constCast(&data.Flatpak[flatpak_index]), .drawFn = drawFlatpak };
    const appimage_index = flatpak_index - data.Flatpak.len;
    if (appimage_index < data.AppImage.len) return .{ .userdata = @constCast(&data.AppImage[appimage_index]), .drawFn = drawAppImage };
    return null;
}

fn drawText(ctx: vxfw.DrawContext, text: []const u8) Allocator.Error!vxfw.Surface {
    var label: vxfw.Text = .{ .text = text, .softwrap = false, .overflow = .ellipsis };
    return label.draw(ctx);
}

fn drawNative(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const pkg: *const sync.CheckUpdatesPackage = @ptrCast(@alignCast(ptr));
    return drawText(ctx, try std.fmt.allocPrint(ctx.arena, "[System] {f}/{f}  {f} → {f}", .{
        diagnostics.safe(pkg.Repository), diagnostics.safe(pkg.Name), diagnostics.safe(pkg.CurrentVersion), diagnostics.safe(pkg.NewVersion),
    }));
}

fn drawAur(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const pkg: *const sync.CheckUpdatesAur = @ptrCast(@alignCast(ptr));
    return drawText(ctx, try std.fmt.allocPrint(ctx.arena, "[AUR] {f}  {f} → {f}", .{
        diagnostics.safe(pkg.Name), diagnostics.safe(pkg.Version), diagnostics.safe(pkg.NewVersion),
    }));
}

fn drawFlatpak(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const pkg: *const sync.CheckUpdatesFlatpak = @ptrCast(@alignCast(ptr));
    return drawText(ctx, try std.fmt.allocPrint(ctx.arena, "[Flatpak:{s}] {f} ({f}/{f}, {f})  {f} → {f}", .{
        if (pkg.InstallLevel == 0) "system" else "user",
        diagnostics.safe(pkg.Id),
        diagnostics.safe(pkg.Arch),
        diagnostics.safe(pkg.Branch),
        diagnostics.safe(pkg.Remote),
        diagnostics.safe(pkg.Version),
        diagnostics.safe(if (pkg.NewVersion.len > 0) pkg.NewVersion else pkg.LatestCommit),
    }));
}

fn drawAppImage(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const pkg: *const @import("../models/appimage.zig").AppImageUpdate = @ptrCast(@alignCast(ptr));
    return drawText(ctx, try std.fmt.allocPrint(ctx.arena, "[AppImage] {f}  available: {f}", .{
        diagnostics.safe(pkg.Name), diagnostics.safe(pkg.Version),
    }));
}
