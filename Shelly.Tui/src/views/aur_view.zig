const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Allocator = std.mem.Allocator;
const AurPackage = @import("../models/packages.zig").AurPackage;
const appendDetailList = @import("detail_format.zig").appendDetailList;
const formatEpoch = @import("detail_format.zig").formatEpoch;

/// Borrows display state and widgets owned by the application.
/// Query execution and user-action handling remain in Model.
pub const View = struct {
    aur_field: *vxfw.TextField,
    aur_list: *vxfw.ListView,
    searching: bool,
    aur_failed: bool,
    aur_query: []const u8,
    result_count: usize,
    pub fn appendContent(self: View, ctx: vxfw.DrawContext, children: *std.ArrayList(vxfw.SubSurface)) Allocator.Error!void {
        const arena = ctx.arena;
        const max = ctx.max.size();

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
            .surface = try self.aur_field.draw(ctx.withConstraints(
                ctx.min,
                .{ .width = max.width -| 2, .height = 1 },
            )),
        });

        // Rows 2..height-2: results
        try children.append(arena, .{
            .origin = .{ .row = 2, .col = 0 },
            .surface = try self.aur_list.draw(ctx.withConstraints(
                .{ .width = 0, .height = 0 },
                .{ .width = max.width, .height = max.height - 3 },
            )),
        });

        if (try self.aurMessage(arena)) |message| {
            var message_text: vxfw.Text = .{
                .text = message.text,
                .style = .{ .fg = .{ .index = if (message.red) @as(u8, 1) else 245 } },
            };
            try children.append(arena, .{
                .origin = .{ .row = 3, .col = 2 },
                .surface = try message_text.draw(ctx.withConstraints(
                    ctx.min,
                    .{ .width = max.width -| 2, .height = 1 },
                )),
                .z_index = 1,
            });
        }
    }
    fn aurMessage(self: View, arena: Allocator) Allocator.Error!?struct { text: []const u8, red: bool } {
        if (self.searching) {
            return .{
                .text = try std.fmt.allocPrint(arena, "Searching AUR for '{s}'…", .{self.aur_query}),
                .red = false,
            };
        }
        if (self.aur_failed) {
            return .{ .text = "Could not search the configured AUR service.", .red = true };
        }
        if (self.aur_query.len == 0) {
            return .{ .text = "Type a search term and press Enter to query the AUR.", .red = false };
        }
        if (self.result_count == 0) {
            return .{ .text = "No AUR packages matched.", .red = false };
        }
        return null;
    }
    pub fn statusText(self: View, arena: Allocator) Allocator.Error![]const u8 {
        if (self.searching) {
            return try std.fmt.allocPrint(arena, "Searching AUR for '{s}'…", .{self.aur_query});
        }
        if (self.aur_failed) return "Could not search the configured AUR service.";
        if (self.aur_query.len == 0) return "AUR — type a query and press Enter";
        return try std.fmt.allocPrint(arena, "{d} AUR results for '{s}'", .{
            self.result_count, self.aur_query,
        });
    }
};

pub fn drawAurRow(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const pkg: *const AurPackage = @ptrCast(@alignCast(ptr));
    const arena = ctx.arena;

    var spans: std.ArrayList(vxfw.RichText.TextSpan) = .empty;
    try spans.append(arena, .{ .text = "  " });
    try spans.append(arena, .{ .text = pkg.Name, .style = .{ .bold = true } });
    try spans.append(arena, .{ .text = "  " });
    try spans.append(arena, .{
        .text = pkg.Version,
        .style = .{ .fg = .{ .index = if (pkg.OutOfDate != null) @as(u8, 1) else 245 } },
    });
    try spans.append(arena, .{
        .text = try std.fmt.allocPrint(arena, " ▲ {d}", .{pkg.NumVotes}),
        .style = .{ .fg = .{ .index = 245 } },
    });
    if (pkg.Description) |description| {
        if (description.len > 0) {
            try spans.append(arena, .{ .text = " — " });
            try spans.append(arena, .{
                .text = description,
                .style = .{ .fg = .{ .index = 245 } },
            });
        }
    }

    const rich = try arena.create(vxfw.RichText);
    rich.* = .{
        .text = spans.items,
        .softwrap = false,
        .overflow = .ellipsis,
    };
    return rich.draw(ctx);
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
