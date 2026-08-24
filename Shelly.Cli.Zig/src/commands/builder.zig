const std = @import("std");
const Zigalpm = @import("Zigalpm");
const runtime = @import("../runtime/context.zig");
const elevation = @import("../runtime/elevation.zig");
const parser = @import("../cli/parser.zig");
const test_support = @import("test_support.zig");
const PackageBuilder = Zigalpm.builder.PackageBuilder;
const standard_single_pane = @import("../output/standard_single_pane.zig");
const ui_operation = @import("../output/ui_operation.zig");
const ShellyBuildConfiguration = Zigalpm.builder.ShellyBuildConfiguration;

const command_path = "shelly build build";

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    if (!std.mem.eql(u8, invocation.command.path, command_path)) return null;
    if (shouldElevateSyncDeps(invocation, elevation.isRoot())) {
        const elevated_exit = elevation.relaunchIfNeeded(context, invocation.arguments) catch |err| {
            try context.stderr.print("Unable to elevate build dependency installation: {t}\n", .{err});
            return 1;
        };
        if (elevated_exit) |exit_code| return exit_code;
    }
    return try executeWithRunner(context, invocation, Real{});
}

/// `--sync-deps` installs missing dependencies before the build. Dependency
/// transactions require root, but the builder itself refuses root, so the
/// elevated process acts only as a coordinator: it resolves and installs the
/// missing dependencies, then re-executes the build as the invoking user.
fn syncDepsRequested(invocation: *const parser.Invocation) bool {
    return optionEnabled(invocation, "--sync-deps") and
        !optionEnabled(invocation, "--coordinator-child");
}

fn shouldElevateSyncDeps(invocation: *const parser.Invocation, running_as_root: bool) bool {
    return syncDepsRequested(invocation) and !running_as_root;
}

fn executeWithRunner(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: anytype,
) !u8 {
    if (invocation.globals.ui_mode) {
        return try ui_operation.runTransaction(
            context,
            invocation,
            .{
                .opening = "Preparing PKGBUILD...",
                .success_message = "Build completed.",
                .failure_message = "Build failed.",
                .failure_label = "Build failed",
                .cancelled_message = "Build cancelled.",
            },
            runner,
        );
    }

    const succeeded = try standard_single_pane.output(
        context,
        "Preparing PKGBUILD...",
        invocation.globals.no_confirm,
        runner,
        invocation,
        "Build completed.",
        "Build failed.",
    );
    return if (succeeded) 0 else 1;
}

const Real = struct {
    pub fn run(
        _: Real,
        context: *runtime.RuntimeContext,
        operation_context: *Zigalpm.OperationContext,
        invocation: *const parser.Invocation,
    ) !void {
        if (syncDepsRequested(invocation))
            return runSyncDepsCoordinator(context, operation_context, invocation);

        try Zigalpm.builder.secureBuilderProcess();
        const requested_path = if (invocation.positionals.len == 0) "PKGBUILD" else invocation.positionals[0];
        const pkgbuild_path = try std.Io.Dir.cwd().realPathFileAlloc(
            context.io,
            requested_path,
            context.allocator,
        );
        defer context.allocator.free(pkgbuild_path);
        const build_directory = std.fs.path.dirname(pkgbuild_path) orelse
            return error.InvalidPkgbuildPath;

        var operation = operation_context.begin(.{
            .backend = .aur,
            .kind = .build,
            .subject = pkgbuild_path,
        });

        var completion: Zigalpm.OperationCompletionStatus = .failed;
        defer operation.finish(completion);

        const shellybuild = try ShellyBuildConfiguration.init(
            context.io,
            context.allocator,
            context.environ,
        );
        defer shellybuild.deinit();

        const pkgbuild_content = try std.Io.Dir.cwd().readFileAlloc(
            context.io,
            pkgbuild_path,
            context.allocator,
            .limited(32 * 1024 * 1024),
        );
        defer context.allocator.free(pkgbuild_content);
        const pkgbuild_parser = Zigalpm.pkgbuild.Parser{
            .allocator = context.allocator,
            .io = context.io,
            .package_carch = shellybuild.build.carch,
        };

        var names = try pkgbuild_parser.package_names_content(pkgbuild_content);
        defer names.deinit(context.allocator);

        var requested_names: std.ArrayList([]const u8) = .empty;
        defer requested_names.deinit(context.allocator);
        const build_all_members = !hasPackageSelection(invocation);
        for (invocation.options) |option| {
            if (!std.mem.eql(u8, option.name, "--package")) continue;
            const requested_name = option.value orelse return error.MissingPackageName;
            if (!containsString(requested_names.items, requested_name))
                try requested_names.append(context.allocator, requested_name);
        }
        if (requested_names.items.len == 0)
            try requested_names.appendSlice(context.allocator, names.items);

        const package_builds = try context.allocator.alloc(
            Zigalpm.pkgbuild.parser.Pkgbuild,
            requested_names.items.len,
        );

        var parsed_count: usize = 0;
        defer {
            for (package_builds[0..parsed_count]) |*pkgbuild|
                pkgbuild.deinit(context.allocator);
            context.allocator.free(package_builds);
        }

        for (requested_names.items, package_builds) |name, *pkgbuild| {
            const parse_name = if (containsString(names.items, name)) name else names.items[0];
            pkgbuild.* = try (Zigalpm.pkgbuild.Parser{
                .allocator = context.allocator,
                .io = context.io,
                .selected_package_name = parse_name,
                .package_carch = shellybuild.build.carch,
            }).parser_content(pkgbuild_content, build_directory);

            parsed_count += 1;
        }
        var review = try Zigalpm.builder.preparePkgbuildReview(
            context.allocator,
            context.io,
            build_directory,
            pkgbuild_content,
            package_builds,
        );
        defer review.deinit();

        const coordinator_child = optionEnabled(invocation, "--coordinator-child");
        const expected_digest = if (coordinator_child) digest: {
            const encoded = optionValue(invocation, "--review-digest") orelse
                return error.MissingReviewDigest;
            const parsed = try parseReviewDigest(encoded);
            if (!std.mem.eql(u8, &parsed, &review.digest))
                return error.ReviewedPkgbuildChanged;
            break :digest parsed;
        } else review.digest;

        if (!coordinator_child and !optionEnabled(invocation, "--reviewed")) {
            var answer = try operation.ask(.{
                .kind = .review_changes,
                .prompt = "Build packages from this PKGBUILD?",
                .review = .{
                    .subject = pkgbuild_path,
                    .findings = review.findings,
                    .old_content = "",
                    .new_content = pkgbuild_content,
                    .related_files = review.related_files,
                },
                .default_response = if (review.findings.len == 0)
                    .accepted
                else
                    .declined,
            });

            defer answer.deinit(context.allocator);

            if (answer.response != .accepted) {
                completion = .cancelled;
                return error.Cancelled;
            }
        }

        try review.verifyCurrent(
            context.allocator,
            context.io,
            pkgbuild_path,
            build_directory,
        );

        const package_base = package_builds[0].variables.get("pkgbase") orelse
            package_builds[0].pkg_name orelse return error.MissingPackageName;
        if (!optionEnabled(invocation, "--skip-source-pgp-verification"))
            try ensureSourcePgpKeys(context, &operation, package_base, package_builds);
        const work_directory = if (shellybuild.destinations.build) |build_root|
            try Zigalpm.builder.uniqueWorkDirectory(
                context.allocator,
                context.io,
                build_root,
                package_base,
            )
        else
            try context.allocator.dupe(u8, build_directory);
        defer context.allocator.free(work_directory);

        const builder = try PackageBuilder.init(
            context.allocator,
            package_builds,
            operation_context,
            shellybuild.*,
            requested_names.items,
            .{
                .start_directory = build_directory,
                .work_directory = work_directory,
                .package_destination = shellybuild.destinations.packages orelse build_directory,
                .source_destination = shellybuild.destinations.sources orelse build_directory,
                .log_destination = shellybuild.destinations.logs orelse build_directory,
                .pkgbuild_path = pkgbuild_path,
                .clean_after_success = !optionEnabled(invocation, "--keep-workdirs"),
                .overwrite = !optionEnabled(invocation, "--no-overwrite"),
                .run_check = if (optionEnabled(invocation, "--no-check"))
                    false
                else if (optionEnabled(invocation, "--check"))
                    true
                else
                    shellybuild.build.check,
                .sign = if (optionEnabled(invocation, "--nosign"))
                    false
                else if (optionEnabled(invocation, "--sign"))
                    true
                else
                    shellybuild.package.sign,
                .sign_key = optionValue(invocation, "--key") orelse shellybuild.package.sign_key,
                .run_verify = !optionEnabled(invocation, "--noverify"),
                .skip_source_pgp_verification = optionEnabled(invocation, "--skip-source-pgp-verification"),
                .reviewed_pkgbuild_digest = expected_digest,
                .install_scripts = review.install_scripts,
                .reviewed_files = review.reviewed_files,
                .build_all_members = build_all_members,
                .sources_prepared = false,
            },
            context.environ,
            context.io,
        );
        defer builder.deinit();
        const artifacts = builder.runWithOperation(&operation) catch |err| {
            operation.reportError(
                err,
                "Failed to build",
                "build",
                null,
                false,
            );
            return err;
        };
        defer Zigalpm.builder.deinitArtifacts(context.allocator, artifacts);
        for (artifacts) |artifact| {
            const message = try std.fmt.allocPrint(
                context.allocator,
                "Built {s}: {s}",
                .{ artifact.package_name, artifact.path },
            );
            defer context.allocator.free(message);
            operation.status(.success, message, "build.artifact", null);
        }
        completion = .success;
    }
};

const SourcePgpCommandContext = struct {
    runtime_context: *runtime.RuntimeContext,
    executable: []const u8,

    fn contains(data: ?*anyopaque, fingerprint: []const u8) !bool {
        const self: *@This() = @ptrCast(@alignCast(data.?));
        return runQuiet(self.runtime_context, &.{
            "/usr/bin/gpg",
            "--batch",
            "--no-tty",
            "--list-keys",
            fingerprint,
        });
    }

    fn receive(data: ?*anyopaque, fingerprint: []const u8) !bool {
        const self: *@This() = @ptrCast(@alignCast(data.?));
        var child = try std.process.spawn(self.runtime_context.io, .{
            .argv = &.{
                self.executable,
                "keyring",
                "recv",
                "--user",
                "--no-confirm",
                fingerprint,
            },
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        });
        errdefer child.kill(self.runtime_context.io);
        return childSucceeded(try child.wait(self.runtime_context.io));
    }
};

fn ensureSourcePgpKeys(
    context: *runtime.RuntimeContext,
    operation: *const Zigalpm.Operation,
    package_name: []const u8,
    package_builds: []const Zigalpm.pkgbuild.parser.Pkgbuild,
) !void {
    var fingerprints: std.ArrayList([]const u8) = .empty;
    defer fingerprints.deinit(context.allocator);
    for (package_builds) |package_build|
        if (package_build.valid_pgp_keys) |keys|
            try fingerprints.appendSlice(context.allocator, keys);
    if (fingerprints.items.len == 0) return;

    const executable_allocated = try std.process.executablePathAlloc(context.io, context.allocator);
    defer context.allocator.free(executable_allocated);
    var command_context: SourcePgpCommandContext = .{
        .runtime_context = context,
        .executable = std.mem.trimEnd(u8, executable_allocated, " (deleted)"),
    };
    try Zigalpm.source_pgp_keyring.ensurePinnedKeys(
        context.allocator,
        operation,
        package_name,
        fingerprints.items,
        .{
            .context = &command_context,
            .contains = SourcePgpCommandContext.contains,
            .receive = SourcePgpCommandContext.receive,
        },
    );
}

fn runQuiet(context: *runtime.RuntimeContext, argv: []const []const u8) !bool {
    var child = try std.process.spawn(context.io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    errdefer child.kill(context.io);
    return childSucceeded(try child.wait(context.io));
}

fn childSucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

const BuildRequest = struct {
    pkgbuild_path: []u8,
    /// Borrows `pkgbuild_path`; valid until the request is deinitialized.
    build_directory: []const u8,
    shellybuild: *ShellyBuildConfiguration,
    package_builds: []Zigalpm.pkgbuild.parser.Pkgbuild,
    parsed_count: usize,
    no_check: bool,

    fn deinit(self: *BuildRequest, context: *runtime.RuntimeContext) void {
        for (self.package_builds[0..self.parsed_count]) |*pkgbuild|
            pkgbuild.deinit(context.allocator);
        context.allocator.free(self.package_builds);
        self.shellybuild.deinit();
        context.allocator.free(self.pkgbuild_path);
        self.* = undefined;
    }
};

/// Parses the PKGBUILD targeted by the invocation once per requested
/// split-package member, shared by the pre-elevation check and the elevated
/// coordinator.
fn parseBuildRequest(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !BuildRequest {
    const requested_path = if (invocation.positionals.len == 0) "PKGBUILD" else invocation.positionals[0];
    const pkgbuild_path = try std.Io.Dir.cwd().realPathFileAlloc(
        context.io,
        requested_path,
        context.allocator,
    );
    errdefer context.allocator.free(pkgbuild_path);
    const build_directory = std.fs.path.dirname(pkgbuild_path) orelse {
        context.allocator.free(pkgbuild_path);
        return error.InvalidPkgbuildPath;
    };

    const shellybuild = try ShellyBuildConfiguration.init(
        context.io,
        context.allocator,
        context.environ,
    );
    errdefer shellybuild.deinit();

    const pkgbuild_content = try std.Io.Dir.cwd().readFileAlloc(
        context.io,
        pkgbuild_path,
        context.allocator,
        .limited(32 * 1024 * 1024),
    );
    defer context.allocator.free(pkgbuild_content);

    var names = try (Zigalpm.pkgbuild.Parser{
        .allocator = context.allocator,
        .io = context.io,
        .package_carch = shellybuild.build.carch,
    }).package_names_content(pkgbuild_content);
    defer names.deinit(context.allocator);

    var requested_names: std.ArrayList([]const u8) = .empty;
    defer requested_names.deinit(context.allocator);
    for (invocation.options) |option| {
        if (!std.mem.eql(u8, option.name, "--package")) continue;
        const requested_name = option.value orelse return error.MissingPackageName;
        if (!containsString(requested_names.items, requested_name))
            try requested_names.append(context.allocator, requested_name);
    }
    if (requested_names.items.len == 0)
        try requested_names.appendSlice(context.allocator, names.items);

    const package_builds = try context.allocator.alloc(
        Zigalpm.pkgbuild.parser.Pkgbuild,
        requested_names.items.len,
    );
    errdefer context.allocator.free(package_builds);
    var parsed_count: usize = 0;
    errdefer for (package_builds[0..parsed_count]) |*pkgbuild|
        pkgbuild.deinit(context.allocator);
    for (requested_names.items, package_builds) |name, *pkgbuild| {
        const parse_name = if (containsString(names.items, name)) name else names.items[0];
        pkgbuild.* = try (Zigalpm.pkgbuild.Parser{
            .allocator = context.allocator,
            .io = context.io,
            .selected_package_name = parse_name,
            .package_carch = shellybuild.build.carch,
        }).parser_content(pkgbuild_content, build_directory);
        parsed_count += 1;
    }

    const no_check = if (optionEnabled(invocation, "--no-check"))
        true
    else if (optionEnabled(invocation, "--check"))
        false
    else
        !shellybuild.build.check;

    return .{
        .pkgbuild_path = pkgbuild_path,
        .build_directory = build_directory,
        .shellybuild = shellybuild,
        .package_builds = package_builds,
        .parsed_count = parsed_count,
        .no_check = no_check,
    };
}

/// Elevated half of `--sync-deps`: resolves the PKGBUILD's dependencies
/// against the host ALPM state, installs the missing repository packages and
/// builds the missing AUR packages, re-executes the build as the invoking
/// user, and removes build-only dependencies afterward. The coordinator never
/// runs the builder itself.
fn runSyncDepsCoordinator(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !void {
    if (!elevation.isRoot()) {
        try context.stderr.print(
            "Cannot install build dependencies without elevated privileges.\n",
            .{},
        );
        return error.ElevationRequired;
    }

    var request = try parseBuildRequest(context, invocation);
    defer request.deinit(context);

    const manager = try Zigalpm.AlpmManager.init(
        context.allocator,
        context.environ,
        .{ .use_root = true, .operation_context = operation_context },
    );
    defer manager.deinit();
    try manager.sync(false);

    var backend_context: AlpmResolverContext = .{ .manager = manager };
    const backend = backend_context.backend();

    var plan = try resolveSyncDependencies(
        context.allocator,
        request.package_builds,
        request.no_check,
        backend,
    );
    defer plan.deinit(context.allocator);

    // Collected before any installation so the freshly installed packages
    // are still seen as build-only candidates for post-build removal.
    const build_only = try collectBuildOnlyDependencies(
        context.allocator,
        request.package_builds,
        request.no_check,
        backend,
    );
    defer deinitOwnedPaths(context.allocator, build_only);
    // Build-only dependencies are removed on every exit path: the errdefer
    // covers coordinator failures, and the explicit call after the child
    // covers build success and build failure alike.
    errdefer removeBuildOnlyDependencies(manager, context, build_only);

    if (plan.aur_dependencies.len > 0) {
        const executable = try std.process.executablePathAlloc(context.io, context.allocator);
        defer context.allocator.free(executable);
        const build_command = std.mem.trimEnd(u8, executable, " (deleted)");
        const aur_manager = try Zigalpm.AurManager.init(context.allocator, context.environ, .{
            .root = true,
            .check = checkOverride(invocation),
            .sign = signOverride(invocation),
            .build_command = build_command,
            .operation_context = operation_context,
        });
        defer aur_manager.deinit();
        aur_manager.setOperationContext(operation_context);
        defer aur_manager.setOperationContext(null);
        try aur_manager.installAurBuildDependencies(plan.aur_dependencies, request.build_directory);
    }

    if (plan.repo_dependencies.len > 0) {
        var targets: std.ArrayList([:0]const u8) = .empty;
        defer {
            for (targets.items) |target| context.allocator.free(target);
            targets.deinit(context.allocator);
        }
        for (plan.repo_dependencies) |dependency|
            try targets.append(context.allocator, try context.allocator.dupeZ(u8, dependency.name));
        try manager.install_packages(targets.items, .{ .alldeps = true });
    }

    const child_arguments = try buildChildArguments(context.allocator, invocation.arguments);
    defer context.allocator.free(child_arguments);
    const child_exit = try elevation.runAsInvokingUser(context, child_arguments);
    const exit_code = child_exit orelse {
        try context.stderr.print(
            "Cannot run the build as the invoking user; --sync-deps must start from a regular user session.\n",
            .{},
        );
        return error.InvokingUserUnavailable;
    };

    removeBuildOnlyDependencies(manager, context, build_only);
    if (exit_code != 0) return error.BuildFailed;
}

fn checkOverride(invocation: *const parser.Invocation) ?bool {
    if (optionEnabled(invocation, "--no-check")) return false;
    if (optionEnabled(invocation, "--check")) return true;
    return null;
}

fn signOverride(invocation: *const parser.Invocation) ?bool {
    if (optionEnabled(invocation, "--nosign")) return false;
    if (optionEnabled(invocation, "--sign")) return true;
    return null;
}

const AlpmResolverContext = struct {
    manager: *Zigalpm.AlpmManager,

    fn backend(self: *AlpmResolverContext) Zigalpm.aur.dependency_resolver.Backend {
        return .{
            .context = self,
            .is_installed = alpmDependencyInstalled,
            .find_repo_satisfier = alpmRepoSatisfier,
        };
    }
};

fn alpmDependencyInstalled(context: ?*anyopaque, dependency: [:0]const u8) bool {
    const self: *AlpmResolverContext = @ptrCast(@alignCast(context.?));
    return self.manager.is_dependency_satisfied_by_installed_packages(dependency) catch false;
}

fn alpmRepoSatisfier(context: ?*anyopaque, dependency: [:0]const u8) ?[]const u8 {
    const self: *AlpmResolverContext = @ptrCast(@alignCast(context.?));
    return self.manager.find_remote_satisfier_for_dependency(dependency) catch null;
}

const SyncDependencyPlan = struct {
    repo_dependencies: []Zigalpm.aur.dependency_resolver.RepoDependency,
    aur_dependencies: [][]u8,

    fn deinit(self: *SyncDependencyPlan, allocator: std.mem.Allocator) void {
        for (self.repo_dependencies) |dependency| allocator.free(dependency.name);
        allocator.free(self.repo_dependencies);
        for (self.aur_dependencies) |name| allocator.free(name);
        allocator.free(self.aur_dependencies);
        self.* = undefined;
    }
};

/// Resolves dependencies for every requested split-package member and merges
/// the results, keeping the strongest role per repository package and a
/// distinct name list of AUR dependencies for diagnostics.
fn resolveSyncDependencies(
    allocator: std.mem.Allocator,
    package_builds: []const Zigalpm.pkgbuild.parser.Pkgbuild,
    no_check: bool,
    backend: Zigalpm.aur.dependency_resolver.Backend,
) !SyncDependencyPlan {
    const resolver = Zigalpm.aur.dependency_resolver;
    var repo: std.ArrayList(resolver.RepoDependency) = .empty;
    errdefer {
        for (repo.items) |dependency| allocator.free(dependency.name);
        repo.deinit(allocator);
    }
    var aur: std.ArrayList([]u8) = .empty;
    errdefer {
        for (aur.items) |name| allocator.free(name);
        aur.deinit(allocator);
    }

    var provided: std.ArrayList(resolver.ProvidedPackage) = .empty;
    defer {
        for (provided.items) |package| allocator.free(package.version);
        provided.deinit(allocator);
    }
    for (package_builds) |package_build| {
        const name = package_build.pkg_name orelse continue;
        const full_version = try package_build.get_full_version(allocator);
        provided.append(allocator, .{
            .name = name,
            .version = full_version,
        }) catch |err| {
            allocator.free(full_version);
            return err;
        };
    }

    for (package_builds) |*package_build| {
        var resolution = try resolver.resolveWithProvided(allocator, package_build, no_check, backend, provided.items);
        defer resolution.deinit(allocator);
        for (resolution.repo_packages) |dependency| {
            if (findRepoDependency(repo.items, dependency.name)) |index| {
                repo.items[index].role = resolver.strongerRole(repo.items[index].role, dependency.role);
            } else {
                try repo.append(allocator, .{
                    .name = try allocator.dupe(u8, dependency.name),
                    .role = dependency.role,
                });
            }
        }
        for (resolution.aur_packages) |dependency| {
            if (containsString(aur.items, dependency.dependency.name)) continue;
            try aur.append(allocator, try allocator.dupe(u8, dependency.dependency.name));
        }
    }

    return .{
        .repo_dependencies = try repo.toOwnedSlice(allocator),
        .aur_dependencies = try aur.toOwnedSlice(allocator),
    };
}

fn findRepoDependency(
    dependencies: []const Zigalpm.aur.dependency_resolver.RepoDependency,
    name: []const u8,
) ?usize {
    for (dependencies, 0..) |dependency, index|
        if (std.mem.eql(u8, dependency.name, name)) return index;
    return null;
}

fn collectBuildOnlyDependencies(
    allocator: std.mem.Allocator,
    package_builds: []const Zigalpm.pkgbuild.parser.Pkgbuild,
    no_check: bool,
    backend: Zigalpm.aur.dependency_resolver.Backend,
) ![][]u8 {
    var result: std.ArrayList([]u8) = .empty;
    errdefer {
        for (result.items) |name| allocator.free(name);
        result.deinit(allocator);
    }
    for (package_builds) |*package_build| {
        const names = try Zigalpm.aur.dependency_resolver.collectBuildOnlyDependencies(
            allocator,
            package_build,
            no_check,
            backend,
        );
        defer {
            for (names) |name| allocator.free(name);
            allocator.free(names);
        }
        for (names) |name| {
            if (containsString(result.items, name)) continue;
            try result.append(allocator, try allocator.dupe(u8, name));
        }
    }
    return result.toOwnedSlice(allocator);
}

fn deinitOwnedPaths(allocator: std.mem.Allocator, paths: [][]u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

/// Best-effort removal mirroring the AUR manager's post-build cleanup: only
/// installed packages are targeted and removal errors never mask the build
/// result.
fn removeBuildOnlyDependencies(
    manager: *Zigalpm.AlpmManager,
    context: *runtime.RuntimeContext,
    build_only: []const []u8,
) void {
    if (build_only.len == 0) return;
    var installed: std.ArrayList([:0]const u8) = .empty;
    defer {
        for (installed.items) |name| context.allocator.free(name);
        installed.deinit(context.allocator);
    }
    for (build_only) |name| {
        const name_z = context.allocator.dupeZ(u8, name) catch continue;
        if (manager.is_package_installed(name_z)) {
            installed.append(context.allocator, name_z) catch {
                context.allocator.free(name_z);
                continue;
            };
        } else {
            context.allocator.free(name_z);
        }
    }
    if (installed.items.len == 0) return;
    manager.remove_packages(installed.items, .{}, true) catch {};
}

/// Arguments for the invoking-user re-execution: the original invocation
/// minus the sync-deps flag, so the child performs a normal build instead of
/// re-entering the coordinator.
fn buildChildArguments(
    allocator: std.mem.Allocator,
    arguments: []const []const u8,
) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    defer result.deinit(allocator);
    for (arguments) |argument| {
        if (std.mem.eql(u8, argument, "--sync-deps") or
            std.mem.eql(u8, argument, "-s")) continue;
        try result.append(allocator, argument);
    }
    return try result.toOwnedSlice(allocator);
}

fn optionEnabled(invocation: *const parser.Invocation, name: []const u8) bool {
    for (invocation.options) |option| {
        if (!std.mem.eql(u8, option.name, name)) continue;
        const value = option.value orelse return true;
        return !std.ascii.eqlIgnoreCase(value, "false");
    }
    return false;
}

fn optionValue(invocation: *const parser.Invocation, name: []const u8) ?[]const u8 {
    for (invocation.options) |option|
        if (std.mem.eql(u8, option.name, name)) return option.value;
    return null;
}

fn hasPackageSelection(invocation: *const parser.Invocation) bool {
    for (invocation.options) |option|
        if (std.mem.eql(u8, option.name, "--package")) return true;
    return false;
}

fn containsString(values: []const []const u8, wanted: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, wanted)) return true;
    return false;
}

fn parseReviewDigest(encoded: []const u8) ![std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    if (encoded.len != digest.len * 2) return error.InvalidReviewDigest;
    _ = std.fmt.hexToBytes(&digest, encoded) catch return error.InvalidReviewDigest;
    return digest;
}

test "build command routes review questions through standard and UI lifecycles" {
    const spec = @import("../cli/spec.zig");
    var test_context: test_support.TestContext = .{};
    test_context.init();
    defer test_context.deinit();
    const manifest = try spec.Manifest.load(test_context.arena.allocator());

    const ReviewRunner = struct {
        response: ?Zigalpm.OperationQuestionResponse = null,

        pub fn run(
            self: *@This(),
            context: *runtime.RuntimeContext,
            operation_context: *Zigalpm.OperationContext,
            _: *const parser.Invocation,
        ) !void {
            var operation = operation_context.begin(.{
                .backend = .aur,
                .kind = .build,
                .subject = "PKGBUILD",
            });
            defer operation.finish(.success);
            var answer = try operation.ask(.{
                .kind = .review_changes,
                .prompt = "Build packages from this PKGBUILD?",
                .review = .{
                    .subject = "PKGBUILD",
                    .old_content = "",
                    .new_content = "pkgname=demo\n",
                },
                .default_response = .accepted,
            });
            defer answer.deinit(context.allocator);
            self.response = answer.response;
        }
    };

    const standard = try parser.parse(
        test_context.arena.allocator(),
        &manifest,
        &.{ "build", "--no-confirm" },
    );
    var standard_runner: ReviewRunner = .{};
    try std.testing.expectEqual(
        @as(u8, 0),
        try executeWithRunner(&test_context.context, &standard.dispatch, &standard_runner),
    );
    try std.testing.expectEqual(
        Zigalpm.OperationQuestionResponse.accepted,
        standard_runner.response.?,
    );

    test_context.stdout.writer.end = 0;
    const ui = try parser.parse(
        test_context.arena.allocator(),
        &manifest,
        &.{ "build", "--ui-mode", "--no-confirm" },
    );
    var ui_runner: ReviewRunner = .{};
    try std.testing.expectEqual(
        @as(u8, 0),
        try executeWithRunner(&test_context.context, &ui.dispatch, &ui_runner),
    );
    try std.testing.expectEqual(
        Zigalpm.OperationQuestionResponse.accepted,
        ui_runner.response.?,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        test_context.stdout.writer.buffered(),
        "TransactionDone",
    ) != null);
}

test "reviewed option only controls whether build approval is requested" {
    const spec = @import("../cli/spec.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const reviewed = try parser.parse(arena.allocator(), &manifest, &.{ "build", "--reviewed" });
    const normal = try parser.parse(arena.allocator(), &manifest, &.{"build"});
    try std.testing.expect(optionEnabled(&reviewed.dispatch, "--reviewed"));
    try std.testing.expect(!optionEnabled(&normal.dispatch, "--reviewed"));
}

test "coordinator build options preserve selected packages and reviewed digest" {
    const spec = @import("../cli/spec.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const encoded = "5a" ** std.crypto.hash.sha2.Sha256.digest_length;
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "build",
        "--coordinator-child",
        "--review-digest",
        encoded,
        "--package",
        "demo",
        "--package",
        "demo-docs",
        "--check",
        "--noverify",
        "/tmp/PKGBUILD",
    });
    try std.testing.expect(optionEnabled(&outcome.dispatch, "--coordinator-child"));
    try std.testing.expect(optionEnabled(&outcome.dispatch, "--check"));
    try std.testing.expect(optionEnabled(&outcome.dispatch, "--noverify"));
    try std.testing.expectEqualStrings(encoded, optionValue(&outcome.dispatch, "--review-digest").?);
    var selected: usize = 0;
    for (outcome.dispatch.options) |option| {
        if (std.mem.eql(u8, option.name, "--package")) selected += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), selected);
    try std.testing.expectEqualStrings("/tmp/PKGBUILD", outcome.dispatch.positionals[0]);

    const digest = try parseReviewDigest(encoded);
    try std.testing.expectEqualSlices(u8, &([_]u8{0x5a} ** digest.len), &digest);
    try std.testing.expectError(error.InvalidReviewDigest, parseReviewDigest("abc"));
}

fn testEnvironWithHome(allocator: std.mem.Allocator, home: []const u8) !std.process.Environ {
    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();
    try map.put("HOME", home);
    return .{ .block = try map.createPosixBlock(allocator, .{}) };
}

test "build request parsing selects members and honors check overrides" {
    const spec = @import("../cli/spec.zig");
    var test_context: test_support.TestContext = .{};
    test_context.init();
    defer test_context.deinit();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const directory_path = try test_context.arena.allocator().dupe(u8, path_buffer[0..path_length]);
    const pkgbuild_path = try std.fs.path.join(test_context.arena.allocator(), &.{ directory_path, "PKGBUILD" });
    var pkgbuild = try std.Io.Dir.cwd().createFile(std.testing.io, pkgbuild_path, .{ .permissions = .default_file });
    try pkgbuild.writeStreamingAll(std.testing.io, sync_deps_pkgbuild);
    pkgbuild.close(std.testing.io);

    const environ = try testEnvironWithHome(std.testing.allocator, directory_path);
    defer environ.block.deinit(std.testing.allocator);
    test_context.context.environ = environ;

    const manifest = try spec.Manifest.load(test_context.arena.allocator());

    const everything = try parser.parse(
        test_context.arena.allocator(),
        &manifest,
        &.{ "build", "--no-confirm", pkgbuild_path },
    );
    var full_request = try parseBuildRequest(&test_context.context, &everything.dispatch);
    try std.testing.expectEqual(@as(usize, 2), full_request.parsed_count);
    try std.testing.expect(!full_request.no_check);
    full_request.deinit(&test_context.context);

    const selected = try parser.parse(
        test_context.arena.allocator(),
        &manifest,
        &.{ "build", "--no-confirm", "--no-check", "--package", "demo-cli", pkgbuild_path },
    );
    var member_request = try parseBuildRequest(&test_context.context, &selected.dispatch);
    try std.testing.expectEqual(@as(usize, 1), member_request.parsed_count);
    try std.testing.expect(member_request.no_check);
    member_request.deinit(&test_context.context);

    const missing = try parser.parse(
        test_context.arena.allocator(),
        &manifest,
        &.{ "build", "--no-confirm", "--package", "demo-missing", pkgbuild_path },
    );
    var deferred_request = try parseBuildRequest(&test_context.context, &missing.dispatch);
    try std.testing.expectEqual(@as(usize, 1), deferred_request.parsed_count);
    try std.testing.expectEqualStrings("demo", deferred_request.package_builds[0].pkg_name.?);
    deferred_request.deinit(&test_context.context);
}

test "package selection intent distinguishes implicit all from explicit members" {
    const spec = @import("../cli/spec.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const all = try parser.parse(arena.allocator(), &manifest, &.{"build"});
    const selected = try parser.parse(
        arena.allocator(),
        &manifest,
        &.{ "build", "--package", "demo-addon" },
    );
    try std.testing.expect(!hasPackageSelection(&all.dispatch));
    try std.testing.expect(hasPackageSelection(&selected.dispatch));
}

test "sync deps options parse under both spellings" {
    const spec = @import("../cli/spec.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const long_form = try parser.parse(arena.allocator(), &manifest, &.{ "build", "--sync-deps" });
    const short_form = try parser.parse(arena.allocator(), &manifest, &.{ "build", "-s" });
    const plain = try parser.parse(arena.allocator(), &manifest, &.{"build"});
    try std.testing.expect(syncDepsRequested(&long_form.dispatch));
    try std.testing.expect(syncDepsRequested(&short_form.dispatch));
    try std.testing.expect(!syncDepsRequested(&plain.dispatch));
    try std.testing.expect(shouldElevateSyncDeps(&long_form.dispatch, false));
    try std.testing.expect(shouldElevateSyncDeps(&short_form.dispatch, false));
    try std.testing.expect(!shouldElevateSyncDeps(&long_form.dispatch, true));
    try std.testing.expect(!shouldElevateSyncDeps(&plain.dispatch, false));
}

test "coordinator child builds never re-enter the sync deps coordinator" {
    const spec = @import("../cli/spec.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "build",
        "--coordinator-child",
        "--sync-deps",
    });
    try std.testing.expect(optionEnabled(&outcome.dispatch, "--sync-deps"));
    try std.testing.expect(!syncDepsRequested(&outcome.dispatch));
    try std.testing.expect(!shouldElevateSyncDeps(&outcome.dispatch, false));
}

test "invoking user build arguments drop sync deps flags and keep everything else" {
    const allocator = std.testing.allocator;
    const arguments = [_][]const u8{
        "build",
        "--sync-deps",
        "--no-check",
        "-s",
        "--package",
        "demo",
        "/tmp/PKGBUILD",
    };
    const child = try buildChildArguments(allocator, &arguments);
    defer allocator.free(child);
    const expected = [_][]const u8{ "build", "--no-check", "--package", "demo", "/tmp/PKGBUILD" };
    try std.testing.expectEqualStrings(&expected, child);
}

test "sync deps child preserves implicit all-members selection" {
    const allocator = std.testing.allocator;
    const arguments = [_][]const u8{ "build", "--sync-deps", "/tmp/PKGBUILD" };
    const child = try buildChildArguments(allocator, &arguments);
    defer allocator.free(child);
    const expected = [_][]const u8{ "build", "/tmp/PKGBUILD" };
    try std.testing.expectEqualStrings(&expected, child);
}

const fake_sync_deps_backend = struct {
    fn installed(_: ?*anyopaque, dependency: [:0]const u8) bool {
        return std.mem.eql(u8, dependency, "glibc");
    }

    fn repo(_: ?*anyopaque, dependency: [:0]const u8) ?[]const u8 {
        if (std.mem.eql(u8, dependency, "cmake>=3")) return "cmake";
        if (std.mem.eql(u8, dependency, "meson")) return "meson";
        return null;
    }

    fn backend() Zigalpm.aur.dependency_resolver.Backend {
        return .{
            .context = null,
            .is_installed = installed,
            .find_repo_satisfier = repo,
        };
    }
};

const sync_deps_pkgbuild =
    \\pkgbase=demo
    \\pkgname=(demo-cli demo-docs)
    \\pkgver=1
    \\pkgrel=1
    \\arch=('any')
    \\makedepends=('cmake>=3')
    \\checkdepends=('meson')
    \\
    \\package_demo-cli() {
    \\    depends=('glibc' 'aur-runtime')
    \\}
    \\
    \\package_demo-docs() {
    \\    depends=('demo-cli=1-1' 'cmake>=3')
    \\}
;

test "sync deps resolution merges split members and upgrades roles" {
    const allocator = std.testing.allocator;
    var cli_build = try (Zigalpm.pkgbuild.Parser{
        .allocator = allocator,
        .io = std.testing.io,
        .selected_package_name = "demo-cli",
    }).parser_content(sync_deps_pkgbuild, null);
    defer cli_build.deinit(allocator);
    var docs_build = try (Zigalpm.pkgbuild.Parser{
        .allocator = allocator,
        .io = std.testing.io,
        .selected_package_name = "demo-docs",
    }).parser_content(sync_deps_pkgbuild, null);
    defer docs_build.deinit(allocator);

    const builds = [_]Zigalpm.pkgbuild.parser.Pkgbuild{ cli_build, docs_build };

    var plan = try resolveSyncDependencies(allocator, &builds, false, fake_sync_deps_backend.backend());
    defer plan.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), plan.repo_dependencies.len);
    try std.testing.expectEqualStrings("cmake", plan.repo_dependencies[0].name);
    try std.testing.expectEqual(Zigalpm.aur.dependency_resolver.Role.runtime, plan.repo_dependencies[0].role);
    try std.testing.expectEqualStrings("meson", plan.repo_dependencies[1].name);
    try std.testing.expectEqual(Zigalpm.aur.dependency_resolver.Role.check, plan.repo_dependencies[1].role);
    try std.testing.expectEqualSlices([]const u8, &.{"aur-runtime"}, plan.aur_dependencies);

    var unchecked = try resolveSyncDependencies(allocator, &builds, true, fake_sync_deps_backend.backend());
    defer unchecked.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), unchecked.repo_dependencies.len);
    try std.testing.expectEqualStrings("cmake", unchecked.repo_dependencies[0].name);
    try std.testing.expectEqual(@as(usize, 1), unchecked.aur_dependencies.len);
}

test "sync deps build-only collection deduplicates across split members" {
    const allocator = std.testing.allocator;
    var cli_build = try (Zigalpm.pkgbuild.Parser{
        .allocator = allocator,
        .io = std.testing.io,
        .selected_package_name = "demo-cli",
    }).parser_content(sync_deps_pkgbuild, null);
    defer cli_build.deinit(allocator);
    var docs_build = try (Zigalpm.pkgbuild.Parser{
        .allocator = allocator,
        .io = std.testing.io,
        .selected_package_name = "demo-docs",
    }).parser_content(sync_deps_pkgbuild, null);
    defer docs_build.deinit(allocator);

    const builds = [_]Zigalpm.pkgbuild.parser.Pkgbuild{ cli_build, docs_build };

    const with_check = try collectBuildOnlyDependencies(allocator, &builds, false, fake_sync_deps_backend.backend());
    defer deinitOwnedPaths(allocator, with_check);
    try std.testing.expectEqualSlices([]const u8, &.{ "cmake", "meson" }, with_check);

    const without_check = try collectBuildOnlyDependencies(allocator, &builds, true, fake_sync_deps_backend.backend());
    defer deinitOwnedPaths(allocator, without_check);
    try std.testing.expectEqualSlices([]const u8, &.{"cmake"}, without_check);
}
