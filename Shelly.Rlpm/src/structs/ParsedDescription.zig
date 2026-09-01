const ParsedDescription = @This();

const std = @import("std");
const Package = @import("Package.zig");

/// Temporary representation of a local database `desc` file.
///
/// String values borrow from the input buffer passed to the parser. The array
/// lists own only their backing storage, not the strings stored in them. Keep
/// the input buffer alive until this value has been converted into a Package.
name: ?[]const u8 = null,
version: ?[]const u8 = null,
base: ?[]const u8 = null,
description: ?[]const u8 = null,
url: ?[]const u8 = null,
architecture: ?[]const u8 = null,
build_date: ?i64 = null,
install_date: ?i64 = null,
packager: ?[]const u8 = null,
installed_size: ?u64 = null,
reason: ?Package.InstallReason = null,
validation: Package.Validation = .{},

groups: std.ArrayList([]const u8) = .empty,
licenses: std.ArrayList([]const u8) = .empty,
depends: std.ArrayList([]const u8) = .empty,
optional_depends: std.ArrayList([]const u8) = .empty,
make_depends: std.ArrayList([]const u8) = .empty,
check_depends: std.ArrayList([]const u8) = .empty,
conflicts: std.ArrayList([]const u8) = .empty,
provides: std.ArrayList([]const u8) = .empty,
replaces: std.ArrayList([]const u8) = .empty,
xdata: std.ArrayList(Package.XData) = .empty,

/// Releases list backing storage. Borrowed strings are not freed.
pub fn deinit(self: *ParsedDescription, allocator: std.mem.Allocator) void {
    self.groups.deinit(allocator);
    self.licenses.deinit(allocator);
    self.depends.deinit(allocator);
    self.optional_depends.deinit(allocator);
    self.make_depends.deinit(allocator);
    self.check_depends.deinit(allocator);
    self.conflicts.deinit(allocator);
    self.provides.deinit(allocator);
    self.replaces.deinit(allocator);
    self.xdata.deinit(allocator);
    self.* = undefined;
}

test "ParsedDescription defaults to empty and releases list storage" {
    const allocator = std.testing.allocator;
    var parsed: ParsedDescription = .{};
    defer parsed.deinit(allocator);

    try parsed.groups.append(allocator, "base");
    try parsed.depends.append(allocator, "glibc>=2.39");
    try parsed.xdata.append(allocator, .{
        .name = "pkgtype",
        .value = "pkg",
    });

    try std.testing.expect(parsed.name == null);
    try std.testing.expectEqualStrings("base", parsed.groups.items[0]);
    try std.testing.expectEqualStrings("glibc>=2.39", parsed.depends.items[0]);
    try std.testing.expectEqualStrings("pkgtype", parsed.xdata.items[0].name);
}
