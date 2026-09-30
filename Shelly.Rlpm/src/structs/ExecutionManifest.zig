//! Transaction-owned preflight result. All views expire at transaction release.
//! Package ids refer to the frozen TransactionPlan. Only a successful manifest
//! may drive an executor, which must revalidate and use root-relative descriptors.
const std = @import("std");
const Root = @import("RootPath.zig");
const Plan = @import("TransactionPlan.zig");
const Package = @import("Package.zig");
const PackageFile = @import("PackageFile.zig");
const BackupFile = @import("BackupFile.zig");

const Manifest = @This();
pub const Capacity = Root.Capacity;

pub const Action = enum { install, replace, remove, preserve, shared_directory, no_extract, pacnew, pacsave };

pub const Entry = struct {
    package: Plan.Id,
    file: PackageFile,
    /// Canonical root-relative path without a directory's trailing slash.
    path: []const u8,
    action: Action,
    /// Archive header index; null for removal entries.
    archive_index: ?usize = null,
    before: ?Root.State = null,
    new_hash: ?[]const u8 = null,
    /// .pacnew/.pacsave destination. pacsave rotation is recorded separately.
    destination: ?[]const u8 = null,
    /// Native backup handling updates an existing pacnew even when preserving
    /// local contents because the distributed version has not changed.
    refresh_existing_pacnew: bool = false,
    /// Directory removals use rmdir and preserve nonempty/shared/mounted trees.
    remove_if_empty: bool = false,
    /// Missing implicit ancestors, in creation order, for this operation.
    create_parents: []const []const u8 = &.{},
};

pub const Archive = struct {
    id: Plan.Id,
    package: Package,
    /// Root archive metadata is never installed as payload.
    metadata: []const Entry = &.{},
    payload: []const Entry = &.{},
    by_path: std.StringHashMapUnmanaged(usize) = .empty,

    pub fn find(self: Archive, path: []const u8) ?Entry {
        return self.payload[self.by_path.get(path) orelse return null];
    }
};

pub const Local = struct {
    id: Plan.Id,
    package: Package,
};

pub const DatabaseChange = struct {
    package: Plan.Id,
    old: ?Plan.Id,
    remove: bool,
    files: []const PackageFile,
    backups: []const BackupFile,
    reason: ?Package.InstallReason,
    installed_database: ?[]const u8,
};

pub const Conflict = struct {
    kind: enum { target, filesystem },
    path: []const u8,
    package: Plan.Id,
    other: ?Plan.Id = null,
};

pub const Issue = struct {
    cause: anyerror,
    package: ?Plan.Id = null,
    path: ?[]const u8 = null,
};

pub const Guard = struct {
    path: []const u8,
    follow: bool = false,
    before: ?Root.State,
};

pub const Space = struct {
    path: []const u8,
    database: bool,
    capacity: Root.Capacity,
    delta: i128 = 0,
    peak: u64 = 0,
};

pub const Rotation = struct {
    from: []const u8,
    to: []const u8,
};
arena: std.heap.ArenaAllocator,
root: Root,
database: Root,
archives: std.ArrayList(Archive) = .empty,
locals: std.ArrayList(Local) = .empty,
entries: std.ArrayList(Entry) = .empty,
database_changes: std.ArrayList(DatabaseChange) = .empty,
conflicts: std.ArrayList(Conflict) = .empty,
guards: std.ArrayList(Guard) = .empty,
guard_indices: [2]std.StringHashMapUnmanaged(usize) = .{ .empty, .empty },
spaces: std.ArrayList(Space) = .empty,
rotations: std.ArrayList(Rotation) = .empty,
warnings: std.ArrayList(Issue) = .empty,
failure: ?Issue = null,
complete: bool = false,

pub fn init(allocator: std.mem.Allocator, root: []const u8, database: []const u8) !Manifest {
    var held = try Root.init(root);
    errdefer held.deinit();
    return .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .root = held,
        .database = try Root.init(database),
    };
}

pub fn deinit(self: *Manifest) void {
    for (self.archives.items) |*archive|
        archive.package.deinit();
    self.root.deinit();
    self.database.deinit();
    self.arena.deinit();
    self.* = undefined;
}

pub fn check(self: *const Manifest) !void {
    if (self.failure) |issue| return issue.cause;
    if (self.conflicts.items.len != 0) return error.FileConflicts;
    if (!self.complete) return error.IncompletePreflight;
}

pub fn remember(self: *Manifest, path: []const u8, follow: bool) !?Root.State {
    const map = &self.guard_indices[@intFromBool(follow)];
    if (map.get(path)) |index| return self.guards.items[index].before;
    const before = try self.root.inspect(path, follow);
    const owned = try self.arena.allocator().dupe(u8, path);
    try map.put(self.arena.allocator(), owned, self.guards.items.len);
    try self.guards.append(self.arena.allocator(), .{
        .path = owned,
        .follow = follow,
        .before = before,
    });
    return before;
}

/// Checks root identity, all observed paths (including symlink ancestors), and
/// current free space. Recheck after pre-transaction hooks before changing payloads.
pub fn revalidate(
    self: *const Manifest,
    root_path: []const u8,
    db_path: []const u8,
    check_space: bool,
) !void {
    try self.check();
    try self.revalidateRoots(root_path, db_path);
    for (self.guards.items) |guard|
        if (!std.meta.eql(
            guard.before,
            try self.root.inspect(guard.path, guard.follow),
        ))
            return error.StaleFilesystemState;
    for (self.entries.items) |entry| {
        if (entry.action == .no_extract or entry.action == .shared_directory or
            (entry.action == .preserve and
                !entry.refresh_existing_pacnew))
            continue;
        try self.root.access(entry.destination orelse entry.path);
    }
    for (self.rotations.items) |rotation| {
        try self.root.access(rotation.from);
        try self.root.access(rotation.to);
    }
    if (self.database_changes.items.len != 0) {
        try Root.writable(self.database.fd);
        if (Root.capacity(self.database.fd)) |cap| {
            if (cap.read_only) return error.ReadOnlyFilesystem;
        } else |_| {}
    }
    for (self.spaces.items) |space| {
        const root = if (space.database) &self.database else &self.root;
        const fd = try root.ancestor(space.path);
        defer _ = Root.c.close(fd);
        try Root.writable(fd);
        const cap = Root.capacity(fd) catch |err| switch (err) {
            error.CapacityUnavailable => continue, // native warns and skips unknown mounts
            else => return err,
        };
        if (cap.device != space.capacity.device or cap.block_size != space.capacity.block_size)
            return error.StaleFilesystemState;
        if (cap.read_only) return error.ReadOnlyFilesystem;
        if (check_space) try checkCapacity(cap, space.peak);
    }
}

pub fn checkCapacity(cap: Root.Capacity, blocks: u64) !void {
    if (cap.read_only) return error.ReadOnlyFilesystem;
    if (cap.block_size == 0) return error.CapacityUnavailable;
    const cushion = @min(cap.total / 20 + 1, 20 * 1024 * 1024 / cap.block_size + 1);
    if (@as(u128, blocks) + cushion > cap.available) return error.DiskSpaceInsufficient;
}

/// Recheck root identities at mutation boundaries; hook changes to contents are allowed.
pub fn revalidateRoots(self: *const Manifest, root_path: []const u8, db_path: []const u8) !void {
    var current_root = try Root.init(root_path);
    defer current_root.deinit();
    var current_db = try Root.init(db_path);
    defer current_db.deinit();
    for ([_]struct {
        old: Root,
        new: Root,
    }{
        .{ .old = self.root, .new = current_root },
        .{ .old = self.database, .new = current_db },
    }) |pair| {
        const old = try Root.state(pair.old.fd);
        const new = try Root.state(pair.new.fd);
        if (old.device != new.device or old.inode != new.inode or old.mount_id != new.mount_id)
            return error.StaleFilesystemState;
    }
}
