const std = @import("std");
const Zigalpm = @import("Zigalpm");
const test_support = @import("test_support.zig");
const output = @import("../output/config.zig");
const colors = @import("../output/colors.zig");
const detail_output = @import("../output/detail.zig");
const format = @import("../output/format.zig");
const table = @import("../output/table.zig");
const parser = @import("../cli/parser.zig");
const runtime = @import("../runtime/context.zig");
const spec = @import("../cli/spec.zig");
const aur_url = @import("../config/aur_url.zig");

const joined = format.joined;
const nonNegative = format.nonNegative;
const loadSizeDisplay = format.loadSizeDisplay;
const formatSize = format.formatSize;
const formatDateTime = format.formatDateTime;
const formatLongDate = format.formatLongDate;
const formatIsoDateTime = format.formatIsoDateTime;
const truncate = format.truncate;

const standard_command_path = "shelly search standard";
const aur_command_path = "shelly search aur";
const flatpak_command_path = "shelly search flatpak";

pub const StandardPackage = struct {
    name: []const u8,
    package_base: []const u8 = "",
    version: []const u8,
    size: i64 = 0,
    description: []const u8 = "",
    url: []const u8 = "",
    repository: []const u8 = "",
    replaces: []const []const u8 = &.{},
    licenses: []const []const u8 = &.{},
    groups: []const []const u8 = &.{},
    provides: []const []const u8 = &.{},
    depends: []const []const u8 = &.{},
    optional_depends: []const []const u8 = &.{},
    optional_depends_installed: []const bool = &.{},
    conflicts: []const []const u8 = &.{},
    install_reason: []const u8 = "Unknown",
    install_date: ?i64 = null,
    build_date: i64 = 0,
    download_size: i64 = 0,
    installed_size: i64 = 0,
    required_by: []const []const u8 = &.{},
    optional_for: []const []const u8 = &.{},
};

const LocalPackage = struct {
    name: []const u8,
    size: u64,
};

pub const AurPackage = struct {
    id: i64 = 0,
    name: []const u8,
    package_base_id: i64 = 0,
    package_base: []const u8 = "",
    version: []const u8,
    description: ?[]const u8 = null,
    url: ?[]const u8 = null,
    num_votes: i64 = 0,
    popularity: f64 = 0,
    out_of_date: ?i64 = null,
    maintainer: ?[]const u8 = null,
    first_submitted: i64 = 0,
    last_modified: i64 = 0,
    url_path: ?[]const u8 = null,
    depends: ?[]const []const u8 = null,
    make_depends: ?[]const []const u8 = null,
    optional_depends: ?[]const []const u8 = null,
    check_depends: ?[]const []const u8 = null,
    conflicts: ?[]const []const u8 = null,
    provides: ?[]const []const u8 = null,
    replaces: ?[]const []const u8 = null,
    groups: ?[]const []const u8 = null,
    licenses: ?[]const []const u8 = null,
    keywords: ?[]const []const u8 = null,
    required_by: ?[]const []const u8 = null,
    optional_for: ?[]const []const u8 = null,
    explicit: bool = false,
};

const FlatpakPackage = struct {
    name: []const u8,
    id: []const u8,
    summary: []const u8,
    remote: []const u8,
    description: []const u8 = "",
    package_type: []const u8 = "desktop-application",
    project_license: []const u8 = "",
    developer_name: []const u8 = "",
    categories: []const []const u8 = &.{},
    keywords: []const []const u8 = &.{},
    verified: bool = false,
    verification_method: ?[]const u8 = null,
    download_size: u64 = 0,
    installed_size: u64 = 0,
    permissions: []const []const u8 = &.{},
    scope: Zigalpm.flatpak.Scope = .unknown,
};

const StandardMode = enum { packages, repositories, groups, detail };

const StandardResult = struct {
    mode: StandardMode = .packages,
    packages: []const StandardPackage = &.{},
    local_packages: []const LocalPackage = &.{},
    repositories: []const []const u8 = &.{},
    groups: []const []const u8 = &.{},
    detail: ?StandardPackage = null,
    requested_packages: bool = false,
    requested_local: bool = false,
};

const PackageBuild = struct {
    name: []const u8,
    pkgbuild: ?[]const u8,
};

const AurResult = struct {
    packages: []const AurPackage = &.{},
    standard_packages: []const StandardPackage = &.{},
    pkgbuilds: ?[]const PackageBuild = null,
    detail: ?AurPackage = null,
};

const FlatpakResult = struct {
    query: []const u8,
    packages: []const FlatpakPackage,
    page: usize,
    limit: usize,
    total_pages: usize,
    total_hits: usize,
};

const Result = union(enum) {
    standard: StandardResult,
    aur: AurResult,
    flatpak: FlatpakResult,
};

const Real = struct {
    fn search(
        _: Real,
        context: *runtime.RuntimeContext,
        invocation: *const parser.Invocation,
    ) !Result {
        return runRealSearch(context, invocation);
    }
};

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    if (!isSearchPath(invocation.command.path)) return null;
    return try executeWithRunner(context, invocation, Real{});
}

fn executeWithRunner(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: anytype,
) anyerror!u8 {
    if (std.mem.eql(u8, invocation.command.path, aur_command_path)) {
        if (optionEnabled(invocation, "--detail")) {
            if (optionEnabled(invocation, "--pkgbuild"))
                return writeFailure(context, invocation, "Cannot combine --detail with --pkgbuild.");
            if (optionEnabled(invocation, "--standard"))
                return writeFailure(context, invocation, "Cannot combine --detail with --standard.");
        }
        if (optionEnabled(invocation, "--pkgbuild")) {
            if (optionEnabled(invocation, "--standard"))
                return writeFailure(context, invocation, "Cannot combine --pkgbuild with --standard.");
            for (invocation.positionals) |package| {
                if (std.mem.trim(u8, package, " \t\r\n").len == 0)
                    return writeFailure(context, invocation, "Package name cannot be empty.");
            }
        } else {
            const query = try joinedQuery(context.allocator, invocation.positionals);
            if (std.mem.trim(u8, query, " \t\r\n").len < 2) {
                const message = if (std.mem.trim(u8, query, " \t\r\n").len == 0)
                    "Query cannot be empty."
                else
                    "Error: Query must be at least 2 characters long";
                return writeFailure(context, invocation, message);
            }
        }
    }
    if (std.mem.eql(u8, invocation.command.path, flatpak_command_path) and
        std.mem.trim(u8, invocation.positionals[0], " \t\r\n").len == 0)
    {
        return writeFailure(context, invocation, "Query cannot be empty.");
    }
    if ((std.mem.eql(u8, invocation.command.path, standard_command_path) or
        std.mem.eql(u8, invocation.command.path, flatpak_command_path)) and
        (optionInteger(invocation, "--limit", defaultLimit(invocation)) <= 0 or
            optionInteger(invocation, "--page", 1) <= 0))
    {
        return writeFailure(context, invocation, "Page and limit must be greater than zero.");
    }

    const result = runner.search(context, invocation) catch |err| {
        const failure: anyerror = err;
        if (Zigalpm.flatpak.errors.unavailableMessage(failure)) |message|
            return writeFailure(context, invocation, message);
        const message = switch (failure) {
            error.NoPackageSpecified => "No package specified",
            error.PackageNotFound => try Zigalpm.user_errors.missingPackage(context.allocator, if (invocation.positionals.len > 0) invocation.positionals[0] else "the requested package"),
            else => try Zigalpm.user_errors.format(context.allocator, failure, .{ .operation = "the package search" }),
        };
        return writeFailure(context, invocation, message);
    };
    switch (result) {
        .standard => |value| try renderStandard(context, invocation, value),
        .aur => |value| try renderAur(context, invocation, value),
        .flatpak => |value| try renderFlatpak(context, invocation, value),
    }
    return 0;
}

fn writeFailure(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    message: []const u8,
) !u8 {
    if (invocation.globals.ui_mode)
        try output.writeErrorFrame(context, message)
    else
        try output.writeFailure(context, message);
    return 1;
}

fn runRealSearch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !Result {
    if (std.mem.eql(u8, invocation.command.path, standard_command_path))
        return .{ .standard = try runStandard(context, invocation) };
    if (std.mem.eql(u8, invocation.command.path, aur_command_path))
        return .{ .aur = try runAur(context, invocation) };
    if (std.mem.eql(u8, invocation.command.path, flatpak_command_path))
        return .{ .flatpak = try runFlatpak(context, invocation) };
    return error.UnsupportedSearchType;
}

fn runStandard(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !StandardResult {
    const repositories = optionEnabled(invocation, "--repos");
    var available = optionEnabled(invocation, "--available");
    var installed = optionEnabled(invocation, "--installed");
    const local = optionEnabled(invocation, "--local");
    var detail = optionEnabled(invocation, "--detail");
    const group = optionEnabled(invocation, "--group");
    const show_hidden = optionEnabled(invocation, "--show-hidden");
    const query: ?[]const u8 = if (invocation.positionals.len == 0) null else invocation.positionals[0];
    const depends = optionEnabled(invocation, "--depends");
    const explicit = optionEnabled(invocation, "--explicit");

    if (!repositories and !available and !installed and !local and !detail) {
        installed = true;
        available = true;
        detail = query != null and std.mem.trim(u8, query.?, " \t\r\n").len != 0;
    }
    if (detail) available = true;
    if (group) available = true;

    const manager = try Zigalpm.AlpmManager.init(
        context.allocator,
        context.environ,
        .{ .use_root = false },
    );
    defer manager.deinit();
    if (show_hidden and !manager.show_hidden_packages) _ = manager.toggle_hidden_packages();

    if (repositories) {
        var names: std.ArrayList([]const u8) = .empty;
        for (manager.config.repositories.items) |repository|
            try names.append(context.allocator, try context.allocator.dupe(u8, repository.name));
        return .{ .mode = .repositories, .repositories = try names.toOwnedSlice(context.allocator) };
    }

    var packages: std.ArrayList(StandardPackage) = .empty;
    if (installed) {
        const values = try manager.get_installed_packages();
        defer Zigalpm.alpm.OwnedPackage.deinitSlice(context.allocator, values);
        for (values) |value| {
            const name = value.name() orelse continue;
            if (!show_hidden and ignoredPackage(manager, name)) continue;
            if (depends and value.reason_value == .Dependency) {
                try packages.append(context.allocator, try copyStandardPackage(context.allocator, value));
                continue;
            }
            if (explicit and value.reason_value == .Explicit) {
                try packages.append(context.allocator, try copyStandardPackage(context.allocator, value));
                continue;
            }
            if (!explicit and !depends) try packages.append(context.allocator, try copyStandardPackage(context.allocator, value));
        }
    }
    if (available) {
        const values = try manager.get_available_packages();
        defer Zigalpm.alpm.OwnedPackage.deinitSlice(context.allocator, values);
        var seen = std.StringHashMap(void).init(context.allocator);
        defer seen.deinit();
        for (values) |value| {
            const name = value.name() orelse continue;
            if (seen.contains(name)) continue;
            try seen.put(name, {});
            if (!show_hidden and ignoredPackage(manager, name)) continue;
            try packages.append(context.allocator, try copyStandardPackage(context.allocator, value));
        }
    }

    if (detail and !group) {
        const wanted = query orelse return error.NoPackageSpecified;
        for (packages.items) |package| {
            var pkg = package;
            if (std.ascii.eqlIgnoreCase(package.name, wanted)) {
                pkg.required_by = try manager.get_required_packages(package.name, package.repository);
                pkg.optional_depends_installed = try optionalDependencyInstalledStates(
                    context.allocator,
                    manager,
                    package.optional_depends,
                );
                return .{ .mode = .detail, .detail = pkg };
            }
        }
        return error.PackageNotFound;
    }

    if (group and query == null) {
        var groups: std.ArrayList([]const u8) = .empty;
        var seen = std.StringHashMap(void).init(context.allocator);
        defer seen.deinit();
        for (packages.items) |package| for (package.groups) |name| {
            if (seen.contains(name)) continue;
            try seen.put(name, {});
            try groups.append(context.allocator, name);
        };
        return .{ .mode = .groups, .groups = try groups.toOwnedSlice(context.allocator) };
    }

    var selected: std.ArrayList(StandardPackage) = .empty;
    if (query) |wanted| {
        if (group) {
            for (packages.items) |package| {
                if (containsExact(package.groups, wanted)) try selected.append(context.allocator, package);
            }
        } else {
            var scored: std.ArrayList(ScoredStandard) = .empty;
            defer scored.deinit(context.allocator);
            for (packages.items) |package| {
                const rank = packageScore(package.name, package.description, wanted);
                if (rank > 0) try scored.append(context.allocator, .{ .package = package, .score = rank });
            }
            std.mem.sort(ScoredStandard, scored.items, {}, scoredStandardLessThan);
            for (scored.items) |item| try selected.append(context.allocator, item.package);
        }
    } else {
        try selected.appendSlice(context.allocator, packages.items);
    }

    var local_packages: std.ArrayList(LocalPackage) = .empty;
    if (local) {
        var local_manager = Zigalpm.LocalManager.init(context.allocator, context.io, .{});
        defer local_manager.deinit();
        const values = try local_manager.getInstalledBinaryPackages();
        defer Zigalpm.local.Package.deinitSlice(context.allocator, values);
        if (query) |wanted| {
            var scored: std.ArrayList(ScoredLocal) = .empty;
            defer scored.deinit(context.allocator);
            for (values) |value| {
                const rank = packageScore(value.path, null, wanted);
                if (rank > 0) try scored.append(context.allocator, .{
                    .package = .{ .name = try context.allocator.dupe(u8, value.path), .size = value.size },
                    .score = rank,
                });
            }
            std.mem.sort(ScoredLocal, scored.items, {}, scoredLocalLessThan);
            for (scored.items) |item| try local_packages.append(context.allocator, item.package);
        } else {
            for (values) |value| try local_packages.append(context.allocator, .{
                .name = try context.allocator.dupe(u8, value.path),
                .size = value.size,
            });
        }
    }

    if (invocation.globals.ui_mode) {
        return .{
            .mode = .packages,
            .packages = selected.items,
            .local_packages = local_packages.items,
            .requested_packages = available or installed,
            .requested_local = local,
        };
    }

    const limit: usize = @intCast(optionInteger(invocation, "--limit", 100));
    const page: usize = @intCast(optionInteger(invocation, "--page", 1));

    return .{
        .mode = .packages,
        .packages = try pageSlice(StandardPackage, context.allocator, selected.items, page, limit),
        .local_packages = try pageSlice(LocalPackage, context.allocator, local_packages.items, page, limit),
        .requested_packages = available or installed,
        .requested_local = local,
    };
}

const ScoredStandard = struct { package: StandardPackage, score: u16 };
const ScoredLocal = struct { package: LocalPackage, score: u16 };

fn scoredStandardLessThan(_: void, left: ScoredStandard, right: ScoredStandard) bool {
    if (left.score != right.score) return left.score > right.score;
    return orderIgnoreCase(left.package.name, right.package.name) == .lt;
}

fn scoredLocalLessThan(_: void, left: ScoredLocal, right: ScoredLocal) bool {
    if (left.score != right.score) return left.score > right.score;
    return orderIgnoreCase(left.package.name, right.package.name) == .lt;
}

fn runAur(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !AurResult {
    const aur_base = try aur_url.resolveFor(context, invocation);
    var manager = try Zigalpm.AurManager.init(context.allocator, context.environ, .{
        .aur_git_base_url = aur_base,
    });
    defer manager.deinit();

    if (optionEnabled(invocation, "--pkgbuild")) {
        const builds = try context.allocator.alloc(PackageBuild, invocation.positionals.len);
        var initialized: usize = 0;
        errdefer {
            for (builds[0..initialized]) |build| {
                context.allocator.free(build.name);
                if (build.pkgbuild) |pkgbuild| context.allocator.free(pkgbuild);
            }
            context.allocator.free(builds);
        }
        for (invocation.positionals, builds) |package, *build| {
            const name = try context.allocator.dupe(u8, package);
            const pkgbuild = manager.fetchPkgbuild(package) catch |err| {
                context.allocator.free(name);
                return err;
            };
            build.* = .{ .name = name, .pkgbuild = pkgbuild };
            initialized += 1;
        }
        return .{ .pkgbuilds = builds };
    }

    const detail = optionEnabled(invocation, "--detail");
    const query = try joinedQuery(context.allocator, invocation.positionals);

    var standard_packages: std.ArrayList(StandardPackage) = .empty;
    if (optionEnabled(invocation, "--standard") and !detail) {
        const values = try manager.alpm.get_available_packages();
        defer Zigalpm.alpm.OwnedPackage.deinitSlice(context.allocator, values);
        for (values) |value| {
            const name = value.name() orelse continue;
            if (try partialRatio(context.allocator, query, name) < 90) continue;
            try standard_packages.append(context.allocator, try copyStandardPackage(context.allocator, value));
        }
        std.mem.reverse(StandardPackage, standard_packages.items);
    }

    const values = try manager.searchPackages(query);
    defer Zigalpm.aur.models.Package.deinitSlice(context.allocator, values);
    const packages = try context.allocator.alloc(AurPackage, values.len);
    for (values, packages) |value, *destination|
        destination.* = try copyAurPackage(context.allocator, value);

    if (detail) {
        for (packages) |package| {
            if (std.ascii.eqlIgnoreCase(package.name, query))
                return .{ .detail = package };
        }
        return error.PackageNotFound;
    }

    return .{
        .packages = packages,
        .standard_packages = try standard_packages.toOwnedSlice(context.allocator),
    };
}

fn runFlatpak(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !FlatpakResult {
    const query = invocation.positionals[0];
    const limit: usize = @intCast(optionInteger(invocation, "--limit", 21));
    const page: usize = @intCast(optionInteger(invocation, "--page", 1));
    var manager = Zigalpm.flatpak.AppstreamManager.init(context.allocator, context.io);
    const catalogs = try manager.getAllRemoteCatalogs(null);
    defer Zigalpm.flatpak.AppstreamCatalog.deinitSlice(context.allocator, catalogs);

    var matches: std.ArrayList(FlatpakPackage) = .empty;
    for (catalogs) |catalog| {
        for (catalog.apps) |application| {
            if (!containsIgnoreCase(application.name, query) and !containsIgnoreCase(application.id, query)) continue;
            try matches.append(context.allocator, .{
                .name = try context.allocator.dupe(u8, application.name),
                .id = try context.allocator.dupe(u8, application.id),
                .summary = try context.allocator.dupe(u8, application.summary),
                .remote = try context.allocator.dupe(u8, catalog.remote_name),
                .description = try context.allocator.dupe(u8, application.description),
                .package_type = try context.allocator.dupe(u8, application.type),
                .project_license = try context.allocator.dupe(u8, application.project_license),
                .developer_name = try context.allocator.dupe(u8, application.developer_name),
                .categories = try copyStrings(context.allocator, application.categories),
                .keywords = try copyStrings(context.allocator, application.keywords),
                .verified = application.is_verified,
                .verification_method = if (application.verification_method) |value|
                    try context.allocator.dupe(u8, value)
                else
                    null,
                .scope = catalog.scope,
            });
        }
    }
    const total_hits = matches.items.len;
    const packages = try pageSlice(FlatpakPackage, context.allocator, matches.items, page, limit);
    try enrichFlatpakRemoteInfo(context, packages);
    return .{
        .query = try context.allocator.dupe(u8, query),
        .packages = packages,
        .page = page,
        .limit = limit,
        .total_pages = if (total_hits == 0) 0 else (total_hits + limit - 1) / limit,
        .total_hits = total_hits,
    };
}

fn enrichFlatpakRemoteInfo(
    context: *runtime.RuntimeContext,
    packages: []FlatpakPackage,
) !void {
    var manager = Zigalpm.FlatpakManager{ .allocator = context.allocator, .io = context.io };
    defer manager.deinit();
    for (packages) |*package| {
        if (package.scope == .unknown or package.remote.len == 0 or package.id.len == 0) continue;
        const remote = try context.allocator.dupeZ(u8, package.remote);
        defer context.allocator.free(remote);
        const id = try context.allocator.dupeZ(u8, package.id);
        defer context.allocator.free(id);
        var info = manager.get_remote_ref_info_flatpak(
            remote,
            id,
            // Empty branch: let the backend resolve the branch.
            "",
            package.scope,
        ) catch continue;
        defer info.deinit(context.allocator);
        package.download_size = info.download_size;
        package.installed_size = info.installed_size;
        package.permissions = try copySentinelStrings(context.allocator, info.permissions);
    }
}

fn renderStandard(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    result: StandardResult,
) !void {
    if (invocation.globals.ui_mode) {
        if (result.mode == .packages) {
            if (result.packages.len > 0) {
                var package_payload = std.Io.Writer.Allocating.init(context.allocator);
                defer package_payload.deinit();
                try writeStandardPackagesJson(&package_payload.writer, result.packages);
                try output.writeFrame(context, package_payload.writer.buffered());
            }
            if (result.local_packages.len > 0) {
                var local_payload = std.Io.Writer.Allocating.init(context.allocator);
                defer local_payload.deinit();
                try writeLocalPackagesJson(&local_payload.writer, result.local_packages);
                try output.writeFrame(context, local_payload.writer.buffered());
            }
            const count = result.packages.len + result.local_packages.len;
            const message = try std.fmt.allocPrint(context.allocator, "Showing {d} search results", .{count});
            try output.writeInfoFrame(context, message);
            return;
        }
        var payload = std.Io.Writer.Allocating.init(context.allocator);
        defer payload.deinit();
        try writeStandardResultJson(&payload.writer, result);
        try output.writeFrame(context, payload.writer.buffered());
        return;
    }
    if (invocation.globals.json) {
        if (result.mode == .packages) {
            if (result.packages.len > 0) {
                try writeStandardPackagesJson(context.stdout, result.packages);
                try context.stdout.writeByte('\n');
            }
            if (result.local_packages.len > 0) {
                try writeLocalPackagesJson(context.stdout, result.local_packages);
                try context.stdout.writeByte('\n');
            }
            return;
        }
        try writeStandardResultJson(context.stdout, result);
        try context.stdout.writeByte('\n');
        return;
    }

    switch (result.mode) {
        .repositories => for (result.repositories) |repository| try context.stdout.print("{s}\n", .{repository}),
        .groups => {
            var rows: std.ArrayList([]const []const u8) = .empty;
            for (result.groups) |group_name| try rows.append(context.allocator, try row(context.allocator, &.{group_name}));
            try table.write(context, &.{"Group"}, rows.items);
            try context.stdout.writeByte('\n');
        },
        .detail => try writePackageDetail(context, result.detail.?),
        .packages => {
            const size_display = try loadSizeDisplay(context);
            if (result.local_packages.len > 0) {
                var rows: std.ArrayList([]const []const u8) = .empty;
                for (result.local_packages) |package| try rows.append(context.allocator, try row(context.allocator, &.{
                    package.name,
                    try formatSize(context.allocator, size_display, package.size),
                }));
                try table.write(context, &.{ "Name", "Size" }, rows.items);
                try context.stdout.writeByte('\n');
            }
            if (result.packages.len > 0) {
                var rows: std.ArrayList([]const []const u8) = .empty;
                for (result.packages) |package| try rows.append(context.allocator, try row(context.allocator, &.{
                    package.name,
                    package.repository,
                    package.version,
                    try formatSize(context.allocator, size_display, nonNegative(package.installed_size)),
                    truncate(package.description, 50),
                }));
                try table.write(
                    context,
                    &.{ "Name", "Repository", "Version", "Size", "Description" },
                    rows.items,
                );
                try context.stdout.writeByte('\n');
            }
            if (result.requested_local)
                try context.stdout.print("Total: {d} local packages\n", .{result.local_packages.len});
            if (result.requested_packages)
                try context.stdout.print("Total: {d} packages\n", .{result.packages.len});
            try context.stdout.writeByte('\n');
        },
    }
}

fn renderAur(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    result: AurResult,
) !void {
    if (result.pkgbuilds) |builds| return renderPkgbuilds(context, invocation, builds);
    if (result.detail) |package| {
        if (invocation.globals.ui_mode) {
            var payload = std.Io.Writer.Allocating.init(context.allocator);
            defer payload.deinit();
            const single = [_]AurPackage{package};
            try writeAurPackagesJson(&payload.writer, &single);
            try output.writeFrame(context, payload.writer.buffered());
            return;
        }
        if (invocation.globals.json) {
            const single = [_]AurPackage{package};
            try writeAurPackagesJson(context.stdout, &single);
            try context.stdout.writeByte('\n');
            return;
        }
        try writeAurPackageDetail(context, package);
        return;
    }
    if (invocation.globals.ui_mode) {
        var payload = std.Io.Writer.Allocating.init(context.allocator);
        defer payload.deinit();
        try writeAurPackagesJson(&payload.writer, result.packages);
        try output.writeFrame(context, payload.writer.buffered());
        return;
    }
    if (invocation.globals.json) {
        try writeAurPackagesJson(context.stdout, result.packages);
        try context.stdout.writeByte('\n');
        if (result.standard_packages.len > 0) {
            try writeStandardPackagesJson(context.stdout, result.standard_packages);
            try context.stdout.writeByte('\n');
        }
        return;
    }

    var rows: std.ArrayList([]const []const u8) = .empty;
    const display_count = @min(@as(usize, 25), result.packages.len + result.standard_packages.len);
    var index: usize = 0;
    while (index < result.packages.len and rows.items.len < display_count) : (index += 1) {
        const package = result.packages[index];
        try rows.append(context.allocator, try row(context.allocator, &.{
            package.name,
            package.version,
            package.maintainer orelse "Unknown Maintainer",
            try formatDateTime(context.allocator, package.last_modified),
            truncate(package.description orelse "", 60),
        }));
    }
    index = 0;
    while (index < result.standard_packages.len and rows.items.len < display_count) : (index += 1) {
        const package = result.standard_packages[index];
        try rows.append(context.allocator, try row(context.allocator, &.{
            package.name,
            package.version,
            package.repository,
            try formatDateTime(context.allocator, package.build_date),
            truncate(package.description, 60),
        }));
    }
    try table.write(
        context,
        &.{ "Name", "Version", "Maintainer/Repository", "Last Updated/Build Date", "Description" },
        rows.items,
    );
    try context.stdout.writeByte('\n');
    try context.stdout.print("Total results: {d}\n", .{result.packages.len + result.standard_packages.len});
}

fn renderPkgbuilds(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    builds: []const PackageBuild,
) !void {
    if (invocation.globals.ui_mode or invocation.globals.json) {
        var payload = std.Io.Writer.Allocating.init(context.allocator);
        defer payload.deinit();
        try writePkgbuildsJson(&payload.writer, builds);
        if (invocation.globals.ui_mode)
            try output.writeFrame(context, payload.writer.buffered())
        else {
            try context.stdout.writeAll(payload.writer.buffered());
            try context.stdout.writeByte('\n');
        }
        return;
    }

    for (builds) |build| {
        const pkgbuild = build.pkgbuild orelse {
            try colors.printLine(context, .err, "Failed to get PKGBUILD for: {s}", .{build.name});
            continue;
        };
        try colors.printLine(context, .warning, "Package build for: {s}", .{build.name});
        try context.stdout.writeAll(pkgbuild);
        if (!std.mem.endsWith(u8, pkgbuild, "\n")) try context.stdout.writeByte('\n');
    }
}

fn renderFlatpak(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    result: FlatpakResult,
) !void {
    if (invocation.globals.ui_mode or invocation.globals.json) {
        var payload = std.Io.Writer.Allocating.init(context.allocator);
        defer payload.deinit();
        try writeFlatpakResponseJson(&payload.writer, result);
        if (invocation.globals.ui_mode) {
            try output.writeFrame(context, payload.writer.buffered());
            const message = try std.fmt.allocPrint(
                context.allocator,
                "Shown: {d} / Total Pages: {d} / Current Page: {d} / Total hits: {d}",
                .{ result.packages.len, result.total_pages, result.page, result.total_hits },
            );
            try output.writeInfoFrame(context, message);
        } else {
            try context.stdout.writeAll(payload.writer.buffered());
            try context.stdout.writeByte('\n');
        }
        return;
    }

    var rows: std.ArrayList([]const []const u8) = .empty;
    const size_display = try loadSizeDisplay(context);
    for (result.packages) |package| try rows.append(context.allocator, try row(context.allocator, &.{
        package.name,
        package.id,
        truncate(package.summary, 70),
        package.remote,
        try formatSize(context.allocator, size_display, package.download_size),
        try formatSize(context.allocator, size_display, package.installed_size),
        try joined(context.allocator, package.permissions),
    }));
    try table.write(
        context,
        &.{ "Name", "AppId", "Summary", "Remote", "Download Size", "Installed Size", "Permissions" },
        rows.items,
    );
    try context.stdout.writeByte('\n');
}

fn writePackageDetail(context: *runtime.RuntimeContext, package: StandardPackage) !void {
    return detail_output.writePackageDetail(context, package);
}

fn writeAurPackageDetail(context: *runtime.RuntimeContext, package: AurPackage) !void {
    return detail_output.writeAurPackageDetail(context, package);
}

fn writeStandardResultJson(writer: *std.Io.Writer, result: StandardResult) !void {
    switch (result.mode) {
        .repositories => {
            var json: std.json.Stringify = .{ .writer = writer };
            try json.write(result.repositories);
        },
        .groups => {
            var json: std.json.Stringify = .{ .writer = writer };
            try json.write(result.groups);
        },
        .detail => try writeStandardPackageJson(writer, result.detail.?),
        .packages => {
            if (result.local_packages.len > 0 and result.packages.len == 0) {
                try writeLocalPackagesJson(writer, result.local_packages);
            } else if (result.packages.len > 0 and result.local_packages.len == 0) {
                try writeStandardPackagesJson(writer, result.packages);
            } else {
                var json: std.json.Stringify = .{ .writer = writer };
                try json.beginObject();
                try json.objectField("Packages");
                try writeStandardPackagesJsonWith(&json, result.packages);
                try json.objectField("LocalPackages");
                try writeLocalPackagesJsonWith(&json, result.local_packages);
                try json.endObject();
            }
        },
    }
}

fn writeStandardPackagesJson(writer: *std.Io.Writer, packages: []const StandardPackage) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try writeStandardPackagesJsonWith(&json, packages);
}

fn writeStandardPackagesJsonWith(json: *std.json.Stringify, packages: []const StandardPackage) !void {
    try json.beginArray();
    for (packages) |package| try writeStandardPackageJsonWith(json, package);
    try json.endArray();
}

fn writeStandardPackageJson(writer: *std.Io.Writer, package: StandardPackage) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try writeStandardPackageJsonWith(&json, package);
}

fn writeStandardPackageJsonWith(json: *std.json.Stringify, package: StandardPackage) !void {
    try json.beginObject();
    try field(json, "Name", package.name);
    try field(json, "PackageBase", package.package_base);
    try field(json, "Version", package.version);
    try field(json, "Size", package.size);
    try field(json, "Description", package.description);
    try field(json, "Url", package.url);
    try field(json, "Repository", package.repository);
    try field(json, "Replaces", package.replaces);
    try field(json, "Licenses", package.licenses);
    try field(json, "Groups", package.groups);
    try field(json, "Provides", package.provides);
    try field(json, "Depends", package.depends);
    try field(json, "OptDepends", package.optional_depends);
    try field(json, "OptDependsInstalled", package.optional_depends_installed);
    try field(json, "Conflicts", package.conflicts);
    try field(json, "PackageFile", null);
    try field(json, "InstallReason", package.install_reason);
    try json.objectField("InstallDate");
    if (package.install_date) |seconds| {
        var buffer: [32]u8 = undefined;
        try json.write(try formatIsoDateTime(&buffer, seconds));
    } else {
        try json.write(null);
    }
    try json.objectField("BuildDate");
    var build_date_buffer: [32]u8 = undefined;
    try json.write(try formatIsoDateTime(&build_date_buffer, package.build_date));
    try field(json, "DownloadSize", package.download_size);
    try field(json, "InstalledSize", package.installed_size);
    try field(json, "RequiredBy", package.required_by);
    try field(json, "OptionalFor", package.optional_for);
    try json.endObject();
}

fn writeLocalPackagesJson(writer: *std.Io.Writer, packages: []const LocalPackage) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try writeLocalPackagesJsonWith(&json, packages);
}

fn writeLocalPackagesJsonWith(json: *std.json.Stringify, packages: []const LocalPackage) !void {
    try json.beginArray();
    for (packages) |package| {
        try json.beginObject();
        try field(json, "Name", package.name);
        try field(json, "Size", package.size);
        try json.endObject();
    }
    try json.endArray();
}

fn writeAurPackagesJson(writer: *std.Io.Writer, packages: []const AurPackage) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginArray();
    for (packages) |package| {
        try json.beginObject();
        try field(&json, "Id", package.id);
        try field(&json, "Name", package.name);
        try field(&json, "PackageBaseId", package.package_base_id);
        try field(&json, "PackageBase", package.package_base);
        try field(&json, "Version", package.version);
        try field(&json, "Description", package.description);
        try field(&json, "Url", package.url);
        try field(&json, "NumVotes", package.num_votes);
        try field(&json, "Popularity", package.popularity);
        try field(&json, "OutOfDate", package.out_of_date);
        try field(&json, "Maintainer", package.maintainer);
        try field(&json, "FirstSubmitted", package.first_submitted);
        try field(&json, "LastModified", package.last_modified);
        try field(&json, "UrlPath", package.url_path);
        try field(&json, "Depends", package.depends);
        try field(&json, "MakeDepends", package.make_depends);
        try field(&json, "OptDepends", package.optional_depends);
        try field(&json, "CheckDepends", package.check_depends);
        try field(&json, "Conflicts", package.conflicts);
        try field(&json, "Provides", package.provides);
        try field(&json, "Replaces", package.replaces);
        try field(&json, "Groups", package.groups);
        try field(&json, "License", package.licenses);
        try field(&json, "Keywords", package.keywords);
        try field(&json, "RequiredBy", package.required_by);
        try field(&json, "OptionalFor", package.optional_for);
        try field(&json, "Explicit", package.explicit);
        try json.endObject();
    }
    try json.endArray();
}

fn writePkgbuildsJson(writer: *std.Io.Writer, builds: []const PackageBuild) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginArray();
    for (builds) |build| {
        try json.beginObject();
        try field(&json, "Name", build.name);
        try field(&json, "PkgBuild", build.pkgbuild);
        try json.endObject();
    }
    try json.endArray();
}

fn writeFlatpakResponseJson(writer: *std.Io.Writer, result: FlatpakResult) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    try json.objectField("hits");
    try json.beginArray();
    for (result.packages) |package| {
        try json.beginObject();
        try field(&json, "name", package.name);
        try field(&json, "keywords", package.keywords);
        try field(&json, "summary", package.summary);
        try field(&json, "description", package.description);
        try field(&json, "id", package.id);
        try field(&json, "type", package.package_type);
        try field(&json, "project_license", package.project_license);
        try field(&json, "app_id", package.id);
        try field(&json, "main_categories", package.categories);
        try field(&json, "developer_name", package.developer_name);
        try field(&json, "verification_verified", package.verified);
        try field(&json, "verification_method", package.verification_method);
        try field(&json, "remote", package.remote);
        try field(&json, "download_size", package.download_size);
        try field(&json, "installed_size", package.installed_size);
        try field(&json, "permissions", package.permissions);
        try json.endObject();
    }
    try json.endArray();
    try field(&json, "query", result.query);
    try field(&json, "hitsPerPage", result.limit);
    try field(&json, "page", result.page);
    try field(&json, "totalPages", result.total_pages);
    try field(&json, "totalHits", result.total_hits);
    try json.endObject();
}

fn field(json: *std.json.Stringify, name: []const u8, value: anytype) !void {
    try json.objectField(name);
    try json.write(value);
}

fn copyStandardPackage(
    allocator: std.mem.Allocator,
    package: Zigalpm.alpm.OwnedPackage,
) !StandardPackage {
    const repository = package.repository() orelse "";
    return .{
        .name = try allocator.dupe(u8, package.name() orelse ""),
        .package_base = try allocator.dupe(u8, package.base()),
        .version = try allocator.dupe(u8, package.version() orelse ""),
        .size = package.download_size(),
        .description = try allocator.dupe(u8, package.description() orelse ""),
        .url = try allocator.dupe(u8, package.url() orelse ""),
        .repository = try allocator.dupe(u8, repository),
        .replaces = try copySentinelStrings(allocator, package.replaces()),
        .licenses = try copySentinelStrings(allocator, package.licenses()),
        .groups = try copySentinelStrings(allocator, package.groups()),
        .provides = try copySentinelStrings(allocator, package.provides()),
        .depends = try copySentinelStrings(allocator, package.depends()),
        .optional_depends = try copySentinelStrings(allocator, package.optional_depends()),
        .conflicts = try copySentinelStrings(allocator, package.conflicts()),
        .install_reason = if (std.mem.eql(u8, repository, "local")) @tagName(package.install_reason()) else "Not Installed",
        .install_date = package.install_date(),
        .build_date = package.build_date(),
        .download_size = package.download_size(),
        .installed_size = package.install_size(),
        .required_by = try copySentinelStrings(allocator, package.required_by()),
        .optional_for = try copySentinelStrings(allocator, package.optional_for()),
    };
}

fn optionalDependencyInstalledStates(
    allocator: std.mem.Allocator,
    manager: *Zigalpm.AlpmManager,
    optional_dependencies: []const []const u8,
) ![]bool {
    const states = try allocator.alloc(bool, optional_dependencies.len);
    errdefer allocator.free(states);
    for (optional_dependencies, states) |raw, *installed| {
        const dependency = optionalDependencyExpression(raw);
        if (dependency.len == 0) {
            installed.* = false;
            continue;
        }
        const dependency_z = try allocator.dupeZ(u8, dependency);
        defer allocator.free(dependency_z);
        installed.* = manager.is_dependency_satisfied_by_installed_packages(dependency_z) catch false;
    }
    return states;
}

fn optionalDependencyExpression(raw: []const u8) []const u8 {
    const description = std.mem.indexOf(u8, raw, ": ") orelse raw.len;
    return std.mem.trim(u8, raw[0..description], " \t\r\n");
}

fn copyAurPackage(allocator: std.mem.Allocator, package: Zigalpm.aur.models.Package) !AurPackage {
    return .{
        .id = package.id,
        .name = try allocator.dupe(u8, package.name),
        .package_base_id = package.package_base_id,
        .package_base = try allocator.dupe(u8, package.package_base),
        .version = try allocator.dupe(u8, package.version),
        .description = try copyOptionalString(allocator, package.description),
        .url = try copyOptionalString(allocator, package.url),
        .num_votes = package.num_votes,
        .popularity = package.popularity,
        .out_of_date = package.out_of_date,
        .maintainer = try copyOptionalString(allocator, package.maintainer),
        .first_submitted = package.first_submitted,
        .last_modified = package.last_modified,
        .url_path = try copyOptionalString(allocator, package.url_path),
        .depends = try copyOptionalStrings(allocator, package.depends),
        .make_depends = try copyOptionalStrings(allocator, package.make_depends),
        .optional_depends = try copyOptionalStrings(allocator, package.opt_depends),
        .check_depends = try copyOptionalStrings(allocator, package.check_depends),
        .conflicts = try copyOptionalStrings(allocator, package.conflicts),
        .provides = try copyOptionalStrings(allocator, package.provides),
        .replaces = try copyOptionalStrings(allocator, package.replaces),
        .groups = try copyOptionalStrings(allocator, package.groups),
        .licenses = try copyOptionalStrings(allocator, package.licenses),
        .keywords = try copyOptionalStrings(allocator, package.keywords),
        .required_by = try copyOptionalStrings(allocator, package.required_by),
        .optional_for = try copyOptionalStrings(allocator, package.optional_for),
        .explicit = package.explicit,
    };
}

fn copyOptionalString(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |text| try allocator.dupe(u8, text) else null;
}

fn copyOptionalStrings(allocator: std.mem.Allocator, value: ?[]const []const u8) !?[]const []const u8 {
    return if (value) |items| try copyStrings(allocator, items) else null;
}

fn copySentinelStrings(allocator: std.mem.Allocator, values: anytype) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, values.len);
    for (values, result) |value, *destination| destination.* = try allocator.dupe(u8, value);
    return result;
}

fn copyStrings(allocator: std.mem.Allocator, values: anytype) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, values.len);
    for (values, result) |value, *destination| destination.* = try allocator.dupe(u8, value);
    return result;
}

fn ignoredPackage(manager: *Zigalpm.AlpmManager, name: []const u8) bool {
    for (manager.config.ignore_package.items) |ignored| {
        if (std.mem.eql(u8, ignored, name)) return true;
    }
    return false;
}

fn packageScore(name: []const u8, description: ?[]const u8, search_value: []const u8) u16 {
    const search = std.mem.trim(u8, search_value, " \t\r\n");
    if (search.len == 0) return 1;
    if (std.ascii.eqlIgnoreCase(name, search)) return 1000;
    if (startsWithIgnoreCase(name, search)) return 800;
    if (containsWordIgnoreCase(name, search)) return 600;
    if (containsIgnoreCase(name, search)) return 400;
    const detail = description orelse "";
    if (startsWithIgnoreCase(detail, search)) return 200;
    if (containsWordIgnoreCase(detail, search)) return 150;
    if (containsIgnoreCase(detail, search)) return 100;
    return 0;
}

fn partialRatio(allocator: std.mem.Allocator, first_value: []const u8, second_value: []const u8) !u8 {
    const first, const second = if (first_value.len <= second_value.len)
        .{ first_value, second_value }
    else
        .{ second_value, first_value };
    if (first.len == 0) return 0;
    var previous = try allocator.alloc(usize, first.len + 1);
    defer allocator.free(previous);
    var current = try allocator.alloc(usize, first.len + 1);
    defer allocator.free(current);
    var best: u8 = 0;
    var offset: usize = 0;
    while (offset + first.len <= second.len) : (offset += 1) {
        for (previous, 0..) |*cell, index| cell.* = index;
        var row_index: usize = 1;
        while (row_index <= first.len) : (row_index += 1) {
            current[0] = row_index;
            var column: usize = 1;
            while (column <= first.len) : (column += 1) {
                const substitution: usize = if (std.ascii.toLower(first[row_index - 1]) ==
                    std.ascii.toLower(second[offset + column - 1])) 0 else 1;
                current[column] = @min(
                    @min(previous[column] + 1, current[column - 1] + 1),
                    previous[column - 1] + substitution,
                );
            }
            const swap = previous;
            previous = current;
            current = swap;
        }
        const distance = previous[first.len];
        const score: u8 = @intCast((first.len - @min(first.len, distance)) * 100 / first.len);
        best = @max(best, score);
    }
    return best;
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn containsIgnoreCase(value: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > value.len) return false;
    var index: usize = 0;
    while (index + needle.len <= value.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(value[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn containsWordIgnoreCase(value: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > value.len) return false;
    var index: usize = 0;
    while (index + needle.len <= value.len) : (index += 1) {
        if (!std.ascii.eqlIgnoreCase(value[index .. index + needle.len], needle)) continue;
        const left_ok = index == 0 or !std.ascii.isAlphanumeric(value[index - 1]);
        const right = index + needle.len;
        const right_ok = right == value.len or !std.ascii.isAlphanumeric(value[right]);
        if (left_ok and right_ok) return true;
    }
    return false;
}

fn orderIgnoreCase(left: []const u8, right: []const u8) std.math.Order {
    const count = @min(left.len, right.len);
    for (left[0..count], right[0..count]) |left_byte, right_byte| {
        const left_lower = std.ascii.toLower(left_byte);
        const right_lower = std.ascii.toLower(right_byte);
        if (left_lower < right_lower) return .lt;
        if (left_lower > right_lower) return .gt;
    }
    return std.math.order(left.len, right.len);
}

fn containsExact(values: []const []const u8, wanted: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, wanted)) return true;
    return false;
}

fn pageSlice(
    comptime T: type,
    allocator: std.mem.Allocator,
    values: []const T,
    page: usize,
    limit: usize,
) ![]T {
    const start = std.math.mul(usize, page - 1, limit) catch values.len;
    if (start >= values.len) return allocator.alloc(T, 0);
    const end = @min(values.len, start +| limit);
    return allocator.dupe(T, values[start..end]);
}

fn optionEnabled(invocation: *const parser.Invocation, name: []const u8) bool {
    for (invocation.options) |option| {
        if (!std.mem.eql(u8, option.name, name)) continue;
        const value = option.value orelse return true;
        return !std.ascii.eqlIgnoreCase(value, "false");
    }
    return false;
}

fn optionInteger(invocation: *const parser.Invocation, name: []const u8, default_value: i64) i64 {
    for (invocation.options) |option| {
        if (!std.mem.eql(u8, option.name, name)) continue;
        return std.fmt.parseInt(i64, option.value orelse return default_value, 10) catch default_value;
    }
    return default_value;
}

fn defaultLimit(invocation: *const parser.Invocation) i64 {
    return if (std.mem.eql(u8, invocation.command.path, flatpak_command_path)) 21 else 100;
}

fn isSearchPath(path: []const u8) bool {
    return std.mem.eql(u8, path, standard_command_path) or
        std.mem.eql(u8, path, aur_command_path) or
        std.mem.eql(u8, path, flatpak_command_path);
}

fn joinedQuery(allocator: std.mem.Allocator, values: []const []const u8) ![]const u8 {
    return std.mem.join(allocator, " ", values);
}

fn row(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    return allocator.dupe([]const u8, values);
}

test "search routes all action-first types through one handler" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());

    const Capture = struct {
        calls: usize = 0,

        fn search(self: *@This(), _: *runtime.RuntimeContext, invocation: *const parser.Invocation) !Result {
            self.calls += 1;
            if (std.mem.eql(u8, invocation.command.path, standard_command_path))
                return .{ .standard = .{ .requested_packages = true } };
            if (std.mem.eql(u8, invocation.command.path, aur_command_path))
                return .{ .aur = .{ .packages = &.{.{ .name = "yay", .version = "1" }} } };
            return .{ .flatpak = .{
                .query = "editor",
                .packages = &.{},
                .page = 1,
                .limit = 21,
                .total_pages = 0,
                .total_hits = 0,
            } };
        }
    };
    var capture: Capture = .{};

    const standard = try parser.parse(tc.arena.allocator(), &manifest, &.{ "search", "standard", "--available", "vim" });
    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&tc.context, &standard.dispatch, &capture));
    tc.stdout.writer.end = 0;
    const aur = try parser.parse(tc.arena.allocator(), &manifest, &.{ "search", "aur", "yay" });
    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&tc.context, &aur.dispatch, &capture));
    tc.stdout.writer.end = 0;
    const flatpak = try parser.parse(tc.arena.allocator(), &manifest, &.{ "search", "flatpak", "editor" });
    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&tc.context, &flatpak.dispatch, &capture));
    try std.testing.expectEqual(@as(usize, 3), capture.calls);
}

test "standard output preserves C# table columns and ranked result order" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{ "search", "standard", "--available", "discord" });

    const StandardFixture = struct {
        fn search(_: @This(), _: *runtime.RuntimeContext, _: *const parser.Invocation) !Result {
            return .{ .standard = .{
                .packages = &.{
                    .{ .name = "discord", .repository = "extra", .version = "1", .description = "Chat" },
                    .{ .name = "webcord", .repository = "extra", .version = "2", .description = "Client" },
                },
                .requested_packages = true,
            } };
        }
    };
    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&tc.context, &outcome.dispatch, StandardFixture{}));
    const rendered = tc.stdout.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "│ Name") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Repository") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "discord").? < std.mem.indexOf(u8, rendered, "webcord").?);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Total: 2 packages") != null);
}

test "standard package detail serializes optional dependency installation state" {
    var output_buffer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output_buffer.deinit();
    try writeStandardPackageJson(&output_buffer.writer, .{
        .name = "editor",
        .package_base = "editor-suite",
        .version = "1.0",
        .optional_depends = &.{ "spellcheck: Spell checking", "plugins>=2: Plugin support" },
        .optional_depends_installed = &.{ true, false },
    });

    const rendered = output_buffer.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"OptDependsInstalled\":[true,false]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"PackageBase\":\"editor-suite\"") != null);
    try std.testing.expectEqualStrings("plugins>=1:2", optionalDependencyExpression("plugins>=1:2: Plugin support"));
    try std.testing.expectEqualStrings("spellcheck", optionalDependencyExpression("spellcheck: Spell checking"));
}

test "AUR standard merge and Flatpak paging are serialized without subprocesses" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());

    const aur = try parser.parse(tc.arena.allocator(), &manifest, &.{ "search", "aur", "--standard", "yay" });
    const AurFixture = struct {
        fn search(_: @This(), _: *runtime.RuntimeContext, _: *const parser.Invocation) !Result {
            return .{ .aur = .{
                .packages = &.{.{ .name = "yay", .version = "12", .maintainer = "dev" }},
                .standard_packages = &.{.{ .name = "yay-bin", .version = "1", .repository = "extra" }},
            } };
        }
    };
    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&tc.context, &aur.dispatch, AurFixture{}));
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "Total results: 2") != null);

    tc.stdout.writer.end = 0;
    const flatpak = try parser.parse(tc.arena.allocator(), &manifest, &.{ "search", "flatpak", "--page", "2", "--limit", "1", "editor", "--json" });
    const FlatpakFixture = struct {
        fn search(_: @This(), _: *runtime.RuntimeContext, _: *const parser.Invocation) !Result {
            return .{ .flatpak = .{
                .query = "editor",
                .packages = &.{.{
                    .name = "Editor",
                    .id = "org.example.Editor",
                    .summary = "Edit",
                    .remote = "flathub",
                    .download_size = 1048576,
                    .installed_size = 2097152,
                    .permissions = &.{ "shared=network", "sockets=wayland" },
                }},
                .page = 2,
                .limit = 1,
                .total_pages = 3,
                .total_hits = 3,
            } };
        }
    };
    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&tc.context, &flatpak.dispatch, FlatpakFixture{}));
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "\"page\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "org.example.Editor") != null);
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "\"download_size\":1048576") != null);
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "\"installed_size\":2097152") != null);
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "\"permissions\":[\"shared=network\",\"sockets=wayland\"]") != null);

    tc.stdout.writer.end = 0;
    const flatpak_plain = try parser.parse(tc.arena.allocator(), &manifest, &.{ "search", "flatpak", "editor" });
    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&tc.context, &flatpak_plain.dispatch, FlatpakFixture{}));
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "Download Size") != null);
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "Installed Size") != null);
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "shared=network") != null);
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "sockets=wayland") != null);
}

test "interactive AUR search table stays within terminal width" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    var environment = std.process.Environ.Map.init(tc.arena.allocator());
    try environment.put("COLUMNS", "80");
    tc.context.environment = &environment;
    tc.context.stdout_is_tty = true;

    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const invocation = try parser.parse(tc.arena.allocator(), &manifest, &.{ "search", "aur", "codelldb-bin" });
    const Fixture = struct {
        fn search(_: @This(), _: *runtime.RuntimeContext, _: *const parser.Invocation) !Result {
            return .{ .aur = .{ .packages = &.{.{
                .name = "codelldb-bin",
                .version = "1.12.3-1",
                .maintainer = "dmitmel",
                .last_modified = 1_777_000_000,
                .description = "A native debugger extension for VSCode based on LLDB. Also known as CodeLLDB.",
            }} } };
        }
    };
    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&tc.context, &invocation.dispatch, Fixture{}));

    const rendered = tc.stdout.writer.buffered();
    var lines = std.mem.splitScalar(u8, rendered, '\n');
    while (lines.next()) |line|
        try std.testing.expect((try std.unicode.utf8CountCodepoints(line)) <= 79);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "codelldb-bin") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "VSCode") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Total results: 1") != null);
}

test "AUR pkgbuild search displays fetched content and structured output" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const PkgbuildFixture = struct {
        fn search(_: @This(), _: *runtime.RuntimeContext, invocation: *const parser.Invocation) !Result {
            try std.testing.expect(optionEnabled(invocation, "--pkgbuild"));
            try std.testing.expectEqual(@as(usize, 2), invocation.positionals.len);
            return .{ .aur = .{ .pkgbuilds = &.{
                .{ .name = "yay", .pkgbuild = "pkgname=yay\npkgver=12" },
                .{ .name = "missing", .pkgbuild = null },
            } } };
        }
    };

    var outcome = try parser.parse(
        tc.arena.allocator(),
        &manifest,
        &.{ "search", "aur", "--pkgbuild", "yay", "missing" },
    );
    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&tc.context, &outcome.dispatch, PkgbuildFixture{}));
    var rendered = tc.stdout.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Package build for: yay") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "pkgname=yay\npkgver=12") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Failed to get PKGBUILD for: missing") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Total results") == null);

    tc.stdout.writer.end = 0;
    outcome = try parser.parse(
        tc.arena.allocator(),
        &manifest,
        &.{ "search", "aur", "-p", "yay", "missing", "--json" },
    );
    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&tc.context, &outcome.dispatch, PkgbuildFixture{}));
    rendered = tc.stdout.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"Name\":\"yay\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"PkgBuild\":\"pkgname=yay\\npkgver=12\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"PkgBuild\":null") != null);
}

test "AUR detail search renders package metadata and structured output" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const DetailFixture = struct {
        fn search(_: @This(), _: *runtime.RuntimeContext, invocation: *const parser.Invocation) !Result {
            try std.testing.expect(optionEnabled(invocation, "--detail"));
            return .{ .aur = .{
                .detail = .{
                    .name = "yay",
                    .version = "12",
                    .package_base = "yay",
                    .maintainer = "dev",
                    .required_by = &.{ "aur-helper-ui", "desktop-meta" },
                    .optional_for = &.{"shell-extras"},
                },
            } };
        }
    };

    var outcome = try parser.parse(
        tc.arena.allocator(),
        &manifest,
        &.{ "search", "aur", "--detail", "yay" },
    );
    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&tc.context, &outcome.dispatch, DetailFixture{}));
    var rendered = tc.stdout.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Total results") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Required By") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "aur-helper-ui") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Optional For") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "shell-extras") != null);

    tc.stdout.writer.end = 0;
    outcome = try parser.parse(
        tc.arena.allocator(),
        &manifest,
        &.{ "search", "aur", "-d", "yay", "--json" },
    );
    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&tc.context, &outcome.dispatch, DetailFixture{}));
    rendered = tc.stdout.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"Name\":\"yay\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"PackageBase\":\"yay\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"RequiredBy\":[\"aur-helper-ui\",\"desktop-meta\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"OptionalFor\":[\"shell-extras\"]") != null);
}

test "search validates AUR query length and positive pagination before backend execution" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const ShouldNotRun = struct {
        fn search(_: @This(), _: *runtime.RuntimeContext, _: *const parser.Invocation) !Result {
            return error.ShouldNotRun;
        }
    };

    const short_aur = try parser.parse(tc.arena.allocator(), &manifest, &.{ "search", "aur", "x" });
    try std.testing.expectEqual(@as(u8, 1), try executeWithRunner(&tc.context, &short_aur.dispatch, ShouldNotRun{}));
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "at least 2 characters") != null);
    tc.stdout.writer.end = 0;
    const conflicting_aur = try parser.parse(
        tc.arena.allocator(),
        &manifest,
        &.{ "search", "aur", "--pkgbuild", "--standard", "yay" },
    );
    try std.testing.expectEqual(@as(u8, 1), try executeWithRunner(&tc.context, &conflicting_aur.dispatch, ShouldNotRun{}));
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "Cannot combine --pkgbuild with --standard") != null);
    tc.stdout.writer.end = 0;
    const detail_pkgbuild = try parser.parse(
        tc.arena.allocator(),
        &manifest,
        &.{ "search", "aur", "--detail", "--pkgbuild", "yay" },
    );
    try std.testing.expectEqual(@as(u8, 1), try executeWithRunner(&tc.context, &detail_pkgbuild.dispatch, ShouldNotRun{}));
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "Cannot combine --detail with --pkgbuild") != null);
    tc.stdout.writer.end = 0;
    const detail_standard = try parser.parse(
        tc.arena.allocator(),
        &manifest,
        &.{ "search", "aur", "--detail", "--standard", "yay" },
    );
    try std.testing.expectEqual(@as(u8, 1), try executeWithRunner(&tc.context, &detail_standard.dispatch, ShouldNotRun{}));
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "Cannot combine --detail with --standard") != null);
    tc.stdout.writer.end = 0;
    const bad_page = try parser.parse(tc.arena.allocator(), &manifest, &.{ "search", "flatpak", "editor", "--page", "0" });
    try std.testing.expectEqual(@as(u8, 1), try executeWithRunner(&tc.context, &bad_page.dispatch, ShouldNotRun{}));
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "greater than zero") != null);
}

test "package scoring matches the C# ranking tiers" {
    try std.testing.expectEqual(@as(u16, 1000), packageScore("discord", "chat", "discord"));
    try std.testing.expectEqual(@as(u16, 800), packageScore("discord-canary", "chat", "discord"));
    try std.testing.expectEqual(@as(u16, 600), packageScore("python-discord-utils", "chat", "discord"));
    try std.testing.expectEqual(@as(u16, 400), packageScore("webcord", "chat", "cord"));
    try std.testing.expectEqual(@as(u16, 200), packageScore("vesktop", "Discord client", "discord"));
    try std.testing.expectEqual(@as(u16, 150), packageScore("vesktop", "A custom discord client", "discord"));
    try std.testing.expectEqual(@as(u16, 100), packageScore("webcord", "A discordlike app", "discord"));
}
