const PackageRelation = @This();

const std = @import("std");
const Version = @import("Version.zig");

pub const Constraint = union(enum) {
    any,
    equal: Version,
    greater_equal: Version,
    less_equal: Version,
    greater: Version,
    less: Version,
};

name: []const u8,
constraint: Constraint = .any,
description: ?[]const u8 = null,

test "PackageRelation defaults to an unconstrained relation" {
    const relation: PackageRelation = .{ .name = "go" };

    try std.testing.expectEqualStrings("go", relation.name);
    try std.testing.expect(relation.constraint == .any);
    try std.testing.expect(relation.description == null);
}

test "PackageRelation stores a version constraint and description" {
    var version = try Version.init("0:1.26.0-1", std.testing.allocator);
    defer version.deinit(std.testing.allocator);

    const relation: PackageRelation = .{
        .name = "go",
        .constraint = .{ .greater_equal = version },
        .description = "Go compiler",
    };

    switch (relation.constraint) {
        .greater_equal => |minimum| {
            try std.testing.expectEqualStrings("0:1.26.0-1", minimum.raw);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("Go compiler", relation.description.?);
}
