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
