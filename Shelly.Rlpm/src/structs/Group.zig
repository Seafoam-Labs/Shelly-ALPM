const Group = @This();

const std = @import("std");
const Package = @import("Package.zig");
const Version = @import("Version.zig");

name: []const u8,
packages: std.ArrayList(*Package),

test "Group stores packages in insertion order" {
    const allocator = std.testing.allocator;
    var version = try Version.init("0:1.0-1", allocator);
    defer version.deinit(allocator);

    var no_relations = [_]@import("PackageRelation.zig"){};
    var package: Package = .{
        .name = "example",
        .version = version,
        .database_name = "extra",
        .provides = no_relations[0..],
        .depends = no_relations[0..],
        .make_depends = no_relations[0..],
        .conflicts = no_relations[0..],
        .replaces = no_relations[0..],
    };

    var group: Group = .{
        .name = try allocator.dupe(u8, "example-group"),
        .packages = .empty,
    };
    defer {
        allocator.free(group.name);
        group.packages.deinit(allocator);
    }

    try group.packages.append(allocator, &package);

    try std.testing.expectEqualStrings("example-group", group.name);
    try std.testing.expectEqual(@as(usize, 1), group.packages.items.len);
    try std.testing.expect(group.packages.items[0] == &package);
}
