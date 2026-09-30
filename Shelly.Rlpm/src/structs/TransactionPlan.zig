//! Owned, read-only resolution result. Treat its views as immutable. It survives
//! Owner/cache/archive release; deinit exactly once. A failed plan is diagnostic
//! data, never an executable transaction. Transaction binds review to live state.
const std = @import("std");
const Package = @import("Package.zig");
const Relation = @import("PackageRelation.zig");
const Callbacks = @import("Callbacks.zig");
const PackageRef = @import("PackageRef.zig");
const TransactionFlags = @import("TransactionFlags.zig");

const Plan = @This();

pub const Id = enum(u32) { _ };

pub const Candidate = struct {
    reference: PackageRef,
    package: Package,
    repository: ?usize = null,
};

pub const Addition = struct {
    package: Id,
    old: ?Id,
    action: enum { install, reinstall, upgrade, downgrade },
    /// Reason during dependency preparation, before executor overrides.
    selection_reason: Package.InstallReason,
    /// Final reason, including old reason and ALLDEPS/ALLEXPLICIT precedence.
    reason: Package.InstallReason,
    explicit_target: bool,
    installed_database: ?[]const u8,
};

pub const Edge = struct {
    requiring: Id,
    dependency: Relation,
    satisfier: union(enum) { package: Id, assumed: Relation },
    /// null means the package's literal name/version satisfied this edge.
    provision: ?Relation = null,
    version_ignored: bool = false,
};

pub const Missing = struct {
    requiring: Id,
    dependency: Relation,
    causing: ?Id = null,
};

pub const Conflict = struct {
    first: Id,
    second: Id,
    reason: Relation,
};

pub const Failure = enum {
    target_not_found,
    ignored,
    duplicate_target,
    invalid_architecture,
    unsatisfied_dependencies,
    conflicting_dependencies,
    duplicate_filename,
};

pub const Issue = union(enum) {
    target: []const u8,
    duplicate: struct {
        first: Id,
        second: Id,
    },
    architecture: Id,
    missing: Missing,
    conflict: Conflict,
    filename: struct {
        first: Id,
        second: Id,
        filename: []const u8,
    },
};

pub const Warning = union(enum) {
    cycle: struct {
        before: Id,
        after: Id,
        removal: bool,
    },
    local_newer: struct {
        local: Id,
        sync: Id,
    },
    ignored_upgrade: struct {
        local: Id,
        sync: Id,
    },
    provided_target: struct {
        removed: Id,
        provider: Id,
    },
    skipped_needed: Id,
    skipped_unresolvable: Id,
    optional_dependency_removed: struct {
        package: Id,
        dependency: Relation,
    },
};

pub const Sizes = struct {
    installed_add: u64 = 0,
    installed_remove: u64 = 0,
    /// Upper estimate before accounting for cached archives and partial downloads.
    download_upper_bound: u64 = 0,
    unknown_installed: usize = 0,
    unknown_download: usize = 0,
};

arena: std.heap.ArenaAllocator,
candidates: []const Candidate = &.{},
flags: TransactionFlags = .{},
/// Whether target selection left work for native prepare to enter a phase.
had_prepare_targets: bool = false,
additions: []const Addition = &.{},
removals: []const Id = &.{},
unchanged_satisfiers: []const Id = &.{},
edges: []const Edge = &.{},
questions: []const Callbacks.Question = &.{},
warnings: []const Warning = &.{},
issues: []const Issue = &.{},
failure: ?Failure = null,
sizes: Sizes = .{},

pub fn deinit(self: *Plan) void {
    for (self.candidates) |candidate|
        if (candidate.package.verified_archive) |file| {
            var owned = file;
            owned.deinit();
        };
    self.arena.deinit();
    self.* = undefined;
}

pub fn package(self: *const Plan, id: Id) *const Package {
    return &self.candidates[@intFromEnum(id)].package;
}

pub fn findReference(self: *const Plan, reference: PackageRef) ?Id {
    for (self.candidates, 0..) |candidate, index| {
        if (std.meta.eql(candidate.reference, reference)) return @enumFromInt(index);
    }
    return null;
}

pub fn check(self: *const Plan) !void {
    return switch (self.failure orelse return) {
        .target_not_found => error.TargetNotFound,
        .ignored => error.PackageIgnored,
        .duplicate_target => error.DuplicateTarget,
        .invalid_architecture => error.InvalidArchitecture,
        .unsatisfied_dependencies => error.UnsatisfiedDependencies,
        .conflicting_dependencies => error.ConflictingDependencies,
        .duplicate_filename => error.DuplicateFilename,
    };
}

/// Deep metadata copy into an enclosing arena. Resource ownership is handled
/// separately by the caller; never copy allocator or descriptor internals.
pub fn copyMetadata(allocator: std.mem.Allocator, source: Package) !Package {
    var result: Package = undefined;
    inline for (std.meta.fields(Package)) |field| {
        if (comptime std.mem.eql(u8, field.name, "archive_arena") or
            std.mem.eql(
                u8,
                field.name,
                "verified_archive",
            ))
        {
            @field(result, field.name) = null;
        } else @field(result, field.name) = try copyValue(field.type, allocator, @field(source, field.name));
    }
    return result;
}

pub fn copyValue(comptime T: type, allocator: std.mem.Allocator, value: T) error{OutOfMemory}!T {
    switch (@typeInfo(T)) {
        .pointer => |info| {
            if (info.size != .slice) @compileError("snapshot copy requires slices");
            const result = try allocator.alloc(info.child, value.len);
            for (value, result) |item, *out|
                out.* = try copyValue(info.child, allocator, item);
            return result;
        },
        .optional => |info| {
            if (@typeInfo(info.child) == .error_set) return value;
            return if (value) |item| try copyValue(info.child, allocator, item) else null;
        },
        .@"struct" => {
            var result: T = undefined;
            inline for (std.meta.fields(T)) |field|
                @field(result, field.name) = try copyValue(
                    field.type,
                    allocator,
                    @field(value, field.name),
                );
            return result;
        },
        .@"union" => return switch (value) {
            inline else => |item, tag| @unionInit(T, @tagName(tag), try copyValue(@TypeOf(item), allocator, item)),
        },
        else => return value,
    }
}
