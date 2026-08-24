const std = @import("std");
const colors = @import("colors.zig");
const output_config = @import("config.zig");
const terminal = @import("terminal.zig");
const runtime = @import("../runtime/context.zig");

const minimum_boxed_column_width: usize = 3;

pub const Options = struct {
    color_headers: bool = false,
    max_width: ?usize = null,
};

const Fragment = struct {
    text: []const u8,
    width: usize,
};

const Unit = struct {
    length: usize,
    width: usize,
    is_space: bool = false,
};

/// Render a compact table which preserves its natural layout for redirected
/// output and scales to the live terminal width for interactive output.
pub fn write(
    context: *runtime.RuntimeContext,
    headers: []const []const u8,
    rows: []const []const []const u8,
) !void {
    return writeWithOptions(
        context.allocator,
        context.stdout,
        headers,
        rows,
        .{
            .color_headers = output_config.supportsAnsi(context),
            .max_width = terminal.interactiveWidth(context),
        },
    );
}

pub fn writeWithOptions(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    headers: []const []const u8,
    rows: []const []const []const u8,
    options: Options,
) !void {
    if (headers.len == 0) return;

    var storage = std.heap.ArenaAllocator.init(allocator);
    defer storage.deinit();
    const scratch = storage.allocator();

    const widths = try scratch.alloc(usize, headers.len);
    for (headers, 0..) |header, index| widths[index] = longestLineWidth(header);
    for (rows) |row| {
        for (headers, 0..) |_, index| {
            const cell = if (index < row.len) row[index] else "";
            widths[index] = @max(widths[index], longestLineWidth(cell));
        }
    }

    if (options.max_width) |max_width| {
        if (boxedWidth(widths) > max_width) {
            if (!canRenderBox(headers.len, max_width))
                return writeStacked(scratch, writer, headers, rows, options.color_headers, max_width);
            try allocateWidths(scratch, widths, max_width);
        }
    }

    try border(writer, "┌", "┬", "┐", widths);
    try writeLogicalRow(scratch, writer, headers, widths, options.color_headers);
    try border(writer, "├", "┼", "┤", widths);
    for (rows) |row| try writeLogicalRow(scratch, writer, row, widths, false);
    try border(writer, "└", "┴", "┘", widths);
}

fn boxedWidth(widths: []const usize) usize {
    var width: usize = 1;
    for (widths) |column_width| width += column_width + 3;
    return width;
}

fn boxOverhead(column_count: usize) usize {
    return 1 + column_count * 3;
}

fn canRenderBox(column_count: usize, max_width: usize) bool {
    return max_width >= boxOverhead(column_count) + column_count * minimum_boxed_column_width;
}

fn allocateWidths(
    allocator: std.mem.Allocator,
    widths: []usize,
    max_width: usize,
) !void {
    const available = max_width - boxOverhead(widths.len);
    const natural = try allocator.dupe(usize, widths);
    const floors = try allocator.alloc(usize, widths.len);

    var assigned: usize = 0;
    for (widths, floors) |*width, *floor| {
        floor.* = @min(width.*, minimum_boxed_column_width);
        const preferred_minimum = @max(
            floor.*,
            @min(@as(usize, 12), width.*),
        );
        width.* = @min(width.*, preferred_minimum);
        assigned += width.*;
    }

    while (assigned > available) {
        var candidate: ?usize = null;
        for (widths, floors, 0..) |width, floor, index| {
            if (width <= floor) continue;
            if (candidate == null or widths[candidate.?] < width) candidate = index;
        }
        const index = candidate orelse break;
        widths[index] -= 1;
        assigned -= 1;
    }

    while (assigned < available) {
        var progressed = false;
        for (widths, natural) |*width, natural_width| {
            if (assigned == available) break;
            if (width.* >= natural_width) continue;
            width.* += 1;
            assigned += 1;
            progressed = true;
        }
        if (!progressed) break;
    }
}

fn writeLogicalRow(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    cells: []const []const u8,
    widths: []const usize,
    color_cells: bool,
) !void {
    const wrapped = try allocator.alloc([]const Fragment, widths.len);
    var height: usize = 1;
    for (widths, 0..) |width, index| {
        const cell = if (index < cells.len) cells[index] else "";
        wrapped[index] = try wrapCell(allocator, cell, width);
        height = @max(height, wrapped[index].len);
    }

    for (0..height) |line_index| {
        try writer.writeAll("│");
        for (widths, wrapped) |width, fragments| {
            const fragment: Fragment = if (line_index < fragments.len)
                fragments[line_index]
            else
                .{ .text = "", .width = 0 };
            try writer.writeByte(' ');
            if (color_cells and fragment.text.len != 0) try writer.writeAll(colors.colorCode(.warning));
            try writeCellText(writer, fragment.text);
            if (color_cells and fragment.text.len != 0) try writer.writeAll(colors.reset);
            try writer.splatByteAll(' ', width - fragment.width + 1);
            try writer.writeAll("│");
        }
        try writer.writeByte('\n');
    }
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
        for (0..width + 2) |_| try writer.writeAll("─");
        try writer.writeAll(if (index + 1 == widths.len) right else middle);
    }
    try writer.writeByte('\n');
}

fn writeStacked(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    headers: []const []const u8,
    rows: []const []const []const u8,
    color_headers: bool,
    max_width: usize,
) !void {
    for (rows, 0..) |row, row_index| {
        if (row_index != 0) try writer.writeByte('\n');
        for (headers, 0..) |header, index| {
            const label = try std.fmt.allocPrint(allocator, "{s}:", .{header});
            const label_fragments = try wrapCell(allocator, label, @max(@as(usize, 1), max_width));
            for (label_fragments) |fragment| {
                if (color_headers and fragment.text.len != 0) try writer.writeAll(colors.colorCode(.warning));
                try writeCellText(writer, fragment.text);
                if (color_headers and fragment.text.len != 0) try writer.writeAll(colors.reset);
                try writer.writeByte('\n');
            }

            const indent_width: usize = if (max_width > 2) 2 else 0;
            const value_width = @max(@as(usize, 1), max_width -| indent_width);
            const value = if (index < row.len) row[index] else "";
            const value_fragments = try wrapCell(allocator, value, value_width);
            for (value_fragments) |fragment| {
                try writer.splatByteAll(' ', indent_width);
                try writeCellText(writer, fragment.text);
                try writer.writeByte('\n');
            }
        }
    }
}

fn wrapCell(allocator: std.mem.Allocator, value: []const u8, width: usize) ![]const Fragment {
    var fragments: std.ArrayList(Fragment) = .empty;
    var logical_start: usize = 0;
    while (true) {
        const relative_end = std.mem.indexOfScalar(u8, value[logical_start..], '\n');
        const logical_end = if (relative_end) |offset| logical_start + offset else value.len;
        try wrapLogicalLine(allocator, &fragments, value[logical_start..logical_end], @max(@as(usize, 1), width));
        if (relative_end == null) break;
        logical_start = logical_end + 1;
        if (logical_start == value.len) {
            try fragments.append(allocator, .{ .text = "", .width = 0 });
            break;
        }
    }
    return fragments.toOwnedSlice(allocator);
}

fn wrapLogicalLine(
    allocator: std.mem.Allocator,
    fragments: *std.ArrayList(Fragment),
    line: []const u8,
    maximum_width: usize,
) !void {
    if (line.len == 0) {
        try fragments.append(allocator, .{ .text = "", .width = 0 });
        return;
    }

    var start = skipSpaces(line, 0);
    if (start == line.len) {
        try fragments.append(allocator, .{ .text = "", .width = 0 });
        return;
    }

    while (start < line.len) {
        var index = start;
        var used_width: usize = 0;
        var break_index: ?usize = null;
        var break_width: usize = 0;
        var break_next: usize = 0;

        while (index < line.len) {
            const unit = nextUnit(line, index);
            if (unit.is_space) {
                break_index = index;
                break_width = used_width;
                break_next = index + unit.length;
            }
            if (unit.width != 0 and used_width + unit.width > maximum_width) break;
            used_width += unit.width;
            index += unit.length;
        }

        if (index == line.len) {
            const end = trimEndSpaces(line, start, line.len);
            try fragments.append(allocator, .{
                .text = line[start..end],
                .width = displayWidth(line[start..end]),
            });
            break;
        }

        if (break_index) |word_end| {
            if (word_end > start) {
                try fragments.append(allocator, .{
                    .text = line[start..word_end],
                    .width = break_width,
                });
                start = skipSpaces(line, break_next);
                continue;
            }
        }

        if (index == start) {
            const unit = nextUnit(line, index);
            index += unit.length;
            used_width = unit.width;
        }
        try fragments.append(allocator, .{ .text = line[start..index], .width = used_width });
        start = skipSpaces(line, index);
    }
}

fn skipSpaces(value: []const u8, initial: usize) usize {
    var index = initial;
    while (index < value.len) {
        const unit = nextUnit(value, index);
        if (!unit.is_space) break;
        index += unit.length;
    }
    return index;
}

fn trimEndSpaces(value: []const u8, start: usize, initial_end: usize) usize {
    var end = initial_end;
    while (end > start and (value[end - 1] == ' ' or value[end - 1] == '\t' or value[end - 1] == '\r')) end -= 1;
    return end;
}

fn longestLineWidth(value: []const u8) usize {
    var maximum: usize = 0;
    var lines = std.mem.splitScalar(u8, value, '\n');
    while (lines.next()) |line| maximum = @max(maximum, displayWidth(line));
    return maximum;
}

fn displayWidth(value: []const u8) usize {
    var width: usize = 0;
    var index: usize = 0;
    while (index < value.len) {
        const unit = nextUnit(value, index);
        width += unit.width;
        index += unit.length;
    }
    return width;
}

fn writeCellText(writer: *std.Io.Writer, value: []const u8) !void {
    var index: usize = 0;
    while (index < value.len) {
        const unit = nextUnit(value, index);
        const first = value[index];
        if (first < 0x20 or first == 0x7f) {
            if (first == 0x1b and unit.width == 0)
                try writer.writeAll(value[index .. index + unit.length])
            else
                try writer.writeByte(' ');
        } else {
            try writer.writeAll(value[index .. index + unit.length]);
        }
        index += unit.length;
    }
}

fn nextUnit(value: []const u8, index: usize) Unit {
    const first = value[index];
    if (first == 0x1b and index + 1 < value.len and value[index + 1] == '[') {
        var end = index + 2;
        while (end < value.len) : (end += 1) {
            if (value[end] >= 0x40 and value[end] <= 0x7e)
                return .{ .length = end - index + 1, .width = 0 };
        }
    }
    if (first < 0x80) return .{
        .length = 1,
        .width = 1,
        .is_space = first == ' ' or first == '\t' or first == '\r',
    };

    const sequence_length = std.unicode.utf8ByteSequenceLength(first) catch 1;
    const length: usize = @intCast(sequence_length);
    if (index + length > value.len) return .{ .length = 1, .width = 1 };
    const codepoint = std.unicode.utf8Decode(value[index..][0..length]) catch
        return .{ .length = 1, .width = 1 };
    return .{ .length = length, .width = codepointWidth(codepoint) };
}

fn codepointWidth(codepoint: u21) usize {
    if (codepoint == 0x200d or codepoint == 0xfe0f or
        (codepoint >= 0x0300 and codepoint <= 0x036f) or
        (codepoint >= 0x1ab0 and codepoint <= 0x1aff) or
        (codepoint >= 0x1dc0 and codepoint <= 0x1dff) or
        (codepoint >= 0x20d0 and codepoint <= 0x20ff) or
        (codepoint >= 0xfe20 and codepoint <= 0xfe2f)) return 0;

    if ((codepoint >= 0x1100 and codepoint <= 0x115f) or
        codepoint == 0x2329 or codepoint == 0x232a or
        (codepoint >= 0x2e80 and codepoint <= 0xa4cf and codepoint != 0x303f) or
        (codepoint >= 0xac00 and codepoint <= 0xd7a3) or
        (codepoint >= 0xf900 and codepoint <= 0xfaff) or
        (codepoint >= 0xfe10 and codepoint <= 0xfe19) or
        (codepoint >= 0xfe30 and codepoint <= 0xfe6f) or
        (codepoint >= 0xff00 and codepoint <= 0xff60) or
        (codepoint >= 0xffe0 and codepoint <= 0xffe6) or
        (codepoint >= 0x1f300 and codepoint <= 0x1faff) or
        (codepoint >= 0x20000 and codepoint <= 0x3fffd)) return 2;
    return 1;
}

test "renders the existing compact box layout when it fits" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    const rows = [_][]const []const u8{
        &.{ "one", "1" },
        &.{ "longer", "22" },
    };
    try writeWithOptions(std.testing.allocator, &output.writer, &.{ "Name", "Value" }, &rows, .{});
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

test "responsive table wraps long search rows without exceeding width" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    const rows = [_][]const []const u8{&.{
        "codelldb-bin",
        "1.12.3-1",
        "dmitmel",
        "2026-08-24 00:08:13",
        "A native debugger extension for VSCode based on LLDB. Also known as a very long description.",
    }};
    try writeWithOptions(
        std.testing.allocator,
        &output.writer,
        &.{ "Name", "Version", "Maintainer/Repository", "Last Updated/Build Date", "Description" },
        &rows,
        .{ .max_width = 79 },
    );

    var lines = std.mem.splitScalar(u8, output.writer.buffered(), '\n');
    while (lines.next()) |line| try std.testing.expect(displayWidth(line) <= 79);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "native") != null);
    try std.testing.expect(std.mem.count(u8, output.writer.buffered(), "│") > 12);
}

test "responsive table honors newlines and Unicode display width" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    const rows = [_][]const []const u8{&.{ "软件", "network\nwayland" }};
    try writeWithOptions(
        std.testing.allocator,
        &output.writer,
        &.{ "Name", "Permissions" },
        &rows,
        .{ .max_width = 24, .color_headers = true },
    );
    var lines = std.mem.splitScalar(u8, output.writer.buffered(), '\n');
    while (lines.next()) |line| try std.testing.expect(displayWidth(line) <= 24);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "network") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "wayland") != null);
}

test "very narrow tables fall back to stacked fields" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    const rows = [_][]const []const u8{&.{ "demo", "a description that wraps" }};
    try writeWithOptions(
        std.testing.allocator,
        &output.writer,
        &.{ "Name", "Description" },
        &rows,
        .{ .max_width = 10 },
    );
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "Name:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "┌") == null);
    var lines = std.mem.splitScalar(u8, output.writer.buffered(), '\n');
    while (lines.next()) |line| try std.testing.expect(displayWidth(line) <= 10);
}
