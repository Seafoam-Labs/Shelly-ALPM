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

/// Versioned package metadata. Unknown versions must never silently disable migration.
pub const metadata_prefix = "shelly.migration.";
pub const metadata_key = metadata_prefix ++ "v1";
pub const Origin = enum { api, declared, automatic, retained };
pub const Declaration = struct {
    path: []const u8,
    from: []const u8,
    optional: bool = false,
    backup: bool = false,
};

pub fn parse(allocator: std.mem.Allocator, text: []const u8) !std.json.Parsed(Declaration) {
    if (std.mem.indexOfAny(u8, text, "\r\n\x00") != null) return error.InvalidMigrationMetadata;
    const parsed = std.json.parseFromSlice(Declaration, allocator, text, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidMigrationMetadata,
    };
    errdefer parsed.deinit();
    try validatePath(parsed.value.path);
    if (!std.mem.eql(u8, parsed.value.from, "unowned")) {
        const prefix = "package:";
        if (!std.mem.startsWith(u8, parsed.value.from, prefix)) return error.InvalidMigrationSource;
        const name = parsed.value.from[prefix.len..];
        if (name.len == 0 or name[0] == '-' or name[0] == '.') return error.InvalidMigrationSource;
        for (name) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "@._+-", c) == null)
            return error.InvalidMigrationSource;
    }
    return parsed;
}

pub fn validateDeclarations(allocator: std.mem.Allocator, values: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var paths: std.StringHashMapUnmanaged(void) = .empty;
    for (values) |text| {
        const parsed = try parse(arena.allocator(), text);
        defer parsed.deinit();
        const path = try arena.allocator().dupe(u8, parsed.value.path);
        if ((try paths.getOrPut(arena.allocator(), path)).found_existing) return error.DuplicateMigration;
    }
}

pub fn validateXdata(allocator: std.mem.Allocator, values: anytype) !void {
    var declarations: std.ArrayList([]const u8) = .empty;
    defer declarations.deinit(allocator);
    for (values) |value| {
        if (!std.mem.startsWith(u8, value.name, metadata_prefix)) continue;
        if (!std.mem.eql(u8, value.name, metadata_key)) return error.UnsupportedMigrationVersion;
        try declarations.append(allocator, value.value);
    }
    try validateDeclarations(allocator, declarations.items);
}
