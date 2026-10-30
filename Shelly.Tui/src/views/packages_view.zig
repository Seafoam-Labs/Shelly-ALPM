const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Allocator = std.mem.Allocator;
const Package = @import("../models/packages.zig").Package;
const appendDetailList = @import("detail_format.zig").appendDetailList;
const diagnostics = @import("diagnostics");
const formatSize = @import("detail_format.zig").formatSize;

/// Borrows display state and widgets owned by the application.
/// Query execution and user-action handling remain in Model.
pub const View = struct {
    installed_only: bool = false,
    text_field: *vxfw.TextField,
    list_view: *vxfw.ListView,
    details_scroll: *vxfw.ScrollView,
    selected: ?*const Package,
    details_active: bool,
    list_active: bool,
    selected_count: usize,
    loading: bool,
    load_failed: bool,
    query: []const u8,
    filtered_count: usize,
    package_count: usize,
    pub fn appendContent(self: View, ctx: vxfw.DrawContext, children: *std.ArrayList(vxfw.SubSurface)) Allocator.Error!void {
        const arena = ctx.arena;
        const max = ctx.max.size();
        const split = max.width >= 64;
        const right_w: u16 = if (split) @min(44, max.width / 2) else max.width;
        const left_w: u16 = if (split) max.width - right_w else max.width;
        const bordered_search = max.width >= 2 and max.height >= 8;
        const search_height: u16 = if (bordered_search) 3 else 1;
        const content_row = 1 + search_height;
        const height = max.height -| (content_row + 1);

        const search_labels = [_]vxfw.Border.BorderLabel{.{
            .text = "Search packages",
            .alignment = .top_left,
        }};
        var search_border: vxfw.Border = .{
            .child = self.text_field.widget(),
            .labels = &search_labels,
            .style = if (!self.list_active and !self.details_active) .{ .fg = .{ .index = 4 } } else .{},
        };
        try children.append(arena, .{
            .origin = .{ .row = 1, .col = 0 },
            .surface = if (bordered_search)
                try search_border.widget().draw(ctx.withConstraints(
                    .{ .width = max.width, .height = search_height },
                    .{ .width = max.width, .height = search_height },
                ))
            else
                try self.text_field.draw(ctx.withConstraints(.{}, .{ .width = max.width, .height = search_height })),
        });

        if (split or !self.details_active) {
            const message: ?[]const u8 = if (self.loading)
                "Loading packages…"
            else if (self.load_failed)
                "Could not load the package list."
            else if (self.filtered_count == 0)
                "No packages match."
            else
                null;
            const list_width = left_w -| @as(u16, if (split) 1 else 0);
            var label: vxfw.Text = .{ .text = message orelse "" };
            const labels = [_]vxfw.Border.BorderLabel{.{
                .text = if (self.installed_only) "Installed packages" else "Packages",
                .alignment = .top_left,
            }};
            const content = if (message != null) label.widget() else self.list_view.widget();
            var border: vxfw.Border = .{
                .child = content,
                .labels = &labels,
                .style = if (self.list_active and !self.details_active) .{ .fg = .{ .index = 4 } } else .{},
            };
            try children.append(arena, .{
                .origin = .{ .row = @intCast(content_row), .col = 0 },
                .surface = if (list_width >= 2 and height >= 2)
                    try border.widget().draw(ctx.withConstraints(
                        .{ .width = list_width, .height = height },
                        .{ .width = list_width, .height = height },
                    ))
                else
                    try content.draw(ctx.withConstraints(.{}, .{ .width = list_width, .height = height })),
            });
        }

        if ((split or self.details_active) and right_w >= 2 and height >= 2) {
            const labels = [_]vxfw.Border.BorderLabel{.{
                .text = if (self.selected) |pkg|
                    try std.fmt.allocPrint(arena, "{f}", .{diagnostics.safe(pkg.Name)})
                else
                    "Details",
                .alignment = .top_left,
            }};
            var empty: vxfw.Text = .{ .text = if (self.loading) "Loading packages…" else if (self.load_failed) "Package details unavailable." else "Select a package to see details." };
            var border: vxfw.Border = .{
                .child = if (self.selected != null and !self.loading and !self.load_failed) self.details_scroll.widget() else empty.widget(),
                .labels = &labels,
                .style = if (self.details_active) .{ .fg = .{ .index = 4 } } else .{},
            };
            try children.append(arena, .{
                .origin = .{ .row = @intCast(content_row), .col = if (split) left_w else 0 },
                .surface = try border.widget().draw(ctx.withConstraints(
                    .{ .width = right_w, .height = height },
                    .{ .width = right_w, .height = height },
                )),
            });
        }
    }
    pub fn statusText(self: View, arena: Allocator) Allocator.Error![]const u8 {
        if (self.loading) return "Loading packages…";
        if (self.load_failed) return "Could not load the package list.";
        const actions = if (self.selected) |pkg|
            if (pkg.Installed) "I: reinstall — R: remove" else "I: install"
        else
            "";
        if (self.details_active) return std.fmt.allocPrint(arena, "↑↓: scroll — {s} — ←/Q: packages", .{actions});
        if (self.list_active) return std.fmt.allocPrint(arena, "↑↓: select — {s} — →: details — /: search", .{actions});
        if (self.selected_count > 0) return std.fmt.allocPrint(arena, "{d} packages marked — Space: toggle — ↑↓: browse — Ctrl+L: installed/all", .{self.selected_count});
        if (self.installed_only) return std.fmt.allocPrint(arena, "{d} installed matches — ↑↓: browse — Ctrl+L: all", .{self.filtered_count});
        if (self.query.len > 0) {
            return try std.fmt.allocPrint(arena, "{d} of {d} matches — ↑↓: browse — Ctrl+L: installed", .{
                self.filtered_count, self.package_count,
            });
        }
        return try std.fmt.allocPrint(arena, "{d} packages — ↑↓: browse — Ctrl+L: installed", .{self.package_count});
    }
};

pub fn drawPackageRow(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const pkg: *const Package = @ptrCast(@alignCast(ptr));
    const arena = ctx.arena;

    var spans: std.ArrayList(vxfw.RichText.TextSpan) = .empty;
    if (pkg.Installed) {
        try spans.append(arena, .{ .text = "● ", .style = .{ .fg = .{ .index = 2 } } });
    } else {
        try spans.append(arena, .{ .text = "  " });
    }
    try spans.append(arena, .{ .text = pkg.Name, .style = .{ .bold = true } });
    try spans.append(arena, .{ .text = "  " });
    try spans.append(arena, .{ .text = pkg.Version, .style = .{ .fg = .{ .index = 245 } } });
    if (pkg.Description.len > 0) {
        try spans.append(arena, .{ .text = " — " });
        try spans.append(arena, .{
            .text = pkg.Description,
            .style = .{ .fg = .{ .index = 245 } },
        });
    }

    const rich = try arena.create(vxfw.RichText);
    rich.* = .{
        .text = spans.items,
        .softwrap = false,
        .overflow = .ellipsis,
    };
    return rich.draw(ctx);
}

pub fn drawSelectedRow(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const name_ptr: *const []const u8 = @ptrCast(@alignCast(ptr));
    const name = name_ptr.*;
    const arena = ctx.arena;
    var spans: std.ArrayList(vxfw.RichText.TextSpan) = .empty;
    try spans.append(arena, .{ .text = name });
    const rich = try arena.create(vxfw.RichText);
    rich.* = .{ .text = spans.items, .softwrap = false, .overflow = .ellipsis };
    return rich.draw(ctx);
}

pub fn detailsText(arena: Allocator, pkg: *const Package) Allocator.Error![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;

    try lines.append(arena, if (pkg.Description.len > 0) pkg.Description else "No description.");
    try lines.append(arena, "");

    try lines.append(arena, try std.fmt.allocPrint(arena, "Version: {s}", .{pkg.Version}));
    try lines.append(arena, try std.fmt.allocPrint(arena, "Repository: {s}", .{pkg.Repository}));
    try lines.append(arena, try std.fmt.allocPrint(arena, "Installed: {s}", .{if (pkg.Installed) "Yes" else "No"}));
    try appendDetailList(arena, &lines, "Licenses: ", pkg.Licenses);
    try appendDetailList(arena, &lines, "Groups: ", pkg.Groups);
    if (pkg.Url) |url| {
        try lines.append(arena, "");
        try lines.append(arena, try std.fmt.allocPrint(arena, "URL: {s}", .{url}));
    }
    try lines.append(arena, "");
    try lines.append(arena, try std.fmt.allocPrint(arena, "Download size: {s}", .{try formatSize(arena, pkg.DownloadSize)}));
    try lines.append(arena, try std.fmt.allocPrint(arena, "Installed size: {s}", .{try formatSize(arena, pkg.InstalledSize)}));
    if (pkg.BuildDate.len > 0) {
        try lines.append(arena, try std.fmt.allocPrint(arena, "Build date: {s}", .{pkg.BuildDate}));
    }

    try appendSection(arena, &lines, "Dependencies", pkg.Depends);
    try appendSection(arena, &lines, "Optional dependencies", pkg.OptDepends);
    try appendSection(arena, &lines, "Provides", pkg.Provides);
    try appendSection(arena, &lines, "Conflicts", pkg.Conflicts);
    try appendSection(arena, &lines, "Replaces", pkg.Replaces);

    return try std.mem.join(arena, "\n", lines.items);
}

fn appendSection(arena: Allocator, lines: *std.ArrayList([]const u8), title: []const u8, items: []const []const u8) Allocator.Error!void {
    if (items.len == 0) return;
    try lines.appendSlice(arena, &.{ "", title, "" });
    for (items) |item| {
        try lines.append(arena, try std.fmt.allocPrint(arena, "• {s}", .{item}));
    }
}

/// ScrollView builds this single wrapped document on demand in the frame arena.
pub fn drawDetails(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const pkg: *const Package = @ptrCast(@alignCast(ptr));
    const body = try std.fmt.allocPrint(ctx.arena, "{f}\n\n{s}", .{
        diagnostics.safe(try detailsText(ctx.arena, pkg)),
        if (pkg.Installed) "I: install/reinstall   R: remove" else "I: install",
    });
    var text: vxfw.Text = .{ .text = body, .softwrap = true };
    // ScrollView allows horizontal overflow and supplies its viewport width
    // as the minimum. Wrap to that width instead of the unbounded maximum.
    const width = ctx.max.width orelse ctx.min.width;
    return text.draw(ctx.withConstraints(
        .{ .width = width, .height = 0 },
        .{ .width = width, .height = null },
    ));
}

test "details wrap long dependency names to the scroll viewport width" {
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var pkg: Package = .{
        .Description = "A description that needs several lines in a narrow package details pane.",
        .Depends = &.{"a-very-long-dependency-name-without-spaces>=1234567890"},
    };
    for ([_]u16{ 18, 38 }) |width| {
        const surface = try drawDetails(&pkg, .{
            .arena = arena.allocator(),
            .min = .{ .width = width },
            .max = .{},
            .cell_size = .{ .width = 10, .height = 20 },
        });
        try std.testing.expectEqual(width, surface.size.width);
        var rendered: std.ArrayList(u8) = .empty;
        for (surface.buffer) |cell| {
            if (!std.mem.eql(u8, cell.char.grapheme, " "))
                try rendered.appendSlice(arena.allocator(), cell.char.grapheme);
        }
        try std.testing.expect(std.mem.indexOf(u8, rendered.items, pkg.Depends[0]) != null);
    }
}
