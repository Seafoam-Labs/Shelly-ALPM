//! Executor stages owned by Transaction. The executor brackets each payload/local
//! record change with beforePackage/afterPackage, then calls finish only after
//! all mutations succeed. This is not an alternative public commit method.
const std = @import("std");
const Transaction = @import("Transaction.zig");
const Hooks = @import("Hooks.zig");
const Process = @import("ActionProcess.zig");
const Scriptlets = @import("Scriptlets.zig");
const Plan = @import("TransactionPlan.zig");
const Diagnostic = @import("Diagnostic.zig");
const c = @import("action_protocol").c;
const Audit = @import("Audit.zig");
const PackageRelation = @import("PackageRelation.zig");

const Actions = @This();

pub const State = enum { initialized, ready, package, complete, failed, disabled };

pub const Kind = enum { hook_parse, pre_hook, post_hook, scriptlet, ldconfig, cleanup };

pub const Outcome = struct {
    kind: Kind,
    name: []const u8,
    function: ?Scriptlets.Function = null,
    process: ?Process.Result = null,
    cause: ?anyerror = null,
    line: usize = 0,
    warning: bool = false,
};
tx: *Transaction,
arena: std.heap.ArenaAllocator,
state: State = .initialized,
next: usize = 0,
started: bool = false,
effects: []const Hooks.Change = &.{},
outcomes: std.ArrayList(Outcome) = .empty,

pub fn init(tx: *Transaction) !Actions {
    try checkTransaction(tx);
    var self: Actions = .{ .tx = tx, .arena = std.heap.ArenaAllocator.init(tx.owner.allocator) };
    errdefer self.deinit();
    const plan = tx.plan().?;
    if ((tx.flags.download_only and plan.additions.len != 0) or plan.additions.len + plan.removals.len == 0) {
        self.state = .disabled;
        return self;
    }
    const manifest = tx.manifest() orelse return error.IncompletePreflight;
    try manifest.check();
    self.effects = try Hooks.changes(
        self.arena.allocator(),
        plan,
        tx.manifest().?,
        tx.owner.configuration.no_extract,
    );
    return self;
}

pub fn deinit(self: *Actions) void {
    self.arena.deinit();
    self.* = undefined;
}

fn checkTransaction(tx: *Transaction) !void {
    if (tx.state != .committing or tx.owner.active_transaction != tx or !tx.owner.busy)
        return error.InvalidTransactionState;
    if (tx.lock) |*lock| try lock.validate() else return error.TransactionNotLocked;
    if (tx.plan() == null) return error.InvalidTransactionState;
    try tx.owner.checkCancelled();
}

fn guard(self: *Actions, expected: State) !void {
    checkTransaction(self.tx) catch |err| {
        self.state = .failed;
        return err;
    };
    if (self.state != expected) return error.InvalidActionState;
}

fn record(self: *Actions, outcome: Outcome) !void {
    var owned = outcome;
    owned.name = try self.arena.allocator().dupe(u8, outcome.name);
    try self.outcomes.append(self.arena.allocator(), owned);
    if (outcome.cause) |cause|
        self.tx.owner.transactionEvent(
            .{
                .diagnostic = Diagnostic.init(.transaction, cause, null),
            },
        );
}

/// Pre-hook abort leaves the session failed. Callers must not perform payload
/// changes; normal nonfatal hook failures are retained in outcomes.
pub fn begin(self: *Actions) !void {
    if (self.state == .disabled) return;
    try self.guard(.initialized);
    errdefer self.state = .failed;
    try self.hooks(.pre_transaction);
    try self.tx.owner.checkCancelled();
    self.started = true;
    Audit.log(self.tx, "transaction started", .{});
    self.tx.owner.transactionEvent(.{ .phase = .{ .phase = .transaction, .boundary = .start } });
    try self.tx.owner.checkCancelled();
    self.state = .ready;
}

fn hooks(self: *Actions, when: Hooks.When) !void {
    if (self.tx.flags.no_hooks) return;
    const owner = self.tx.owner;
    var discovered = Hooks.init(owner.allocator);
    defer discovered.deinit();
    try discovered.discover(self.tx.io, owner.configuration.hook_directories orelse &.{});
    for (discovered.issues.items) |issue|
        try self.record(
            .{
                .kind = .hook_parse,
                .name = issue.name,
                .line = issue.line,
                .cause = issue.cause,
                .warning = issue.warning,
            },
        );
    if (when == .pre_transaction) try discovered.check();
    const matches = try discovered.match(when, self.effects);
    if (matches.len == 0) return;
    owner.transactionEvent(.{ .hook = .{ .when = when, .boundary = .start } });
    defer owner.transactionEvent(.{ .hook = .{ .when = when, .boundary = .done } });
    for (matches, 0..) |selected, position| {
        try owner.checkCancelled();
        const hook = selected.hook;
        owner.transactionEvent(
            .{
                .hook_run = .{
                    .name = hook.name,
                    .description = hook.description,
                    .position = position + 1,
                    .total = matches.len,
                    .boundary = .start,
                },
            },
        );
        var outcome: Outcome = .{
            .kind = if (when == .pre_transaction) .pre_hook else .post_hook,
            .name = hook.name,
        };
        outcome.process = self.runHook(selected) catch |err| blk: {
            outcome.cause = err;
            break :blk null;
        };
        if (outcome.process) |process| {
            if (!process.success())
                outcome.cause = error.HookFailed
            else if (process.network_warning != null)
                outcome.cause = error.NetworkIsolationWarning;
        }
        owner.transactionEvent(
            .{
                .hook_run = .{
                    .name = hook.name,
                    .description = hook.description,
                    .position = position + 1,
                    .total = matches.len,
                    .boundary = .done,
                },
            },
        );
        try self.record(outcome);
        if (outcome.cause) |cause| {
            if (cause == error.Cancelled or cause == error.OutOfMemory) return cause;
        }
        if (outcome.cause != null and hook.abort_on_fail and when == .pre_transaction)
            return error.PreTransactionHookFailed;
    }
}

fn runHook(self: *Actions, selected: Hooks.Match) !Process.Result {
    const owner = self.tx.owner;
    // Consult the live local cache at invocation time. The executor publishes new
    // local state before post hooks. AssumeInstalled does not satisfy Depends.
    const local = &owner.local.?;
    try local.loadDescriptions(self.tx.io);
    for (selected.hook.depends.items) |text| {
        const dependency = try PackageRelation.parse(text);
        var found = false;
        for (local.packages.packages.items) |*package|
            if (package.satisfies(dependency)) {
                found = true;
                break;
            };
        if (!found) return error.HookDependencyMissing;
    }
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(owner.allocator);
    if (selected.hook.needs_targets)
        for (selected.targets) |target| {
            try input.appendSlice(owner.allocator, target);
            try input.append(owner.allocator, '\n');
        };
    return Process.run(
        owner,
        self.tx.io,
        .{
            .root = &self.tx.manifest().?.root,
            .argv = selected.hook.argv,
            .stdin = input.items,
            .network = if (selected.hook.allow_network)
                .allowed
            else
                .required,
        },
    );
}

fn current(self: *Actions) ?struct {
    id: Plan.Id,
    addition: ?Plan.Addition,
} {
    const plan = self.tx.plan().?;
    if (self.next < plan.removals.len) return .{ .id = plan.removals[self.next], .addition = null };
    const index = self.next - plan.removals.len;
    if (index >= plan.additions.len) return null;
    const addition = plan.additions[index];
    return .{ .id = addition.package, .addition = addition };
}

/// Executor order is removals followed by additions, in resolved order.
pub fn beforePackage(self: *Actions, id: Plan.Id) !void {
    try self.guard(.ready);
    const item = self.current() orelse return error.InvalidActionState;
    if (item.id != id) return error.InvalidActionState;
    errdefer self.state = .failed;
    try self.scriptlet(item.id, item.addition, false);
    try self.tx.owner.checkCancelled();
    self.state = .package;
}

/// For removals call before deleting the old local record. For additions call
/// after writing its new install member. Reinstall/downgrade use upgrade scripts.
pub fn afterPackage(self: *Actions, id: Plan.Id) !void {
    try self.guard(.package);
    const item = self.current().?;
    if (item.id != id) return error.InvalidActionState;
    errdefer self.state = .failed;
    try self.scriptlet(item.id, item.addition, true);
    try self.tx.owner.checkCancelled();
    self.next += 1;
    self.state = .ready;
}

fn scriptlet(self: *Actions, id: Plan.Id, addition: ?Plan.Addition, post: bool) !void {
    if (self.tx.flags.no_scriptlets) return;
    const plan = self.tx.plan().?;
    const package = plan.package(id);
    const function: Scriptlets.Function = if (addition) |add|
        (if (add.old != null)
            (if (post) .post_upgrade else .pre_upgrade)
        else
            (if (post) .post_install else .pre_install))
    else
        (if (post) .post_remove else .pre_remove);
    const source: Scriptlets.Source = if (addition != null and !post) blk: {
        for (self.tx.manifest().?.archives.items) |*archive|
            if (archive.id == id)
                break :blk .{ .package = &archive.package };
        return error.InvalidActionState;
    } else .{
        .file = try std.fmt.allocPrint(
            self.arena.allocator(),
            "{s}local/{s}-{s}/install",
            .{
                self.tx.owner.configuration.database_path,
                package.name,
                package.version.raw,
            },
        ),
    };
    var outcome: Outcome = .{
        .kind = .scriptlet,
        .name = package.name,
        .function = function,
    };
    const result = Scriptlets.run(
        self.tx.owner,
        self.tx.io,
        &self.tx.manifest().?.root,
        source,
        function,
        package.version.raw,
        if (addition) |add|
            (if (add.old) |old|
                plan.package(old).version.raw
            else
                null)
        else
            null,
    ) catch |err| {
        outcome.cause = err;
        try self.record(outcome);
        if (err == error.Cancelled or err == error.OutOfMemory) return err;
        return;
    };
    if (result.process) |process| {
        outcome.process = process;
        if (!process.success()) outcome.cause = error.ScriptletFailed;
        try self.record(outcome);
    }
    if (result.cleanup_failed)
        try self.record(
            .{
                .kind = .cleanup,
                .name = package.name,
                .cause = error.ScriptletCleanupFailed,
            },
        );
}

/// An executor that fails between before/afterPackage must call fail, never
/// finish. There are no post-transaction hooks after failure or cancellation.
pub fn fail(self: *Actions) void {
    self.state = .failed;
}

pub fn finish(self: *Actions) !void {
    if (self.state == .disabled) return;
    try self.guard(.ready);
    if (self.current() != null) return error.InvalidActionState;
    errdefer self.state = .failed;
    try self.ldconfig();
    try self.tx.owner.checkCancelled();
    self.tx.owner.transactionEvent(.{ .phase = .{ .phase = .transaction, .boundary = .done } });
    try self.tx.owner.checkCancelled();
    Audit.log(self.tx, "transaction completed", .{});
    try self.hooks(.post_transaction);
    try self.tx.owner.checkCancelled();
    self.state = .complete;
}

fn ldconfig(self: *Actions) !void {
    const root = &self.tx.manifest().?.root;
    if (try root.inspect("etc/ld.so.conf", true) == null) return;
    const executable = (try root.open("usr/bin/ldconfig", true)) orelse return;
    defer _ = c.close(executable);
    if (c.faccessat(executable, "", c.X_OK, c.AT_EMPTY_PATH | c.AT_EACCESS) != 0) return;
    var outcome: Outcome = .{ .kind = .ldconfig, .name = "ldconfig" };
    outcome.process = Process.run(
        self.tx.owner,
        self.tx.io,
        .{
            .root = root,
            .argv = &.{"ldconfig"},
            .command = "/usr/bin/ldconfig",
            .network = .best_effort,
        },
    ) catch |err| blk: {
        outcome.cause = err;
        break :blk null;
    };
    if (outcome.process) |process| {
        if (!process.success())
            outcome.cause = error.LdconfigFailed
        else if (process.network_warning != null)
            outcome.cause = error.NetworkIsolationWarning;
    }
    try self.record(outcome);
    if (outcome.cause) |cause| {
        if (cause == error.Cancelled or cause == error.OutOfMemory) return cause;
    }
}
