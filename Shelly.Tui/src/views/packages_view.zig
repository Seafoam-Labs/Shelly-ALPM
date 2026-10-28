const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Allocator = std.mem.Allocator;
const Package = @import("../models/packages.zig").Package;
const appendDetailList = @import("detail_format.zig").appendDetailList;
const formatSize = @import("detail_format.zig").formatSize;

/// Borrows display state and widgets owned by the application.
/// Query execution and user-action handling remain in Model.
pub const View = struct {
    text_field: *vxfw.TextField,
    list_view: *vxfw.ListView,
    selected_list_view: *vxfw.ListView,
    loading: bool,
    load_failed: bool,
    query: []const u8,
    filtered_count: usize,
    package_count: usize,
    pub fn appendContent(self: View, ctx: vxfw.DrawContext, children: *std.ArrayList(vxfw.SubSurface)) Allocator.Error!void {
        const arena = ctx.arena;
        const max = ctx.max.size();
        const right_w: u16 = @max(24, max.width / 4);
        const left_w: u16 = max.width -| right_w;

        // Row 1: search prompt + field
        var prompt: vxfw.Text = .{ .text = "❯", .style = .{ .fg = .{ .index = 4 } } };
        try children.append(arena, .{
            .origin = .{ .row = 1, .col = 0 },
            .surface = try prompt.draw(ctx.withConstraints(
                ctx.min,
                .{ .width = 2, .height = 1 },
            )),
        });
        try children.append(arena, .{
            .origin = .{ .row = 1, .col = 2 },
            .surface = try self.text_field.draw(ctx.withConstraints(
                ctx.min,
                .{ .width = max.width -| 2, .height = 1 },
            )),
        });

        // Rows 2..height-2: package list
        try children.append(arena, .{
            .origin = .{ .row = 2, .col = 0 },
            .surface = try self.list_view.draw(ctx.withConstraints(
                .{ .width = 0, .height = 0 },
                .{ .width = left_w -| 1, .height = max.height - 3 },
            )),
        });
        try children.append(arena, .{
            .origin = .{ .row = 2, .col = left_w },
            .surface = try self.selected_list_view.draw(ctx.withConstraints(.{ .width = 0, .height = 0 }, .{ .width = right_w, .height = max.height - 3 })),
        });

        if (self.loading or self.load_failed) {
            var message: vxfw.Text = if (self.loading)
                .{ .text = "Loading packages…", .style = .{ .fg = .{ .index = 245 } } }
            else
                .{ .text = "Could not load the package list.", .style = .{ .fg = .{ .index = 1 } } };
            try children.append(arena, .{
                .origin = .{ .row = 3, .col = 2 },
                .surface = try message.draw(ctx.withConstraints(
                    ctx.min,
                    .{ .width = max.width -| 2, .height = 1 },
                )),
                .z_index = 1,
            });
        }
    }
    pub fn statusText(self: View, arena: Allocator) Allocator.Error![]const u8 {
        if (self.loading) return "Loading packages…";
        if (self.load_failed) return "Could not load the package list.";
        if (self.query.len > 0) {
            return try std.fmt.allocPrint(arena, "{d} of {d} packages match", .{
                self.filtered_count, self.package_count,
            });
        }
        return try std.fmt.allocPrint(arena, "{d} packages", .{self.package_count});
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

    try lines.append(arena, try std.fmt.allocPrint(arena, "Repository:     {s}", .{pkg.Repository}));
    try lines.append(arena, try std.fmt.allocPrint(arena, "Version:        {s}", .{pkg.Version}));
    try lines.append(arena, try std.fmt.allocPrint(arena, "Installed:      {s}", .{if (pkg.Installed) "yes" else "no"}));
    if (pkg.Url) |url| {
        try lines.append(arena, try std.fmt.allocPrint(arena, "URL:            {s}", .{url}));
    }
    try appendDetailList(arena, &lines, "Licenses:     ", pkg.Licenses);
    try appendDetailList(arena, &lines, "Groups:       ", pkg.Groups);
    try appendDetailList(arena, &lines, "Depends:      ", pkg.Depends);
    try appendDetailList(arena, &lines, "Opt depends:  ", pkg.OptDepends);
    try appendDetailList(arena, &lines, "Provides:     ", pkg.Provides);
    try appendDetailList(arena, &lines, "Conflicts:    ", pkg.Conflicts);
    try appendDetailList(arena, &lines, "Replaces:     ", pkg.Replaces);
    try lines.append(arena, try std.fmt.allocPrint(arena, "Download size:  {s}", .{try formatSize(arena, pkg.DownloadSize)}));
    try lines.append(arena, try std.fmt.allocPrint(arena, "Installed size: {s}", .{try formatSize(arena, pkg.InstalledSize)}));
    if (pkg.BuildDate.len > 0) {
        try lines.append(arena, try std.fmt.allocPrint(arena, "Build date:     {s}", .{pkg.BuildDate}));
    }

    return try std.mem.join(arena, "\n", lines.items);
}
