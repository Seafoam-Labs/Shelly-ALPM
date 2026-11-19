const std = @import("std");
const drawColumn = @import("list_table.zig").drawColumn;
const styles = @import("styles.zig");
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
    list_percent: u8 = 40,
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
        if (max.width < 2 or max.height < 3) return;
        const split = max.width >= 64;
        if (!split) if (self.help) |panel| {
            try children.append(arena, .{
                .origin = .{ .row = 1, .col = 0 },
                .surface = try panel.draw(ctx.withConstraints(.{}, .{ .width = max.width, .height = max.height -| 2 })),
            });
            return;
        };
        const left_w: u16 = if (split) @import("split_layout.zig").listWidth(max.width, self.list_percent) else max.width;
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
            .focused = !self.list_active and !self.details_active,
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

        if ((split or !self.details_active) and height > 0) {
            const message: ?[]const u8 = if (self.loading)
                "Loading packages…"
            else if (self.load_failed)
                "Could not load the package list."
            else if (self.filtered_count == 0)
                "No packages match."
            else
                null;
            var label: vxfw.Text = .{ .text = message orelse "" };
            const content: vxfw.Widget = if (message != null) label.widget() else .{ .userdata = self.list_view, .drawFn = drawPackageTable };
            var border: Border = .{
                .child = content,
                .focused = self.list_active and !self.details_active,
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
            var empty: vxfw.Text = .{ .text = if (self.loading) (if (split) "" else "Loading packages…") else if (self.load_failed) "Package details unavailable." else "Select a package to see details." };
            var border: Border = .{
                .child = if (self.selected != null and !self.loading and !self.load_failed) self.details_scroll.widget() else empty.widget(),
                .labels = &labels,
                .focused = self.details_active,
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
        if (self.selected_count > 0) return std.fmt.allocPrint(arena, "{d} selected · {d} installed · {d} available", .{ self.selected_count, self.selected_installed, self.selected_count - self.selected_installed });
        if (self.installed_only) return std.fmt.allocPrint(arena, "{d} installed matches", .{self.filtered_count});
        return std.fmt.allocPrint(arena, "{d} of {d} packages", .{ self.filtered_count, self.package_count });
    }
};

const marker_width = 2;
const selected_width: u16 = "Selected".len;
const minimum_table_width = 30;

fn repositoryColumn(width: u16) u16 {
    const available = width - selected_width;
    return available - @max(11, available / 3);
}

fn drawPackageTable(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const list: *vxfw.ListView = @ptrCast(@alignCast(ptr));
    const size = ctx.max.size();
    const gutter: u16 = if (list.draw_cursor) 2 else 0;
    const width = size.width -| gutter;
    if (width < minimum_table_width or size.height < 2) return list.draw(ctx);

    const repo = repositoryColumn(width);
    const header = try vxfw.Surface.init(ctx.arena, .{ .userdata = ptr, .drawFn = drawPackageTable }, .{ .width = size.width, .height = 1 });
    @memset(header.buffer, .{});
    try drawColumn(ctx, header.buffer, gutter + marker_width, repo - marker_width, "Packages", styles.emphasis);
    try drawColumn(ctx, header.buffer, gutter + repo, width - selected_width - repo, "Repository", styles.emphasis);
    try drawColumn(ctx, header.buffer, size.width - selected_width, selected_width, "Selected", styles.emphasis);
    const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = header };
    children[1] = .{
        .origin = .{ .row = 1, .col = 0 },
        .surface = try list.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height - 1 })),
    };
    return .{ .size = size, .widget = header.widget, .buffer = &.{}, .children = children };
}

pub fn drawPackageRow(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    return drawRow(ptr, ctx, false);
}

pub fn drawMarkedPackageRow(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    return drawRow(ptr, ctx, true);
}

fn drawRow(ptr: *anyopaque, ctx: vxfw.DrawContext, selected: bool) Allocator.Error!vxfw.Surface {
    const pkg: *const Package = @ptrCast(@alignCast(ptr));
    const arena = ctx.arena;

    const width = ctx.max.width orelse ctx.min.width;
    const table = width >= minimum_table_width;
    const checkbox_col = if (table) width - selected_width else width -| 3;
    const name = try diagnostics.sanitizeAlloc(arena, pkg.Name);
    const repository = try diagnostics.sanitizeAlloc(arena, pkg.Repository);
    const widget: vxfw.Widget = .{ .userdata = ptr, .drawFn = if (selected) drawMarkedPackageRow else drawPackageRow };
    const surface = try vxfw.Surface.init(arena, widget, .{ .width = width, .height = 1 });
    @memset(surface.buffer, .{});
    if (pkg.Installed)
        try drawColumn(ctx, surface.buffer, 0, @min(marker_width, checkbox_col), "●", .{ .fg = .{ .index = 2 } });
    if (table) {
        const repo = repositoryColumn(width);
        try drawColumn(ctx, surface.buffer, marker_width, repo - marker_width - 1, name, styles.emphasis);
        try drawColumn(ctx, surface.buffer, repo, checkbox_col - repo - 1, repository, styles.secondary);
    } else {
        const summary = if (repository.len == 0) name else try std.fmt.allocPrint(arena, "{s} · {s}", .{ name, repository });
        try drawColumn(ctx, surface.buffer, marker_width, checkbox_col -| (marker_width + 1), summary, styles.emphasis);
    }
    try drawColumn(ctx, surface.buffer, checkbox_col, @min(3, width - checkbox_col), if (selected) "[x]" else "[ ]", .{ .bold = selected });
    return surface;
}

pub fn drawSelectedRow(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const name_ptr: *const []const u8 = @ptrCast(@alignCast(ptr));
    const name = name_ptr.*;
    const arena = ctx.arena;
    var spans: std.ArrayList(vxfw.RichText.TextSpan) = .empty;
    try spans.append(arena, .{ .text = try diagnostics.sanitizeAlloc(arena, name) });
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

const detail_fields = @import("detail_fields.zig");
const DetailField = detail_fields.Field;
const listField = detail_fields.listField;

/// Render a structured document for ScrollView. Values wrap independently of
/// labels, so continuation lines keep their indentation after resizing.
pub fn drawDetails(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const pkg: *const Package = @ptrCast(@alignCast(ptr));
    const arena = ctx.arena;
    var fields: std.ArrayList(DetailField) = .empty;
    try fields.appendSlice(arena, &.{
        .{ .label = "Description", .value = if (pkg.Description.len > 0) pkg.Description else "No description." },
        .{ .label = "Version", .value = pkg.Version, .gap = true },
        .{ .label = "Repository", .value = pkg.Repository },
        .{ .label = "Installed", .value = if (pkg.Installed) "Yes" else "No" },
    });
    if (pkg.Licenses.len > 0) try fields.append(arena, .{ .label = "Licenses", .value = try std.mem.join(arena, ", ", pkg.Licenses) });
    if (pkg.Groups.len > 0) try fields.append(arena, .{ .label = "Groups", .value = try std.mem.join(arena, ", ", pkg.Groups) });
    if (pkg.Url) |url| try fields.append(arena, .{ .label = "URL", .value = url, .preserve_url = true });
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

    return detail_fields.draw(.{ .userdata = ptr, .drawFn = drawDetails }, ctx, fields.items);
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
    try std.testing.expectEqualStrings("x", marked.buffer[40 - selected_width + 1].char.grapheme);
    try std.testing.expectEqualStrings(" ", unmarked.buffer[40 - selected_width + 1].char.grapheme);
    try std.testing.expectEqualStrings("●", marked.buffer[0].char.grapheme);
    try std.testing.expectEqualStrings("●", unmarked.buffer[0].char.grapheme);
}

test "package rows show repository and escape terminal control bytes without changing identity" {
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const name = "demo\x1b[31m\r\x7f";
    var pkg: Package = .{ .Name = name, .Repository = "extra" };
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 1 }, .cell_size = .{ .width = 10, .height = 20 } };
    inline for (.{ drawPackageRow, drawMarkedPackageRow }) |draw| {
        const surface = try draw(&pkg, ctx);
        var text: std.ArrayList(u8) = .empty;
        for (surface.buffer) |cell| try text.appendSlice(arena.allocator(), cell.char.grapheme);
        try std.testing.expect(std.mem.indexOf(u8, text.items, "demo\\x1b[31m\\x0d\\x7f") != null);
        try std.testing.expectEqualStrings("e", surface.buffer[repositoryColumn(80)].char.grapheme);
        try std.testing.expect(std.mem.indexOfAny(u8, text.items, "\x1b\r\x7f") == null);
        try std.testing.expectEqualStrings(name, pkg.Name);
    }
}

test "selected package names escape terminal control bytes" {
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var name: []const u8 = "demo\x1b[31m\r\x7f";
    const surface = try drawSelectedRow(@ptrCast(&name), .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 1 }, .cell_size = .{ .width = 10, .height = 20 } });
    var text: std.ArrayList(u8) = .empty;
    for (surface.buffer) |cell| try text.appendSlice(arena.allocator(), cell.char.grapheme);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "demo\\x1b[31m\\x0d\\x7f") != null);
    try std.testing.expect(std.mem.indexOfAny(u8, text.items, "\x1b\r\x7f") == null);
    try std.testing.expectEqualStrings("demo\x1b[31m\r\x7f", name);
}
