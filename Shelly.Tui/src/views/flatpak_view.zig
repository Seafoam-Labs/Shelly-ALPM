const std = @import("std");
const Border = @import("border.zig");
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
            .installed => |app| std.fmt.allocPrint(arena, "{f}\n\nName: {f}\nID: {f}\nVersion: {f}\nScope: {s}\nKind: {s}\nArchitecture: {f}\nBranch: {f}\nRemote: {f}\nRef: {f}\nFull ref: {f}\nInstalled size: {s}", .{ diagnostics.safe(app.Summary), diagnostics.safe(app.Name), diagnostics.safe(app.Id), diagnostics.safe(app.Version), @tagName(app.InstallLevel), @tagName(app.Kind), diagnostics.safe(app.Arch), diagnostics.safe(app.Branch), diagnostics.safe(app.Remote), diagnostics.safe(app.Ref), diagnostics.safe(app.FullRef), try formatSize(arena, app.InstalledSize) }),
            .catalog => |app| blk: {
                var remotes: std.ArrayList(u8) = .empty;
                for (app.Remotes, 0..) |remote, i| {
                    const text = try std.fmt.allocPrint(arena, "{s}{f} ({s})", .{ if (i == 0) "" else ", ", diagnostics.safe(remote.Name), @tagName(remote.Scope) });
                    try remotes.appendSlice(arena, text);
                }
                break :blk std.fmt.allocPrint(arena, "{f}\n\nName: {f}\nID: {f}\nType: {f}\nDeveloper: {f}\nLicense: {f}\nVerified: {s}\nRemotes: {s}\n\n{f}\n\nCatalog metadata — installation status and permissions are not queried.", .{ diagnostics.safe(app.Summary), diagnostics.safe(app.Name), diagnostics.safe(app.Id), diagnostics.safe(app.Type), diagnostics.safe(app.DeveloperName), diagnostics.safe(app.ProjectLicense), if (app.IsVerified) "yes" else "no", remotes.items, diagnostics.safe(app.Description) });
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
    checking_backend: bool = false,
    backend_failure: ?anyerror = null,
    failure: ?anyerror,
    checked: bool,
    count: usize,
    selected: ?Row = null,
    details_scroll: *vxfw.ScrollView,
    details_active: bool = false,
    list_active: bool = false,
    help: ?*@import("help_view.zig").Panel = null,

    pub fn statusText(self: View, arena: Allocator) Allocator.Error![]const u8 {
        if (self.checking_backend) return "Checking Flatpak backend…";
        if (self.backend_failure) |err| return std.fmt.allocPrint(arena, "Flatpak backend check failed: {s}", .{@errorName(err)});
        if (self.loading) return "Loading Flatpaks…";
        if (self.failure) |err| return std.fmt.allocPrint(arena, "Flatpak query failed: {s}", .{@errorName(err)});
        return std.fmt.allocPrint(arena, "{d} {s}", .{ self.count, if (self.installed_only) "installed Flatpaks" else "catalog apps" });
    }

    pub fn appendContent(self: View, ctx: vxfw.DrawContext, children: *std.ArrayList(vxfw.SubSurface)) Allocator.Error!void {
        const arena = ctx.arena;
        const max = ctx.max.size();
        const split = max.width >= 64;
        const left_w: u16 = if (split) @max(28, @as(u16, @intCast(@as(u32, max.width) * 2 / 5))) else max.width;
        const right_w = if (split) max.width - left_w else max.width;
        const list_width = left_w -| @as(u16, if (split) 1 else 0);
        const search_height: u16 = if (max.width >= 2 and max.height >= 8) 3 else 1;
        const list_row = 1 + search_height;
        const list_height = max.height -| (list_row + 1);
        const pane_row: u16 = 1;
        const pane_height = max.height -| (pane_row + 1);
        const show_pane = split or self.details_active or self.help != null;
        if (split or !show_pane) {
            var search_border: Border = .{ .child = self.field.widget(), .style = if (!self.list_active and !self.details_active) .{ .fg = .{ .index = 7 }, .bold = true } else .{} };
            try children.append(arena, .{
                .origin = .{ .row = 1, .col = 0 },
                .surface = if (search_height == 3)
                    try search_border.draw(ctx.withConstraints(.{ .width = list_width, .height = search_height }, .{ .width = list_width, .height = search_height }))
                else
                    try self.field.draw(ctx.withConstraints(.{}, .{ .width = list_width, .height = search_height })),
            });
            const message = self.contentMessage();
            var label: vxfw.Text = .{ .text = message orelse "", .style = .{ .fg = .{ .index = 250 } } };
            const labels = [_]Border.BorderLabel{.{ .text = if (self.installed_only) "Installed Flatpaks" else "Flatpak applications", .alignment = .top_left }};
            const content = if (message != null) label.widget() else self.list.widget();
            var border: Border = .{ .child = content, .labels = &labels, .style = if (self.list_active and !self.details_active) .{ .fg = .{ .index = 7 }, .bold = true } else .{} };
            try children.append(arena, .{
                .origin = .{ .row = @intCast(list_row), .col = 0 },
                .surface = if (list_width >= 2 and list_height >= 2)
                    try border.draw(ctx.withConstraints(.{ .width = list_width, .height = list_height }, .{ .width = list_width, .height = list_height }))
                else
                    try content.draw(ctx.withConstraints(.{}, .{ .width = list_width, .height = list_height })),
            });
        }
        if (show_pane and pane_height >= 2 and right_w >= 2) {
            const pane_ctx = ctx.withConstraints(.{}, .{ .width = right_w, .height = pane_height });
            const surface = if (self.help) |panel|
                try panel.draw(pane_ctx)
            else blk: {
                const title = if (self.selected) |pkg| try std.fmt.allocPrint(arena, "{f}", .{diagnostics.safe(switch (pkg) {
                    .catalog => |app| if (app.Name.len > 0) app.Name else app.Id,
                    .installed => |app| if (app.Name.len > 0) app.Name else app.Id,
                })}) else "Flatpak details";
                const labels = [_]Border.BorderLabel{.{ .text = title, .alignment = .top_left }};
                var empty: vxfw.Text = .{ .text = if (self.loading) "Loading Flatpaks…" else "Select a result to see details." };
                var border: Border = .{
                    .child = if (self.selected != null and !self.loading) self.details_scroll.widget() else empty.widget(),
                    .labels = &labels,
                    .style = if (self.details_active) .{ .fg = .{ .index = 7 }, .bold = true } else .{},
                };
                break :blk try border.draw(pane_ctx.withConstraints(.{ .width = right_w, .height = pane_height }, .{ .width = right_w, .height = pane_height }));
            };
            try children.append(arena, .{ .origin = .{ .row = @intCast(pane_row), .col = if (split) @intCast(left_w) else 0 }, .surface = surface });
        }
    }
    fn contentMessage(self: View) ?[]const u8 {
        return if (self.checking_backend) "Checking Flatpak backend…" else if (self.backend_failure != null) "Flatpak is enabled, but its backend could not be used. Install the Shelly Flatpak backend to use this source." else if (self.loading) "Loading Flatpaks…" else if (self.failure != null) "Could not load Flatpaks." else if (!self.checked) "Flatpak list not loaded yet." else if (self.count == 0) "No Flatpaks match. Catalogs reflect configured remotes and cached metadata." else null;
    }
};

fn drawCatalog(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const app: *const data.AppstreamApp = @ptrCast(@alignCast(ptr));
    var label: vxfw.Text = .{ .style = .{ .bold = true }, .text = try std.fmt.allocPrint(ctx.arena, "{f}", .{diagnostics.safe(if (app.Name.len > 0) app.Name else app.Id)}), .softwrap = false, .overflow = .ellipsis };
    return label.draw(ctx);
}

fn drawInstalled(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const app: *const data.Flatpak = @ptrCast(@alignCast(ptr));
    const spans = [_]vxfw.RichText.TextSpan{
        .{ .text = "● ", .style = .{ .fg = .{ .index = 2 } } },
        .{ .text = try std.fmt.allocPrint(ctx.arena, "{f} ({s})", .{ diagnostics.safe(if (app.Name.len > 0) app.Name else app.Id), @tagName(app.InstallLevel) }), .style = .{ .bold = true } },
    };
    var label: vxfw.RichText = .{ .text = &spans, .softwrap = false, .overflow = .ellipsis };
    return label.draw(ctx);
}

pub fn drawInstallChoices(ctx: vxfw.DrawContext, app: *const data.AppstreamApp, selected: usize) Allocator.Error!?vxfw.SubSurface {
    const size = ctx.max.size();
    const width = @min(size.width -| 2, @as(u16, 80));
    const height = @min(size.height -| 2, @as(u16, 22));
    if (width < 20 or height < 6) return null;
    var lines: std.ArrayList(u8) = .empty;
    const heading = try std.fmt.allocPrint(ctx.arena, "Install {f}\nChoose a remote and installation scope.\n\n", .{diagnostics.safe(app.Id)});
    try lines.appendSlice(ctx.arena, heading);
    const capacity = @max(@as(usize, 1), height -| 5);
    const start = selected -| (capacity / 2);
    for (start..@min(app.Remotes.len, start + capacity)) |index| {
        const remote = app.Remotes[index];
        try lines.appendSlice(ctx.arena, try std.fmt.allocPrint(ctx.arena, "{s} {f} — {s}\n", .{ if (index == selected) ">" else " ", diagnostics.safe(remote.Name), @tagName(remote.Scope) }));
    }
    var text: vxfw.Text = .{ .text = lines.items };
    const labels = [_]Border.BorderLabel{.{ .text = "Flatpak installation", .alignment = .top_left }};
    var border: Border = .{ .child = text.widget(), .labels = &labels };
    const surface = try border.widget().draw(ctx.withConstraints(.{}, .{ .width = width, .height = height }));
    return .{ .origin = .{ .row = @divFloor(@as(i17, size.height) - surface.size.height, 2), .col = @divFloor(@as(i17, size.width) - surface.size.width, 2) }, .surface = surface, .z_index = 2 };
}

const detail_fields = @import("detail_fields.zig");
pub fn drawDetails(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const row: *const Row = @ptrCast(@alignCast(ptr));
    const arena = ctx.arena;
    var fields: std.ArrayList(detail_fields.Field) = .empty;
    switch (row.*) {
        .installed => |app| try fields.appendSlice(arena, &.{
            .{ .label = "Description", .value = app.Summary },
            .{ .label = "Name", .value = app.Name, .gap = true },
            .{ .label = "ID", .value = app.Id },
            .{ .label = "Version", .value = app.Version },
            .{ .label = "Scope", .value = @tagName(app.InstallLevel) },
            .{ .label = "Kind", .value = @tagName(app.Kind) },
            .{ .label = "Architecture", .value = app.Arch },
            .{ .label = "Branch", .value = app.Branch },
            .{ .label = "Remote", .value = app.Remote },
            .{ .label = "Ref", .value = app.Ref },
            .{ .label = "Full ref", .value = app.FullRef },
            .{ .label = "Size", .value = try formatSize(arena, app.InstalledSize) },
        }),
        .catalog => |app| {
            try fields.appendSlice(arena, &.{
                .{ .label = "Summary", .value = app.Summary },
                .{ .label = "Description", .value = app.Description, .gap = true },
                .{ .label = "Name", .value = app.Name, .gap = true },
                .{ .label = "ID", .value = app.Id },
                .{ .label = "Type", .value = app.Type },
                .{ .label = "Developer", .value = app.DeveloperName },
                .{ .label = "License", .value = app.ProjectLicense },
                .{ .label = "Verified", .value = if (app.IsVerified) "Yes" else "No" },
            });
            for (app.Remotes, 0..) |remote, i| try fields.append(arena, .{ .label = if (i == 0) "Remotes" else "", .value = try std.fmt.allocPrint(arena, "{s} ({s})", .{ remote.Name, @tagName(remote.Scope) }) });
        },
    }
    return detail_fields.draw(.{ .userdata = ptr, .drawFn = drawDetails }, ctx, fields.items);
}
