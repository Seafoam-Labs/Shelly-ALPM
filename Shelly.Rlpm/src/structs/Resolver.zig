//! Native prepare-time selection, following the pinned libalpm dependency walk.
//! No downloads, host database access, locks, subprocesses, or package writes.
const std = @import("std");
const Plan = @import("TransactionPlan.zig");
const Package = @import("Package.zig");
const Relation = @import("PackageRelation.zig");
const Version = @import("Version.zig");
const Ref = @import("PackageRef.zig");
const DatabaseRef = @import("DatabaseRef.zig");
const Callbacks = @import("Callbacks.zig");
const Flags = @import("TransactionFlags.zig");
const DatabaseUsage = @import("DatabaseUsage.zig");

const Id = Plan.Id;
const List = std.ArrayList(Id);
const Index = std.StringHashMapUnmanaged(List);
extern "c" fn fnmatch([*:0]const u8, [*:0]const u8, c_int) c_int;

pub const Entry = struct {
    reference: Ref,
    package: *const Package,
};

pub const Repository = struct {
    reference: DatabaseRef,
    name: []const u8,
    usage: DatabaseUsage = .{},
    packages: []const Entry,
    status: enum { valid, missing, invalid } = .valid,
};

pub const Snapshot = struct {
    owner: DatabaseRef.OwnerId = @enumFromInt(0),
    local: []const Entry = &.{},
    repositories: []const Repository = &.{},
};

pub const Options = struct {
    architectures: []const []const u8 = &.{},
    ignore_packages: []const []const u8 = &.{},
    ignore_groups: []const []const u8 = &.{},
    assume_installed: []const Relation = &.{},
};

pub const Target = union(enum) {
    /// Frontend syntax: name/relation or repository/name/relation.
    text: []const u8,
    reference: Ref,
    /// Metadata-only archives can be planned, but retain no integrity claim.
    archive: *const Package,
};

pub const Request = struct {
    install: []const Target = &.{},
    remove: []const []const u8 = &.{},
    system_upgrade: bool = false,
    allow_downgrade: bool = false,
    flags: Flags = .{},
};

pub const Context = struct {
    user: ?*anyopaque = null,
    question: ?*const fn (?*anyopaque, *Callbacks.Question) anyerror!void = null,
    check_cancelled: ?*const fn (?*anyopaque) anyerror!void = null,
    event: ?*const fn (?*anyopaque, Callbacks.Event) anyerror!void = null,
};
var archive_generation: std.atomic.Value(u64) = .init(1);

/// List order wins here, including a provider before a later literal name.
pub fn findSatisfier(packages: []const Entry, dependency: Relation) ?Ref {
    for (packages) |item|
        if (item.package.satisfies(dependency)) return item.reference;
    return null;
}

/// Literal lookup in repository order. Like alpm_sync_get_new_version, this
/// query does not apply ignore or usage policy; system-upgrade planning does.
pub fn newVersion(snapshot: Snapshot, target: *const Package) ?Ref {
    for (snapshot.repositories) |repo|
        for (repo.packages) |item| {
            if (!std.mem.eql(u8, item.package.name, target.name)) continue;
            return if (Version.compareStrings(item.package.version.raw, target.version.raw) == .greaterThan)
                item.reference
            else
                null;
        };
    return null;
}

pub fn shouldIgnore(allocator: std.mem.Allocator, options: Options, pkg: *const Package) !bool {
    if (try matchesPatterns(allocator, options.ignore_packages, pkg.name)) return true;
    for (pkg.groups) |group|
        if (try matchesPatterns(allocator, options.ignore_groups, group)) return true;
    return false;
}

fn matchesPatterns(
    allocator: std.mem.Allocator,
    patterns: []const []const u8,
    value: []const u8,
) !bool {
    if (patterns.len == 0) return false;
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidSnapshot;
    const text = try allocator.dupeZ(u8, value);
    defer allocator.free(text);
    for (patterns) |pattern| {
        if (std.mem.indexOfScalar(u8, pattern, 0) != null) return error.InvalidOption;
        const pat = try allocator.dupeZ(u8, pattern);
        defer allocator.free(pat);
        if (fnmatch(pat, text, 0) == 0) return true;
    }
    return false;
}

/// Inputs are borrowed for this call; every returned view belongs to the plan.
/// Operational failures throw. Semantic failures return an inspectable failed
/// plan; call plan.check() before using additions/removals as an accepted set.
pub fn resolve(
    allocator: std.mem.Allocator,
    snapshot: Snapshot,
    options: Options,
    request: Request,
    context: Context,
) !Plan {
    for (options.assume_installed) |dep|
        if (dep.constraint != .any and dep.constraint != .equal)
            return error.InvalidOption;
    var plan: Plan = .{ .arena = .init(allocator), .flags = request.flags };
    errdefer plan.deinit();
    const a = plan.arena.allocator();
    var solver: Solver = .{
        .a = a,
        .plan = &plan,
        .options = try Plan.copyValue(Options, a, options),
        .context = context,
    };
    try solver.cancel();
    var candidates: std.ArrayList(Plan.Candidate) = .empty;
    for (snapshot.local) |entry| {
        try solver.cancel();
        if (entry.package.origin != .local) return error.InvalidSnapshot;
        try solver.local.append(a, try appendCandidate(&plan, &candidates, entry, null));
    }
    solver.sortNames(solver.local.items);
    for (snapshot.repositories, 0..) |repo, ri| {
        var owned: Repo = .{
            .reference = repo.reference,
            .name = try a.dupe(u8, repo.name),
            .usage = repo.usage,
            .status = repo.status,
        };
        for (repo.packages) |entry| {
            try solver.cancel();
            if (entry.package.origin != .sync or !entry.reference.database.eql(repo.reference))
                return error.InvalidSnapshot;
            try owned.packages.append(a, try appendCandidate(&plan, &candidates, entry, ri));
        }
        solver.sortNames(owned.packages.items);
        try solver.repositories.append(a, owned);
    }
    // A unique generation prevents archive references from aliasing another plan.
    const generation = try nextArchiveGeneration();
    var archives: std.AutoHashMapUnmanaged(usize, Id) = .empty;
    for (request.install) |target|
        if (target == .archive) {
            const pkg = target.archive;
            if (pkg.origin != .archive) return error.UnsupportedPackageOrigin;
            if (!archives.contains(@intFromPtr(pkg))) {
                const ref: Ref = .{
                    .database = .{ .owner = snapshot.owner, .id = .archive },
                    .generation = generation,
                    .id = @enumFromInt(candidates.items.len),
                };
                try archives.put(
                    a,
                    @intFromPtr(pkg),
                    try appendCandidate(
                        &plan,
                        &candidates,
                        .{ .reference = ref, .package = pkg },
                        null,
                    ),
                );
            }
        };
    for (solver.local.items) |id|
        try solver.indexPackage(id);
    for (solver.repositories.items) |repo|
        for (repo.packages.items) |id|
            try solver.indexPackage(id);
    var archive_ids = archives.valueIterator();
    while (archive_ids.next()) |id|
        try solver.indexPackage(id.*);
    for (request.remove) |name| {
        const id = solver.localName(name) orelse {
            try solver.issue(.target_not_found, .{ .target = try a.dupe(u8, name) });
            continue;
        };
        try solver.appendUnique(&solver.explicit_removals, id);
    }
    for (request.install) |target| {
        try solver.cancel();
        const id: Id = switch (target) {
            .archive => |pkg| archives.get(@intFromPtr(pkg)).?,
            .reference => |reference| plan.findReference(reference) orelse return error.StalePackageReference,
            .text => |text| blk: {
                const owned = try a.dupe(u8, text);
                var relation_text = owned;
                var repo_index: ?usize = null;
                if (std.mem.indexOfScalar(u8, owned, '/')) |slash| {
                    for (solver.repositories.items, 0..) |repo, i|
                        if (std.mem.eql(u8, repo.name, owned[0..slash])) {
                            repo_index = i;
                            break;
                        };
                    if (repo_index == null) {
                        try solver.issue(.target_not_found, .{ .target = owned });
                        continue;
                    }
                    relation_text = owned[slash + 1 ..];
                }
                const dep = try Relation.parse(relation_text);
                solver.saw_ignored = false;
                break :blk (try solver.choose(dep, &.{}, repo_index, true, false)) orelse {
                    try solver.issue(
                        if (solver.saw_ignored) .ignored else .target_not_found,
                        .{ .target = owned },
                    );
                    continue;
                };
            },
        };
        if (solver.pkg(id).origin == .local) return error.UnsupportedPackageOrigin;
        if (solver.byName(solver.roots.items, solver.pkg(id).name)) |previous| {
            if (previous != id)
                try solver.issue(
                    .duplicate_target,
                    .{
                        .duplicate = .{ .first = previous, .second = id },
                    },
                );
            continue;
        }
        if (request.flags.needed) {
            if (solver.localName(solver.pkg(id).name)) |old|
                if (solver.compare(id, old) == .equal) {
                    try solver.warn(.{ .skipped_needed = id });
                    continue;
                };
        }
        try solver.roots.append(a, id);
        try solver.reasons.put(a, id, .explicit);
    }
    if (plan.failure == null and request.system_upgrade) try solver.upgrade(request.allow_downgrade);
    plan.had_prepare_targets = solver.roots.items.len != 0 or solver.explicit_removals.items.len != 0;
    if (plan.failure == null and plan.had_prepare_targets) try solver.prepare();
    try solver.finish();
    try solver.cancel();
    return plan;
}

fn appendCandidate(
    plan: *Plan,
    list: *std.ArrayList(Plan.Candidate),
    entry: Entry,
    repository: ?usize,
) !Id {
    const a = plan.arena.allocator();
    if (list.items.len >= std.math.maxInt(u32)) return error.TooManyPackages;
    if (!entry.package.description_loaded) return error.IncompleteMetadata;
    if (entry.package.metadata_error) |err| return err;
    var pkg = try Plan.copyMetadata(a, entry.package.*);
    if (entry.package.verified_archive) |*file| pkg.verified_archive = try file.clone();
    errdefer if (pkg.verified_archive) |*file| file.deinit();
    try list.append(a, .{
        .reference = entry.reference,
        .package = pkg,
        .repository = repository,
    });
    plan.candidates = list.items;
    return @enumFromInt(list.items.len - 1);
}

fn nextArchiveGeneration() !u64 {
    var current = archive_generation.load(.monotonic);
    while (true) {
        const next = std.math.add(u64, current, 1) catch return error.IdentityExhausted;
        if (archive_generation.cmpxchgWeak(current, next, .monotonic, .monotonic)) |actual|
            current = actual
        else
            return current;
    }
}

const Repo = struct {
    reference: DatabaseRef,
    name: []const u8,
    usage: DatabaseUsage,
    status: @FieldType(Repository, "status"),
    packages: List = .empty,
};

const Replacement = struct {
    new: Id,
    old: Id,
};

const ProviderDecision = struct {
    root: Id,
    requiring: ?Id,
    question: Callbacks.Question,
    used: bool = true,
};

const Solver = struct {
    a: std.mem.Allocator,
    plan: *Plan,
    options: Options,
    context: Context,
    local: List = .empty,
    repositories: std.ArrayList(Repo) = .empty,
    names: Index = .empty,
    providers: Index = .empty,
    reverse: Index = .empty,
    roots: List = .empty,
    additions: List = .empty,
    explicit_removals: List = .empty,
    removals: List = .empty,
    replacements: std.ArrayList(Replacement) = .empty,
    reasons: std.AutoHashMapUnmanaged(Id, Package.InstallReason) = .empty,
    questions: std.ArrayList(Callbacks.Question) = .empty,
    warnings: std.ArrayList(Plan.Warning) = .empty,
    issues: std.ArrayList(Plan.Issue) = .empty,
    saw_ignored: bool = false,
    resolving_root: ?Id = null,
    resolving_package: ?Id = null,
    recomputing: bool = false,
    provider_decisions: std.ArrayList(ProviderDecision) = .empty,

    fn pkg(self: *const Solver, id: Id) *const Package {
        return self.plan.package(id);
    }

    fn filename(self: *const Solver, id: Id) ?[]const u8 {
        const item = self.pkg(id);
        return if (item.origin == .archive) item.archive_path else item.repository_filename;
    }

    fn ref(self: *const Solver, id: Id) Ref {
        return self.plan.candidates[@intFromEnum(id)].reference;
    }

    fn cancel(self: *const Solver) !void {
        if (self.context.check_cancelled) |call| try call(self.context.user);
    }

    fn compare(self: *const Solver, first: Id, second: Id) Version.CompareResults {
        return Version.compareStrings(self.pkg(first).version.raw, self.pkg(second).version.raw);
    }

    fn has(ids: []const Id, id: Id) bool {
        return std.mem.indexOfScalar(Id, ids, id) != null;
    }

    fn appendUnique(self: *Solver, list: *List, id: Id) !void {
        if (!has(list.items, id)) try list.append(self.a, id);
    }

    fn index(self: *Solver, map: *Index, name: []const u8, id: Id) !void {
        const result = try map.getOrPut(self.a, name);
        if (!result.found_existing) result.value_ptr.* = .empty;
        try self.appendUnique(result.value_ptr, id);
    }

    fn indexPackage(self: *Solver, id: Id) !void {
        try self.cancel();
        try self.index(&self.names, self.pkg(id).name, id);
        for (self.pkg(id).provides) |dep|
            try self.index(&self.providers, dep.name, id);
        for (self.pkg(id).depends) |dep|
            try self.index(&self.reverse, dep.name, id);
    }

    fn sortNames(self: *Solver, ids: []Id) void {
        std.mem.sort(Id, ids, self, struct {
            fn less(s: *Solver, a: Id, b: Id) bool {
                return std.mem.lessThan(u8, s.pkg(a).name, s.pkg(b).name);
            }
        }.less);
    }

    fn byName(self: *const Solver, ids: []const Id, name: []const u8) ?Id {
        for (ids) |id|
            if (std.mem.eql(u8, self.pkg(id).name, name)) return id;
        return null;
    }

    fn localName(self: *const Solver, name: []const u8) ?Id {
        const ids = self.names.get(name) orelse return null;
        for (ids.items) |id|
            if (self.pkg(id).origin == .local) return id;
        return null;
    }

    fn effective(self: *const Solver, dep: Relation) Relation {
        var result = dep;
        if (self.plan.flags.no_dependency_versions) result.constraint = .any;
        return result;
    }

    fn satisfier(self: *const Solver, ids: []const Id, dep: Relation) ?Id {
        for (ids) |id|
            if (self.pkg(id).satisfies(dep)) return id;
        return null;
    }

    fn assumed(self: *const Solver, dep: Relation) ?Relation {
        for (self.options.assume_installed) |provided|
            if (dep.providedBy(&.{provided})) return provided;
        return null;
    }

    fn warn(self: *Solver, warning: Plan.Warning) !void {
        try self.warnings.append(self.a, warning);
    }

    fn issue(self: *Solver, failure: Plan.Failure, value: Plan.Issue) !void {
        if (self.plan.failure == null) self.plan.failure = failure;
        try self.issues.append(self.a, value);
    }

    fn views(self: *Solver, ids: []const Id) ![]const Callbacks.PackageView {
        const result = try self.a.alloc(Callbacks.PackageView, ids.len);
        for (ids, result) |id, *out|
            out.* = .{ .reference = self.ref(id), .package = self.pkg(id) };
        return result;
    }

    fn refs(self: *Solver, ids: []const Id) ![]const Ref {
        const result = try self.a.alloc(Ref, ids.len);
        for (ids, result) |id, *out|
            out.* = self.ref(id);
        return result;
    }

    fn ask(self: *Solver, original: Callbacks.Question) !Callbacks.Question {
        try self.cancel();
        if (original == .select_provider and self.recomputing) {
            for (self.provider_decisions.items) |*decision| {
                if (decision.used or self.resolving_root != decision.root or
                    self.resolving_package != decision.requiring)
                    continue;
                const previous = decision.question.select_provider;
                const current = original.select_provider;
                if (!sameRelation(previous.dependency, current.dependency) or
                    previous.candidates.len != current.candidates.len)
                    continue;
                var same = true;
                for (previous.candidates, current.candidates) |one, two|
                    if (!std.meta.eql(one, two)) {
                        same = false;
                        break;
                    };
                if (same) {
                    decision.used = true;
                    var replay = original;
                    replay.select_provider.selected = previous.selected;
                    return replay;
                }
            }
        }
        var answer = original;
        if (self.context.question) |call| try call(self.context.user, &answer);
        try self.cancel();
        if (std.meta.activeTag(original) != std.meta.activeTag(answer)) return error.InvalidAnswer;
        // Only answers are mutable: callbacks cannot replace the problem data.
        var recorded = original;
        switch (original) {
            .install_ignored => recorded.install_ignored.install = answer.install_ignored.install,
            .replace => recorded.replace.replace = answer.replace.replace,
            .conflict => recorded.conflict.remove = answer.conflict.remove,
            .remove_packages => recorded.remove_packages.skip = answer.remove_packages.skip,
            .select_provider => |q| {
                if (answer.select_provider.selected >= q.candidates.len) return error.InvalidAnswer;
                recorded.select_provider.selected = answer.select_provider.selected;
            },
            else => unreachable,
        }
        try self.questions.append(self.a, recorded);
        if (recorded == .select_provider)
            if (self.resolving_root) |root| {
                try self.provider_decisions.append(
                    self.a,
                    .{
                        .root = root,
                        .requiring = self.resolving_package,
                        .question = recorded,
                    },
                );
            };
        return recorded;
    }

    fn sameRelation(first: Relation, second: Relation) bool {
        if (!std.mem.eql(u8, first.name, second.name) or
            std.meta.activeTag(first.constraint) != std.meta.activeTag(second.constraint))
            return false;
        return switch (first.constraint) {
            .any => true,
            inline else => |value, tag| std.mem.eql(u8, value, @field(second.constraint, @tagName(tag))),
        };
    }

    fn ignored(self: *Solver, id: Id) !bool {
        return shouldIgnore(self.a, self.options, self.pkg(id));
    }

    fn allow(self: *Solver, id: Id, prompt: bool) !bool {
        if (!try self.ignored(id)) return true;
        self.saw_ignored = true;
        if (!prompt) return false;
        return (try self.ask(
            .{
                .install_ignored = .{
                    .package = self.ref(id),
                    .views = try self.views(&.{id}),
                },
            },
        )).install_ignored.install;
    }

    fn eligible(self: *Solver, id: Id, repo_index: ?usize, local_only: bool) bool {
        const candidate = self.plan.candidates[@intFromEnum(id)];
        if (local_only) return candidate.package.origin == .local;
        const ri = candidate.repository orelse return false;
        if (repo_index) |wanted|
            if (ri != wanted) return false;
        const usage = self.repositories.items[ri].usage;
        return usage.install or usage.upgrade;
    }

    fn choose(
        self: *Solver,
        dep: Relation,
        excluding: []const Id,
        repo_index: ?usize,
        prompt: bool,
        local_only: bool,
    ) !?Id {
        try self.cancel();
        // Literal matches in any eligible repository precede virtual providers.
        if (self.names.get(dep.name)) |ids|
            for (ids.items) |id| {
                if (!self.eligible(id, repo_index, local_only) or !dep.matchesVersion(self.pkg(id).version.raw) or
                    self.byName(excluding, self.pkg(id).name) != null)
                    continue;
                if (try self.allow(id, prompt)) return id;
            };
        var candidates: List = .empty;
        // Index was populated in repository/name order, independent of input
        // archive ordering. Same names in different repos remain alternatives.
        if (self.providers.get(dep.name)) |ids|
            for (ids.items) |id| {
                if (!self.eligible(id, repo_index, local_only) or std.mem.eql(u8, self.pkg(id).name, dep.name) or
                    !self.pkg(id).satisfies(dep) or
                    self.byName(excluding, self.pkg(id).name) != null)
                    continue;
                if (!try self.allow(id, prompt)) continue;
                if (self.localName(self.pkg(id).name) != null) return id;
                try candidates.append(self.a, id);
            };
        if (candidates.items.len == 0) return null;
        if (candidates.items.len == 1) return candidates.items[0];
        const answer = try self.ask(
            .{
                .select_provider = .{
                    .dependency = dep,
                    .candidates = try self.refs(candidates.items),
                    .views = try self.views(candidates.items),
                },
            },
        );
        return candidates.items[answer.select_provider.selected];
    }

    fn upgrade(self: *Solver, downgrade: bool) !void {
        for (self.local.items) |old| {
            try self.cancel();
            if (has(self.explicit_removals.items, old) or
                self.byName(self.roots.items, self.pkg(old).name) != null)
                continue;
            for (self.repositories.items, 0..) |repo, ri| {
                if (!repo.usage.upgrade) continue;
                var newly_replaced = false;
                for (repo.packages.items) |new| {
                    var replaces = false;
                    for (self.pkg(new).replaces) |dep|
                        if (std.mem.eql(u8, dep.name, self.pkg(old).name) and
                            dep.matchesVersion(self.pkg(old).version.raw))
                        {
                            replaces = true;
                            break;
                        };
                    if (!replaces or try self.ignored(old) or try self.ignored(new)) continue;
                    const answer = try self.ask(
                        .{
                            .replace = .{
                                .old = self.ref(old),
                                .new = self.ref(new),
                                .database = repo.reference,
                                .views = try self.views(&.{ old, new }),
                            },
                        },
                    );
                    if (!answer.replace.replace) continue;
                    if (self.byName(self.roots.items, self.pkg(new).name)) |existing| {
                        if (self.plan.candidates[@intFromEnum(existing)].repository != ri) continue;
                        try self.replacements.append(self.a, .{ .new = existing, .old = old });
                        if (self.pkg(old).install_reason == .explicit)
                            try self.reasons.put(self.a, existing, .explicit);
                    } else {
                        try self.roots.append(self.a, new);
                        try self.reasons.put(self.a, new, self.pkg(old).install_reason orelse .explicit);
                        try self.replacements.append(self.a, .{ .new = new, .old = old });
                        newly_replaced = true;
                    }
                }
                if (newly_replaced) break;
                if (self.byName(repo.packages.items, self.pkg(old).name)) |new| {
                    const cmp = self.compare(new, old);
                    if (cmp == .lessThan and !downgrade) {
                        try self.warn(.{ .local_newer = .{ .local = old, .sync = new } });
                    } else if (cmp != .equal) {
                        if (try self.ignored(old) or try self.ignored(new)) {
                            try self.warn(.{ .ignored_upgrade = .{ .local = old, .sync = new } });
                        } else {
                            if (self.byName(self.roots.items, self.pkg(new).name) == null) {
                                try self.roots.append(self.a, new);
                                try self.reasons.put(self.a, new, .explicit);
                            }
                        }
                    }
                    break;
                }
            }
        }
    }

    fn buildRemovals(self: *Solver, adds: []const Id) !void {
        self.removals.clearRetainingCapacity();
        try self.removals.appendSlice(self.a, self.explicit_removals.items);
        // Package-removal lists are traversed in addition order by libalpm.
        for (adds) |new|
            for (self.replacements.items) |replacement|
                if (replacement.new == new)
                    try self.appendUnique(
                        &self.removals,
                        replacement.old,
                    );
    }

    fn prepare(self: *Solver) !void {
        for (self.roots.items) |id| {
            if (self.options.architectures.len == 0) break;
            const arch = self.pkg(id).architecture orelse continue;
            if (std.mem.eql(u8, arch, "any")) continue;
            var valid = false;
            for (self.options.architectures) |accepted|
                if (std.mem.eql(u8, arch, accepted)) {
                    valid = true;
                    break;
                };
            if (!valid) try self.issue(.invalid_architecture, .{ .architecture = id });
        }
        if (self.plan.failure != null) return;
        if (self.roots.items.len != 0) {
            var from_sync = false;
            for (self.roots.items) |id|
                if (self.pkg(id).origin == .sync) {
                    from_sync = true;
                    break;
                };
            for (self.repositories.items) |repo| {
                if (repo.status == .invalid) return error.InvalidDatabase;
                if (repo.status == .missing and from_sync) return error.DatabaseNotFound;
            }
        }
        try self.buildRemovals(self.roots.items);
        if (self.roots.items.len == 0) {
            try self.prepareRemoval();
        } else {
            if (self.plan.flags.no_dependencies) {
                try self.additions.appendSlice(self.a, self.roots.items);
            } else {
                try self.phase(.resolve_dependencies, .start);
                while (true) {
                    self.additions.clearRetainingCapacity();
                    for (self.provider_decisions.items) |*decision|
                        decision.used = false;
                    var failed: List = .empty;
                    for (self.roots.items) |id|
                        if (!try self.expand(id)) try failed.append(self.a, id);
                    if (failed.items.len == 0) {
                        self.issues.clearRetainingCapacity();
                        break;
                    }
                    const answer = try self.ask(
                        .{
                            .remove_packages = .{
                                .packages = try self.refs(failed.items),
                                .views = try self.views(failed.items),
                            },
                        },
                    );
                    if (!answer.remove_packages.skip) {
                        self.plan.failure = .unsatisfied_dependencies;
                        return;
                    }
                    for (failed.items) |id| {
                        _ = self.roots.orderedRemove(std.mem.indexOfScalar(Id, self.roots.items, id).?);
                        try self.warn(.{ .skipped_unresolvable = id });
                    }
                    self.issues.clearRetainingCapacity();
                    self.recomputing = true;
                    try self.buildRemovals(self.roots.items);
                }
                for (self.additions.items, 0..) |id, i| {
                    const name = self.filename(id) orelse continue;
                    for (self.additions.items[0..i]) |previous|
                        if (self.filename(previous)) |other| {
                            if (std.mem.eql(u8, name, other))
                                try self.issue(
                                    .duplicate_filename,
                                    .{
                                        .filename = .{
                                            .first = previous,
                                            .second = id,
                                            .filename = name,
                                        },
                                    },
                                );
                        };
                }
                if (self.plan.failure == null) try self.phase(.resolve_dependencies, .done);
            }
            if (self.plan.failure != null) return;
            if (!self.plan.flags.no_conflicts) {
                try self.phase(.inter_conflicts, .start);
                try self.conflicts();
                if (self.plan.failure == null) try self.phase(.inter_conflicts, .done);
            }
            if (self.plan.failure != null) return;
            try self.buildRemovals(self.additions.items);
            if (!self.plan.flags.no_dependencies) {
                try self.checkFuture(true);
                if (self.issues.items.len != 0) self.plan.failure = .unsatisfied_dependencies;
            }
        }
        if (self.plan.failure == null and !self.plan.flags.no_dependencies) {
            self.additions = try self.order(self.additions.items, self.removals.items, false);
            self.removals = try self.order(self.removals.items, &.{}, true);
        }
    }

    fn localSatisfier(self: *Solver, dep: Relation, current: ?Id, fake: bool) ?Id {
        for (self.local.items) |id| {
            if (has(self.removals.items, id)) continue;
            if (self.byName(if (fake) self.roots.items else self.additions.items, self.pkg(id).name) != null)
                continue;
            if (current) |package|
                if (std.mem.eql(u8, self.pkg(package).name, self.pkg(id).name)) continue;
            if (self.pkg(id).satisfies(dep)) return id;
        }
        return null;
    }

    const Frame = struct {
        id: Id,
        next: usize = 0,
        saved: usize,
        failed: bool = false,
        pending: ?Relation = null,
    };

    fn push(self: *Solver, frames: *std.ArrayList(Frame), id: Id) !void {
        try frames.append(self.a, .{ .id = id, .saved = self.additions.items.len });
        try self.additions.append(self.a, id);
    }

    fn missing(self: *Solver, requiring: Id, dep: Relation) !void {
        try self.issues.append(self.a, .{ .missing = .{ .requiring = requiring, .dependency = dep } });
    }

    /// Explicit stack: large dependency chains cannot exhaust the process stack.
    fn expand(self: *Solver, root: Id) !bool {
        self.resolving_root = root;
        defer self.resolving_root = null;
        if (self.byName(self.additions.items, self.pkg(root).name) != null) return true;
        var frames: std.ArrayList(Frame) = .empty;
        try self.push(&frames, root);
        while (frames.items.len != 0) {
            try self.cancel();
            const frame = &frames.items[frames.items.len - 1];
            if (frame.next == self.pkg(frame.id).depends.len) {
                const done = frames.pop().?;
                if (done.failed) self.additions.shrinkRetainingCapacity(done.saved);
                if (frames.items.len == 0) return !done.failed;
                const parent = &frames.items[frames.items.len - 1];
                self.resolving_package = parent.id;
                const dep = parent.pending.?;
                parent.pending = null;
                if (done.failed) {
                    if (try self.choose(dep, self.removals.items, null, false, true) == null) {
                        try self.missing(parent.id, dep);
                        parent.failed = true;
                    }
                }
                continue;
            }
            const dep = self.effective(self.pkg(frame.id).depends[frame.next]);
            self.resolving_package = frame.id;
            frame.next += 1;
            if (self.pkg(frame.id).satisfies(dep) or self.localSatisfier(dep, frame.id, true) != null or
                self.assumed(dep) != null or
                self.satisfier(self.additions.items, dep) != null)
                continue;
            const candidate = self.satisfier(self.roots.items, dep) orelse
                try self.choose(
                    dep,
                    self.additions.items,
                    null,
                    false,
                    false,
                );
            if (candidate) |id| {
                if (self.byName(self.additions.items, self.pkg(id).name) != null) continue;
                frame.pending = dep;
                try self.push(&frames, id);
            } else if (try self.choose(dep, self.removals.items, null, false, true) == null) {
                try self.missing(frame.id, dep);
                frame.failed = true;
            }
        }
        unreachable;
    }

    fn checkFuture(self: *Solver, reverse: bool) !void {
        for (self.additions.items) |id|
            for (self.pkg(id).depends) |original| {
                const dep = self.effective(original);
                if (self.satisfier(self.additions.items, dep) == null and
                    self.localSatisfier(dep, null, false) == null and
                    self.assumed(dep) == null)
                    try self.missing(id, dep);
            };
        if (!reverse) return;
        // Only pre-existing dependencies broken by this transaction are errors.
        // The reverse name index avoids treating unrelated broken packages as
        // newly broken and retains the first causing local package in DB order.
        const affected = try self.a.alloc(bool, self.plan.candidates.len);
        @memset(affected, false);
        for (self.local.items) |old| {
            if (!has(self.removals.items, old) and
                self.byName(self.additions.items, self.pkg(old).name) == null)
                continue;
            if (self.reverse.get(self.pkg(old).name)) |requiring|
                for (requiring.items) |id| {
                    affected[@intFromEnum(id)] = true;
                };
            for (self.pkg(old).provides) |dep|
                if (self.reverse.get(dep.name)) |requiring|
                    for (requiring.items) |id| {
                        affected[@intFromEnum(id)] = true;
                    };
        }
        for (self.local.items) |id| {
            try self.cancel();
            if (!affected[@intFromEnum(id)]) continue;
            if (has(self.removals.items, id) or self.byName(self.additions.items, self.pkg(id).name) != null)
                continue;
            for (self.pkg(id).depends) |original| {
                const dep = self.effective(original);
                if (self.satisfier(self.additions.items, dep) != null or
                    self.localSatisfier(dep, null, false) != null or
                    self.assumed(dep) != null)
                    continue;
                for (self.local.items) |old| {
                    if (!has(self.removals.items, old) and
                        self.byName(
                            self.additions.items,
                            self.pkg(old).name,
                        ) == null)
                        continue;
                    if (self.pkg(old).satisfies(dep)) {
                        try self.issues.append(
                            self.a,
                            .{
                                .missing = .{
                                    .requiring = id,
                                    .dependency = dep,
                                    .causing = old,
                                },
                            },
                        );
                        break;
                    }
                }
            }
        }
    }

    fn conflictPairs(
        self: *Solver,
        first: []const Id,
        second: []const Id,
        reverse: bool,
        result: *std.ArrayList(Plan.Conflict),
    ) !void {
        for (first) |one|
            for (self.pkg(one).conflicts) |dep|
                for (second) |two| {
                    if (std.mem.eql(u8, self.pkg(one).name, self.pkg(two).name) or !self.pkg(two).satisfies(dep))
                        continue;
                    var duplicate = false;
                    for (result.items) |pair|
                        if ((pair.first == one and pair.second == two) or
                            (pair.first == two and pair.second == one))
                        {
                            duplicate = true;
                            break;
                        };
                    if (!duplicate)
                        try result.append(
                            self.a,
                            .{
                                .first = if (reverse) two else one,
                                .second = if (reverse) one else two,
                                .reason = dep,
                            },
                        );
                };
    }

    fn conflicts(self: *Solver) !void {
        var pairs: std.ArrayList(Plan.Conflict) = .empty;
        try self.conflictPairs(self.additions.items, self.additions.items, false, &pairs);
        for (pairs.items) |pair| {
            if (!has(self.additions.items, pair.first) or !has(self.additions.items, pair.second)) continue;
            var removed: ?Id = null;
            var provider: Id = pair.first;
            if ((Relation{ .name = self.pkg(pair.second).name }).providedBy(self.pkg(pair.first).provides)) {
                removed = pair.second;
            } else if ((Relation{ .name = self.pkg(pair.first).name }).providedBy(
                self.pkg(pair.second).provides,
            )) {
                removed = pair.first;
                provider = pair.second;
            }
            if (removed) |id| {
                _ = self.additions.orderedRemove(std.mem.indexOfScalar(Id, self.additions.items, id).?);
                try self.warn(.{ .provided_target = .{ .removed = id, .provider = provider } });
            } else {
                try self.issue(.conflicting_dependencies, .{ .conflict = pair });
                return;
            }
        }
        if (self.plan.failure != null) return;
        pairs.clearRetainingCapacity();
        var locals: List = .empty;
        for (self.local.items) |id|
            if (self.byName(self.additions.items, self.pkg(id).name) == null)
                try locals.append(self.a, id);
        try self.conflictPairs(self.additions.items, locals.items, false, &pairs);
        try self.conflictPairs(locals.items, self.additions.items, true, &pairs);
        for (pairs.items) |pair| {
            var removed = has(self.explicit_removals.items, pair.second);
            for (self.replacements.items) |replacement|
                if (replacement.old == pair.second and
                    has(self.additions.items, replacement.new))
                {
                    removed = true;
                    break;
                };
            if (removed) continue;
            const answer = try self.ask(
                .{
                    .conflict = .{
                        .first = self.ref(pair.first),
                        .second = self.ref(pair.second),
                        .reason = pair.reason,
                        .views = try self.views(&.{ pair.first, pair.second }),
                    },
                },
            );
            if (answer.conflict.remove) {
                try self.replacements.append(self.a, .{ .new = pair.first, .old = pair.second });
            } else {
                try self.issue(.conflicting_dependencies, .{ .conflict = pair });
                return;
            }
        }
    }

    fn dependsOn(self: *Solver, requiring: Id, provider: Id) bool {
        for (self.pkg(requiring).depends) |dep|
            if (self.pkg(provider).satisfies(dep)) return true;
        return false;
    }

    fn recursiveRemovals(self: *Solver) !void {
        var selected: List = .empty;
        var keep: List = .empty;
        for (self.local.items) |id|
            if (!has(self.removals.items, id)) try keep.append(self.a, id);
        var scan: List = .empty;
        try scan.appendSlice(self.a, self.removals.items);
        var i: usize = 0;
        while (i < scan.items.len) : (i += 1) {
            try self.cancel();
            var j: usize = 0;
            while (j < keep.items.len) {
                const id = keep.items[j];
                if ((self.plan.flags.recurse_all or self.pkg(id).install_reason == .dependency) and
                    self.dependsOn(scan.items[i], id))
                {
                    try selected.append(self.a, id);
                    try scan.append(self.a, id);
                    _ = keep.orderedRemove(j);
                } else j += 1;
            }
        }
        i = 0;
        while (i < keep.items.len) : (i += 1) {
            try self.cancel();
            var j: usize = 0;
            while (j < selected.items.len) {
                if (self.dependsOn(keep.items[i], selected.items[j])) {
                    try keep.append(self.a, selected.orderedRemove(j));
                } else j += 1;
            }
        }
        try self.removals.appendSlice(self.a, selected.items);
    }

    fn prepareRemoval(self: *Solver) !void {
        const flags = self.plan.flags;
        if (flags.recurse and !flags.cascade) try self.recursiveRemovals();
        if (!flags.no_dependencies) {
            try self.phase(.dependencies, .start);
            while (true) {
                try self.cancel();
                self.issues.clearRetainingCapacity();
                try self.checkFuture(true);
                if (self.issues.items.len == 0) break;
                if (flags.cascade) {
                    for (self.issues.items) |issue_value|
                        try self.appendUnique(
                            &self.removals,
                            issue_value.missing.requiring,
                        );
                } else if (flags.unneeded) {
                    for (self.issues.items) |issue_value|
                        if (std.mem.indexOfScalar(
                            Id,
                            self.removals.items,
                            issue_value.missing.causing.?,
                        )) |index_value| {
                            _ = self.removals.orderedRemove(index_value);
                        };
                } else {
                    self.plan.failure = .unsatisfied_dependencies;
                    return;
                }
            }
        }
        if (flags.cascade and flags.recurse) try self.recursiveRemovals();
        if (!flags.no_dependencies)
            for (self.local.items) |id| {
                if (has(self.removals.items, id)) continue;
                for (self.pkg(id).optional_depends) |dep|
                    if (self.satisfier(self.removals.items, dep) != null) {
                        try self.warn(.{ .optional_dependency_removed = .{ .package = id, .dependency = dep } });
                        try self.event(
                            .{
                                .optional_dependency_removed = .{
                                    .package = self.plan.candidates[@intFromEnum(id)].reference,
                                    .dependency = dep,
                                },
                            },
                        );
                    };
            };
        if (!flags.no_dependencies) try self.phase(.dependencies, .done);
    }

    fn event(self: *Solver, value: Callbacks.Event) !void {
        try self.cancel();
        if (self.context.event) |callback| try callback(self.context.user, value);
        try self.cancel();
    }

    fn phase(self: *Solver, value: Callbacks.Phase, boundary: Callbacks.Boundary) !void {
        try self.event(.{ .phase = .{ .phase = value, .boundary = boundary } });
    }

    fn order(self: *Solver, targets: []const Id, ignore: []const Id, reverse_order: bool) !List {
        var vertices: List = .empty;
        try vertices.appendSlice(self.a, targets);
        var remaining: List = .empty;
        for (self.local.items) |id|
            if (self.byName(targets, self.pkg(id).name) == null and !has(ignore, id))
                try remaining.append(self.a, id);
        var children: std.ArrayList(List) = .empty;
        var vi: usize = 0;
        while (vi < vertices.items.len) : (vi += 1) {
            try self.cancel();
            const id = vertices.items[vi];
            var edges: List = .empty;
            for (vertices.items, 0..) |other, index_value|
                if (other != id and self.dependsOn(id, other))
                    try edges.append(
                        self.a,
                        @enumFromInt(index_value),
                    );
            var li: usize = 0;
            while (li < remaining.items.len) {
                const other = remaining.items[li];
                if (self.dependsOn(id, other)) {
                    try edges.append(self.a, @enumFromInt(vertices.items.len));
                    try vertices.append(self.a, other);
                    _ = remaining.orderedRemove(li);
                } else li += 1;
            }
            try children.append(self.a, edges);
        }
        const state = try self.a.alloc(u2, vertices.items.len);
        @memset(state, 0);
        const next = try self.a.alloc(usize, vertices.items.len);
        @memset(next, 0);
        var stack: std.ArrayList(usize) = .empty;
        var result: List = .empty;
        for (vertices.items, 0..) |_, start| {
            if (state[start] != 0) continue;
            try stack.append(self.a, start);
            while (stack.items.len != 0) {
                try self.cancel();
                const v = stack.items[stack.items.len - 1];
                state[v] = 1;
                if (next[v] < children.items[v].items.len) {
                    const child = @intFromEnum(children.items[v].items[next[v]]);
                    next[v] += 1;
                    if (state[child] == 0) {
                        try stack.append(self.a, child);
                        continue;
                    }
                    if (state[child] == 1 and child < targets.len) {
                        var parent = stack.items.len;
                        while (parent > 0) {
                            parent -= 1;
                            const ancestor = stack.items[parent];
                            if (ancestor < targets.len) {
                                if (ancestor != child)
                                    try self.warn(
                                        .{
                                            .cycle = .{
                                                .before = vertices.items[ancestor],
                                                .after = vertices.items[child],
                                                .removal = reverse_order,
                                            },
                                        },
                                    );
                                break;
                            }
                        }
                    }
                } else {
                    if (v < targets.len) try result.append(self.a, vertices.items[v]);
                    state[v] = 2;
                    _ = stack.pop();
                }
            }
        }
        if (reverse_order) std.mem.reverse(Id, result.items);
        return result;
    }

    fn finish(self: *Solver) !void {
        var additions: std.ArrayList(Plan.Addition) = .empty;
        var edges: std.ArrayList(Plan.Edge) = .empty;
        var unchanged: List = .empty;
        var counted_old: List = .empty;
        for (self.additions.items) |id| {
            try self.cancel();
            const package = self.pkg(id);
            const old = self.localName(package.name);
            const selection_reason = if (has(self.roots.items, id))
                self.reasons.get(id) orelse .explicit
            else
                .dependency;
            var reason = if (old) |previous|
                self.pkg(previous).install_reason orelse .explicit
            else
                selection_reason;
            if (self.plan.flags.all_dependencies)
                reason = .dependency
            else if (self.plan.flags.all_explicit)
                reason = .explicit;
            try additions.append(self.a, .{
                .package = id,
                .old = old,
                .action = if (old) |previous| switch (self.compare(id, previous)) {
                    .equal => .reinstall,
                    .lessThan => .downgrade,
                    .greaterThan => .upgrade,
                } else .install,
                .selection_reason = selection_reason,
                .reason = reason,
                .explicit_target = has(self.roots.items, id),
                .installed_database = if (package.origin == .sync)
                    package.database_name
                else
                    package.installed_database,
            });
            if (package.installed_size) |size|
                self.plan.sizes.installed_add = try std.math.add(
                    u64,
                    self.plan.sizes.installed_add,
                    size,
                )
            else
                self.plan.sizes.unknown_installed += 1;
            if (package.origin != .archive) {
                if (package.compressed_size) |size|
                    self.plan.sizes.download_upper_bound = try std.math.add(
                        u64,
                        self.plan.sizes.download_upper_bound,
                        size,
                    )
                else
                    self.plan.sizes.unknown_download += 1;
            }
            if (old) |previous| try self.appendUnique(&counted_old, previous);
        }
        try counted_old.appendSlice(self.a, self.removals.items);
        var seen: List = .empty;
        for (counted_old.items) |old| {
            if (has(seen.items, old)) continue;
            try seen.append(self.a, old);
            if (self.pkg(old).installed_size) |size|
                self.plan.sizes.installed_remove = try std.math.add(
                    u64,
                    self.plan.sizes.installed_remove,
                    size,
                )
            else
                self.plan.sizes.unknown_installed += 1;
        }
        // Edges describe the final future state, including dependencies of
        // surviving installed packages. Ignored hard deps have no invented edge.
        if (!self.plan.flags.no_dependencies and self.plan.failure == null) {
            var future: List = .empty;
            try future.appendSlice(self.a, self.additions.items);
            for (self.local.items) |id|
                if (!has(self.removals.items, id) and
                    self.byName(
                        self.additions.items,
                        self.pkg(id).name,
                    ) == null)
                    try future.append(self.a, id);
            for (future.items) |id|
                for (self.pkg(id).depends) |original| {
                    const dep = self.effective(original);
                    if (self.satisfier(future.items, dep)) |provider| {
                        var provision: ?Relation = null;
                        if (!std.mem.eql(u8, dep.name, self.pkg(provider).name) or
                            !dep.matchesVersion(
                                self.pkg(provider).version.raw,
                            ))
                        {
                            for (self.pkg(provider).provides) |provided|
                                if (dep.providedBy(&.{provided})) {
                                    provision = provided;
                                    break;
                                };
                        }
                        try edges.append(
                            self.a,
                            .{
                                .requiring = id,
                                .dependency = original,
                                .satisfier = .{ .package = provider },
                                .provision = provision,
                                .version_ignored = self.plan.flags.no_dependency_versions,
                            },
                        );
                        if (self.pkg(provider).origin == .local) try self.appendUnique(&unchanged, provider);
                    } else if (self.assumed(dep)) |provided|
                        try edges.append(
                            self.a,
                            .{
                                .requiring = id,
                                .dependency = original,
                                .satisfier = .{ .assumed = provided },
                                .version_ignored = self.plan.flags.no_dependency_versions,
                            },
                        );
                };
        }
        self.plan.additions = additions.items;
        self.plan.removals = self.removals.items;
        self.plan.unchanged_satisfiers = unchanged.items;
        self.plan.edges = edges.items;
        self.plan.questions = self.questions.items;
        self.plan.warnings = self.warnings.items;
        self.plan.issues = self.issues.items;
    }
};
