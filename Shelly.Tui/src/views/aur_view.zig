const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Border = @import("border.zig");
const commands = @import("../commands.zig");
const diagnostics = @import("diagnostics");
const help_view = @import("help_view.zig");
const pkgbuild_view = @import("pkgbuild_view.zig");
const Allocator = std.mem.Allocator;
const AurPackage = @import("../models/packages.zig").AurPackage;
const appendDetailList = @import("detail_format.zig").appendDetailList;
const formatEpoch = @import("detail_format.zig").formatEpoch;

/// Borrows display state and widgets owned by the application.
/// Query execution and user-action handling remain in Model.
pub const View = struct {
    installed_only: bool = false,
    aur_field: *vxfw.TextField,
    aur_list: *vxfw.ListView,
    searching: bool,
    aur_failed: bool,
    aur_query: []const u8,
    result_count: usize,
    selected: ?*const AurPackage = null,
    details_scroll: *vxfw.ScrollView,
    details_active: bool = false,
    list_active: bool = false,
    preview: ?pkgbuild_view.View = null,
    help: ?*help_view.Panel = null,
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
        const show_pane = split or self.details_active or self.preview != null or self.help != null;
        if (split or !show_pane) {
            var search_border: Border = .{ .child = self.aur_field.widget(), .style = if (!self.list_active and !self.details_active) .{ .fg = .{ .index = 7 }, .bold = true } else .{} };
            try children.append(arena, .{
                .origin = .{ .row = 1, .col = 0 },
                .surface = if (search_height == 3)
                    try search_border.draw(ctx.withConstraints(.{ .width = list_width, .height = search_height }, .{ .width = list_width, .height = search_height }))
                else
                    try self.aur_field.draw(ctx.withConstraints(.{}, .{ .width = list_width, .height = search_height })),
            });
            const message = try self.aurMessage(arena);
            var label: vxfw.Text = .{ .text = if (message) |item| item.text else "", .style = .{ .fg = .{ .index = if (message != null and message.?.red) @as(u8, 1) else 250 } } };
            const labels = [_]Border.BorderLabel{.{ .text = if (self.installed_only) "Installed AUR packages" else "AUR packages", .alignment = .top_left }};
            const content = if (message != null) label.widget() else self.aur_list.widget();
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
            else if (self.preview) |preview|
                try preview.drawInPane(pane_ctx)
            else blk: {
                const title = if (self.selected) |pkg| try std.fmt.allocPrint(arena, "{f}", .{diagnostics.safe(pkg.Name)}) else "AUR details";
                const labels = [_]Border.BorderLabel{.{ .text = title, .alignment = .top_left }};
                var empty: vxfw.Text = .{ .text = if (self.searching) "Waiting for search results…" else "Select a result to see details." };
                var border: Border = .{
                    .child = if (self.selected != null and !self.searching) self.details_scroll.widget() else empty.widget(),
                    .labels = &labels,
                    .style = if (self.details_active) .{ .fg = .{ .index = 7 }, .bold = true } else .{},
                };
                break :blk try border.draw(pane_ctx.withConstraints(.{ .width = right_w, .height = pane_height }, .{ .width = right_w, .height = pane_height }));
            };
            try children.append(arena, .{ .origin = .{ .row = @intCast(pane_row), .col = if (split) @intCast(left_w) else 0 }, .surface = surface });
        }
    }
    fn aurMessage(self: View, arena: Allocator) Allocator.Error!?struct { text: []const u8, red: bool } {
        if (self.searching and self.installed_only) return .{ .text = "Loading installed AUR packages…", .red = false };
        if (self.aur_failed and self.installed_only) return .{ .text = "Could not load installed AUR packages. Ctrl+R: retry.", .red = true };
        if (self.searching) {
            return .{
                .text = try std.fmt.allocPrint(arena, "Searching AUR for '{s}'…", .{self.aur_query}),
                .red = false,
            };
        }
        if (self.aur_failed) {
            return .{ .text = "Could not search the configured AUR service.", .red = true };
        }
        if (self.installed_only) return if (self.result_count == 0) .{ .text = "No installed AUR packages match the filter.", .red = false } else null;
        if (self.aur_query.len == 0) {
            return .{ .text = try std.fmt.allocPrint(arena, "Type a search term and press {s} to query the AUR.", .{try commands.label(arena, .confirm)}), .red = false };
        }
        if (self.result_count == 0) {
            return .{ .text = "No AUR packages matched.", .red = false };
        }
        return null;
    }
    pub fn statusText(self: View, arena: Allocator) Allocator.Error![]const u8 {
        if (self.searching and self.installed_only) return "Loading installed AUR packages…";
        if (self.aur_failed and self.installed_only) return "Installed AUR query failed — Ctrl+R: retry";
        if (self.searching) {
            return try std.fmt.allocPrint(arena, "Searching AUR for '{s}'…", .{self.aur_query});
        }
        if (self.aur_failed) return "Could not search the configured AUR service.";
        if (self.installed_only) return std.fmt.allocPrint(arena, "{d} installed AUR packages — Ctrl+L: search AUR — Ctrl+R: refresh", .{self.result_count});
        if (self.aur_query.len == 0) return "AUR — Enter: search — Ctrl+L: installed";
        return try std.fmt.allocPrint(arena, "{d} AUR results for '{s}' — Ctrl+L: installed", .{
            self.result_count, self.aur_query,
        });
    }
};

pub fn drawAurRow(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    return drawRow(ptr, ctx, false);
}

pub fn drawSelectedAurRow(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    return drawRow(ptr, ctx, true);
}

fn drawRow(ptr: *anyopaque, ctx: vxfw.DrawContext, selected: bool) Allocator.Error!vxfw.Surface {
    const pkg: *const AurPackage = @ptrCast(@alignCast(ptr));
    const arena = ctx.arena;

    var spans: std.ArrayList(vxfw.RichText.TextSpan) = .empty;
    try spans.append(arena, .{ .text = if (selected) "[x] " else "[ ] ", .style = .{ .bold = selected } });
    try spans.append(arena, .{ .text = if (pkg.Installed) "● " else "  ", .style = .{ .fg = .{ .index = 2 } } });
    try spans.append(arena, .{ .text = pkg.Name, .style = .{ .bold = true } });

    const rich = try arena.create(vxfw.RichText);
    rich.* = .{
        .text = spans.items,
        .softwrap = false,
        .overflow = .ellipsis,
    };
    const width = ctx.max.width orelse ctx.min.width;
    return rich.draw(ctx.withConstraints(.{ .width = width }, .{ .width = width, .height = 1 }));
}

pub fn detailsText(arena: Allocator, pkg: *const AurPackage) Allocator.Error![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;

    try lines.append(arena, pkg.Description orelse "No description.");
    try lines.append(arena, "");

    try lines.append(arena, try std.fmt.allocPrint(arena, "Installed:       {s}", .{if (pkg.Installed) "yes" else "no"}));
    try lines.append(arena, try std.fmt.allocPrint(arena, "Version:         {s}", .{pkg.Version}));
    try lines.append(arena, try std.fmt.allocPrint(arena, "Package base:    {s}", .{pkg.PackageBase}));
    try lines.append(arena, try std.fmt.allocPrint(arena, "Votes:           {d}", .{pkg.NumVotes}));
    try lines.append(arena, try std.fmt.allocPrint(arena, "Popularity:      {d:.2}", .{pkg.Popularity}));
    try lines.append(arena, try std.fmt.allocPrint(arena, "Maintainer:      {s}", .{pkg.Maintainer orelse "—"}));
    try lines.append(arena, try std.fmt.allocPrint(arena, "Out of date:     {s}", .{if (pkg.OutOfDate != null) "yes" else "no"}));
    if (pkg.Url) |url| {
        try lines.append(arena, try std.fmt.allocPrint(arena, "URL:             {s}", .{url}));
    }
    if (pkg.License) |licenses| try appendDetailList(arena, &lines, "Licenses:     ", licenses);
    if (pkg.Depends) |depends| try appendDetailList(arena, &lines, "Depends:       ", depends);
    if (pkg.MakeDepends) |make_depends| try appendDetailList(arena, &lines, "Make deps:     ", make_depends);
    try lines.append(arena, try std.fmt.allocPrint(arena, "First submitted: {s}", .{try formatEpoch(arena, pkg.FirstSubmitted)}));
    try lines.append(arena, try std.fmt.allocPrint(arena, "Last modified:   {s}", .{try formatEpoch(arena, pkg.LastModified)}));

    return try std.mem.join(arena, "\n", lines.items);
}

const detail_fields = @import("detail_fields.zig");

pub fn drawDetails(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const pkg: *const AurPackage = @ptrCast(@alignCast(ptr));
    const arena = ctx.arena;
    var fields: std.ArrayList(detail_fields.Field) = .empty;
    try fields.appendSlice(arena, &.{
        .{ .label = "Description", .value = pkg.Description orelse "No description." },
        .{ .label = "Version", .value = pkg.Version, .gap = true },
        .{ .label = "Installed", .value = if (pkg.Installed) "Yes" else "No" },
        .{ .label = "Package base", .value = pkg.PackageBase },
        .{ .label = "Maintainer", .value = pkg.Maintainer orelse "—" },
        .{ .label = "Votes", .value = try std.fmt.allocPrint(arena, "{d}", .{pkg.NumVotes}) },
        .{ .label = "Popularity", .value = try std.fmt.allocPrint(arena, "{d:.2}", .{pkg.Popularity}) },
        .{ .label = "Out of date", .value = if (pkg.OutOfDate != null) "Yes" else "No" },
    });
    if (pkg.Url) |url| try fields.append(arena, .{ .label = "URL", .value = url });
    if (pkg.License) |items| if (items.len > 0) {
        try fields.append(arena, .{ .label = "Licenses", .value = try std.mem.join(arena, ", ", items) });
    };
    try fields.appendSlice(arena, &.{
        .{ .label = "Submitted", .value = try formatEpoch(arena, pkg.FirstSubmitted), .gap = true },
        .{ .label = "Modified", .value = try formatEpoch(arena, pkg.LastModified) },
    });
    if (pkg.Depends) |items| try detail_fields.listField(arena, &fields, "Dependencies", items);
    if (pkg.MakeDepends) |items| try detail_fields.listField(arena, &fields, "Make deps", items);
    return detail_fields.draw(.{ .userdata = ptr, .drawFn = drawDetails }, ctx, fields.items);
}

// ScrollView supplies unbounded constraints; buttons need a finite viewport.
pub fn drawPreviewButton(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const button: *vxfw.Button = @ptrCast(@alignCast(ptr));
    const viewport = ctx.max.width orelse ctx.min.width;
    const width: u16 = @intCast(@min(viewport, ctx.stringWidth(button.label)));
    var surface = try button.draw(ctx.withConstraints(.{ .width = width }, .{ .width = width, .height = 1 }));
    surface.widget.drawFn = drawPreviewButton;
    return surface;
}
