const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const diagnostics = @import("diagnostics");
const Allocator = std.mem.Allocator;

pub const Field = struct {
    label: []const u8,
    value: []const u8,
    gap: bool = false,
    preserve_url: bool = false,
};

pub fn listField(arena: Allocator, fields: *std.ArrayList(Field), label: []const u8, items: []const []const u8) Allocator.Error!void {
    if (items.len == 0) return;
    try fields.append(arena, .{ .label = label, .value = try std.mem.join(arena, "\n", items), .gap = true });
}

fn displayValue(arena: Allocator, field: Field) Allocator.Error![]const u8 {
    if (!field.preserve_url) return std.fmt.allocPrint(arena, "{f}", .{diagnostics.safe(field.value)});
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(arena);
    const hex = "0123456789abcdef";
    for (field.value) |byte| {
        if ((byte < 0x20 and byte != '\n' and byte != '\t') or byte == 0x7f)
            try out.appendSlice(arena, &.{ '\\', 'x', hex[byte >> 4], hex[byte & 15] })
        else
            try out.append(arena, byte);
    }
    return out.toOwnedSlice(arena);
}

pub fn draw(widget: vxfw.Widget, ctx: vxfw.DrawContext, fields: []const Field) Allocator.Error!vxfw.Surface {
    const arena = ctx.arena;
    const width = ctx.max.width orelse ctx.min.width;
    const columns = width >= 36;
    const label_width: u16 = if (columns) 12 else width;
    const value_col: u16 = if (columns) 14 else 0;
    const value_width = width - value_col;
    var children: std.ArrayList(vxfw.SubSurface) = .empty;
    var row: u16 = 0;
    for (fields) |field| {
        if (field.gap or (!columns and row > 0)) row += 1;
        var label: vxfw.Text = .{ .text = field.label, .style = .{ .bold = true, .fg = .{ .index = 7 } } };
        const label_surface = try label.draw(ctx.withConstraints(.{}, .{ .width = label_width, .height = null }));
        try children.append(arena, .{ .origin = .{ .row = row, .col = 0 }, .surface = label_surface });
        const value_row = row + if (columns) @as(u16, 0) else label_surface.size.height;
        var value: vxfw.Text = .{ .text = try displayValue(arena, field), .softwrap = true };
        const value_surface = try value.draw(ctx.withConstraints(
            .{ .width = value_width },
            .{ .width = value_width, .height = null },
        ));
        try children.append(arena, .{ .origin = .{ .row = value_row, .col = value_col }, .surface = value_surface });
        row = @max(row + label_surface.size.height, value_row + value_surface.size.height);
    }
    // Flatten the document into one scrollable surface; no frame-arena Text
    // widgets need to survive the draw call.
    const surface = try vxfw.Surface.init(arena, widget, .{ .width = width, .height = row });
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

test "package homepage URLs retain paths and queries while escaping terminal controls" {
    const url = "https://example.org/project/releases?version=1#details";
    const literal = try displayValue(std.testing.allocator, .{ .label = "URL", .value = url, .preserve_url = true });
    defer std.testing.allocator.free(literal);
    try std.testing.expectEqualStrings(url, literal);
    const escaped = try displayValue(std.testing.allocator, .{ .label = "URL", .value = "https://example.org/path\x1b[31m", .preserve_url = true });
    defer std.testing.allocator.free(escaped);
    try std.testing.expectEqualStrings("https://example.org/path\\x1b[31m", escaped);
}
