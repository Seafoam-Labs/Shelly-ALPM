const Database = @This();

const std = @import("std");
const Package = @import("Package.zig");
const Group = @import("Group.zig");
const DatabaseStatus = @import("DatabaseStatus.zig");
const SignaturePolicy = @import("SignaturePolicy.zig");
const DatabaseUsage = @import("DatabaseUsage.zig");

pub const PackageId = enum(u32) {
    _,
};

pub const GroupId = enum(u32) {
    _,
};

pub const GroupIndex = struct {
    groups: std.ArrayList(Group),
    by_name: std.StringHashMap(GroupId),
    ordered: std.ArrayList(GroupId),
};

pub const PackageIndex = struct {
    packages: std.ArrayList(Package),
    by_name: std.StringHashMapUnmanaged(PackageId),
    ordered: std.ArrayList(PackageId),
};

//owner: *Handle,

name: []u8,
path: ?[]u8 = null,

//backend: Backend, Could probably be retooled,

packages: PackageIndex = .{},
groups: GroupIndex = .{},

cache_servers: std.ArrayList([]u8) = .empty,
servers: std.ArrayList([]u8) = .empty,

status: DatabaseStatus = .{},
signature_policy: SignaturePolicy = .{},
usage: DatabaseUsage = .{},

pub fn deinit(
    self: *Database,
    allocator: std.mem.Allocator,
) void {
    allocator.free(self.tree_name);
    if (self.path) |path| allocator.free(path);

    self.packages.deinit(allocator);
    self.groups.deinit(allocator);

    freeStrings(allocator, &self.cache_servers);
    freeStrings(allocator, &self.servers);

    self.* = undefined;
}

fn freeStrings(
    allocator: std.mem.Allocator,
    strings: *std.ArrayList([]u8),
) void {
    for (strings.items) |string| {
        allocator.free(string);
    }
    strings.deinit(allocator);
    strings.* = .empty;
}

test "freeStrings frees each string and the list storage" {
    const allocator = std.testing.allocator;
    var strings: std.ArrayList([]u8) = .empty;
    defer {
        for (strings.items) |string| allocator.free(string);
        strings.deinit(allocator);
    }

    const first = try allocator.dupe(u8, "https://mirror-one.example");
    strings.append(allocator, first) catch |err| {
        allocator.free(first);
        return err;
    };

    const second = try allocator.dupe(u8, "https://mirror-two.example");
    strings.append(allocator, second) catch |err| {
        allocator.free(second);
        return err;
    };

    freeStrings(allocator, &strings);

    try std.testing.expectEqual(@as(usize, 0), strings.items.len);
    try std.testing.expectEqual(@as(usize, 0), strings.capacity);
}
