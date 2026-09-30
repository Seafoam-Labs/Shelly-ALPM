const std = @import("std");
const PackageId = @import("PackageRef.zig").Id;

const Group = @This();

name: []const u8,
/// IDs into the containing database's current package cache, never raw pointers.
packages: std.ArrayList(PackageId),

test "Group retains package IDs in insertion order" {
    var group: Group = .{ .name = "example-group", .packages = .empty };
    defer group.packages.deinit(std.testing.allocator);
    try group.packages.appendSlice(std.testing.allocator, &.{ @enumFromInt(5), @enumFromInt(2) });
    try std.testing.expectEqual(@as(u32, 5), @intFromEnum(group.packages.items[0]));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(group.packages.items[1]));
}
