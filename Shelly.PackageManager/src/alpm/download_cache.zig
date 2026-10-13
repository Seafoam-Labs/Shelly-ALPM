//! Empty pacman download directories, planned separately from package retention.
const std = @import("std");
const operations = @import("operation_context");

pub const Entry = struct {
    name: []u8,
    inode: std.Io.File.INode,
    ctime: std.Io.Timestamp,
};

pub const Cache = struct {
    path: []u8,
    // Pin the parent across confirmation; replacing its path cannot redirect deletion.
    directory: std.Io.Dir,
    entries: []Entry,

    fn deinit(self: *Cache, allocator: std.mem.Allocator, io: std.Io) void {
        self.directory.close(io);
        allocator.free(self.path);
        for (self.entries) |entry| allocator.free(entry.name);
        allocator.free(self.entries);
    }
};

pub const RemovalPlan = struct {
    caches: []Cache,
    dry_run: bool,

    pub fn count(self: RemovalPlan) usize {
        var total: usize = 0;
        for (self.caches) |cache| total += cache.entries.len;
        return total;
    }

    pub fn deinit(self: *RemovalPlan, allocator: std.mem.Allocator, io: std.Io) void {
        for (self.caches) |*cache| cache.deinit(allocator, io);
        allocator.free(self.caches);
        self.* = undefined;
    }
};

pub fn isDownloadDirectoryName(name: []const u8) bool {
    const prefix = "download-";
    if (name.len != prefix.len + 6 or !std.mem.startsWith(u8, name, prefix)) return false;
    for (name[prefix.len..]) |byte| if (!std.ascii.isAlphanumeric(byte)) return false;
    return true;
}

fn checkCancelled(context: ?*operations.OperationContext) !void {
    if (context) |active| if (active.isCancelled()) return error.Cancelled;
}

pub fn plan(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: []const [:0]const u8,
    dry_run: bool,
    context: ?*operations.OperationContext,
) !RemovalPlan {
    try checkCancelled(context);
    var caches: std.ArrayList(Cache) = .empty;
    errdefer {
        for (caches.items) |*cache| cache.deinit(allocator, io);
        caches.deinit(allocator);
    }
    for (paths) |path| {
        try checkCancelled(context);
        const root = std.mem.trimEnd(u8, path, "/");
        if (!std.fs.path.isAbsolute(root)) return error.InvalidCacheRoot;
        const duplicate = for (caches.items) |cache| {
            if (std.mem.eql(u8, cache.path, root)) break true;
        } else false;
        if (duplicate) continue;
        var directory = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        errdefer directory.close(io);
        var entries: std.ArrayList(Entry) = .empty;
        errdefer {
            for (entries.items) |entry| allocator.free(entry.name);
            entries.deinit(allocator);
        }
        var iterator = directory.iterate();
        while (try iterator.next(io)) |entry| {
            try checkCancelled(context);
            if (!isDownloadDirectoryName(entry.name)) continue;
            const stat = directory.statFile(io, entry.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            if (stat.kind != .directory) continue;
            var child = directory.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound, error.NotDir, error.SymLinkLoop => continue,
                else => return err,
            };
            defer child.close(io);
            const opened = try child.stat(io);
            if (opened.inode != stat.inode) continue;
            var contents = child.iterate();
            if (try contents.next(io) != null) continue;
            const name = try allocator.dupe(u8, entry.name);
            errdefer allocator.free(name);
            try entries.append(allocator, .{ .name = name, .inode = opened.inode, .ctime = opened.ctime });
        }
        const owned_path = try allocator.dupe(u8, root);
        errdefer allocator.free(owned_path);
        const owned_entries = try entries.toOwnedSlice(allocator);
        errdefer {
            for (owned_entries) |entry| allocator.free(entry.name);
            allocator.free(owned_entries);
        }
        try caches.append(allocator, .{ .path = owned_path, .directory = directory, .entries = owned_entries });
    }
    return .{ .caches = try caches.toOwnedSlice(allocator), .dry_run = dry_run };
}

/// The caller must hold the backend's package database lock throughout execution.
/// Only planned immediate children are considered; rmdir atomically preserves
/// nonempty directories, including downloads started since the preview.
pub fn execute(io: std.Io, removal_plan: *const RemovalPlan, context: ?*operations.OperationContext) !usize {
    try checkCancelled(context);
    if (removal_plan.dry_run) return 0;
    var removed: usize = 0;
    for (removal_plan.caches) |cache| {
        for (cache.entries) |entry| {
            try checkCancelled(context);
            if (!isDownloadDirectoryName(entry.name)) return error.InvalidPlan;
            const stat = cache.directory.statFile(io, entry.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            if (stat.kind != .directory or stat.inode != entry.inode or stat.ctime.nanoseconds != entry.ctime.nanoseconds) continue;
            cache.directory.deleteDir(io, entry.name) catch |err| switch (err) {
                error.FileNotFound, error.DirNotEmpty, error.NotDir, error.SymLinkLoop => continue,
                else => return err,
            };
            removed += 1;
        }
    }
    return removed;
}
