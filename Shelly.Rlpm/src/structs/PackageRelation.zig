const PackageRelation = @This();

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
description: ?[]const u8 = null
