const std = @import("std");
const diagnostics = @import("diagnostics");
const vxfw = @import("vaxis").vxfw;
const data = @import("../models/flatpak.zig");
const Allocator = std.mem.Allocator;
const formatSize = @import("detail_format.zig").formatSize;

pub const Row = union(enum) {
    catalog: *const data.AppstreamApp,
    installed: *const data.Flatpak,

    pub fn matches(self: Row, query: []const u8) bool {
        return switch (self) {
            .catalog => |app| contains(app.Id, query) or contains(app.Name, query) or contains(app.Summary, query),
            .installed => |app| contains(app.Id, query) or contains(app.Name, query) or contains(app.Summary, query) or contains(app.Remote, query),
        };
    }

    pub fn sameIdentity(self: Row, other: Row) bool {
        return switch (self) {
            .catalog => |app| other == .catalog and std.mem.eql(u8, app.Id, other.catalog.Id),
            .installed => |app| other == .installed and app.InstallLevel == other.installed.InstallLevel and
                app.Kind == other.installed.Kind and std.mem.eql(u8, app.Id, other.installed.Id) and
                std.mem.eql(u8, app.Arch, other.installed.Arch) and std.mem.eql(u8, app.Branch, other.installed.Branch) and
                std.mem.eql(u8, app.Remote, other.installed.Remote),
        };
    }

    pub fn widget(self: Row) vxfw.Widget {
        return switch (self) {
            .catalog => |app| .{ .userdata = @constCast(app), .drawFn = drawCatalog },
            .installed => |app| .{ .userdata = @constCast(app), .drawFn = drawInstalled },
        };
    }

    pub fn title(self: Row) []const u8 {
        return switch (self) {
            .catalog => |app| app.Id,
            .installed => |app| app.Id,
        };
    }

    pub fn details(self: Row, arena: Allocator) Allocator.Error![]const u8 {
        return switch (self) {
            .installed => |app| std.fmt.allocPrint(arena, "{f}\n\nName: {f}\nID: {f}\nVersion: {f}\nScope: {s}\nKind: {s}\nArchitecture: {f}\nBranch: {f}\nRemote: {f}\nRef: {f}\nFull ref: {f}\nInstalled size: {s}\n\nRead only — Q: close    Esc: quit", .{ diagnostics.safe(app.Summary), diagnostics.safe(app.Name), diagnostics.safe(app.Id), diagnostics.safe(app.Version), @tagName(app.InstallLevel), @tagName(app.Kind), diagnostics.safe(app.Arch), diagnostics.safe(app.Branch), diagnostics.safe(app.Remote), diagnostics.safe(app.Ref), diagnostics.safe(app.FullRef), try formatSize(arena, app.InstalledSize) }),
            .catalog => |app| blk: {
                var remotes: std.ArrayList(u8) = .empty;
                for (app.Remotes, 0..) |remote, i| {
                    const text = try std.fmt.allocPrint(arena, "{s}{f} ({s})", .{ if (i == 0) "" else ", ", diagnostics.safe(remote.Name), @tagName(remote.Scope) });
                    try remotes.appendSlice(arena, text);
                }
                break :blk std.fmt.allocPrint(arena, "{f}\n\nName: {f}\nID: {f}\nType: {f}\nDeveloper: {f}\nLicense: {f}\nVerified: {s}\nRemotes: {s}\n\n{f}\n\nCatalog metadata — installation status and permissions are not queried.\nQ: close    Esc: quit", .{ diagnostics.safe(app.Summary), diagnostics.safe(app.Name), diagnostics.safe(app.Id), diagnostics.safe(app.Type), diagnostics.safe(app.DeveloperName), diagnostics.safe(app.ProjectLicense), if (app.IsVerified) "yes" else "no", remotes.items, diagnostics.safe(app.Description) });
            },
        };
    }
};

fn contains(text: []const u8, query: []const u8) bool {
    if (query.len > text.len) return false;
    for (0..text.len - query.len + 1) |start|
        if (std.ascii.eqlIgnoreCase(text[start..][0..query.len], query)) return true;
    return false;
}

pub const View = struct {
    field: *vxfw.TextField,
    list: *vxfw.ListView,
    installed_only: bool,
    loading: bool,
    failure: ?anyerror,
    checked: bool,
    count: usize,

    pub fn statusText(self: View, arena: Allocator) Allocator.Error![]const u8 {
        if (self.loading) return "Loading Flatpaks…";
        if (self.failure) |err| return std.fmt.allocPrint(arena, "Flatpak query failed: {s} — Ctrl+R: retry", .{@errorName(err)});
        return std.fmt.allocPrint(arena, "{d} {s} — Enter: details  Ctrl+L: {s}  Ctrl+R: refresh", .{ self.count, if (self.installed_only) "installed Flatpaks" else "catalog apps", if (self.installed_only) "catalog" else "installed" });
    }

    pub fn appendContent(self: View, ctx: vxfw.DrawContext, children: *std.ArrayList(vxfw.SubSurface)) Allocator.Error!void {
        const size = ctx.max.size();
        try children.append(ctx.arena, .{ .origin = .{ .row = 1, .col = 0 }, .surface = try self.field.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = 1 })) });
        const message: ?[]const u8 = if (self.loading) "Loading Flatpaks…" else if (self.failure != null) "Could not load Flatpaks. Ctrl+R: retry; Ctrl+L: change list." else if (!self.checked) "Flatpak list not loaded yet." else if (self.count == 0) "No Flatpaks match. Catalogs reflect configured remotes and cached metadata." else null;
        const content_ctx = ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height -| 3 });
        var label: vxfw.Text = .{ .text = message orelse "" };
        try children.append(ctx.arena, .{ .origin = .{ .row = 2, .col = 0 }, .surface = if (message != null) try label.draw(content_ctx) else try self.list.draw(content_ctx) });
    }
};

fn drawCatalog(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const app: *const data.AppstreamApp = @ptrCast(@alignCast(ptr));
    var label: vxfw.Text = .{ .text = try std.fmt.allocPrint(ctx.arena, "{f} — {f}  {f}", .{ diagnostics.safe(app.Name), diagnostics.safe(app.Id), diagnostics.safe(app.Summary) }), .softwrap = false, .overflow = .ellipsis };
    return label.draw(ctx);
}

fn drawInstalled(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const app: *const data.Flatpak = @ptrCast(@alignCast(ptr));
    var label: vxfw.Text = .{ .text = try std.fmt.allocPrint(ctx.arena, "[{s}/{s}] {f}/{f}/{f}  {f}  ({f})", .{ @tagName(app.InstallLevel), @tagName(app.Kind), diagnostics.safe(app.Id), diagnostics.safe(app.Arch), diagnostics.safe(app.Branch), diagnostics.safe(app.Version), diagnostics.safe(app.Remote) }), .softwrap = false, .overflow = .ellipsis };
    return label.draw(ctx);
}
