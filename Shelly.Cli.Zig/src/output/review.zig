const std = @import("std");

pub const DiffKind = enum {
    unchanged,
    added,
    removed,
};

pub const DiffLine = struct {
    kind: DiffKind,
    text: []const u8,
};

pub fn buildDiff(
    allocator: std.mem.Allocator,
    old_content: []const u8,
    new_content: []const u8,
) ![]DiffLine {
    var old_lines: std.ArrayList([]const u8) = .empty;
    defer old_lines.deinit(allocator);
    var old_iterator = std.mem.splitScalar(u8, old_content, '\n');
    while (old_iterator.next()) |line| try old_lines.append(allocator, trimCarriageReturn(line));

    var new_lines: std.ArrayList([]const u8) = .empty;
    defer new_lines.deinit(allocator);
    var new_iterator = std.mem.splitScalar(u8, new_content, '\n');
    while (new_iterator.next()) |line| try new_lines.append(allocator, trimCarriageReturn(line));

    const columns = new_lines.items.len + 1;
    const cells = try allocator.alloc(usize, (old_lines.items.len + 1) * columns);
    defer allocator.free(cells);
    @memset(cells, 0);

    var old_index = old_lines.items.len;
    while (old_index > 0) {
        old_index -= 1;
        var new_index = new_lines.items.len;
        while (new_index > 0) {
            new_index -= 1;
            cells[old_index * columns + new_index] = if (std.mem.eql(
                u8,
                old_lines.items[old_index],
                new_lines.items[new_index],
            ))
                cells[(old_index + 1) * columns + new_index + 1] + 1
            else
                @max(
                    cells[(old_index + 1) * columns + new_index],
                    cells[old_index * columns + new_index + 1],
                );
        }
    }

    var result: std.ArrayList(DiffLine) = .empty;
    errdefer result.deinit(allocator);
    old_index = 0;
    var new_index: usize = 0;
    while (old_index < old_lines.items.len or new_index < new_lines.items.len) {
        if (old_index < old_lines.items.len and new_index < new_lines.items.len and
            std.mem.eql(u8, old_lines.items[old_index], new_lines.items[new_index]))
        {
            try result.append(allocator, .{ .kind = .unchanged, .text = old_lines.items[old_index] });
            old_index += 1;
            new_index += 1;
        } else if (new_index < new_lines.items.len and
            (old_index >= old_lines.items.len or
                cells[old_index * columns + new_index + 1] >=
                    cells[(old_index + 1) * columns + new_index]))
        {
            try result.append(allocator, .{ .kind = .added, .text = new_lines.items[new_index] });
            new_index += 1;
        } else {
            try result.append(allocator, .{ .kind = .removed, .text = old_lines.items[old_index] });
            old_index += 1;
        }
    }
    return result.toOwnedSlice(allocator);
}

fn trimCarriageReturn(line: []const u8) []const u8 {
    return std.mem.trimEnd(u8, line, "\r");
}

test "diff preserves C# LCS ordering and line kinds" {
    const lines = try buildDiff(std.testing.allocator, "one\ntwo\n", "one\nthree\n");
    defer std.testing.allocator.free(lines);

    try std.testing.expectEqual(@as(usize, 4), lines.len);
    try std.testing.expectEqual(DiffKind.unchanged, lines[0].kind);
    try std.testing.expectEqual(DiffKind.added, lines[1].kind);
    try std.testing.expectEqualStrings("three", lines[1].text);
    try std.testing.expectEqual(DiffKind.removed, lines[2].kind);
    try std.testing.expectEqualStrings("two", lines[2].text);
}
