//! Backend-neutral snapshots of native prepared build transactions.
//! All returned strings belong to the caller's arena. No transaction is committed
//! in capture mode; verification runs before downloads, hooks, or installation.
const std = @import("std");
const types = @import("types.zig");

pub const Package = struct {
    name: []const u8,
    repository: []const u8,
    version: []const u8,
    architecture: []const u8,
    filename: []const u8,
    sha256: ?[]const u8,
    locations: []const []const u8 = &.{},
    depends: []const [:0]u8,
    provides: []const [:0]u8,
    groups: []const [:0]u8,
};

pub const Issue = struct { requirement: []const u8, requiredBy: []const u8, code: []const u8 };

pub const Request = struct {
    issues: ?*[]const Issue = null,
    allocator: std.mem.Allocator,
    output: ?*[]const Package = null,
    expected: ?[]const Package = null,

    pub fn finish(self: Request, packages: []Package) !void {
        std.mem.sort(Package, packages, {}, lessThan);
        if (self.expected) |expected| {
            if (packages.len != expected.len) return error.DependencyPlanMismatch;
            for (packages, expected) |actual, pinned| {
                if (!sameIdentity(actual, pinned)) return error.DependencyPlanMismatch;
            }
        }
        if (self.output) |output| output.* = packages;
    }
};

fn lessThan(_: void, a: Package, b: Package) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

pub fn sameIdentity(a: Package, b: Package) bool {
    inline for (.{ "name", "repository", "version", "architecture", "filename" }) |field| {
        if (!std.mem.eql(u8, @field(a, field), @field(b, field))) return false;
    }
    const ah = a.sha256 orelse return false;
    const bh = b.sha256 orelse return false;
    return validHash(ah) and validHash(bh) and std.ascii.eqlIgnoreCase(ah, bh);
}

pub fn validHash(hash: []const u8) bool {
    if (hash.len != 64) return false;
    for (hash) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

pub fn fromOwned(allocator: std.mem.Allocator, package: types.OwnedPackage, hash: ?[]const u8) !Package {
    return .{
        .name = package.name_value,
        .repository = package.repository_value orelse "",
        .version = package.version_value,
        .architecture = package.architecture_value orelse "",
        .filename = package.file_name_value,
        .sha256 = if (hash) |value| try allocator.dupe(u8, value) else null,
        .depends = package.depends_value,
        .provides = package.provides_value,
        .groups = package.groups_value,
    };
}
