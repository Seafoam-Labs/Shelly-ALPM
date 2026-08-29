const DatabaseUsage = @This();
const std = @import("std");

sync: bool = true,
search: bool = true,
install: bool = true,
upgrade: bool = true,

test "DatabaseUsage enables every operation by default" {
    const usage: DatabaseUsage = .{};

    try std.testing.expect(usage.sync);
    try std.testing.expect(usage.search);
    try std.testing.expect(usage.install);
    try std.testing.expect(usage.upgrade);
}

test "DatabaseUsage operations can be independently disabled" {
    const usage: DatabaseUsage = .{
        .sync = false,
        .install = false,
    };

    try std.testing.expect(!usage.sync);
    try std.testing.expect(usage.search);
    try std.testing.expect(!usage.install);
    try std.testing.expect(usage.upgrade);
}
