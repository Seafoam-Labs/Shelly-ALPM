const std = @import("std");
const Border = @import("border.zig");
const help_view = @import("help_view.zig");
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
    help: ?*help_view.Panel = null,
    selected: ?*const Package,
    details_active: bool,
    list_active: bool,
    selected_count: usize,
    selected_installed: usize = 0,
    loading: bool,
    load_failed: bool,
    query: []const u8,
    filtered_count: usize,
    package_count: usize,
    pub fn appendContent(self: View, ctx: vxfw.DrawContext, children: *std.ArrayList(vxfw.SubSurface)) Allocator.Error!void {
        const arena = ctx.arena;
        const max = ctx.max.size();
        const split = max.width >= 64;
        if (!split) if (self.help) |panel| {
            try children.append(arena, .{
                .origin = .{ .row = 1, .col = 0 },
                .surface = try panel.draw(ctx.withConstraints(.{}, .{ .width = max.width, .height = max.height -| 2 })),
            });
            return;
        };
        const left_w: u16 = if (split) @max(28, @as(u16, @intCast(@as(u32, max.width) * 2 / 5))) else max.width;
        const right_w: u16 = if (split) max.width - left_w else max.width;
        const list_width = left_w -| @as(u16, if (split) 1 else 0);
        const bordered_search = max.width >= 2 and max.height >= 8;
        const search_height: u16 = if (bordered_search) 3 else 1;
        const content_row = 1 + search_height;
        const height = max.height -| (content_row + 1);
        const details_row: u16 = if (split) 1 else content_row;
        const details_height = max.height -| (details_row + 1);
        var search_border: Border = .{
            .child = self.text_field.widget(),
            .style = if (!self.list_active and !self.details_active) .{ .fg = .{ .index = 7 }, .bold = true } else .{},
        };
        try children.append(arena, .{
            .origin = .{ .row = 1, .col = 0 },
            .surface = if (bordered_search)
                try search_border.widget().draw(ctx.withConstraints(
                    .{ .width = list_width, .height = search_height },
                    .{ .width = list_width, .height = search_height },
                ))
            else
                try self.text_field.draw(ctx.withConstraints(.{}, .{ .width = list_width, .height = search_height })),
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
            var label: vxfw.Text = .{ .text = message orelse "" };
            const labels = [_]Border.BorderLabel{.{
                .text = if (self.installed_only) "Installed packages" else "Packages",
                .alignment = .top_left,
            }};
            const content = if (message != null) label.widget() else self.list_view.widget();
            var border: Border = .{
                .child = content,
                .labels = &labels,
                .style = if (self.list_active and !self.details_active) .{ .fg = .{ .index = 7 }, .bold = true } else .{},
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

        if (self.help) |panel| {
            try children.append(arena, .{
                .origin = .{ .row = @intCast(details_row), .col = @intCast(left_w) },
                .surface = try panel.draw(ctx.withConstraints(.{}, .{ .width = right_w, .height = details_height })),
            });
            return;
        }

        if ((split or self.details_active) and right_w >= 2 and details_height >= 2) {
            const labels = [_]Border.BorderLabel{.{
                .text = if (self.selected) |pkg|
                    try std.fmt.allocPrint(arena, "{f}", .{diagnostics.safe(pkg.Name)})
                else
                    "Details",
                .alignment = .top_left,
            }};
            var empty: vxfw.Text = .{ .text = if (self.loading) "Loading packages…" else if (self.load_failed) "Package details unavailable." else "Select a package to see details." };
            var border: Border = .{
                .child = if (self.selected != null and !self.loading and !self.load_failed) self.details_scroll.widget() else empty.widget(),
                .labels = &labels,
                .style = if (self.details_active) .{ .fg = .{ .index = 7 }, .bold = true } else .{},
            };
            try children.append(arena, .{
                .origin = .{ .row = @intCast(details_row), .col = if (split) left_w else 0 },
                .surface = try border.widget().draw(ctx.withConstraints(
                    .{ .width = right_w, .height = details_height },
                    .{ .width = right_w, .height = details_height },
                )),
            });
        }
    }
    pub fn statusText(self: View, arena: Allocator) Allocator.Error![]const u8 {
        if (self.loading) return "Loading packages…";
        if (self.load_failed) return "Could not load the package list.";
        const actions = if (self.selected_count > 0)
            if (self.selected_installed > 0) "I: install/reinstall — R: remove installed" else "I: install"
        else if (self.selected) |pkg|
            if (pkg.Installed) "I: reinstall — R: remove" else "I: install"
        else
            "";
        const selection = if (self.selected_count > 0)
            try std.fmt.allocPrint(arena, "{d} selected · {d} installed · {d} available — ", .{ self.selected_count, self.selected_installed, self.selected_count - self.selected_installed })
        else
            "";
        if (self.details_active) return std.fmt.allocPrint(arena, "{s}↑↓: scroll — {s} — ←/Q: packages", .{ selection, actions });
        if (self.list_active) return std.fmt.allocPrint(arena, "{s}{s} — Enter: select — →: details — /: search", .{ selection, actions });
        if (self.selected_count > 0) return std.fmt.allocPrint(arena, "{s}↑↓: browse — Ctrl+L: installed/all", .{selection});
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
    return drawRow(ptr, ctx, false);
}

pub fn drawMarkedPackageRow(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    return drawRow(ptr, ctx, true);
}

fn drawRow(ptr: *anyopaque, ctx: vxfw.DrawContext, selected: bool) Allocator.Error!vxfw.Surface {
    const pkg: *const Package = @ptrCast(@alignCast(ptr));
    const arena = ctx.arena;

    var spans: std.ArrayList(vxfw.RichText.TextSpan) = .empty;
    try spans.append(arena, .{ .text = if (selected) "[x] " else "[ ] ", .style = .{ .bold = selected } });
    if (pkg.Installed) {
        try spans.append(arena, .{ .text = "● ", .style = .{ .fg = .{ .index = 2 } } });
    } else {
        try spans.append(arena, .{ .text = "  " });
    }
    try spans.append(arena, .{ .text = pkg.Name, .style = .{ .bold = true } });

    const rich = try arena.create(vxfw.RichText);
    rich.* = .{
        .text = spans.items,
        .softwrap = false,
        .overflow = .ellipsis,
    };
    // ListView allows horizontal overflow. Constrain rows to its viewport
    // so long package names are ellipsized instead of extending off screen.
    const width = ctx.max.width orelse ctx.min.width;
    return rich.draw(ctx.withConstraints(
        .{ .width = width, .height = 0 },
        .{ .width = width, .height = 1 },
    ));
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

const DetailField = struct {
    label: []const u8,
    value: []const u8,
    gap: bool = false,
};

fn listField(arena: Allocator, fields: *std.ArrayList(DetailField), label: []const u8, items: []const []const u8) Allocator.Error!void {
    if (items.len == 0) return;
    try fields.append(arena, .{ .label = label, .value = try std.mem.join(arena, "\n", items), .gap = true });
}

/// Render a structured document for ScrollView. Values wrap independently of
/// labels, so continuation lines keep their indentation after resizing.
pub fn drawDetails(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const pkg: *const Package = @ptrCast(@alignCast(ptr));
    const arena = ctx.arena;
    const width = ctx.max.width orelse ctx.min.width;
    const columns = width >= 36;
    const label_width: u16 = if (columns) 12 else width;
    const value_col: u16 = if (columns) 14 else 0;
    const value_width = width - value_col;
    var fields: std.ArrayList(DetailField) = .empty;
    try fields.appendSlice(arena, &.{
        .{ .label = "Description", .value = if (pkg.Description.len > 0) pkg.Description else "No description." },
        .{ .label = "Version", .value = pkg.Version, .gap = true },
        .{ .label = "Repository", .value = pkg.Repository },
        .{ .label = "Installed", .value = if (pkg.Installed) "Yes" else "No" },
    });
    if (pkg.Licenses.len > 0) try fields.append(arena, .{ .label = "Licenses", .value = try std.mem.join(arena, ", ", pkg.Licenses) });
    if (pkg.Groups.len > 0) try fields.append(arena, .{ .label = "Groups", .value = try std.mem.join(arena, ", ", pkg.Groups) });
    if (pkg.Url) |url| try fields.append(arena, .{ .label = "URL", .value = url });
    try fields.appendSlice(arena, &.{
        .{ .label = "Download", .value = try formatSize(arena, pkg.DownloadSize), .gap = true },
        .{ .label = "Disk usage", .value = try formatSize(arena, pkg.InstalledSize) },
    });
    if (pkg.BuildDate.len > 0) try fields.append(arena, .{ .label = "Build date", .value = pkg.BuildDate });
    try listField(arena, &fields, "Dependencies", pkg.Depends);
    try listField(arena, &fields, "Optional", pkg.OptDepends);
    try listField(arena, &fields, "Provides", pkg.Provides);
    try listField(arena, &fields, "Conflicts", pkg.Conflicts);
    try listField(arena, &fields, "Replaces", pkg.Replaces);

    var children: std.ArrayList(vxfw.SubSurface) = .empty;
    var row: u16 = 0;
    for (fields.items) |field| {
        if (field.gap or (!columns and row > 0)) row += 1;
        var label: vxfw.Text = .{ .text = field.label, .style = .{ .bold = true, .fg = .{ .index = 7 } } };
        const label_surface = try label.draw(ctx.withConstraints(.{}, .{ .width = label_width, .height = null }));
        try children.append(arena, .{ .origin = .{ .row = row, .col = 0 }, .surface = label_surface });
        const value_row = row + if (columns) @as(u16, 0) else label_surface.size.height;
        var value: vxfw.Text = .{ .text = try std.fmt.allocPrint(arena, "{f}", .{diagnostics.safe(field.value)}), .softwrap = true };
        const value_surface = try value.draw(ctx.withConstraints(
            .{ .width = value_width },
            .{ .width = value_width, .height = null },
        ));
        try children.append(arena, .{ .origin = .{ .row = value_row, .col = value_col }, .surface = value_surface });
        row = @max(row + label_surface.size.height, value_row + value_surface.size.height);
    }
    // Flatten the document into one scrollable surface; no frame-arena Text
    // widgets need to survive the draw call.
    const surface = try vxfw.Surface.init(arena, .{ .userdata = ptr, .drawFn = drawDetails }, .{ .width = width, .height = row });
    @memset(surface.buffer, .{});
    for (children.items) |child| {
        const origin_row: usize = @intCast(child.origin.row);
        const origin_col: usize = @intCast(child.origin.col);
        for (0..child.surface.size.height) |line| {
            const source = line * child.surface.size.width;
            const target = (origin_row + line) * width + origin_col;
            @memcpy(surface.buffer[target .. target + child.surface.size.width], child.surface.buffer[source .. source + child.surface.size.width]);
        }
    }
    return surface;
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

test "package rows truncate long names to the list viewport" {
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var pkg: Package = .{ .Name = "an-example-package-with-a-long-name", .Version = "1", .Description = "Description belongs in details." };
    const surface = try drawPackageRow(&pkg, .{
        .arena = arena.allocator(),
        .min = .{ .width = 28 },
        .max = .{},
        .cell_size = .{ .width = 10, .height = 20 },
    });
    try std.testing.expectEqual(@as(u16, 28), surface.size.width);
    try std.testing.expectEqual(@as(u16, 1), surface.size.height);
    var ellipsis = false;
    for (surface.buffer) |cell| ellipsis = ellipsis or std.mem.eql(u8, cell.char.grapheme, "…");
    try std.testing.expect(ellipsis);
}

test "structured details align wrapped values and stack fields in narrow panes" {
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var pkg: Package = .{
        .Description = "Description text that continues onto another line in the value column.",
        .Depends = &.{ "dependency-one", "dependency-two" },
    };
    for ([_]u16{ 50, 24 }) |width| {
        const surface = try drawDetails(&pkg, .{
            .arena = arena.allocator(),
            .min = .{ .width = width },
            .max = .{},
            .cell_size = .{ .width = 10, .height = 20 },
        });
        try std.testing.expect(surface.buffer[0].style.bold);
        const value_col: usize = if (width >= 36) 14 else 0;
        const value_row: usize = if (width >= 36) 0 else 1;
        try std.testing.expectEqualStrings("D", surface.buffer[value_row * width + value_col].char.grapheme);
        var rendered: std.ArrayList(u8) = .empty;
        for (surface.buffer) |cell| try rendered.append(arena.allocator(), if (cell.char.grapheme.len == 1) cell.char.grapheme[0] else ' ');
        for (pkg.Depends) |dependency| {
            const index = std.mem.indexOf(u8, rendered.items, dependency).?;
            try std.testing.expectEqual(value_col, index % width);
        }
        if (width >= 36) {
            for (surface.buffer[width .. width + 14]) |cell|
                try std.testing.expectEqualStrings(" ", cell.char.grapheme);
        }
    }
}

test "selection checkbox is independent of the installed indicator" {
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var pkg: Package = .{ .Name = "installed", .Installed = true };
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 40, .height = 1 }, .cell_size = .{ .width = 10, .height = 20 } };
    const marked = try drawMarkedPackageRow(&pkg, ctx);
    const unmarked = try drawPackageRow(&pkg, ctx);
    try std.testing.expectEqualStrings("x", marked.buffer[1].char.grapheme);
    try std.testing.expectEqualStrings(" ", unmarked.buffer[1].char.grapheme);
    try std.testing.expectEqualStrings("●", marked.buffer[4].char.grapheme);
    try std.testing.expectEqualStrings("●", unmarked.buffer[4].char.grapheme);
}
