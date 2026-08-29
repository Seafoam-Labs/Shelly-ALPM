const Package = @This();

const std = @import("std");
const Version = @import("Version.zig");
const PackageRelation = @import("PackageRelation.zig");

name: []const u8,
version: Version,
database_name: []const u8,
provides: []PackageRelation,
depends: []PackageRelation,
make_depends: []PackageRelation,
conflicts: []PackageRelation,
replaces: []PackageRelation,
