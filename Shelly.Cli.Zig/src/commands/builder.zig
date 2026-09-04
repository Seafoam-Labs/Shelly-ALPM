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
const aur_url = @import("../config/aur_url.zig");
const isolated_build = @import("isolated_build.zig");

const command_path = "shelly build build";

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    if (!std.mem.eql(u8, invocation.command.path, command_path)) return null;
    if (optionEnabled(invocation, "--makesrcinfo"))
        return try executeMakeSrcinfo(context, invocation);
    if (shouldElevateBuildCoordinator(invocation, elevation.isRoot())) {
        const elevated_arguments = try aur_url.argumentsWithEffectiveBase(context, invocation);
        defer context.allocator.free(elevated_arguments);
        const elevated_exit = elevation.relaunchIfNeeded(context, elevated_arguments) catch |err| {
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

fn isolatedRequested(invocation: *const parser.Invocation) bool {
    return optionEnabled(invocation, "--isolated") and
        !optionEnabled(invocation, "--coordinator-child");
}

fn shouldElevateBuildCoordinator(invocation: *const parser.Invocation, running_as_root: bool) bool {
    return !running_as_root and
        (syncDepsRequested(invocation) or isolatedRequested(invocation));
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

fn executeMakeSrcinfo(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !u8 {
    if (hasPackageSelection(invocation)) {
        try context.stderr.writeAll("--makesrcinfo always describes the complete pkgbase and cannot be combined with --package.\n");
        try context.stderr.flush();
        return 1;
    }

    var generated: std.Io.Writer.Allocating = .init(context.allocator);
    defer generated.deinit();
    var runner: SrcinfoReal = .{ .writer = &generated.writer };

    const stdout = context.stdout;
    context.stdout = context.stderr;
    const succeeded = standard_single_pane.output(
        context,
        "Preparing PKGBUILD metadata...",
        invocation.globals.no_confirm,
        &runner,
        invocation,
        "SRCINFO generated.",
        "SRCINFO generation failed.",
    ) catch |err| {
        context.stdout = stdout;
        return err;
    };
    context.stdout = stdout;
    if (!succeeded) return 1;
    try context.stdout.writeAll(generated.writer.buffered());
    try context.stdout.flush();
    return 0;
}

const SrcinfoReal = struct {
    writer: *std.Io.Writer,

    pub fn run(
        self: *SrcinfoReal,
        context: *runtime.RuntimeContext,
        operation_context: *Zigalpm.OperationContext,
        invocation: *const parser.Invocation,
    ) !void {
        var request = try parseBuildRequest(context, invocation);
        defer request.deinit(context);

        const pkgbuild_content = try std.Io.Dir.cwd().readFileAlloc(
            context.io,
            request.pkgbuild_path,
            context.allocator,
            .limited(32 * 1024 * 1024),
        );
        defer context.allocator.free(pkgbuild_content);
        var review = try Zigalpm.builder.preparePkgbuildReview(
            context.allocator,
            context.io,
            request.build_directory,
            pkgbuild_content,
            request.package_builds,
        );
        defer review.deinit();

        const reviewed_digest = if (optionValue(invocation, "--review-digest")) |encoded| blk: {
            const expected = try parseReviewDigest(encoded);
            if (!std.mem.eql(u8, &expected, &review.digest))
                return error.ReviewedPkgbuildChanged;
            break :blk expected;
        } else null;

        var operation = operation_context.begin(.{
            .backend = .aur,
            .kind = .build,
            .subject = request.pkgbuild_path,
        });
        var completion: Zigalpm.OperationCompletionStatus = .failed;
        defer operation.finish(completion);

        if (!optionEnabled(invocation, "--reviewed") and reviewed_digest == null) {
            var answer = try operation.ask(.{
                .kind = .review_changes,
                .prompt = "Generate SRCINFO from this PKGBUILD?",
                .review = .{
                    .subject = request.pkgbuild_path,
                    .findings = review.findings,
                    .old_content = "",
                    .new_content = pkgbuild_content,
                    .related_files = review.related_files,
                },
                .default_response = if (review.findings.len == 0) .accepted else .declined,
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
            request.pkgbuild_path,
            request.build_directory,
        );

        const requested_names = try context.allocator.alloc([]const u8, request.package_builds.len);
        defer context.allocator.free(requested_names);
        for (request.package_builds, requested_names) |package_build, *name|
            name.* = package_build.pkg_name orelse return error.MissingPackageName;
        const package_base = request.package_builds[0].variables.get("pkgbase") orelse
            requested_names[0];
        const work_directory = if (request.shellybuild.destinations.build) |build_root|
            try Zigalpm.builder.uniqueWorkDirectory(
                context.allocator,
                context.io,
                build_root,
                package_base,
            )
        else
            try context.allocator.dupe(u8, request.build_directory);
        defer context.allocator.free(work_directory);
        const ephemeral_work_directory = request.shellybuild.destinations.build != null;
        if (ephemeral_work_directory)
            try std.Io.Dir.cwd().createDirPath(context.io, work_directory);
        defer if (ephemeral_work_directory)
            std.Io.Dir.cwd().deleteTree(context.io, work_directory) catch {};

        const builder = try PackageBuilder.init(
            context.allocator,
            request.package_builds,
            operation_context,
            request.shellybuild.*,
            requested_names,
            .{
                .start_directory = request.build_directory,
                .work_directory = work_directory,
                .package_destination = request.build_directory,
                .source_destination = request.build_directory,
                .log_destination = request.build_directory,
                .pkgbuild_path = request.pkgbuild_path,
                .clean_after_success = true,
                .overwrite = false,
                .run_check = false,
                .run_verify = false,
                .reviewed_pkgbuild_digest = review.digest,
                .install_scripts = review.install_scripts,
                .reviewed_files = review.reviewed_files,
                .build_all_members = true,
                .sources_prepared = false,
            },
            context.environ,
            context.io,
        );
        defer builder.deinit();
        try builder.writeSrcinfoWithOperation(&operation, self.writer);
        completion = .success;
    }
};

const Real = struct {
    pub fn run(
        _: Real,
        context: *runtime.RuntimeContext,
        operation_context: *Zigalpm.OperationContext,
        invocation: *const parser.Invocation,
    ) !void {
        if (isolatedRequested(invocation))
            return runIsolatedCoordinator(context, operation_context, invocation);
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

/// Root-only coordinator for the nspawn backend. It reviews the host input,
/// stages the reviewed snapshots, provisions an operation-scoped guest, and
/// then runs the ordinary Shelly builder as the fixed unprivileged guest.
fn runIsolatedCoordinator(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !void {
    if (!elevation.isRoot()) return error.ElevationRequired;
    const invoking_ids = (try elevation.invokingUserIds(context)) orelse
        return error.InvokingUserUnavailable;
    if (optionEnabled(invocation, "--sign") and !optionEnabled(invocation, "--nosign"))
        return error.IsolatedSigningUnsupported;

    var request = try parseBuildRequest(context, invocation);
    defer request.deinit(context);
    if (request.shellybuild.package.sign and !optionEnabled(invocation, "--nosign"))
        return error.IsolatedSigningUnsupported;

    const pkgbuild_content = try std.Io.Dir.cwd().readFileAlloc(
        context.io,
        request.pkgbuild_path,
        context.allocator,
        .limited(32 * 1024 * 1024),
    );
    defer context.allocator.free(pkgbuild_content);
    var review = try Zigalpm.builder.preparePkgbuildReview(
        context.allocator,
        context.io,
        request.build_directory,
        pkgbuild_content,
        request.package_builds,
    );
    defer review.deinit();

    var operation = operation_context.begin(.{
        .backend = .aur,
        .kind = .build,
        .subject = request.pkgbuild_path,
    });
    var completion: Zigalpm.OperationCompletionStatus = .failed;
    defer operation.finish(completion);

    if (!optionEnabled(invocation, "--reviewed")) {
        var answer = try operation.ask(.{
            .kind = .review_changes,
            .prompt = "Build packages in a systemd-nspawn isolated root?",
            .review = .{
                .subject = request.pkgbuild_path,
                .findings = review.findings,
                .old_content = "",
                .new_content = pkgbuild_content,
                .related_files = review.related_files,
            },
            .default_response = if (review.findings.len == 0) .accepted else .declined,
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
        request.pkgbuild_path,
        request.build_directory,
    );

    var dependency_plan: ?SyncDependencyPlan = null;
    defer if (dependency_plan) |*plan| plan.deinit(context.allocator);
    var bootstrap_packages: std.ArrayList([]const u8) = .empty;
    defer bootstrap_packages.deinit(context.allocator);
    if (optionEnabled(invocation, "--sync-deps")) {
        const manager = try Zigalpm.AlpmManager.init(
            context.allocator,
            context.environ,
            .{ .use_root = true, .operation_context = operation_context },
        );
        defer manager.deinit();
        try manager.sync(false);
        var resolver_context: IsolatedResolverContext = .{ .manager = manager };
        dependency_plan = try resolveSyncDependencies(
            context.allocator,
            request.package_builds,
            request.no_check,
            resolver_context.backend(),
        );
        if (dependency_plan.?.aur_dependencies.len != 0) {
            for (dependency_plan.?.aur_dependencies) |name|
                operation.status(.warning, name, "build.isolation.aur-dependency", null);
            return error.IsolatedAurDependencyUnsupported;
        }
        for (dependency_plan.?.repo_dependencies) |dependency|
            try bootstrap_packages.append(context.allocator, dependency.name);
    }

    var root = try isolated_build.Root.create(context.allocator, context.io);
    defer root.deinit();
    operation.status(.information, "Provisioning clean build root", "build.isolation.provision", null);
    try root.bootstrap(bootstrap_packages.items);
    try root.stageReviewedInputs(pkgbuild_content, review.reviewed_files);

    const executable_allocated = try std.process.executablePathAlloc(context.io, context.allocator);
    defer context.allocator.free(executable_allocated);
    const executable = std.mem.trimEnd(u8, executable_allocated, " (deleted)");
    try root.stageExecutable(executable);

    const guest_configuration = try renderIsolatedConfiguration(
        context.allocator,
        request.shellybuild,
    );
    defer context.allocator.free(guest_configuration);
    try root.writeBuildConfiguration(guest_configuration);

    const digest_hex = std.fmt.bytesToHex(review.digest, .lower);
    const child_arguments = try buildIsolatedChildArguments(
        context.allocator,
        invocation.arguments,
        if (invocation.positionals.len == 0) null else invocation.positionals[0],
        &digest_hex,
    );
    defer context.allocator.free(child_arguments);
    operation.status(.information, "Running unprivileged nspawn build", "build.isolation.execute", null);
    try root.run(child_arguments);

    const expected_names = try context.allocator.alloc([]const u8, request.package_builds.len);
    defer context.allocator.free(expected_names);
    for (request.package_builds, expected_names) |package_build, *name|
        name.* = package_build.pkg_name orelse return error.MissingPackageName;
    try validateIsolatedArtifacts(context, root.artifact_path, expected_names);

    const destination = request.shellybuild.destinations.packages orelse request.build_directory;
    const artifact_count = try root.exportArtifacts(
        destination,
        !optionEnabled(invocation, "--no-overwrite"),
        invoking_ids.uid,
        invoking_ids.gid,
    );
    const message = try std.fmt.allocPrint(
        context.allocator,
        "Exported {d} isolated build artifact{s} to {s}",
        .{ artifact_count, if (artifact_count == 1) "" else "s", destination },
    );
    defer context.allocator.free(message);
    operation.status(.success, message, "build.isolation.artifacts", null);
    root.succeeded = true;
    completion = .success;
}

fn validateIsolatedArtifacts(
    context: *runtime.RuntimeContext,
    artifact_directory: []const u8,
    expected_names: []const []const u8,
) !void {
    const bindings = Zigalpm.alpm.bindings.libalpm;
    const raw = bindings.alpm;
    var alpm_error: raw.alpm_errno_t = 0;
    const handle = raw.alpm_initialize("/", "/var/lib/pacman", &alpm_error) orelse
        return error.ArtifactValidationFailed;
    defer _ = raw.alpm_release(handle);

    const found = try context.allocator.alloc(bool, expected_names.len);
    defer context.allocator.free(found);
    @memset(found, false);
    var directory = try std.Io.Dir.cwd().openDir(context.io, artifact_directory, .{ .iterate = true });
    defer directory.close(context.io);
    var iterator = directory.iterate();
    while (try iterator.next(context.io)) |entry| {
        if (entry.kind != .file or !isolated_build.isPackageArtifact(entry.name)) continue;
        const path = try std.fs.path.joinZ(context.allocator, &.{ artifact_directory, entry.name });
        defer context.allocator.free(path);
        var package: ?*raw.alpm_pkg_t = null;
        if (raw.alpm_pkg_load(handle, path.ptr, 1, 0, &package) != 0 or package == null)
            return error.ArtifactValidationFailed;
        defer _ = raw.alpm_pkg_free(package.?);
        const package_name = bindings.str(raw.alpm_pkg_get_name(package.?)) orelse
            return error.ArtifactValidationFailed;
        var matched = false;
        for (expected_names, found) |expected, *was_found| {
            if (!std.mem.eql(u8, package_name, expected)) continue;
            if (was_found.*) return error.DuplicateBuildArtifact;
            was_found.* = true;
            matched = true;
            break;
        }
        if (!matched) return error.UnexpectedBuildArtifact;
    }
    for (found) |was_found| if (!was_found) return error.MissingBuildArtifact;
}

fn buildIsolatedChildArguments(
    allocator: std.mem.Allocator,
    arguments: []const []const u8,
    original_positional: ?[]const u8,
    digest_hex: []const u8,
) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    defer result.deinit(allocator);
    var positional_index: ?usize = null;
    if (original_positional) |positional| {
        for (arguments, 0..) |argument, index| {
            if (std.mem.eql(u8, argument, positional)) positional_index = index;
        }
    }
    for (arguments, 0..) |argument, index| {
        if (std.mem.eql(u8, argument, "--isolated") or
            std.mem.eql(u8, argument, "-i") or
            std.mem.eql(u8, argument, "--sync-deps") or
            std.mem.eql(u8, argument, "-s") or
            std.mem.eql(u8, argument, "--")) continue;
        if (positional_index != null and positional_index.? == index) continue;
        try result.append(allocator, argument);
    }
    try result.appendSlice(allocator, &.{
        "--coordinator-child",
        "--review-digest",
        digest_hex,
        "--nosign",
        isolated_build.guest_source ++ "/PKGBUILD",
    });
    return result.toOwnedSlice(allocator);
}

fn renderIsolatedConfiguration(
    allocator: std.mem.Allocator,
    configuration: *const ShellyBuildConfiguration,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    try writer.writeAll("[build]\n");
    try writeTomlString(writer, "carch", configuration.build.carch);
    try writeTomlString(writer, "chost", configuration.build.chost);
    try writeTomlArray(writer, "cppflags", configuration.build.cppflags);
    try writeTomlArray(writer, "cflags", configuration.build.cflags);
    try writeTomlArray(writer, "cxxflags", configuration.build.cxxflags);
    try writeTomlArray(writer, "ldflags", configuration.build.ldflags);
    try writeTomlArray(writer, "ltoflags", configuration.build.ltoflags);
    try writeTomlArray(writer, "makeflags", configuration.build.makeflags);
    try writer.print("check = {}\nccache = false\ndistcc = false\n\n", .{configuration.build.check});

    try writer.writeAll("[package]\n");
    try writeTomlString(writer, "packager", configuration.package.packager);
    try writeTomlString(writer, "extension", configuration.package.extension);
    try writeTomlArray(writer, "options", configuration.package.options);
    try writeTomlArray(writer, "strip_binaries", configuration.package.strip_binaries);
    try writeTomlArray(writer, "strip_shared", configuration.package.strip_shared);
    try writeTomlArray(writer, "strip_static", configuration.package.strip_static);
    try writer.writeAll("sign = false\n\n[destinations]\n");
    try writeTomlString(writer, "build", "/build/work");
    try writeTomlString(writer, "packages", isolated_build.guest_artifacts);
    try writeTomlString(writer, "sources", "/build/sources");
    try writeTomlString(writer, "logs", "/build/logs");
    try writer.writeAll("\n[sandbox]\nenabled = false\n");
    return output.toOwnedSlice();
}

fn writeTomlString(writer: *std.Io.Writer, key: []const u8, value: []const u8) !void {
    try writer.print("{s} = ", .{key});
    try writeTomlQuoted(writer, value);
    try writer.writeByte('\n');
}

fn writeTomlArray(writer: *std.Io.Writer, key: []const u8, values: []const []const u8) !void {
    try writer.print("{s} = [", .{key});
    for (values, 0..) |value, index| {
        if (index != 0) try writer.writeAll(", ");
        try writeTomlQuoted(writer, value);
    }
    try writer.writeAll("]\n");
}

fn writeTomlQuoted(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0x08 => try writer.writeAll("\\b"),
        0x0c => try writer.writeAll("\\f"),
        0x00...0x07, 0x0b, 0x0e...0x1f, 0x7f => try writer.print("\\u{X:0>4}", .{byte}),
        else => try writer.writeByte(byte),
    };
    try writer.writeByte('"');
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

    // Snapshot the local database before dependency installation. Cleanup is
    // based on the resulting package delta rather than only the direct
    // makedepends/checkdepends declarations, so repository and AUR dependency
    // graphs are covered without touching packages that predated this build.
    var dependency_cleanup = try BuildDependencyCleanup.init(context.allocator, manager);
    defer {
        dependency_cleanup.run(manager, context, operation_context);
        dependency_cleanup.deinit();
    }

    var backend_context: AlpmResolverContext = .{ .manager = manager };
    const backend = backend_context.backend();

    var plan = try resolveSyncDependencies(
        context.allocator,
        request.package_builds,
        request.no_check,
        backend,
    );
    defer plan.deinit(context.allocator);

    if (plan.aur_dependencies.len > 0) {
        const executable = try std.process.executablePathAlloc(context.io, context.allocator);
        defer context.allocator.free(executable);
        const build_command = std.mem.trimEnd(u8, executable, " (deleted)");
        const aur_base = try aur_url.resolveFor(context, invocation);
        const aur_manager = try Zigalpm.AurManager.init(context.allocator, context.environ, .{
            .aur_git_base_url = aur_base,
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

    // The AUR manager owns a separate libalpm handle. Reload this coordinator's
    // handle before another transaction so it observes packages installed by
    // that handle rather than using a stale local-database cache.
    if (plan.aur_dependencies.len > 0) try manager.refresh();

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

/// An isolated root starts with no host packages. Repository metadata is
/// shared for resolution, but the host local database must not suppress a
/// dependency that still needs to be provisioned into the guest.
const IsolatedResolverContext = struct {
    manager: *Zigalpm.AlpmManager,

    fn backend(self: *IsolatedResolverContext) Zigalpm.aur.dependency_resolver.Backend {
        return .{
            .context = self,
            .is_installed = isolatedDependencyInstalled,
            .find_repo_satisfier = isolatedRepoSatisfier,
        };
    }
};

fn isolatedDependencyInstalled(_: ?*anyopaque, _: [:0]const u8) bool {
    return false;
}

fn isolatedRepoSatisfier(context: ?*anyopaque, dependency: [:0]const u8) ?[]const u8 {
    const self: *IsolatedResolverContext = @ptrCast(@alignCast(context.?));
    return self.manager.find_remote_satisfier_for_dependency(dependency) catch null;
}

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

const BuildDependencyCleanup = struct {
    allocator: std.mem.Allocator,
    baseline: std.StringHashMap(void),

    fn init(allocator: std.mem.Allocator, manager: *Zigalpm.AlpmManager) !BuildDependencyCleanup {
        var baseline = std.StringHashMap(void).init(allocator);
        errdefer deinitOwnedStringSet(allocator, &baseline);

        const installed = try manager.get_installed_packages();
        defer Zigalpm.alpm.OwnedPackage.deinitSlice(allocator, installed);
        for (installed) |package| {
            const name = package.name() orelse continue;
            if (baseline.contains(name)) continue;
            const owned_name = try allocator.dupe(u8, name);
            baseline.put(owned_name, {}) catch |err| {
                allocator.free(owned_name);
                return err;
            };
        }
        return .{ .allocator = allocator, .baseline = baseline };
    }

    fn deinit(self: *BuildDependencyCleanup) void {
        deinitOwnedStringSet(self.allocator, &self.baseline);
        self.* = undefined;
    }

    /// Best-effort cleanup must outlive cancellation of the build operation.
    /// A fresh context lets ALPM query and remove packages even when the parent
    /// context is cancelled; failures are still reported to the parent as a
    /// recoverable cleanup failure and never replace the build result.
    fn run(
        self: *const BuildDependencyCleanup,
        manager: *Zigalpm.AlpmManager,
        context: *runtime.RuntimeContext,
        parent_context: *Zigalpm.OperationContext,
    ) void {
        var operation = parent_context.begin(.{
            .backend = .alpm,
            .kind = .cleanup,
            .subject = "build dependencies",
        });
        var completion: Zigalpm.OperationCompletionStatus = .success;
        defer operation.finish(completion);

        var cleanup_context = independentCleanupContext(context.allocator, context.io);
        defer cleanup_context.deinit();
        manager.setOperationContext(&cleanup_context);
        defer manager.setOperationContext(parent_context);

        manager.refresh() catch |err| {
            completion = .failed;
            operation.reportError(
                err,
                "Failed to refresh package state for build dependency cleanup",
                "alpm.cleanup",
                null,
                true,
            );
            return;
        };

        const installed = manager.get_installed_packages() catch |err| {
            completion = .failed;
            operation.reportError(
                err,
                "Failed to inspect packages installed for the build",
                "alpm.cleanup",
                null,
                true,
            );
            return;
        };
        defer Zigalpm.alpm.OwnedPackage.deinitSlice(context.allocator, installed);

        var targets: std.ArrayList([:0]const u8) = .empty;
        defer {
            for (targets.items) |name| context.allocator.free(name);
            targets.deinit(context.allocator);
        }
        for (installed) |package| {
            const name = package.name() orelse continue;
            appendCleanupCandidate(
                context.allocator,
                &self.baseline,
                name,
                package.install_reason() == .Dependency,
                &targets,
            ) catch |err| {
                completion = .failed;
                operation.reportError(
                    err,
                    "Failed to prepare build dependency cleanup",
                    "alpm.cleanup",
                    null,
                    true,
                );
                return;
            };
        }
        if (targets.items.len == 0) return;

        manager.remove_packages(targets.items, .{
            .recurse = true,
            .unneeded = true,
        }, true) catch |err| {
            completion = .failed;
            reportCleanupFailure(context.allocator, &operation, err, targets.items);
            return;
        };

        var remaining: std.ArrayList([:0]const u8) = .empty;
        defer remaining.deinit(context.allocator);
        for (targets.items) |name| {
            if (!manager.is_package_installed(name)) continue;
            remaining.append(context.allocator, name) catch |err| {
                completion = .failed;
                operation.reportError(
                    err,
                    "Failed to verify build dependency cleanup",
                    "alpm.cleanup",
                    null,
                    true,
                );
                return;
            };
        }
        if (remaining.items.len != 0) {
            completion = .failed;
            reportCleanupFailure(
                context.allocator,
                &operation,
                error.BuildDependencyCleanupIncomplete,
                remaining.items,
            );
        }
    }
};

fn deinitOwnedStringSet(allocator: std.mem.Allocator, values: *std.StringHashMap(void)) void {
    var keys = values.keyIterator();
    while (keys.next()) |key| allocator.free(key.*);
    values.deinit();
}

fn appendCleanupCandidate(
    allocator: std.mem.Allocator,
    baseline: *const std.StringHashMap(void),
    name: [:0]const u8,
    installed_as_dependency: bool,
    targets: *std.ArrayList([:0]const u8),
) !void {
    if (!installed_as_dependency or baseline.contains(name)) return;
    const owned_name = try allocator.dupeZ(u8, name);
    targets.append(allocator, owned_name) catch |err| {
        allocator.free(owned_name);
        return err;
    };
}

fn independentCleanupContext(allocator: std.mem.Allocator, io: std.Io) Zigalpm.OperationContext {
    return Zigalpm.OperationContext.init(allocator, io);
}

fn reportCleanupFailure(
    allocator: std.mem.Allocator,
    operation: *const Zigalpm.Operation,
    err: anyerror,
    targets: []const [:0]const u8,
) void {
    const names: []const []const u8 = @ptrCast(targets);
    const joined = std.mem.join(allocator, ", ", names) catch null;
    defer if (joined) |value| allocator.free(value);
    const message = if (joined) |value|
        std.fmt.allocPrint(
            allocator,
            "Failed to remove build dependencies ({s}): {s}",
            .{ value, @errorName(err) },
        ) catch null
    else
        null;
    defer if (message) |value| allocator.free(value);
    operation.reportError(
        err,
        message orelse "Failed to remove build dependencies",
        "alpm.cleanup",
        null,
        true,
    );
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
    defer map.deinit();
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

test "makesrcinfo emits clean stdout and never runs lifecycle functions" {
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
    const marker_path = try std.fs.path.join(test_context.arena.allocator(), &.{ directory_path, "lifecycle-ran" });
    const pkgbuild_content = try std.fmt.allocPrint(
        test_context.arena.allocator(),
        "pkgname=demo\npkgver=1\npkgrel=1\npkgdesc=$(printf 'Dynamic description')\narch=(any)\n" ++
            "_enable_plasmoid=${{SYNCTHING_TRAY_ENABLE_PLASMOID:-1}}\n" ++
            "makedepends=('cmake')\n" ++
            "[[ $_enable_plasmoid ]] && makedepends+=('libplasma' 'extra-cmake-modules')\n" ++
            "pkgver() {{ touch '{s}'; printf 2; }}\n" ++
            "build() {{ touch '{s}'; }}\n" ++
            "package() {{ touch '{s}'; }}\n",
        .{ marker_path, marker_path, marker_path },
    );
    var pkgbuild = try std.Io.Dir.cwd().createFile(std.testing.io, pkgbuild_path, .{ .permissions = .default_file });
    try pkgbuild.writeStreamingAll(std.testing.io, pkgbuild_content);
    pkgbuild.close(std.testing.io);

    const environ = try testEnvironWithHome(std.testing.allocator, directory_path);
    defer environ.block.deinit(std.testing.allocator);
    test_context.context.environ = environ;
    const manifest = try spec.Manifest.load(test_context.arena.allocator());
    var package_builds = try test_context.arena.allocator().alloc(Zigalpm.pkgbuild.parser.Pkgbuild, 1);
    package_builds[0] = try (Zigalpm.pkgbuild.Parser{
        .allocator = test_context.arena.allocator(),
        .io = std.testing.io,
        .selected_package_name = "demo",
    }).parser_content(pkgbuild_content, directory_path);
    var review = try Zigalpm.builder.preparePkgbuildReview(
        test_context.arena.allocator(),
        std.testing.io,
        directory_path,
        pkgbuild_content,
        package_builds,
    );
    defer review.deinit();
    const wrong_digest = "5a" ** std.crypto.hash.sha2.Sha256.digest_length;
    const mismatched = try parser.parse(
        test_context.arena.allocator(),
        &manifest,
        &.{ "build", "--makesrcinfo", "--review-digest", wrong_digest, "--no-confirm", pkgbuild_path },
    );
    try std.testing.expect((try executeMakeSrcinfo(&test_context.context, &mismatched.dispatch)) != 0);

    const digest_hex = std.fmt.bytesToHex(review.digest, .lower);
    const outcome = try parser.parse(
        test_context.arena.allocator(),
        &manifest,
        &.{ "build", "--makesrcinfo", "--review-digest", &digest_hex, "--no-confirm", pkgbuild_path },
    );
    try std.testing.expect(optionEnabled(&outcome.dispatch, "--makesrcinfo"));
    try std.testing.expectEqual(
        @as(u8, 0),
        try executeMakeSrcinfo(&test_context.context, &outcome.dispatch),
    );
    try std.testing.expectEqualStrings(
        "pkgbase = demo\n\tpkgdesc = Dynamic description\n\tpkgver = 1\n\tpkgrel = 1\n" ++
            "\tarch = any\n\tmakedepends = cmake\n\tmakedepends = libplasma\n" ++
            "\tmakedepends = extra-cmake-modules\n\npkgname = demo\n",
        test_context.stdout.writer.buffered(),
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        test_context.stderr.writer.buffered(),
        "SRCINFO generated.",
    ) != null);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(std.testing.io, marker_path, .{}),
    );
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

test "isolated builds elevate only the outer coordinator" {
    const spec = @import("../cli/spec.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outer = try parser.parse(arena.allocator(), &manifest, &.{ "build", "--isolated" });
    const child = try parser.parse(arena.allocator(), &manifest, &.{
        "build",
        "--isolated",
        "--coordinator-child",
        "--review-digest",
        "5a" ** std.crypto.hash.sha2.Sha256.digest_length,
    });
    try std.testing.expect(isolatedRequested(&outer.dispatch));
    try std.testing.expect(shouldElevateBuildCoordinator(&outer.dispatch, false));
    try std.testing.expect(!shouldElevateBuildCoordinator(&outer.dispatch, true));
    try std.testing.expect(!isolatedRequested(&child.dispatch));
    try std.testing.expect(!shouldElevateBuildCoordinator(&child.dispatch, false));
}

test "isolated child arguments remove host coordinator flags and replace the path" {
    const arguments = [_][]const u8{
        "build",
        "--isolated",
        "--sync-deps",
        "--no-check",
        "/host/reviewed/PKGBUILD",
    };
    const digest = "5a" ** std.crypto.hash.sha2.Sha256.digest_length;
    const child = try buildIsolatedChildArguments(
        std.testing.allocator,
        &arguments,
        "/host/reviewed/PKGBUILD",
        digest,
    );
    defer std.testing.allocator.free(child);
    const expected = [_][]const u8{
        "build",
        "--no-check",
        "--coordinator-child",
        "--review-digest",
        digest,
        "--nosign",
        "/build/source/PKGBUILD",
    };
    try std.testing.expectEqualStrings(&expected, child);
}

test "isolated configuration preserves build policy and forces guest-local destinations" {
    const configuration = try ShellyBuildConfiguration.initFromBuffers(
        std.testing.allocator,
        null,
        null,
    );
    defer configuration.deinit();
    const rendered = try renderIsolatedConfiguration(std.testing.allocator, configuration);
    defer std.testing.allocator.free(rendered);
    const parsed = try ShellyBuildConfiguration.initFromBuffers(
        std.testing.allocator,
        rendered,
        null,
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings(configuration.build.carch, parsed.build.carch);
    try std.testing.expectEqualStrings(configuration.build.cflags[0], parsed.build.cflags[0]);
    try std.testing.expectEqualStrings("/build/work", parsed.destinations.build.?);
    try std.testing.expectEqualStrings(isolated_build.guest_artifacts, parsed.destinations.packages.?);
    try std.testing.expect(!parsed.package.sign);
    try std.testing.expect(!parsed.sandbox.enabled);
}

test "isolated dependency state never inherits host installations" {
    var dependency = [_:0]u8{ 'd', 'e', 'm', 'o' };
    try std.testing.expect(!isolatedDependencyInstalled(null, &dependency));
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

test "sync deps cleanup selects every new dependency and preserves prior or explicit packages" {
    const allocator = std.testing.allocator;
    var baseline = std.StringHashMap(void).init(allocator);
    defer deinitOwnedStringSet(allocator, &baseline);
    try baseline.put(try allocator.dupe(u8, "preexisting-tool"), {});

    var targets: std.ArrayList([:0]const u8) = .empty;
    defer {
        for (targets.items) |name| allocator.free(name);
        targets.deinit(allocator);
    }
    try appendCleanupCandidate(allocator, &baseline, "preexisting-tool", true, &targets);
    try appendCleanupCandidate(allocator, &baseline, "user-installed-tool", false, &targets);
    try appendCleanupCandidate(allocator, &baseline, "direct-makedep", true, &targets);
    try appendCleanupCandidate(allocator, &baseline, "transitive-repo-dep", true, &targets);
    try appendCleanupCandidate(allocator, &baseline, "transitive-aur-dep", true, &targets);

    try std.testing.expectEqual(@as(usize, 3), targets.items.len);
    try std.testing.expectEqualStrings("direct-makedep", targets.items[0]);
    try std.testing.expectEqualStrings("transitive-repo-dep", targets.items[1]);
    try std.testing.expectEqualStrings("transitive-aur-dep", targets.items[2]);
}

test "sync deps cleanup context remains usable after parent cancellation" {
    var parent = Zigalpm.OperationContext.init(std.testing.allocator, std.testing.io);
    defer parent.deinit();
    parent.cancel();

    var cleanup = independentCleanupContext(std.testing.allocator, std.testing.io);
    defer cleanup.deinit();
    try std.testing.expect(parent.isCancelled());
    try std.testing.expect(!cleanup.isCancelled());
}

test "sync deps cleanup failures are recoverable and identify every remaining package" {
    const Capture = struct {
        failures: usize = 0,
        recoverable: bool = false,
        names_present: bool = false,

        fn event(data: ?*anyopaque, value: Zigalpm.OperationEvent) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            switch (value) {
                .failure => |failure| {
                    self.failures += 1;
                    self.recoverable = failure.recoverable;
                    self.names_present = std.mem.indexOf(u8, failure.message, "direct-makedep") != null and
                        std.mem.indexOf(u8, failure.message, "transitive-dep") != null;
                },
                else => {},
            }
        }
    };

    var operation_context = Zigalpm.OperationContext.init(std.testing.allocator, std.testing.io);
    defer operation_context.deinit();
    var capture: Capture = .{};
    const subscription = try operation_context.subscribe(.{
        .function = Capture.event,
        .data = &capture,
    });
    defer _ = operation_context.unsubscribe(subscription);

    var operation = operation_context.begin(.{
        .backend = .alpm,
        .kind = .cleanup,
        .subject = "build dependencies",
    });
    const targets = [_][:0]const u8{ "direct-makedep", "transitive-dep" };
    reportCleanupFailure(
        std.testing.allocator,
        &operation,
        error.BuildDependencyCleanupIncomplete,
        &targets,
    );
    operation.finish(.failed);

    try std.testing.expectEqual(@as(usize, 1), capture.failures);
    try std.testing.expect(capture.recoverable);
    try std.testing.expect(capture.names_present);
}
