//! Owner-owned, address-stable transaction. Borrow this pointer until release.
//! Fields are implementation state; use methods and treat plan() as immutable.
const std = @import("std");
const Owner = @import("Owner.zig");
const Package = @import("Package.zig");
const Ref = @import("PackageRef.zig");
const Resolver = @import("Resolver.zig");
const Plan = @import("TransactionPlan.zig");
const Snapshot = @import("DatabaseSnapshot.zig");
pub const Executor = @import("Executor.zig");
const Downloads = @import("Downloads.zig");
const TransactionFlags = @import("TransactionFlags.zig");
const ExecutionManifest = @import("ExecutionManifest.zig");
const TransactionActions = @import("TransactionActions.zig");
const DatabaseLock = @import("DatabaseLock.zig");
const Preflight = @import("Preflight.zig");
const Diagnostic = @import("Diagnostic.zig");
const Callbacks = @import("Callbacks.zig");

const Transaction = @This();

pub const State = enum {
    initialized,
    preparing,
    prepared,
    committing,
    completed,
    failed,
    interrupted,
    released,
};

pub const Result = struct {
    state: State,
    cause: ?anyerror = null,
    packages_committed: usize = 0,
    warnings: usize = 0,
};

const Target = union(enum) { text: []const u8, reference: Ref, archive: *Package };

owner: *Owner,
io: std.Io,
flags: TransactionFlags,
state: State = .initialized,
cause: ?anyerror = null,
storage: std.heap.ArenaAllocator,
targets: std.ArrayList(Target) = .empty,
removals: std.ArrayList([]const u8) = .empty,
system_upgrade: bool = false,
allow_downgrade: bool = false,
owned_plan: ?Plan = null,
downloaded_files: ?[]Downloads.File = null,
owned_manifest: ?ExecutionManifest = null,
owned_actions: ?TransactionActions = null,
execution: Executor.Report = .{},
snapshot: [32]u8,
lock: ?DatabaseLock = null,

/// Borrowed action outcomes, including nonfatal process and cleanup failures.
pub fn actions(self: *const Transaction) ?*const TransactionActions {
    return if (self.owned_actions) |*value| value else null;
}

/// Internal executor entry, requires committing state and the Owner busy guard.
/// Used by the ordered mutation executor.
pub fn startActions(self: *Transaction) !*TransactionActions {
    if (self.owned_actions != null) return error.InvalidActionState;
    self.owned_actions = try TransactionActions.init(self);
    try self.owned_actions.?.begin();
    return &self.owned_actions.?;
}

pub fn result(self: *const Transaction) Result {
    var warnings: usize = self.execution.cleanup_failures + (if (self.manifest()) |m|
        m.warnings.items.len
    else
        0);
    if (self.actions()) |value|
        for (value.outcomes.items) |item| {
            if (item.cause != null or item.warning) warnings += 1;
        };
    return .{
        .state = self.state,
        .cause = self.cause,
        .packages_committed = self.execution.completed.items.len,
        .warnings = warnings,
    };
}

pub fn plan(self: *const Transaction) ?*const Plan {
    return if (self.owned_plan) |*value| value else null;
}

pub fn manifest(self: *const Transaction) ?*const ExecutionManifest {
    return if (self.owned_manifest) |*value| value else null;
}

/// Downloads if needed, then constructs a read-only filesystem execution plan.
/// Failed preflight retains structured diagnostics until transaction release.
pub fn preflight(self: *Transaction) !void {
    try self.begin(.prepared);
    defer self.owner.busy = false;
    if (self.flags.download_only) return self.owner.transactionFailure(error.InvalidTransactionState);
    self.preflightInternal() catch |err| return self.failed(err);
}

fn preflightInternal(self: *Transaction) !void {
    try self.checkSnapshot();
    if (self.owned_manifest != null) return self.revalidateInternal();
    try self.downloadInternal();
    self.owned_manifest = try ExecutionManifest.init(
        self.owner.allocator,
        self.owner.configuration.root,
        self.owner.configuration.database_path,
    );
    try Preflight.populate(self, &self.owned_manifest.?);
    try self.checkSnapshot();
    try self.owned_manifest.?.revalidate(
        self.owner.configuration.root,
        self.owner.configuration.database_path,
        self.owner.configuration.check_space,
    );
    try self.owner.checkCancelled();
}

/// Execution and post-hook code must call this before consuming the manifest.
/// Each actual mutation must additionally use confined descriptor operations.
pub fn revalidatePreflight(self: *Transaction) !void {
    try self.begin(.prepared);
    defer self.owner.busy = false;
    self.revalidateInternal() catch |err| return self.failed(err);
}

fn revalidateInternal(self: *Transaction) !void {
    try self.checkSnapshot();
    const value = if (self.owned_manifest) |*value| value else return error.IncompletePreflight;
    try Preflight.reverify(self, value);
    try value.revalidate(
        self.owner.configuration.root,
        self.owner.configuration.database_path,
        self.owner.configuration.check_space,
    );
    try self.owner.checkCancelled();
}

fn begin(self: *Transaction, expected: State) !void {
    try self.owner.beginTransactionOperation(self);
    errdefer self.owner.busy = false;
    if (self.state != expected) return self.owner.transactionFailure(error.InvalidTransactionState);
}

fn recordFailure(self: *Transaction, err: anyerror) void {
    self.owner.last_diagnostic = Diagnostic.init(.transaction, err, null);
}

fn mutable(self: *Transaction) !void {
    try self.begin(.initialized);
    errdefer self.owner.busy = false;
    self.owner.checkCancelled() catch |err| return self.owner.transactionFailure(err);
}

/// Frontend name/relation syntax is resolved during prepare. Exact repeated
/// text is rejected; package identity duplicates are also checked by Resolver.
pub fn addTarget(self: *Transaction, text: []const u8) !void {
    try self.mutable();
    defer self.owner.busy = false;
    errdefer |err| self.recordFailure(err);
    if (text.len == 0 or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidOption;
    for (self.targets.items) |target|
        if (target == .text and std.mem.eql(u8, target.text, text))
            return error.DuplicateTarget;
    const owned = try self.storage.allocator().dupe(u8, text);
    try self.targets.append(self.owner.allocator, .{ .text = owned });
}

pub fn addPackage(self: *Transaction, reference: Ref) !void {
    try self.mutable();
    defer self.owner.busy = false;
    errdefer |err| self.recordFailure(err);
    const package = try self.owner.transactionPackage(reference);
    if (package.origin != .sync) return error.UnsupportedPackageOrigin;
    for (self.targets.items) |target|
        if (target == .reference and std.meta.eql(target.reference, reference))
            return;
    try self.checkName(package.name);
    try self.targets.append(self.owner.allocator, .{ .reference = reference });
}

fn checkName(self: *Transaction, name: []const u8) !void {
    for (self.targets.items) |target| {
        const existing = switch (target) {
            .text => continue,
            .archive => |pkg| pkg,
            .reference => |ref| try self.owner.transactionPackage(ref),
        };
        if (std.mem.eql(u8, existing.name, name)) return error.DuplicateTarget;
    }
}

/// On success the caller is reset to null. On every rejection/allocation error
/// the caller retains the complete package, including its sealed descriptor.
pub fn takeArchive(self: *Transaction, input: *?Package) !void {
    try self.mutable();
    defer self.owner.busy = false;
    errdefer |err| self.recordFailure(err);
    const package = &(input.* orelse return error.InvalidPackageOwnership);
    if (package.origin != .archive or package.archive_arena == null)
        return error.InvalidPackageOwnership;
    try self.checkName(package.name);
    const owned = try self.owner.allocator.create(Package);
    errdefer self.owner.allocator.destroy(owned);
    try self.targets.append(self.owner.allocator, .{ .archive = owned });
    owned.* = package.*;
    input.* = null;
}

pub fn remove(self: *Transaction, name: []const u8) !void {
    try self.mutable();
    defer self.owner.busy = false;
    errdefer |err| self.recordFailure(err);
    for (self.removals.items) |existing|
        if (std.mem.eql(u8, existing, name)) return;
    if (!self.owner.local.?.packages.by_name.contains(name)) return error.TargetNotFound;
    const owned = try self.storage.allocator().dupe(u8, name);
    try self.removals.append(self.owner.allocator, owned);
}

pub fn systemUpgrade(self: *Transaction, allow_downgrade: bool) !void {
    try self.mutable();
    defer self.owner.busy = false;
    self.system_upgrade = true;
    self.allow_downgrade = allow_downgrade;
}

pub fn prepare(self: *Transaction) !void {
    try self.begin(.initialized);
    defer self.owner.busy = false;
    self.transition(.preparing, null);
    self.prepareInternal() catch |err| return self.failed(err);
    // libalpm leaves an initially empty transaction initialized.
    self.transition(
        if (self.owned_plan != null and self.owned_plan.?.had_prepare_targets)
            .prepared
        else
            .initialized,
        null,
    );
    self.owner.checkCancelled() catch |err| return self.failed(err);
}

fn prepareInternal(self: *Transaction) !void {
    try self.checkSnapshot();
    if (self.owned_plan) |*previous| previous.deinit();
    self.owned_plan = null;
    if (self.targets.items.len == 0 and self.removals.items.len == 0 and !self.system_upgrade) return;
    var targets: std.ArrayList(Resolver.Target) = .empty;
    defer targets.deinit(self.owner.allocator);
    for (self.targets.items) |target|
        try targets.append(self.owner.allocator, switch (target) {
            .text => |value| .{ .text = value },
            .reference => |value| .{ .reference = value },
            .archive => |value| .{ .archive = value },
        });
    self.owned_plan = try self.owner.resolveTransaction(
        self,
        .{
            .install = targets.items,
            .remove = self.removals.items,
            .system_upgrade = self.system_upgrade,
            .allow_downgrade = self.allow_downgrade,
            .flags = self.flags,
        },
    );
    try self.owned_plan.?.check();
    try self.checkSnapshot();
}

pub fn commit(self: *Transaction) !void {
    try self.begin(.prepared);
    defer self.owner.busy = false;
    if (self.flags.no_lock) return self.owner.transactionFailure(error.TransactionNotLocked);
    if (self.lock == null) return self.failed(error.LockNotHeld);
    self.checkSnapshot() catch |err| return self.failed(err);
    const reviewed = &self.owned_plan.?;
    if (self.flags.download_only and reviewed.additions.len != 0) {
        self.transition(.committing, null);
        self.downloadInternal() catch |err| return self.failed(err);
    } else if (reviewed.additions.len + reviewed.removals.len != 0) {
        if (self.owner.configuration.local_database_mode == .read_only)
            return self.owner.transactionFailure(
                error.ReadOnlyDatabase,
            );
        self.preflightInternal() catch |err| return self.failed(err);
        self.transition(.committing, null);
        Executor.run(self) catch |err| return self.failed(err);
    } else self.transition(.committing, null);
    self.owner.checkCancelled() catch |err| return self.failed(err);
    self.transition(.completed, null);
}

/// Native interrupt is valid only during commit. requestCancellation on Owner
/// is the cross-thread/any-phase operation, including callback question waits.
pub fn interrupt(self: *Transaction) !void {
    try self.owner.beginTransactionOperation(self);
    defer self.owner.busy = false;
    if (self.state != .committing and self.state != .interrupted)
        return self.owner.transactionFailure(
            error.InvalidTransactionState,
        );
    self.owner.requestCancellation();
    self.transition(.interrupted, error.Cancelled);
}

fn checkSnapshot(self: *Transaction) !void {
    try self.owner.checkCancelled();
    if (self.lock) |*lock| try lock.validate();
    if (!std.mem.eql(u8, &self.snapshot, &try Snapshot.capture(self.owner, self.io)))
        return error.StaleDatabaseState;
}

fn failed(self: *Transaction, err: anyerror) anyerror {
    if (self.owned_actions) |*value| value.fail();
    if (self.owned_manifest) |*value| {
        if (value.failure == null) value.failure = .{ .cause = err };
        value.complete = false;
    }
    self.transition(if (err == error.Cancelled) .interrupted else .failed, err);
    return self.owner.transactionFailure(err);
}

pub fn transition(self: *Transaction, state: State, cause: ?anyerror) void {
    self.state = state;
    self.cause = cause;
    self.owner.transactionEvent(.{ .lifecycle = self.result() });
}

/// Internal: Owner releases even failed/cancelled transactions. Always cleans
/// resources, then reports a lock ownership/unlink error if one occurred.
pub fn destroy(self: *Transaction) !void {
    self.transition(.released, self.cause);
    const allocator = self.owner.allocator;
    defer allocator.destroy(self);
    defer self.storage.deinit();
    defer self.targets.deinit(allocator);
    defer self.removals.deinit(allocator);
    if (self.owned_actions) |*value| value.deinit();
    if (self.owned_manifest) |*value| value.deinit();
    if (self.downloaded_files) |files| {
        for (files) |*file|
            file.deinit();
        allocator.free(files);
    }
    if (self.owned_plan) |*value| value.deinit();
    for (self.targets.items) |target|
        if (target == .archive) {
            target.archive.deinit();
            allocator.destroy(target.archive);
        };
    if (self.lock) |*lock| try lock.release(allocator);
}

/// Acquire and verify the reviewed packages without executing filesystem work.
pub fn download(self: *Transaction) !void {
    try self.begin(.prepared);
    defer self.owner.busy = false;
    self.downloadInternal() catch |err| return self.failed(err);
}

fn downloadInternal(self: *Transaction) !void {
    try self.checkSnapshot();
    if (self.downloaded_files != null) return;
    var requests: std.ArrayList(Downloads.Request) = .empty;
    defer requests.deinit(self.owner.allocator);
    try self.downloadRequests(&requests);
    if (requests.items.len != 0)
        self.owner.transactionEvent(
            .{
                .phase = .{
                    .phase = .package_retrieve,
                    .boundary = .start,
                    .total_packages = requests.items.len,
                },
            },
        );
    errdefer if (requests.items.len != 0)
        self.owner.transactionEvent(
            .{
                .phase = .{
                    .phase = .package_retrieve,
                    .boundary = .failed,
                },
            },
        );
    self.downloaded_files = try Downloads.acquire(self.owner, self.io, requests.items);
    try self.checkSnapshot();
    if (requests.items.len != 0)
        self.owner.transactionEvent(
            .{
                .phase = .{
                    .phase = .package_retrieve,
                    .boundary = .done,
                },
            },
        );
    // Acquisition has already applied effective trust and integrity policy to
    // sealed bytes. Publish the accepted batch at the native phase boundaries.
    if (self.plan().?.additions.len != 0)
        inline for (.{ Callbacks.Phase.keyring, .integrity }) |phase| {
            self.owner.transactionEvent(.{ .phase = .{ .phase = phase, .boundary = .start } });
            try self.owner.checkCancelled();
            self.owner.transactionEvent(.{ .phase = .{ .phase = phase, .boundary = .done } });
        };
}

fn downloadRequests(
    self: *Transaction,
    requests: *std.ArrayList(Downloads.Request),
) !void {
    const reviewed = &self.owned_plan.?;
    for (reviewed.additions) |addition| {
        const candidate = &reviewed.candidates[@intFromEnum(addition.package)];
        const package = &candidate.package;
        if (package.origin != .sync) continue;
        const db = &self.owner.sync_databases.items[candidate.repository.?];
        try requests.append(
            self.owner.allocator,
            .{
                .name = package.repository_filename orelse
                    return error.InvalidPackageFilename,
                .servers = db.servers.items,
                .cache_servers = db.cache_servers.items,
                .package = package,
                .policy = db.signature_policy,
            },
        );
    }
}

pub fn downloadSize(self: *Transaction) !Downloads.Sizes {
    try self.begin(.prepared);
    errdefer |err| self.recordFailure(err);
    defer self.owner.busy = false;
    try self.checkSnapshot();
    var requests: std.ArrayList(Downloads.Request) = .empty;
    defer requests.deinit(self.owner.allocator);
    try self.downloadRequests(&requests);
    return Downloads.sizes(self.owner, self.io, requests.items);
}
