const std = @import("std");

/// the positions of rows to replace, or null when the whole list has to be
/// rebuilt: rows moved, were added or removed, or more than `limit` changed.
/// `context` answers `sameRow(i)` and `unchanged(i)` for the rows at `i`.
pub fn changedRows(alloc: std.mem.Allocator, old_len: usize, new_len: usize, limit: usize, context: anytype) error{OutOfMemory}!?[]usize {
    if (old_len != new_len) return null;

    var changed: std.ArrayListUnmanaged(usize) = .empty;
    errdefer changed.deinit(alloc);
    for (0..new_len) |i| {
        const same = context.sameRow(i);
        if (same and context.unchanged(i)) continue;
        if (!same or changed.items.len == limit) {
            changed.deinit(alloc);
            return null;
        }
        try changed.append(alloc, i);
    }
    return try changed.toOwnedSlice(alloc);
}

const testing = std.testing;

const Row = struct { name: []const u8, version: u32 };

const TestContext = struct {
    old: []const Row,
    new: []const Row,

    pub fn sameRow(self: TestContext, i: usize) bool {
        return std.mem.eql(u8, self.old[i].name, self.new[i].name);
    }

    pub fn unchanged(self: TestContext, i: usize) bool {
        return self.old[i].version == self.new[i].version;
    }
};

fn diff(old: []const Row, new: []const Row, limit: usize) !?[]usize {
    return changedRows(testing.allocator, old.len, new.len, limit, TestContext{ .old = old, .new = new });
}

test "equal lists change no row" {
    const rows = [_]Row{ .{ .name = "a", .version = 1 }, .{ .name = "b", .version = 1 } };
    const changed = (try diff(&rows, &rows, 10)) orelse return error.RebuildExpectedNot;
    defer testing.allocator.free(changed);
    try testing.expectEqual(@as(usize, 0), changed.len);
}

test "only the changed rows are listed" {
    const old = [_]Row{ .{ .name = "a", .version = 1 }, .{ .name = "b", .version = 1 }, .{ .name = "c", .version = 1 } };
    const new = [_]Row{ .{ .name = "a", .version = 2 }, .{ .name = "b", .version = 1 }, .{ .name = "c", .version = 2 } };
    const changed = (try diff(&old, &new, 10)) orelse return error.RebuildExpectedNot;
    defer testing.allocator.free(changed);
    try testing.expectEqualSlices(usize, &.{ 0, 2 }, changed);
}

test "the limit itself is still applied row by row" {
    const old = [_]Row{ .{ .name = "a", .version = 1 }, .{ .name = "b", .version = 1 } };
    const new = [_]Row{ .{ .name = "a", .version = 2 }, .{ .name = "b", .version = 2 } };
    const changed = (try diff(&old, &new, 2)) orelse return error.RebuildExpectedNot;
    defer testing.allocator.free(changed);
    try testing.expectEqual(@as(usize, 2), changed.len);
    try testing.expect((try diff(&old, &new, 1)) == null);
}

test "moved rows rebuild the list" {
    const old = [_]Row{ .{ .name = "a", .version = 1 }, .{ .name = "b", .version = 1 } };
    const new = [_]Row{ .{ .name = "b", .version = 1 }, .{ .name = "a", .version = 1 } };
    try testing.expect((try diff(&old, &new, 10)) == null);
}

test "added rows rebuild the list" {
    const old = [_]Row{.{ .name = "a", .version = 1 }};
    const new = [_]Row{ .{ .name = "a", .version = 1 }, .{ .name = "b", .version = 1 } };
    try testing.expect((try diff(&old, &new, 10)) == null);
}
