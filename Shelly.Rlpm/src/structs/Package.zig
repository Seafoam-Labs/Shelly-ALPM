const Package = @This();

const std = @import("std");
const Version = @import("Version.zig");
const PackageRelation = @import("PackageRelation.zig");

pub const InstallReason = enum {
    explicit,
    dependency,
};

pub const Validation = struct {
    none: bool = false,
    sha256: bool = false,
    pgp: bool = false,
};

pub const XData = struct {
    name: []const u8,
    value: []const u8,
};

name: []const u8,
version: Version,
base: ?[]const u8,
database_name: []const u8,
description: ?[]const u8,
provides: []PackageRelation,
depends: []PackageRelation,
optional_depends: []PackageRelation,
make_depends: []PackageRelation,
conflicts: []PackageRelation,
replaces: []PackageRelation,
install_reason: ?InstallReason,
validation: ?Validation,
url: ?[]const u8,
architecture: ?[]const u8,
build_date: ?i64,
install_date: ?i64,
packager: ?[]const u8,
groups: ?[][]const u8,
xdata: ?[]XData,

test "Package stores version, database, and package relations" {
    var version = try Version.init("0:1.27.0-2", std.testing.allocator);
    defer version.deinit(std.testing.allocator);

    var provides = [_]PackageRelation{
        .{ .name = "go", .constraint = .any },
    };
    var depends = [_]PackageRelation{
        .{ .name = "glibc", .constraint = .any },
    };
    var no_relations = [_]PackageRelation{};

    const package: Package = .{
        .name = "go",
        .version = version,
        .database_name = "core",
        .provides = provides[0..],
        .depends = depends[0..],
        .make_depends = no_relations[0..],
        .conflicts = no_relations[0..],
        .replaces = no_relations[0..],
    };

    try std.testing.expectEqualStrings("go", package.name);
    try std.testing.expectEqualStrings("0:1.27.0-2", package.version.raw);
    try std.testing.expectEqualStrings("core", package.database_name);
    try std.testing.expectEqualStrings("go", package.provides[0].name);
    try std.testing.expectEqualStrings("glibc", package.depends[0].name);
    try std.testing.expectEqual(@as(usize, 0), package.conflicts.len);
}
