//! Explicit, in-place adoption. Requests are copied before prepare; no globbing,
//! recursive traversal, or implicit ownership takeover is performed.
const std = @import("std");
const Root = @import("RootPath.zig");

pub const Request = struct {
    package: []const u8,
    path: []const u8,
    source: union(enum) { unowned, replaced_package: []const u8 } = .unowned,
    optional: bool = false,
    /// Regular files only. Inherited backup baselines take precedence.
    backup: bool = false,
};

pub fn validatePath(path: []const u8) !void {
    const normalized = try Root.normalize(path);
    if (!std.mem.eql(u8, normalized, path) or std.mem.endsWith(u8, path, "/") or
        std.mem.indexOfAny(u8, path, "\r\n\t") != null)
        return error.InvalidMigrationPath;
}
