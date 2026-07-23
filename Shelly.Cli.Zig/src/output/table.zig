const std = @import("std");

/// Render the same compact box table used by the C# CLI's BasicTable helper.
pub fn write(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    headers: []const []const u8,
    rows: []const []const []const u8,
    color_headers: bool,
) !void {
    if (headers.len == 0) return;

    const widths = try allocator.alloc(usize, headers.len);
    defer allocator.free(widths);
    for (headers, 0..) |header, index| widths[index] = header.len;
    for (rows) |row| {
        for (headers, 0..) |_, index| {
            const cell = if (index < row.len) row[index] else "";
            widths[index] = @max(widths[index], cell.len);
        }
    }

    try border(writer, "┌", "┬", "┐", widths);
    try writer.writeAll("│");
    for (headers, 0..) |header, index| {
        try writer.writeByte(' ');
        if (color_headers) try writer.writeAll("\x1b[38;2;128;128;0m");
        try writer.writeAll(header);
        if (color_headers) try writer.writeAll("\x1b[0m");
        try writer.splatByteAll(' ', widths[index] - header.len + 1);
        try writer.writeAll("│");
    }
    try writer.writeByte('\n');
    try border(writer, "├", "┼", "┤", widths);

    for (rows) |row| {
        try writer.writeAll("│");
        for (headers, 0..) |_, index| {
            const cell = if (index < row.len) row[index] else "";
            try writer.writeByte(' ');
            try writer.writeAll(cell);
            try writer.splatByteAll(' ', widths[index] - cell.len + 1);
            try writer.writeAll("│");
        }
        try writer.writeByte('\n');
    }
    try border(writer, "└", "┴", "┘", widths);
}

fn border(
    writer: *std.Io.Writer,
    left: []const u8,
    middle: []const u8,
    right: []const u8,
    widths: []const usize,
) !void {
    try writer.writeAll(left);
    for (widths, 0..) |width, index| {
        var count: usize = 0;
        while (count < width + 2) : (count += 1) try writer.writeAll("─");
        try writer.writeAll(if (index + 1 == widths.len) right else middle);
    }
    try writer.writeByte('\n');
}

test "renders the C# BasicTable box layout" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    const rows = [_][]const []const u8{
        &.{ "one", "1" },
        &.{ "longer", "22" },
    };
    try write(std.testing.allocator, &output.writer, &.{ "Name", "Value" }, &rows, false);
    try std.testing.expectEqualStrings(
        \\┌────────┬───────┐
        \\│ Name   │ Value │
        \\├────────┼───────┤
        \\│ one    │ 1     │
        \\│ longer │ 22    │
        \\└────────┴───────┘
        \\
    ,
        output.writer.buffered(),
    );
}
