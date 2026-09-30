//! Public consumer tests: normal runs replay frozen data without libalpm.
const std = @import("std");
const rlpm = @import("Shelly_Rlpm");
const Archive = @import("archive_fixture.zig");

const R = rlpm.Resolver;
const a = std.testing.allocator;

fn package(name: []const u8, version: []const u8, origin: rlpm.Package.Origin) rlpm.Package {
    return .{
        .name = name,
        .version = .{
            .raw = version,
            .epoch = "0",
            .pkgver = version,
            .pkgrel = null,
        },
        .database_name = if (origin == .local) "local" else "test",
        .origin = origin,
        .install_reason = .explicit,
    };
}

fn entry(pkg: *const rlpm.Package, db: u64, id: u32) R.Entry {
    return .{
        .reference = .{
            .database = .{ .owner = @enumFromInt(1), .id = @enumFromInt(db) },
            .generation = 1,
            .id = @enumFromInt(id),
        },
        .package = pkg,
    };
}

fn repository(packages: []const R.Entry) R.Repository {
    return .{
        .reference = .{ .owner = @enumFromInt(1), .id = @enumFromInt(1) },
        .name = "test",
        .packages = packages,
    };
}

fn expectAdds(plan: *const rlpm.TransactionPlan, names: []const []const u8) !void {
    try plan.check();
    try std.testing.expectEqual(names.len, plan.additions.len);
    for (names, plan.additions) |name, addition|
        try std.testing.expectEqualStrings(
            name,
            plan.package(addition.package).name,
        );
}

test "resolver shared closure and owned original provision edges" {
    var app = package("app", "1-1", .sync);
    app.depends = &.{try rlpm.PackageRelation.parse("virtual>=2")};
    var library = package("library", "3-1", .sync);
    library.provides = &.{try rlpm.PackageRelation.parse("virtual=2")};
    var plan = try R.resolve(
        a,
        .{
            .repositories = &.{
                repository(
                    &.{ entry(&app, 1, 0), entry(&library, 1, 1) },
                ),
            },
        },
        .{},
        .{ .install = &.{.{ .text = "app" }} },
        .{},
    );
    defer plan.deinit();
    try expectAdds(&plan, &.{ "library", "app" });
    try std.testing.expectEqual(.dependency, plan.additions[0].reason);
    try std.testing.expectEqual(.explicit, plan.additions[1].reason);
    try std.testing.expectEqualStrings("2", plan.edges[0].provision.?.constraint.equal);
    try std.testing.expectEqualStrings("2", plan.edges[0].dependency.constraint.greater_equal);
}

test "transaction flags round trip known bits and reject reserved bits" {
    for (0..18) |bit| {
        const mask = @as(u32, 1) << @intCast(bit);
        if (bit == 1 or bit == 12) {
            try std.testing.expectError(error.InvalidTransactionFlags, rlpm.TransactionFlags.fromBits(mask));
        } else try std.testing.expectEqual(mask, (try rlpm.TransactionFlags.fromBits(mask)).toBits());
    }
}

const JsonPackage = struct {
    name: []const u8,
    version: []const u8,
    reason: u8 = 0,
    arch: []const u8 = "any",
    filename: ?[]const u8 = null,
    path: ?[]const u8 = null,
    depends: []const []const u8 = &.{},
    provides: []const []const u8 = &.{},
    conflicts: []const []const u8 = &.{},
    replaces: []const []const u8 = &.{},
    optional_depends: []const []const u8 = &.{},
    make_depends: []const []const u8 = &.{},
    check_depends: []const []const u8 = &.{},
    groups: []const []const u8 = &.{},
};

const Answers = struct {
    install_ignored: usize = 0,
    replace: usize = 0,
    conflict: usize = 0,
    remove_packages: usize = 0,
    select_provider: usize = 0,

    fn answer(context: ?*anyopaque, q: *rlpm.Callbacks.Question) !void {
        const self: *const Answers = @ptrCast(@alignCast(context.?));
        switch (q.*) {
            .install_ignored => |*value| value.install = self.install_ignored != 0,
            .replace => |*value| value.replace = self.replace != 0,
            .conflict => |*value| value.remove = self.conflict != 0,
            .remove_packages => |*value| value.skip = self.remove_packages != 0,
            .select_provider => |*value| value.selected = self.select_provider,
            else => return error.UnexpectedQuestion,
        }
    }
};

const Case = struct {
    name: []const u8,
    local: []const JsonPackage,
    repositories: []const struct {
        name: []const u8,
        usage: u8,
        packages: []const JsonPackage,
    },
    archives: []const JsonPackage = &.{},
    targets: []const []const u8,
    remove: []const []const u8 = &.{},
    system_upgrade: bool = false,
    allow_downgrade: bool = false,
    flags: u32 = 0,
    architectures: []const []const u8 = &.{},
    ignore_packages: []const []const u8 = &.{},
    ignore_groups: []const []const u8 = &.{},
    assume_installed: []const []const u8 = &.{},
    answers: Answers = .{},
    result: struct {
        success: bool,
        category: ?rlpm.TransactionPlan.Failure,
        add: []const struct {
            identity: []const u8,
            reason: u8,
        },
        remove: []const []const u8,
        questions: []const struct {
            kind: []const u8,
            answer: usize,
            packages: []const []const u8,
            dependency: ?[]const u8 = null,
        },
        cycles: []const []const u8,
        issues: []const struct {
            requiring: ?[]const u8 = null,
            dependency: []const u8,
            causing: ?[]const u8 = null,
            first: ?[]const u8 = null,
            second: ?[]const u8 = null,
        },
        queries: []const struct {
            package: []const u8,
            new_version: ?[]const u8,
            ignored: bool,
        },
        edges: []const struct {
            requiring: []const u8,
            dependency: []const u8,
            satisfier: ?[]const u8,
            provision: ?[]const u8,
            assumed: ?[]const u8,
        },
    },
};

fn relations(alloc: std.mem.Allocator, strings: []const []const u8) ![]const rlpm.PackageRelation {
    const result = try alloc.alloc(rlpm.PackageRelation, strings.len);
    for (strings, result) |str, *out|
        out.* = try rlpm.PackageRelation.parse(str);
    return result;
}

fn jsonEntries(
    alloc: std.mem.Allocator,
    packages: []const JsonPackage,
    origin: rlpm.Package.Origin,
    db: u64,
    name: []const u8,
) ![]const R.Entry {
    const entries = try alloc.alloc(R.Entry, packages.len);
    for (packages, entries, 0..) |input, *out, i| {
        const pkg = try alloc.create(rlpm.Package);
        pkg.* = package(input.name, input.version, origin);
        pkg.version = try rlpm.Version.init(input.version, alloc);
        pkg.database_name = name;
        pkg.architecture = input.arch;
        pkg.install_reason = if (input.reason == 0) .explicit else .dependency;
        pkg.repository_filename = if (origin == .archive)
            null
        else
            input.filename orelse
                try std.fmt.allocPrint(
                    alloc,
                    "{s}-{s}.pkg.tar",
                    .{ input.name, input.version },
                );
        if (origin == .archive)
            pkg.archive_path = if (input.path) |path|
                try std.fmt.allocPrint(
                    alloc,
                    "/fixture/{s}",
                    .{path},
                )
            else
                try std.fmt.allocPrint(
                    alloc,
                    "/fixture/{d}.pkg.tar",
                    .{i},
                );
        pkg.installed_size = 300;
        pkg.compressed_size = 100;
        pkg.groups = input.groups;
        inline for (.{
            "depends",
            "provides",
            "conflicts",
            "replaces",
            "optional_depends",
            "make_depends",
            "check_depends",
        }) |field|
            @field(pkg, field) = try relations(alloc, @field(input, field));
        out.* = entry(pkg, db, @intCast(i));
    }
    return entries;
}

fn casePlan(alloc: std.mem.Allocator, case: Case) !rlpm.TransactionPlan {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const scratch = arena.allocator();
    const local = try jsonEntries(scratch, case.local, .local, 0, "local");
    const repositories = try scratch.alloc(R.Repository, case.repositories.len);
    for (case.repositories, repositories, 0..) |input, *out, i| {
        out.* = .{
            .reference = .{ .owner = @enumFromInt(1), .id = @enumFromInt(i + 1) },
            .name = input.name,
            .usage = .{
                .sync = input.usage & 1 != 0,
                .search = input.usage & 2 != 0,
                .install = input.usage & 4 != 0,
                .upgrade = input.usage & 8 != 0,
            },
            .packages = try jsonEntries(scratch, input.packages, .sync, i + 1, input.name),
        };
    }
    for (case.result.queries) |query| {
        for (local) |item| {
            if (!std.mem.eql(u8, query.package, try identity(scratch, item.package))) continue;
            const newer = R.newVersion(.{ .repositories = repositories }, item.package);
            if (query.new_version) |expected| {
                const ref = newer orelse return error.TestUnexpectedResult;
                for (repositories) |repo|
                    for (repo.packages) |candidate| {
                        if (std.meta.eql(ref, candidate.reference))
                            try std.testing.expectEqualStrings(
                                expected,
                                try identity(scratch, candidate.package),
                            );
                    };
            } else try std.testing.expect(newer == null);
            try std.testing.expectEqual(
                query.ignored,
                try R.shouldIgnore(
                    alloc,
                    .{
                        .ignore_packages = case.ignore_packages,
                        .ignore_groups = case.ignore_groups,
                    },
                    item.package,
                ),
            );
        }
    }
    const archives = try jsonEntries(scratch, case.archives, .archive, std.math.maxInt(u64), "");
    const targets = try scratch.alloc(R.Target, case.targets.len);
    for (case.targets, targets) |input, *out| {
        out.* = if (std.mem.startsWith(u8, input, "@"))
            .{
                .archive = archives[try std.fmt.parseInt(usize, input[1..], 10)].package,
            }
        else
            .{ .text = input };
    }
    return R.resolve(alloc, .{
        .owner = @enumFromInt(1),
        .local = local,
        .repositories = repositories,
    }, .{
        .architectures = case.architectures,
        .ignore_packages = case.ignore_packages,
        .ignore_groups = case.ignore_groups,
        .assume_installed = try relations(scratch, case.assume_installed),
    }, .{
        .install = targets,
        .remove = case.remove,
        .system_upgrade = case.system_upgrade,
        .allow_downgrade = case.allow_downgrade,
        .flags = try rlpm.TransactionFlags.fromBits(case.flags),
    }, .{ .user = @constCast(&case.answers), .question = Answers.answer });
}

fn identity(alloc: std.mem.Allocator, pkg: *const rlpm.Package) ![]const u8 {
    return std.fmt.allocPrint(
        alloc,
        "{s}/{s}@{s}",
        .{
            if (pkg.origin == .archive)
                "file"
            else
                pkg.database_name,
            pkg.name,
            pkg.version.raw,
        },
    );
}

fn compareCase(case: Case, plan: *const rlpm.TransactionPlan) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    try std.testing.expectEqual(case.result.success, plan.failure == null);
    try std.testing.expectEqual(case.result.category, plan.failure);
    if (case.result.success) {
        try std.testing.expectEqual(case.result.add.len, plan.additions.len);
        for (case.result.add, plan.additions) |expected, actual| {
            try std.testing.expectEqualStrings(
                expected.identity,
                try identity(
                    scratch,
                    plan.package(actual.package),
                ),
            );
            try std.testing.expectEqual(
                if (expected.reason == 0)
                    rlpm.Package.InstallReason.explicit
                else
                    .dependency,
                actual.selection_reason,
            );
        }
        try std.testing.expectEqual(case.result.remove.len, plan.removals.len);
        for (case.result.remove, plan.removals) |expected, actual|
            try std.testing.expectEqualStrings(
                expected,
                try identity(scratch, plan.package(actual)),
            );
        var cycles: std.ArrayList([]const u8) = .empty;
        for (plan.warnings) |warning|
            if (warning == .cycle) {
                const cycle = warning.cycle;
                try cycles.append(
                    scratch,
                    try std.fmt.allocPrint(
                        scratch,
                        "{s} will be {s} its {s} dependency",
                        .{
                            plan.package(cycle.before).name,
                            if (cycle.removal)
                                "removed after"
                            else
                                "installed before",
                            plan.package(cycle.after).name,
                        },
                    ),
                );
            };
        try std.testing.expectEqual(case.result.cycles.len, cycles.items.len);
        for (case.result.cycles, cycles.items) |expected, actual|
            try std.testing.expectEqualStrings(
                expected,
                actual,
            );
        try std.testing.expectEqual(case.result.edges.len, plan.edges.len);
        for (case.result.edges, plan.edges) |expected, actual| {
            try std.testing.expectEqualStrings(
                expected.requiring,
                try identity(
                    scratch,
                    plan.package(actual.requiring),
                ),
            );
            try std.testing.expectEqualStrings(
                expected.dependency,
                try actual.dependency.formatAlloc(scratch),
            );
            switch (actual.satisfier) {
                .package => |id| try std.testing.expectEqualStrings(
                    expected.satisfier.?,
                    try identity(scratch, plan.package(id)),
                ),
                .assumed => |dep| try std.testing.expectEqualStrings(
                    expected.assumed.?,
                    try dep.formatAlloc(scratch),
                ),
            }
            if (expected.provision) |dep|
                try std.testing.expectEqualStrings(
                    dep,
                    try actual.provision.?.formatAlloc(scratch),
                )
            else
                try std.testing.expect(actual.provision == null);
        }
    }
    try std.testing.expectEqual(case.result.questions.len, plan.questions.len);
    for (case.result.questions, plan.questions) |expected, actual| {
        try std.testing.expectEqualStrings(expected.kind, @tagName(actual));
        const value: struct {
            answer: usize,
            views: []const rlpm.Callbacks.PackageView,
            dependency: ?rlpm.PackageRelation = null,
        } = switch (actual) {
            .install_ignored => |q| .{ .answer = @intFromBool(q.install), .views = q.views },
            .replace => |q| .{ .answer = @intFromBool(q.replace), .views = q.views },
            .conflict => |q| .{
                .answer = @intFromBool(q.remove),
                .views = q.views,
                .dependency = q.reason,
            },
            .remove_packages => |q| .{ .answer = @intFromBool(q.skip), .views = q.views },
            .select_provider => |q| .{
                .answer = q.selected,
                .views = q.views,
                .dependency = q.dependency,
            },
            else => return error.UnexpectedQuestion,
        };
        try std.testing.expectEqual(expected.answer, value.answer);
        try std.testing.expectEqual(expected.packages.len, value.views.len);
        for (expected.packages, value.views) |name, view| {
            try std.testing.expectEqualStrings(name, try identity(scratch, view.package));
            try std.testing.expect(plan.findReference(view.reference) != null);
        }
        if (expected.dependency) |dep|
            try std.testing.expectEqualStrings(
                dep,
                try value.dependency.?.formatAlloc(scratch),
            );
    }
    if (plan.failure == .unsatisfied_dependencies or plan.failure == .conflicting_dependencies) {
        try std.testing.expectEqual(case.result.issues.len, plan.issues.len);
        for (case.result.issues, plan.issues) |expected, actual|
            switch (actual) {
                .missing => |missing| {
                    try std.testing.expectEqualStrings(expected.requiring.?, plan.package(missing.requiring).name);
                    try std.testing.expectEqualStrings(
                        expected.dependency,
                        try missing.dependency.formatAlloc(scratch),
                    );
                    if (expected.causing) |cause|
                        try std.testing.expectEqualStrings(
                            cause,
                            plan.package(missing.causing.?).name,
                        )
                    else
                        try std.testing.expect(missing.causing == null);
                },
                .conflict => |conflict| {
                    try std.testing.expectEqualStrings(
                        expected.first.?,
                        try identity(
                            scratch,
                            plan.package(conflict.first),
                        ),
                    );
                    try std.testing.expectEqualStrings(
                        expected.second.?,
                        try identity(
                            scratch,
                            plan.package(conflict.second),
                        ),
                    );
                    try std.testing.expectEqualStrings(
                        expected.dependency,
                        try conflict.reason.formatAlloc(scratch),
                    );
                },
                else => return error.UnexpectedIssue,
            };
    }
}

const Reference = struct {
    schema: u8,
    library_sha256: []const u8,
    cases: []const Case,
    assumed_options: []const struct {
        relation: []const u8,
        success: bool,
    },
};
test "pinned prepare oracle: frozen pacman adaptations and generated universes" {
    const parsed = try std.json.parseFromSlice(
        Reference,
        a,
        @embedFile("fixtures/resolver-reference.json"),
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "da30edd45277cf4b1000485658976042f8106fe0b97378d1e6c4e81a9d7c4888",
        parsed.value.library_sha256,
    );
    try std.testing.expectEqual(@as(usize, 314), parsed.value.cases.len);
    var failures: usize = 0;
    for (parsed.value.cases) |case| {
        var plan = try casePlan(a, case);
        defer plan.deinit();
        compareCase(case, &plan) catch {
            std.debug.print("reference mismatch: {s}\n", .{case.name});
            failures += 1;
        };
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "resolver final reasons, actions, sizes and selected repository provenance" {
    const parsed = try std.json.parseFromSlice(
        Reference,
        a,
        @embedFile("fixtures/resolver-reference.json"),
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    for (parsed.value.cases) |case| {
        if (!std.mem.startsWith(u8, case.name, "reason-needed-")) continue;
        var plan = try casePlan(a, case);
        defer plan.deinit();
        try plan.check();
        if (plan.additions.len == 0) {
            try std.testing.expectEqualStrings("1-1", case.repositories[0].packages[0].version);
            try std.testing.expect(plan.flags.needed);
            try std.testing.expectEqual(@as(u64, 0), plan.sizes.installed_remove);
            continue;
        }
        const addition = plan.additions[0];
        try std.testing.expectEqual(
            if (plan.flags.all_explicit and !plan.flags.all_dependencies)
                rlpm.Package.InstallReason.explicit
            else
                .dependency,
            addition.reason,
        );
        const version = plan.package(addition.package).version.raw;
        try std.testing.expectEqualStrings(
            if (version[0] == '0')
                "downgrade"
            else if (version[0] == '1')
                "reinstall"
            else
                "upgrade",
            @tagName(addition.action),
        );
        try std.testing.expectEqualStrings("test", addition.installed_database.?);
        try std.testing.expectEqual(@as(u64, 300), plan.sizes.installed_add);
        try std.testing.expectEqual(@as(u64, 300), plan.sizes.installed_remove);
        try std.testing.expectEqual(@as(u64, 100), plan.sizes.download_upper_bound);
    }
}

test "upgrade warnings explain ignored and newer local packages" {
    var old = package("app", "1-1", .local);
    var new = package("app", "2-1", .sync);
    const snapshot: R.Snapshot = .{
        .local = &.{entry(&old, 0, 0)},
        .repositories = &.{repository(&.{entry(&new, 1, 0)})},
    };
    var ignored = try R.resolve(
        a,
        snapshot,
        .{ .ignore_packages = &.{"app"} },
        .{ .system_upgrade = true },
        .{},
    );
    defer ignored.deinit();
    try expectAdds(&ignored, &.{});
    try std.testing.expect(ignored.warnings[0] == .ignored_upgrade);
    new.version.raw = "0-1";
    var newer = try R.resolve(
        a,
        snapshot,
        .{ .ignore_packages = &.{"app"} },
        .{ .system_upgrade = true },
        .{},
    );
    defer newer.deinit();
    try expectAdds(&newer, &.{});
    try std.testing.expect(newer.warnings[0] == .local_newer);
}

fn allocationCase(alloc: std.mem.Allocator, case: Case) !void {
    var plan = try casePlan(alloc, case);
    defer plan.deinit();
    try std.testing.expectEqual(case.result.success, plan.failure == null);
}
test "resolver frees all allocations in success, failure, questions, replacement and removal paths" {
    const parsed = try std.json.parseFromSlice(
        Reference,
        a,
        @embedFile("fixtures/resolver-reference.json"),
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    for (parsed.value.cases) |case| {
        for ([_][]const u8{
            "provider-order",
            "nested-missing",
            "replace-dependency-reused",
            "frozen/remove-recursive-cycle",
            "skip-with-provider-question",
            "conflict-breaks-survivor",
        }) |name| {
            if (std.mem.eql(u8, case.name, name))
                try std.testing.checkAllAllocationFailures(
                    a,
                    allocationCase,
                    .{case},
                );
        }
    }
}

const io = std.testing.io;

const Fixture = struct {
    temp: std.testing.TmpDir,
    root: [:0]u8,
    db: [:0]u8,

    fn init() !Fixture {
        var temp = std.testing.tmpDir(.{});
        errdefer temp.cleanup();
        try temp.dir.createDirPath(io, "root");
        try temp.dir.createDirPath(io, "db/sync");
        try temp.dir.createDirPath(io, "db/local/kept-1-1");
        try temp.dir.writeFile(io, .{ .sub_path = "db/local/ALPM_DB_VERSION", .data = "9\n" });
        try temp.dir.writeFile(
            io,
            .{
                .sub_path = "db/local/kept-1-1/desc",
                .data = "%NAME%\nkept\n\n%VERSION%\n1-1\n\n%REASON%\n1\n\n%INSTALLED_DB%\nold-cachyos\n\n",
            },
        );
        var archive = try Archive.init(
            &.{
                .{
                    .path = "app-2-1/desc",
                    .contents = "%NAME%\napp\n\n%VERSION%\n2-1\n\n%DEPENDS%\nvirtual>=2\n\n%ARCH%\nx86_64_v3\n\n",
                },
                .{ .path = "z-3-1/desc", .contents = "%NAME%\nz\n\n%VERSION%\n3-1\n\n%PROVIDES%\nvirtual=2\n\n" },
                .{ .path = "a-1-1/desc", .contents = "%NAME%\na\n\n%VERSION%\n1-1\n\n%PROVIDES%\nvirtual=2\n\n" },
            },
            .zstd,
        );
        defer archive.deinit();
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, archive.path, a, .limited(1 << 20));
        defer a.free(bytes);
        try temp.dir.writeFile(io, .{ .sub_path = "db/sync/cachyos.db", .data = bytes });
        const root = try temp.dir.realPathFileAlloc(io, "root", a);
        errdefer a.free(root);
        const db = try temp.dir.realPathFileAlloc(io, "db", a);
        return .{
            .temp = temp,
            .root = root,
            .db = db,
        };
    }

    fn config(self: Fixture) rlpm.OwnerConfiguration {
        return .{
            .root = self.root,
            .database_path = self.db,
            .architectures = &.{ "x86_64_v3", "x86_64" },
        };
    }

    fn deinit(self: *Fixture) void {
        a.free(self.root);
        a.free(self.db);
        self.temp.cleanup();
    }
};

test "Owner plans survive cache invalidation and release; provider callbacks have metadata and cannot reenter" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var owner = try rlpm.Owner.init(io, a, fixture.config(), &.{.{ .database_name = "cachyos" }});
    var live = true;
    defer if (live) owner.deinit() catch unreachable;

    const State = struct {
        owner: *rlpm.Owner,
        checked: bool = false,

        fn callback(raw: ?*anyopaque, q: *rlpm.Callbacks.Question) void {
            const state: *@This() = @ptrCast(@alignCast(raw.?));
            std.testing.expectEqualStrings("a", q.select_provider.views[0].package.name) catch unreachable;
            std.testing.expectError(
                error.CallbackReentry,
                state.owner.package(
                    q.select_provider.candidates[0],
                ),
            ) catch
                unreachable;
            state.checked = true;
            q.select_provider.selected = 1;
        }
    };
    var state: State = .{ .owner = &owner };
    try owner.setCallbacks(.{ .question = State.callback, .question_context = &state });
    var plan = try owner.resolve(io, .{ .install = &.{.{ .text = "app" }} });
    defer plan.deinit();
    try std.testing.expect(state.checked);
    try expectAdds(&plan, &.{ "z", "app" });
    try std.testing.expectEqualStrings("cachyos", plan.additions[0].installed_database.?);
    const ref = plan.candidates[@intFromEnum(plan.additions[0].package)].reference;
    try owner.invalidateDatabase(owner.findDatabase("cachyos").?);
    try std.testing.expectError(
        error.StalePackageReference,
        owner.resolve(
            io,
            .{ .install = &.{.{ .reference = ref }} },
        ),
    );
    try owner.deinit();
    live = false;
    try expectAdds(&plan, &.{ "z", "app" });
    try std.testing.expectEqualStrings(
        "2",
        plan.questions[0].select_provider.dependency.constraint.greater_equal,
    );
    try std.testing.expectEqualStrings("old-cachyos", plan.candidates[0].package.installed_database.?);
}

test "Owner resolver rejects invalid answers, cancellation and foreign references, then retries" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var owner = try rlpm.Owner.init(io, a, fixture.config(), &.{.{ .database_name = "cachyos" }});
    defer owner.deinit() catch unreachable;

    const State = struct {
        owner: *rlpm.Owner,
        mode: enum { index, tag, cancel } = .index,

        fn callback(raw: ?*anyopaque, q: *rlpm.Callbacks.Question) void {
            const state: *@This() = @ptrCast(@alignCast(raw.?));
            switch (state.mode) {
                .index => q.select_provider.selected = 100,
                .tag => q.* = .{ .import_key = .{ .key = .{ .fingerprint = "wrong" } } },
                .cancel => state.owner.requestCancellation(),
            }
        }
    };
    var state: State = .{ .owner = &owner };
    try owner.setCallbacks(.{ .question = State.callback, .question_context = &state });
    for ([_]State{
        .{ .owner = &owner },
        .{ .owner = &owner, .mode = .tag },
        .{ .owner = &owner, .mode = .cancel },
    }) |value| {
        state = value;
        try std.testing.expectError(
            if (state.mode == .cancel) error.Cancelled else error.InvalidAnswer,
            owner.resolve(
                io,
                .{ .install = &.{.{ .text = "app" }} },
            ),
        );
        try std.testing.expectEqual(.resolve, owner.diagnostic().?.operation);
    }
    try owner.resetCancellation();
    try owner.setCallbacks(.{});
    var plan = try owner.resolve(io, .{ .install = &.{.{ .text = "app" }} });
    defer plan.deinit();
    try expectAdds(&plan, &.{ "a", "app" });
    var ref = plan.candidates[@intFromEnum(plan.additions[0].package)].reference;
    ref.database.owner = @enumFromInt(0);
    try owner.invalidateDatabase(owner.findDatabase("cachyos").?);
    try fixture.temp.dir.writeFile(
        io,
        .{
            .sub_path = "db/sync/cachyos.db",
            .data = "invalid unrelated database",
        },
    );
    try std.testing.expectError(
        error.ForeignOwner,
        owner.resolve(
            io,
            .{ .install = &.{.{ .reference = ref }} },
        ),
    );
    owner.requestCancellation();
    try std.testing.expectError(error.Cancelled, owner.resolve(io, .{}));
}

test "Owner resolution requires complete local metadata and handles missing repositories by operation" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var owner = try rlpm.Owner.init(
        io,
        a,
        fixture.config(),
        &.{
            .{ .database_name = "cachyos" },
            .{ .database_name = "absent" },
        },
    );
    defer owner.deinit() catch unreachable;
    var removal = try owner.resolve(io, .{ .remove = &.{"kept"} });
    defer removal.deinit();
    try removal.check();
    try std.testing.expectEqual(@as(usize, 1), removal.removals.len);
    try std.testing.expectError(
        error.DatabaseNotFound,
        owner.resolve(
            io,
            .{ .install = &.{.{ .text = "app" }} },
        ),
    );
    var file = package("file", "1-1", .archive);
    var archive_plan = try owner.resolve(io, .{ .install = &.{.{ .archive = &file }} });
    defer archive_plan.deinit();
    try expectAdds(&archive_plan, &.{"file"});
    try owner.invalidateDatabase(owner.localDatabase().?);
    try fixture.temp.dir.deleteFile(io, "db/local/kept-1-1/desc");
    try std.testing.expectError(error.FileNotFound, owner.resolve(io, .{ .remove = &.{"kept"} }));
}

test "Owner resolution queries and assumed provisions preserve native matching rules" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var config = fixture.config();
    config.ignore_packages = &.{"app"};
    var owner = try rlpm.Owner.init(
        io,
        a,
        config,
        &.{
            .{
                .database_name = "cachyos",
                .usage = .{ .install = false, .upgrade = false },
            },
        },
    );
    defer owner.deinit() catch unreachable;
    const parsed = try std.json.parseFromSlice(
        Reference,
        a,
        @embedFile("fixtures/resolver-reference.json"),
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    for (parsed.value.assumed_options) |input| {
        var updated = owner.options();
        updated.assume_installed = &.{try rlpm.PackageRelation.parse(input.relation)};
        if (input.success)
            try owner.setOptions(io, updated)
        else
            try std.testing.expectError(
                error.InvalidOption,
                owner.setOptions(io, updated),
            );
    }
    var cleared = owner.options();
    cleared.assume_installed = &.{};
    try owner.setOptions(io, cleared);
    var old = package("app", "1-1", .archive);
    const newer = (try owner.newVersion(io, &old)).?;
    try std.testing.expectEqualStrings("2-1", (try owner.package(newer)).version.raw);
    try std.testing.expect(try owner.shouldIgnore(io, newer));
    old.version.raw = "3-1";
    try std.testing.expect(try owner.newVersion(io, &old) == null);
    const dep = try rlpm.PackageRelation.parse("virtual=02: first");
    try owner.addAssumedInstalled(io, dep);
    try owner.addAssumedInstalled(io, dep);
    try std.testing.expectError(
        error.InvalidOption,
        owner.addAssumedInstalled(
            io,
            try rlpm.PackageRelation.parse("virtual>=2"),
        ),
    );
    try std.testing.expectEqual(@as(usize, 2), owner.options().assume_installed.len);
    try std.testing.expect(
        !try owner.removeAssumedInstalled(io, try rlpm.PackageRelation.parse("virtual=2")),
    );
    try std.testing.expect(
        try owner.removeAssumedInstalled(
            io,
            try rlpm.PackageRelation.parse(
                "virtual>=02: different",
            ),
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), owner.options().assume_installed.len);
    var provider = package("provider", "1-1", .sync);
    provider.provides = &.{try rlpm.PackageRelation.parse("app=9")};
    const entries = [_]R.Entry{ entry(&provider, 1, 0), entry(&old, 1, 1) };
    try std.testing.expectEqual(
        entries[0].reference,
        R.findSatisfier(
            &entries,
            try rlpm.PackageRelation.parse("app>=2"),
        ).?,
    );
}

fn sealedAllocation(alloc: std.mem.Allocator, file: *const rlpm.Package) !void {
    var plan = try R.resolve(
        alloc,
        .{},
        .{},
        .{ .install = &.{ .{ .archive = file }, .{ .archive = file } } },
        .{},
    );
    defer plan.deinit();
    try plan.check();
    try std.testing.expectEqual(@as(usize, 1), plan.additions.len);
}
test "plans retain verified archive bytes after package release with independent archive identities" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var owner = try rlpm.Owner.init(io, a, fixture.config(), &.{});
    defer owner.deinit() catch unreachable;
    var archive = try Archive.init(&.{
        .{ .path = ".PKGINFO", .contents = "pkgname = file\npkgver = 1-1\narch = any\n" },
        .{ .path = ".CHANGELOG", .contents = "sealed contents" },
        .{ .path = "payload", .contents = "body" },
    }, .zstd);
    defer archive.deinit();
    var file = try owner.loadPackage(io, archive.path, .local_file, .{});
    var file_live = true;
    defer if (file_live) file.deinit();
    try std.testing.checkAllAllocationFailures(a, sealedAllocation, .{&file});
    var plan = try owner.resolve(io, .{ .install = &.{.{ .archive = &file }} });
    defer plan.deinit();
    var other = try owner.resolve(io, .{ .install = &.{.{ .archive = &file }} });
    defer other.deinit();
    const ref = plan.candidates[@intFromEnum(plan.additions[0].package)].reference;
    try std.testing.expect(other.findReference(ref) == null);
    try std.testing.expectError(error.StaleDatabaseReference, owner.package(ref));
    file.deinit();
    file_live = false;
    try archive.temporary.dir.writeFile(io, .{ .sub_path = "package.tar", .data = "changed file" });
    var reader = (try plan.package(plan.additions[0].package).openMember(a, .changelog)).?;
    defer reader.deinit();
    const bytes = try reader.readAll(a, 100);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("sealed contents", bytes);
}

test "large dependency chains use iterative closure and ordering" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const count = 1024;
    const packages = try alloc.alloc(rlpm.Package, count);
    const entries = try alloc.alloc(R.Entry, count);
    for (packages, entries, 0..) |*pkg, *out, i| {
        pkg.* = package(try std.fmt.allocPrint(alloc, "pkg{d}", .{i}), "1-1", .sync);
        if (i + 1 < count)
            pkg.depends = try relations(
                alloc,
                &.{
                    try std.fmt.allocPrint(alloc, "pkg{d}", .{i + 1}),
                },
            );
        out.* = entry(pkg, 1, @intCast(i));
    }
    var plan = try R.resolve(
        a,
        .{ .repositories = &.{repository(entries)} },
        .{},
        .{ .install = &.{.{ .text = "pkg0" }} },
        .{},
    );
    defer plan.deinit();
    try plan.check();
    try std.testing.expectEqual(@as(usize, count), plan.additions.len);
    try std.testing.expectEqualStrings("pkg1023", plan.package(plan.additions[0].package).name);
    try std.testing.expectEqualStrings("pkg0", plan.package(plan.additions[count - 1].package).name);
}
