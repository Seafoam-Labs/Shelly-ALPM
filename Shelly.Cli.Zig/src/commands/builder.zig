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
const source_pgp_transport = @import("source_pgp_transport.zig");
const signals = @import("../runtime/signals.zig");

const command_path = "shelly build build";

pub const BuildCommandArtifact = struct {
    package_name: []u8,
    path: []u8,

    pub fn deinit(self: BuildCommandArtifact, allocator: std.mem.Allocator) void {
        allocator.free(self.package_name);
        allocator.free(self.path);
    }
};

pub const BuildCommandError = struct {
    code: []u8,
    message: []u8,

    pub fn deinit(self: BuildCommandError, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.message);
    }
};

pub const BuildCommandResult = struct {
    package_base: []u8,
    review_digest: ?[std.crypto.hash.sha2.Sha256.digest_length]u8,
    isolated: bool,
    artifacts: []BuildCommandArtifact,
    failure: ?BuildCommandError = null,

    pub fn deinit(self: *BuildCommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.package_base);
        for (self.artifacts) |artifact| artifact.deinit(allocator);
        allocator.free(self.artifacts);
        if (self.failure) |failure| failure.deinit(allocator);
        self.* = undefined;
    }
};

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    if (!std.mem.eql(u8, invocation.command.path, command_path)) return null;
    if (optionEnabled(invocation, "--review-only"))
        return try executeReviewOnly(context, invocation);
    if (optionEnabled(invocation, "--makesrcinfo"))
        return try executeMakeSrcinfo(context, invocation);
    if (optionEnabled(invocation, "--prepare-isolated-source-keys"))
        return try executeSourcePgpKeyPreparation(context, invocation);
    if (shouldElevateBuildCoordinator(invocation, elevation.isRoot())) {
        const elevated_arguments = try aur_url.argumentsWithEffectiveBase(context, invocation);
        defer context.allocator.free(elevated_arguments);
        if (isolatedRequested(invocation)) {
            const elevated = elevation.relaunchIfNeededCancellable(
                context,
                elevated_arguments,
                invocation.globals.json,
            ) catch |err| {
                try context.stderr.print("Unable to elevate isolated build: {t}\n", .{err});
                if (invocation.globals.json) {
                    try writeBuildJson(context.stdout, null, err, true);
                    try context.stdout.writeByte('\n');
                    try context.stdout.flush();
                }
                return exitCodeForBuildError(err);
            };
            if (elevated) |result| {
                defer result.deinit(context.allocator);
                if (invocation.globals.json)
                    return try finishElevatedJsonBuild(context, result, true);
                return result.exit_code;
            }
        } else {
            const elevated_exit = elevation.relaunchIfNeeded(context, elevated_arguments) catch |err| {
                try context.stderr.print("Unable to elevate build dependency installation: {t}\n", .{err});
                return 1;
            };
            if (elevated_exit) |exit_code| return exit_code;
        }
    }
    var runner: Real = .{};
    defer runner.deinit(context.allocator);
    if (invocation.globals.json)
        return try executeJson(context, invocation, &runner);
    return try executeWithRunner(context, invocation, &runner);
}

fn finishElevatedJsonBuild(
    context: *runtime.RuntimeContext,
    elevated: elevation.CancellableRelaunchResult,
    isolated: bool,
) !u8 {
    const output = elevated.stdout orelse "";
    const valid_json = isSingleJsonDocument(context.allocator, output);
    if (valid_json and (!elevated.cancelled or isCancellationBuildJson(context.allocator, output))) {
        try context.stdout.writeAll(output);
        if (output.len == 0 or output[output.len - 1] != '\n')
            try context.stdout.writeByte('\n');
        try context.stdout.flush();
        return elevated.exit_code;
    }

    const failure = if (elevated.cancelled) error.Cancelled else error.InvalidElevatedBuildResult;
    try writeBuildJson(context.stdout, null, failure, isolated);
    try context.stdout.writeByte('\n');
    try context.stdout.flush();
    return if (elevated.cancelled) 130 else 1;
}

fn isSingleJsonDocument(allocator: std.mem.Allocator, document: []const u8) bool {
    if (document.len == 0) return false;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch return false;
    defer parsed.deinit();
    return parsed.value == .object;
}

fn isCancellationBuildJson(allocator: std.mem.Allocator, document: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const success = parsed.value.object.get("success") orelse return false;
    if (success != .bool or success.bool) return false;
    const failure = parsed.value.object.get("error") orelse return false;
    if (failure != .object) return false;
    const code = failure.object.get("code") orelse return false;
    return code == .string and std.mem.eql(u8, code.string, "Cancelled");
}

const ReviewOnlyResult = struct {
    package_base: []u8,
    package_names: [][]u8,
    review: Zigalpm.builder.PreparedPkgbuildReview,
    dependency_plan: ?SyncDependencyPlan = null,
    // Owned by the review arena; used only by the internal key-preparation child.
    source_pgp_fingerprints: []const []const u8 = &.{},

    fn deinit(self: *ReviewOnlyResult, allocator: std.mem.Allocator) void {
        allocator.free(self.package_base);
        for (self.package_names) |name| allocator.free(name);
        allocator.free(self.package_names);
        self.review.deinit();
        if (self.dependency_plan) |*plan| plan.deinit(allocator);
        self.* = undefined;
    }
};

const CapturedReview = struct {
    parsed: std.json.Parsed(std.json.Value),
    package_base: []const u8,
    package_names: []const []const u8,
    digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,
    findings: []Zigalpm.OperationReviewFinding,
    attachments: []Zigalpm.OperationQuestionAttachment,
    reviewed_files: []Zigalpm.builder.pkgbuild_review.ReviewedFile,
    repository_dependencies: []const []const u8,
    aur_dependencies: []const []const u8,

    fn deinit(self: *CapturedReview, allocator: std.mem.Allocator) void {
        allocator.free(self.package_names);
        allocator.free(self.findings);
        allocator.free(self.attachments);
        for (self.reviewed_files) |file| allocator.free(file.contents);
        allocator.free(self.reviewed_files);
        allocator.free(self.repository_dependencies);
        allocator.free(self.aur_dependencies);
        self.parsed.deinit();
        self.* = undefined;
    }
};

const SourcePgpKeyResult = struct {
    public_keys: []const u8 = "",
    failure: ?[]const u8 = null,
};

fn sourcePgpPreparationArguments(allocator: std.mem.Allocator, invocation: *const parser.Invocation, pkgbuild_path: []const u8, digest_hex: []const u8) ![]const []const u8 {
    var arguments: std.ArrayList([]const u8) = .empty;
    defer arguments.deinit(allocator);
    try arguments.appendSlice(allocator, &.{ "build", "--prepare-isolated-source-keys", "--review-digest", digest_hex });
    if (invocation.globals.no_confirm) try arguments.append(allocator, "--no-confirm");
    for (invocation.options) |option| {
        if (std.mem.eql(u8, option.name, "--package"))
            try arguments.appendSlice(allocator, &.{ "--package", option.value orelse return error.MissingPackageName });
    }
    try arguments.append(allocator, pkgbuild_path);
    return arguments.toOwnedSlice(allocator);
}

fn captureSourcePgpKeys(context: *runtime.RuntimeContext, operation_context: *Zigalpm.OperationContext, invocation: *const parser.Invocation, pkgbuild_path: []const u8, digest: Zigalpm.builder.pkgbuild_review.Digest) ![]u8 {
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    const arguments = try sourcePgpPreparationArguments(context.allocator, invocation, pkgbuild_path, &digest_hex);
    defer context.allocator.free(arguments);
    const captured = (try elevation.runAsInvokingUserCapture(context, arguments, operation_context)) orelse return error.InvokingUserUnavailable;
    defer captured.deinit(context.allocator);
    const result = try std.json.parseFromSlice(SourcePgpKeyResult, context.allocator, captured.stdout, .{});
    defer result.deinit();
    if (result.value.failure) |failure| {
        if (std.mem.eql(u8, failure, "PgpKeyImportDeclined")) return error.PgpKeyImportDeclined;
        if (std.mem.eql(u8, failure, "ReviewedPkgbuildChanged")) return error.ReviewedPkgbuildChanged;
        if (std.mem.eql(u8, failure, "Cancelled")) return error.Cancelled;
        return error.IsolatedSourcePgpKeyPreparationFailed;
    }
    if (captured.exit_code != 0) return error.IsolatedSourcePgpKeyPreparationFailed;
    return context.allocator.dupe(u8, result.value.public_keys);
}

fn executeSourcePgpKeyPreparation(context: *runtime.RuntimeContext, invocation: *const parser.Invocation) !u8 {
    var operation_context = Zigalpm.OperationContext.init(context.allocator, context.io);
    defer operation_context.deinit();
    var cancellation_watcher: signals.CancellationWatcher = .{};
    try cancellation_watcher.start(context.io, &operation_context);
    defer cancellation_watcher.deinit();
    const stdout = context.stdout;
    context.stdout = context.stderr;
    defer context.stdout = stdout;
    var renderer = try standard_single_pane.Renderer.init(context, invocation.globals.no_confirm);
    defer renderer.deinit();
    try renderer.attach(&operation_context);
    try renderer.begin("Preparing isolated source-signing keys...");
    const keys = prepareSourcePgpKeyExport(context, invocation, &operation_context) catch |err| {
        const message = try Zigalpm.user_errors.format(context.allocator, err, .{ .operation = "source-signing key preparation" });
        defer context.allocator.free(message);
        if (!renderer.reported_failure.load(.acquire)) try renderer.reportError(message);
        try renderer.finishWithMessage(false, "Source-signing key preparation failed.");
        try std.json.Stringify.value(SourcePgpKeyResult{ .failure = @errorName(err) }, .{}, stdout);
        try stdout.writeByte('\n');
        try stdout.flush();
        return exitCodeForBuildError(err);
    };
    defer context.allocator.free(keys);
    try renderer.finishWithMessage(true, "Source-signing keys prepared.");
    try std.json.Stringify.value(SourcePgpKeyResult{ .public_keys = keys }, .{}, stdout);
    try stdout.writeByte('\n');
    try stdout.flush();
    return 0;
}

fn prepareSourcePgpKeyExport(context: *runtime.RuntimeContext, invocation: *const parser.Invocation, operation_context: *Zigalpm.OperationContext) ![]u8 {
    const expected = try parseReviewDigest(optionValue(invocation, "--review-digest") orelse return error.MissingReviewDigest);
    var result = try prepareReviewOnly(context, operation_context, invocation);
    defer result.deinit(context.allocator);
    if (!std.mem.eql(u8, &expected, &result.review.digest)) return error.ReviewedPkgbuildChanged;
    var operation = operation_context.begin(.{ .backend = .aur, .kind = .build, .subject = result.package_base });
    var completion: Zigalpm.OperationCompletionStatus = .failed;
    defer operation.finish(completion);
    ensureSourcePgpFingerprints(context, &operation, result.package_base, result.source_pgp_fingerprints) catch |err| {
        if (err == error.PgpKeyImportDeclined) {
            try context.stderr.writeAll("Source key imports require approval. Before an unattended isolated build, import the required keys as the invoking host user:\n");
            for (result.source_pgp_fingerprints) |fingerprint|
                try context.stderr.print("  shelly keyring recv --user {s}\n", .{fingerprint});
            try context.stderr.flush();
        }
        return err;
    };
    const keys = try source_pgp_transport.exportKeys(context.allocator, context.io, context.environ, result.source_pgp_fingerprints);
    completion = .success;
    return keys;
}

fn executeReviewOnly(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !u8 {
    if (!invocation.globals.json) {
        try context.stderr.writeAll("--review-only requires --json.\n");
        try context.stderr.flush();
        return 2;
    }
    if (optionEnabled(invocation, "--isolated") or
        optionEnabled(invocation, "--sync-deps") or
        optionValue(invocation, "--review-digest") != null)
    {
        try writeBuildJson(context.stdout, null, error.InvalidReviewOnlyRequest, false);
        try context.stdout.writeByte('\n');
        try context.stdout.flush();
        return 2;
    }

    var operation_context = Zigalpm.OperationContext.init(context.allocator, context.io);
    context.attachTransactionLog(&operation_context);
    defer operation_context.deinit();
    var cancellation_watcher: signals.CancellationWatcher = .{};
    try cancellation_watcher.start(context.io, &operation_context);
    defer cancellation_watcher.deinit();

    const stdout = context.stdout;
    context.stdout = context.stderr;
    defer context.stdout = stdout;
    var renderer = try standard_single_pane.Renderer.init(context, true);
    defer renderer.deinit();
    try renderer.attach(&operation_context);
    try renderer.begin("Reviewing PKGBUILD inputs...");

    var result = prepareReviewOnly(context, &operation_context, invocation) catch |err| {
        const detail = try Zigalpm.user_errors.format(context.allocator, err, .{ .operation = "the PKGBUILD review" });
        defer context.allocator.free(detail);
        try renderer.reportError(detail);
        try renderer.finishWithMessage(false, "PKGBUILD review failed.");
        context.stdout = stdout;
        try writeBuildJson(context.stdout, null, err, false);
        try context.stdout.writeByte('\n');
        try context.stdout.flush();
        context.stdout = context.stderr;
        return exitCodeForBuildError(err);
    };
    defer result.deinit(context.allocator);
    try renderer.finishWithMessage(true, "PKGBUILD review completed.");
    context.stdout = stdout;
    try writeReviewOnlyJson(context.stdout, &result);
    try context.stdout.writeByte('\n');
    try context.stdout.flush();
    context.stdout = context.stderr;
    return 0;
}

fn prepareReviewOnly(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !ReviewOnlyResult {
    var request = try parseBuildRequest(context, invocation);
    defer request.deinit(context);
    const content = try std.Io.Dir.cwd().readFileAlloc(
        context.io,
        request.pkgbuild_path,
        context.allocator,
        .limited(32 * 1024 * 1024),
    );
    defer context.allocator.free(content);
    var static_review = try Zigalpm.builder.preparePkgbuildReview(
        context.allocator,
        context.io,
        request.build_directory,
        content,
        request.package_builds,
    );
    defer static_review.deinit();
    const requested_names = try context.allocator.alloc([]const u8, request.package_builds.len);
    defer context.allocator.free(requested_names);
    for (request.package_builds, requested_names) |package_build, *name|
        name.* = package_build.pkg_name orelse return error.MissingPackageName;

    var operation = operation_context.begin(.{
        .backend = .aur,
        .kind = .build,
        .subject = request.pkgbuild_path,
    });
    var completion: Zigalpm.OperationCompletionStatus = .failed;
    defer operation.finish(completion);
    const builder = try PackageBuilder.init(
        context.allocator,
        request.package_builds,
        operation_context,
        request.shellybuild.*,
        requested_names,
        .{
            .start_directory = request.build_directory,
            .work_directory = request.build_directory,
            .package_destination = request.package_destination,
            .source_destination = request.build_directory,
            .log_destination = request.build_directory,
            .pkgbuild_path = request.pkgbuild_path,
            .clean_after_success = true,
            .overwrite = false,
            .run_check = false,
            .run_verify = false,
            .reviewed_pkgbuild_digest = static_review.digest,
            .install_scripts = static_review.install_scripts,
            .reviewed_files = static_review.reviewed_files,
            .build_all_members = !hasPackageSelection(invocation),
        },
        context.environ,
        context.io,
    );
    defer builder.deinit();
    var final_review = try builder.prepareFinalReviewWithOperation(&operation);
    errdefer final_review.deinit();
    try final_review.verifyCurrent(
        context.allocator,
        context.io,
        request.pkgbuild_path,
        request.build_directory,
    );
    var dependency_plan: ?SyncDependencyPlan = null;
    errdefer if (dependency_plan) |*plan| plan.deinit(context.allocator);
    if (optionEnabled(invocation, "--review-dependencies")) {
        var repositories = try ReviewRepositories.init(
            context,
            operation_context,
            optionEnabled(invocation, "--review-host-dependencies"),
            null,
        );
        defer repositories.deinit(context);
        const manager = repositories.manager;
        if (optionEnabled(invocation, "--review-host-dependencies")) {
            var resolver_context: AlpmResolverContext = .{ .manager = manager };
            dependency_plan = try resolveSyncDependencies(
                context.allocator,
                builder.package_builds,
                request.no_check,
                resolver_context.backend(),
            );
        } else {
            var resolver_context: IsolatedResolverContext = .{ .manager = manager };
            dependency_plan = try resolveSyncDependencies(
                context.allocator,
                builder.package_builds,
                request.no_check,
                resolver_context.backend(),
            );
        }
    }
    const package_names = try context.allocator.alloc([]u8, builder.package_builds.len);
    var copied_names: usize = 0;
    errdefer {
        for (package_names[0..copied_names]) |name| context.allocator.free(name);
        context.allocator.free(package_names);
    }
    for (builder.package_builds, package_names) |package_build, *name| {
        name.* = try context.allocator.dupe(
            u8,
            package_build.pkg_name orelse return error.MissingPackageName,
        );
        copied_names += 1;
    }
    const package_base_value = builder.package_builds[0].variables.get("pkgbase") orelse
        builder.package_builds[0].pkg_name orelse return error.MissingPackageName;
    const package_base = try context.allocator.dupe(u8, package_base_value);
    errdefer context.allocator.free(package_base);
    const review_allocator = final_review.arena.allocator();
    var source_pgp_fingerprints: std.ArrayList([]const u8) = .empty;
    for (builder.package_builds) |package_build| {
        for (package_build.valid_pgp_keys orelse &.{}) |fingerprint| {
            if (!containsString(source_pgp_fingerprints.items, fingerprint))
                try source_pgp_fingerprints.append(review_allocator, try review_allocator.dupe(u8, fingerprint));
        }
    }
    completion = .success;
    return .{
        .package_base = package_base,
        .package_names = package_names,
        .review = final_review,
        .dependency_plan = dependency_plan,
        .source_pgp_fingerprints = try source_pgp_fingerprints.toOwnedSlice(review_allocator),
    };
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

fn executeJson(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: anytype,
) !u8 {
    var operation_context = Zigalpm.OperationContext.init(context.allocator, context.io);
    context.attachTransactionLog(&operation_context);
    defer operation_context.deinit();

    // Reuse the normal event and question lifecycle, but point it at stderr
    // for the whole operation. This includes status events produced from
    // pacman, shellystrap, systemd tools, and nspawn streaming callbacks.
    const stdout = context.stdout;
    context.stdout = context.stderr;
    defer context.stdout = stdout;
    var renderer = try standard_single_pane.Renderer.init(context, invocation.globals.no_confirm);
    defer renderer.deinit();
    try renderer.attach(&operation_context);
    try renderer.begin("Preparing PKGBUILD...");

    runner.run(context, &operation_context, invocation) catch |err| {
        if (err == error.Cancelled) {
            try renderer.finishCancelled();
        } else {
            const detail = try Zigalpm.user_errors.format(context.allocator, err, .{ .operation = "the package build" });
            defer context.allocator.free(detail);
            if (!renderer.reported_failure.load(.acquire)) try renderer.reportError(detail);
            try renderer.finishWithMessage(false, "Build failed.");
        }
        context.stdout = stdout;
        if (runner.child_json) |document| {
            try context.stdout.writeAll(document);
            if (document.len == 0 or document[document.len - 1] != '\n')
                try context.stdout.writeByte('\n');
            try context.stdout.flush();
            context.stdout = context.stderr;
            return runner.child_exit_code;
        }
        try runner.setFailure(context.allocator, err);
        try writeBuildJson(context.stdout, runner.result, err, isolatedRequested(invocation));
        try context.stdout.writeByte('\n');
        try context.stdout.flush();
        context.stdout = context.stderr;
        return exitCodeForBuildError(err);
    };
    try renderer.finishWithMessage(true, "Build completed.");
    context.stdout = stdout;
    if (runner.child_json) |document| {
        try context.stdout.writeAll(document);
        if (document.len == 0 or document[document.len - 1] != '\n')
            try context.stdout.writeByte('\n');
        try context.stdout.flush();
        context.stdout = context.stderr;
        return runner.child_exit_code;
    }
    try writeBuildJson(context.stdout, runner.result, null, isolatedRequested(invocation));
    try context.stdout.writeByte('\n');
    try context.stdout.flush();
    context.stdout = context.stderr;
    return 0;
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
        try ensureConfiguredWorkDirectory(context.io, ephemeral_work_directory, work_directory);
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
                .review_digest_is_automation = reviewed_digest != null,
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
    result: ?BuildCommandResult = null,
    child_json: ?[]u8 = null,
    child_exit_code: u8 = 0,

    fn deinit(self: *Real, allocator: std.mem.Allocator) void {
        if (self.result) |*result| result.deinit(allocator);
        if (self.child_json) |document| allocator.free(document);
        self.result = null;
        self.child_json = null;
    }

    fn ownResult(
        self: *Real,
        allocator: std.mem.Allocator,
        package_base: []const u8,
        review_digest: ?[std.crypto.hash.sha2.Sha256.digest_length]u8,
        isolated: bool,
        artifacts: anytype,
    ) !void {
        if (self.result) |*previous| previous.deinit(allocator);
        self.result = null;
        const owned = try allocator.alloc(BuildCommandArtifact, artifacts.len);
        var count: usize = 0;
        errdefer {
            for (owned[0..count]) |artifact| artifact.deinit(allocator);
            allocator.free(owned);
        }
        for (artifacts, owned) |artifact, *destination| {
            const package_name = try allocator.dupe(u8, artifact.package_name);
            errdefer allocator.free(package_name);
            const path = try allocator.dupe(u8, artifact.path);
            destination.* = .{ .package_name = package_name, .path = path };
            count += 1;
        }
        self.result = .{
            .package_base = try allocator.dupe(u8, package_base),
            .review_digest = review_digest,
            .isolated = isolated,
            .artifacts = owned,
            .failure = null,
        };
    }

    fn setFailure(self: *Real, allocator: std.mem.Allocator, err: anyerror) !void {
        const result = if (self.result) |*value| value else return;
        if (result.failure) |failure| failure.deinit(allocator);
        result.failure = null;
        const code = try allocator.dupe(u8, @errorName(err));
        errdefer allocator.free(code);
        result.failure = .{
            .code = code,
            .message = try allocator.dupe(u8, buildErrorMessage(err)),
        };
    }

    fn setPendingResult(
        self: *Real,
        allocator: std.mem.Allocator,
        package_base: []const u8,
        review_digest: ?[std.crypto.hash.sha2.Sha256.digest_length]u8,
        isolated: bool,
    ) !void {
        return self.ownResult(
            allocator,
            package_base,
            review_digest,
            isolated,
            @as([]const BuildCommandArtifact, &.{}),
        );
    }

    pub fn run(
        self: *Real,
        context: *runtime.RuntimeContext,
        operation_context: *Zigalpm.OperationContext,
        invocation: *const parser.Invocation,
    ) !void {
        var cancellation_watcher: signals.CancellationWatcher = .{};
        try cancellation_watcher.start(context.io, operation_context);
        defer cancellation_watcher.deinit();

        if (isolatedRequested(invocation)) {
            const result = try runIsolatedCoordinator(self, context, operation_context, invocation);
            if (self.result) |*pending| pending.deinit(context.allocator);
            self.result = result;
            return;
        }
        if (syncDepsRequested(invocation))
            return runSyncDepsCoordinator(self, context, operation_context, invocation);

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
        const initial_package_base = try packageBaseFromBuilds(package_builds);
        try self.setPendingResult(context.allocator, initial_package_base, null, false);
        const coordinator_child = optionEnabled(invocation, "--coordinator-child");
        const supplied_digest = if (optionValue(invocation, "--review-digest")) |encoded|
            try parseReviewDigest(encoded)
        else if (coordinator_child)
            return error.MissingReviewDigest
        else
            null;

        var review = try Zigalpm.builder.preparePkgbuildReview(
            context.allocator,
            context.io,
            build_directory,
            pkgbuild_content,
            package_builds,
        );
        defer review.deinit();
        const package_destination = if (optionValue(invocation, "--package-destination")) |path| blk: {
            try validatePackageDestination(path);
            break :blk path;
        } else shellybuild.destinations.packages orelse build_directory;
        const work_directory = if (shellybuild.destinations.build) |build_root|
            try Zigalpm.builder.uniqueWorkDirectory(
                context.allocator,
                context.io,
                build_root,
                initial_package_base,
            )
        else
            try context.allocator.dupe(u8, build_directory);
        defer context.allocator.free(work_directory);
        const ephemeral_work_directory = shellybuild.destinations.build != null;
        try ensureConfiguredWorkDirectory(context.io, ephemeral_work_directory, work_directory);

        const builder = try PackageBuilder.init(
            context.allocator,
            package_builds,
            operation_context,
            shellybuild.*,
            requested_names.items,
            .{
                .start_directory = build_directory,
                .work_directory = work_directory,
                .package_destination = package_destination,
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
                .reviewed_pkgbuild_digest = review.digest,
                .review_digest_is_automation = supplied_digest != null,
                .install_scripts = review.install_scripts,
                .reviewed_files = review.reviewed_files,
                .build_all_members = build_all_members,
                .sources_prepared = false,
            },
            context.environ,
            context.io,
        );
        defer builder.deinit();
        var final_review = try builder.prepareFinalReviewWithOperation(&operation);
        defer final_review.deinit();
        const package_base = try packageBaseFromBuilds(builder.package_builds);
        try self.setPendingResult(context.allocator, package_base, null, false);
        const expected_digest = if (supplied_digest) |digest| digest: {
            if (!std.mem.eql(u8, &digest, &final_review.digest))
                return error.ReviewedPkgbuildChanged;
            break :digest digest;
        } else final_review.digest;

        if (!coordinator_child and supplied_digest == null and !optionEnabled(invocation, "--reviewed")) {
            var answer = try operation.ask(.{
                .kind = .review_changes,
                .prompt = "Build packages from this PKGBUILD?",
                .review = .{
                    .subject = pkgbuild_path,
                    .findings = final_review.findings,
                    .old_content = "",
                    .new_content = pkgbuild_content,
                    .related_files = final_review.related_files,
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

        try final_review.verifyCurrent(
            context.allocator,
            context.io,
            pkgbuild_path,
            build_directory,
        );

        self.result.?.review_digest = expected_digest;
        if (!optionEnabled(invocation, "--skip-source-pgp-verification")) {
            if (coordinator_child and optionEnabled(invocation, "--isolated-source-keys"))
                try source_pgp_transport.importKeys(context.allocator, context.io, context.environ, isolated_build.guest_source_keys);
            try ensureSourcePgpKeys(context, &operation, package_base, builder.package_builds);
        }
        builder.options.reviewed_pkgbuild_digest = expected_digest;
        builder.options.pkgbuild_sha256sum = final_review.pkgbuild_digest;
        builder.options.install_scripts = final_review.install_scripts;
        builder.options.reviewed_files = final_review.reviewed_files;
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
        try self.ownResult(
            context.allocator,
            package_base,
            expected_digest,
            false,
            artifacts,
        );
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
        return source_pgp_transport.containsKey(self.runtime_context.allocator, self.runtime_context.io, self.runtime_context.environ, fingerprint);
    }

    fn receive(data: ?*anyopaque, fingerprint: []const u8) !bool {
        const self: *@This() = @ptrCast(@alignCast(data.?));
        var environment = try self.runtime_context.environ.createMap(self.runtime_context.allocator);
        defer environment.deinit();
        var child = try std.process.spawn(self.runtime_context.io, .{
            .argv = &.{
                self.executable,
                "keyring",
                "recv",
                "--user",
                "--no-confirm",
                fingerprint,
            },
            .environ_map = &environment,
            .stdin = .inherit,
            .stdout = if (self.runtime_context.stdout == self.runtime_context.stderr) .ignore else .inherit,
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

    try ensureSourcePgpFingerprints(context, operation, package_name, fingerprints.items);
}

fn ensureSourcePgpFingerprints(
    context: *runtime.RuntimeContext,
    operation: *const Zigalpm.Operation,
    package_name: []const u8,
    fingerprints: []const []const u8,
) !void {
    if (fingerprints.len == 0) return;

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
        fingerprints,
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
    /// Host-side output selected after configuration is loaded. The command
    /// line value borrows invocation storage; configured values borrow the
    /// ShellyBuildConfiguration arena.
    package_destination: []const u8,

    fn deinit(self: *BuildRequest, context: *runtime.RuntimeContext) void {
        for (self.package_builds[0..self.parsed_count]) |*pkgbuild|
            pkgbuild.deinit(context.allocator);
        context.allocator.free(self.package_builds);
        self.shellybuild.deinit();
        context.allocator.free(self.pkgbuild_path);
        self.* = undefined;
    }
};

fn packageBaseFromBuilds(
    package_builds: []const Zigalpm.pkgbuild.parser.Pkgbuild,
) ![]const u8 {
    if (package_builds.len == 0) return error.MissingPackageName;
    return package_builds[0].variables.get("pkgbase") orelse
        package_builds[0].pkg_name orelse error.MissingPackageName;
}

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

    const package_destination = if (optionValue(invocation, "--package-destination")) |path| blk: {
        try validatePackageDestination(path);
        break :blk path;
    } else shellybuild.destinations.packages orelse build_directory;

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
        .package_destination = package_destination,
    };
}

/// Root-only coordinator for the nspawn backend. It reviews the host input,
/// stages the reviewed snapshots, provisions an operation-scoped guest, and
/// then runs the ordinary Shelly builder as the fixed unprivileged guest.
fn runIsolatedCoordinator(
    runner: *Real,
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !BuildCommandResult {
    if (!elevation.isRoot()) return error.ElevationRequired;
    var request = try parseBuildRequest(context, invocation);
    defer request.deinit(context);
    try runner.setPendingResult(
        context.allocator,
        try packageBaseFromBuilds(request.package_builds),
        null,
        true,
    );
    const invoking_ids = (try elevation.invokingUserIds(context)) orelse
        return error.InvokingUserUnavailable;
    if (optionEnabled(invocation, "--sign") and !optionEnabled(invocation, "--nosign"))
        return error.IsolatedSigningUnsupported;
    // Isolated export deliberately never creates the host job directory. Its
    // existence is part of the caller's ownership boundary and is verified
    // before the expensive root provisioning begins.
    var host_destination = try std.Io.Dir.cwd().openDir(context.io, request.package_destination, .{});
    host_destination.close(context.io);
    if (request.shellybuild.package.sign and !optionEnabled(invocation, "--nosign"))
        return error.IsolatedSigningUnsupported;

    var operation = operation_context.begin(.{
        .backend = .aur,
        .kind = .build,
        .subject = request.pkgbuild_path,
    });
    var completion: Zigalpm.OperationCompletionStatus = .failed;
    defer operation.finish(completion);

    var review = try captureCoordinatorReview(
        context,
        operation_context,
        invocation,
        request.pkgbuild_path,
        .isolated,
    );
    defer review.deinit(context.allocator);
    try runner.setPendingResult(context.allocator, review.package_base, null, true);
    const pkgbuild_content = try std.Io.Dir.cwd().readFileAlloc(
        context.io,
        request.pkgbuild_path,
        context.allocator,
        .limited(32 * 1024 * 1024),
    );
    defer context.allocator.free(pkgbuild_content);
    const current_digest = Zigalpm.builder.pkgbuild_review.digestPreparedReview(
        pkgbuild_content,
        review.reviewed_files,
    );
    if (!std.mem.eql(u8, &current_digest, &review.digest))
        return error.ReviewedPkgbuildChanged;
    const supplied_digest = if (optionValue(invocation, "--review-digest")) |encoded|
        try parseReviewDigest(encoded)
    else
        null;
    if (supplied_digest) |digest|
        if (!std.mem.eql(u8, &digest, &review.digest))
            return error.ReviewedPkgbuildChanged;
    runner.result.?.review_digest = review.digest;

    if (supplied_digest == null and !optionEnabled(invocation, "--reviewed")) {
        var answer = try operation.ask(.{
            .kind = .review_changes,
            .prompt = "Build packages in a systemd-nspawn isolated root?",
            .review = .{
                .subject = request.pkgbuild_path,
                .findings = review.findings,
                .old_content = "",
                .new_content = pkgbuild_content,
                .related_files = review.attachments,
            },
            .default_response = if (review.findings.len == 0) .accepted else .declined,
        });
        defer answer.deinit(context.allocator);
        if (answer.response != .accepted) {
            completion = .cancelled;
            return error.Cancelled;
        }
    }

    var bootstrap_packages: std.ArrayList([]const u8) = .empty;
    defer bootstrap_packages.deinit(context.allocator);
    if (optionEnabled(invocation, "--sync-deps")) {
        if (review.aur_dependencies.len != 0) {
            for (review.aur_dependencies) |name|
                operation.status(.warning, name, "build.isolation.aur-dependency", null);
            return error.IsolatedAurDependencyUnsupported;
        }
        try bootstrap_packages.appendSlice(context.allocator, review.repository_dependencies);
    }

    const source_keys = if (optionEnabled(invocation, "--skip-source-pgp-verification"))
        try context.allocator.dupe(u8, "")
    else
        try captureSourcePgpKeys(context, operation_context, invocation, request.pkgbuild_path, review.digest);
    defer context.allocator.free(source_keys);

    var root = try isolated_build.Root.create(context.allocator, context.io);
    defer root.deinit();
    const executable_allocated = try std.process.executablePathAlloc(context.io, context.allocator);
    defer context.allocator.free(executable_allocated);
    const executable = std.mem.trimEnd(u8, executable_allocated, " (deleted)");
    operation.status(.information, "Provisioning clean build root", "build.isolation.provision", null);
    try root.bootstrap(context.environ, executable, bootstrap_packages.items, &operation);
    try root.stageReviewedInputs(context.environ, pkgbuild_content, review.reviewed_files, &operation);

    try root.stageExecutable(executable);
    if (source_keys.len != 0) try root.stageSourcePgpKeys(source_keys);

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
        source_keys.len != 0,
    );
    defer context.allocator.free(child_arguments);
    operation.status(.information, "Running unprivileged nspawn build", "build.isolation.execute", null);
    try root.run(context.environ, child_arguments, &operation);

    const expected_names = review.package_names;
    const validated_artifacts = try validateIsolatedArtifacts(context, root.artifact_path, expected_names);
    defer isolated_build.deinitValidatedArtifacts(context.allocator, validated_artifacts);

    const destination = request.package_destination;
    const exported_artifacts = try root.exportArtifacts(
        destination,
        validated_artifacts,
        !optionEnabled(invocation, "--no-overwrite"),
        invoking_ids.uid,
        invoking_ids.gid,
    );
    defer isolated_build.deinitExportedArtifacts(context.allocator, exported_artifacts);
    const message = try std.fmt.allocPrint(
        context.allocator,
        "Exported {d} isolated build artifact{s} to {s}",
        .{ exported_artifacts.len, if (exported_artifacts.len == 1) "" else "s", destination },
    );
    defer context.allocator.free(message);
    operation.status(.success, message, "build.isolation.artifacts", null);
    root.succeeded = true;
    completion = .success;
    const command_artifacts = try context.allocator.alloc(BuildCommandArtifact, exported_artifacts.len);
    var command_count: usize = 0;
    errdefer {
        for (command_artifacts[0..command_count]) |artifact| artifact.deinit(context.allocator);
        context.allocator.free(command_artifacts);
    }
    for (exported_artifacts, command_artifacts) |artifact, *command_artifact| {
        const package_name = try context.allocator.dupe(u8, artifact.package_name);
        errdefer context.allocator.free(package_name);
        const path = try context.allocator.dupe(u8, artifact.path);
        command_artifact.* = .{ .package_name = package_name, .path = path };
        command_count += 1;
    }
    return .{
        .package_base = try context.allocator.dupe(u8, review.package_base),
        .review_digest = review.digest,
        .isolated = true,
        .artifacts = command_artifacts,
    };
}

fn validateIsolatedArtifacts(
    context: *runtime.RuntimeContext,
    artifact_directory: []const u8,
    expected_names: []const []const u8,
) ![]isolated_build.ValidatedArtifact {
    const bindings = Zigalpm.alpm.bindings.libalpm;
    const raw = bindings.alpm;
    var alpm_error: raw.alpm_errno_t = 0;
    const handle = raw.alpm_initialize("/", "/var/lib/pacman", &alpm_error) orelse
        return error.ArtifactValidationFailed;
    defer _ = raw.alpm_release(handle);

    const found = try context.allocator.alloc(bool, expected_names.len);
    defer context.allocator.free(found);
    @memset(found, false);
    var validated: std.ArrayList(isolated_build.ValidatedArtifact) = .empty;
    errdefer {
        for (validated.items) |artifact| artifact.deinit(context.allocator);
        validated.deinit(context.allocator);
    }
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
        const owned_name = try context.allocator.dupe(u8, package_name);
        errdefer context.allocator.free(owned_name);
        const owned_filename = try context.allocator.dupe(u8, entry.name);
        errdefer context.allocator.free(owned_filename);
        try validated.append(context.allocator, .{
            .package_name = owned_name,
            .filename = owned_filename,
        });
    }
    for (found) |was_found| if (!was_found) return error.MissingBuildArtifact;
    return validated.toOwnedSlice(context.allocator);
}

fn buildIsolatedChildArguments(
    allocator: std.mem.Allocator,
    arguments: []const []const u8,
    original_positional: ?[]const u8,
    digest_hex: []const u8,
    has_source_keys: bool,
) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    defer result.deinit(allocator);
    var positional_index: ?usize = null;
    if (original_positional) |positional| {
        for (arguments, 0..) |argument, index| {
            if (std.mem.eql(u8, argument, positional)) positional_index = index;
        }
    }
    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        if (std.mem.eql(u8, argument, "--isolated") or
            std.mem.eql(u8, argument, "-i") or
            std.mem.eql(u8, argument, "--sync-deps") or
            std.mem.eql(u8, argument, "-s") or
            std.mem.eql(u8, argument, "--json") or
            std.mem.startsWith(u8, argument, "--json=") or
            std.mem.eql(u8, argument, "-j") or
            std.mem.eql(u8, argument, "--")) continue;
        if (std.mem.eql(u8, argument, "--package-destination")) {
            if (index + 1 >= arguments.len) return error.MissingPackageDestination;
            index += 1;
            continue;
        }
        if (std.mem.startsWith(u8, argument, "--package-destination=")) continue;
        if (positional_index != null and positional_index.? == index) continue;
        try result.append(allocator, argument);
    }
    if (has_source_keys) try result.append(allocator, "--isolated-source-keys");
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
    runner: *Real,
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !void {
    var request = try parseBuildRequest(context, invocation);
    defer request.deinit(context);
    try runner.setPendingResult(
        context.allocator,
        try packageBaseFromBuilds(request.package_builds),
        null,
        false,
    );
    if (!elevation.isRoot()) {
        try context.stderr.print(
            "Cannot install build dependencies without elevated privileges.\n",
            .{},
        );
        return error.ElevationRequired;
    }

    const supplied_digest = if (optionValue(invocation, "--review-digest")) |encoded|
        try parseReviewDigest(encoded)
    else
        null;
    var coordinator_review: ?CapturedReview = null;
    defer if (coordinator_review) |*review| review.deinit(context.allocator);
    if (supplied_digest) |digest| {
        coordinator_review = try captureCoordinatorReview(
            context,
            operation_context,
            invocation,
            request.pkgbuild_path,
            .host,
        );
        const review = &coordinator_review.?;
        try acceptAutomationReview(
            runner,
            context.allocator,
            review.package_base,
            review.digest,
            digest,
            false,
        );
    }

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

    var plan = if (coordinator_review) |*review|
        try dependencyPlanFromReview(
            context.allocator,
            review.repository_dependencies,
            review.aur_dependencies,
        )
    else
        try resolveSyncDependencies(
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
    if (invocation.globals.json) {
        const captured = (try elevation.runAsInvokingUserCapture(context, child_arguments, operation_context)) orelse {
            try context.stderr.print(
                "Cannot run the build as the invoking user; --sync-deps must start from a regular user session.\n",
                .{},
            );
            return error.InvokingUserUnavailable;
        };
        runner.child_json = captured.stdout;
        runner.child_exit_code = captured.exit_code;
        if (captured.exit_code != 0) return error.BuildFailed;
        return;
    }
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

fn acceptAutomationReview(
    runner: *Real,
    allocator: std.mem.Allocator,
    package_base: []const u8,
    reviewed_digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,
    supplied_digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,
    isolated: bool,
) !void {
    // Keep the digest null until every reviewed input has matched. This makes
    // failure JSON distinguish an accepted review from a rejected request.
    try runner.setPendingResult(allocator, package_base, null, isolated);
    if (!std.mem.eql(u8, &supplied_digest, &reviewed_digest))
        return error.ReviewedPkgbuildChanged;
    runner.result.?.review_digest = supplied_digest;
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

/// Isolated dependency review must see newly published repository packages
/// before the coordinator decides whether provisioning can proceed. Keep its
/// refresh private: updating the host sync database here would affect later
/// host transactions, and using its local database would hide guest needs.
const ReviewRepositories = struct {
    manager: *Zigalpm.AlpmManager,
    database_path: ?[]u8,

    fn init(
        context: *runtime.RuntimeContext,
        operation_context: ?*Zigalpm.OperationContext,
        host_dependencies: bool,
        config_path: ?[]const u8,
    ) !ReviewRepositories {
        var database_path: ?[]u8 = null;
        errdefer if (database_path) |path| {
            std.Io.Dir.cwd().deleteTree(context.io, path) catch {};
            context.allocator.free(path);
        };
        if (!host_dependencies) {
            var random: [16]u8 = undefined;
            context.io.random(&random);
            const suffix = std.fmt.bytesToHex(random, .lower);
            const path = try std.fmt.allocPrint(context.allocator, "/tmp/shelly-build-review-{s}", .{suffix});
            errdefer context.allocator.free(path);
            try std.Io.Dir.cwd().createDir(context.io, path, .fromMode(0o700));
            database_path = path;
        }
        const log_path = if (database_path) |path|
            try std.fs.path.join(context.allocator, &.{ path, "alpm.log" })
        else
            null;
        defer if (log_path) |path| context.allocator.free(path);
        const manager = try Zigalpm.AlpmManager.init(context.allocator, context.environ, .{
            .config_path = config_path,
            .use_root = false,
            .operation_context = operation_context,
            .database_path = database_path,
            .log_file = log_path,
        });
        errdefer manager.deinit();
        // Like an unprivileged upgrade preview, defer signature enforcement
        // to the provisioning transaction, which uses the host trust policy.
        if (database_path != null) try manager.sync_for_update_check(false);
        return .{ .manager = manager, .database_path = database_path };
    }

    fn deinit(self: *ReviewRepositories, context: *runtime.RuntimeContext) void {
        self.manager.deinit();
        if (self.database_path) |path| {
            std.Io.Dir.cwd().deleteTree(context.io, path) catch {};
            context.allocator.free(path);
        }
        self.* = undefined;
    }
};

/// An isolated root starts with no host packages. Repository metadata is
/// freshly synchronized, but the host local database must not suppress a
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

fn dependencyPlanFromReview(
    allocator: std.mem.Allocator,
    repository_dependencies: []const []const u8,
    aur_dependencies: []const []const u8,
) !SyncDependencyPlan {
    const repo = try allocator.alloc(
        Zigalpm.aur.dependency_resolver.RepoDependency,
        repository_dependencies.len,
    );
    var repo_count: usize = 0;
    errdefer {
        for (repo[0..repo_count]) |dependency| allocator.free(dependency.name);
        allocator.free(repo);
    }
    for (repository_dependencies, repo) |name, *dependency| {
        dependency.* = .{
            .name = try allocator.dupe(u8, name),
            // Roles have already influenced dependency selection during the
            // reviewed evaluation. The coordinator only needs names for its
            // all-dependencies transaction and delta-based cleanup.
            .role = .runtime,
        };
        repo_count += 1;
    }

    const aur = try allocator.alloc([]u8, aur_dependencies.len);
    var aur_count: usize = 0;
    errdefer {
        for (aur[0..aur_count]) |name| allocator.free(name);
        allocator.free(aur);
    }
    for (aur_dependencies, aur) |name, *owned_name| {
        owned_name.* = try allocator.dupe(u8, name);
        aur_count += 1;
    }
    return .{ .repo_dependencies = repo, .aur_dependencies = aur };
}

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

fn validatePackageDestination(path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) return error.PackageDestinationMustBeAbsolute;
}

/// Final review writes capture files before PackageBuilder.runWithOperation
/// performs its normal directory validation. Create only unique configured
/// work directories here; the builder retains ownership of src/pkg cleanup so
/// --keep-workdirs and failure diagnostics keep their established semantics.
fn ensureConfiguredWorkDirectory(
    io: std.Io,
    configured_build_root: bool,
    work_directory: []const u8,
) !void {
    if (configured_build_root)
        try std.Io.Dir.cwd().createDirPath(io, work_directory);
}

fn exitCodeForBuildError(err: anyerror) u8 {
    if (err == error.Cancelled) return 130;
    return switch (err) {
        error.InvalidReviewDigest,
        error.MissingReviewDigest,
        error.PackageDestinationMustBeAbsolute,
        error.MissingPackageDestination,
        error.ReviewOnlyRequiresJson,
        error.InvalidPkgbuildPath,
        error.MissingPackageName,
        => 2,
        else => 1,
    };
}

fn buildErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.ReviewedPkgbuildChanged => "The reviewed PKGBUILD inputs changed.",
        error.InvalidReviewDigest => "The review digest must be 64 hexadecimal characters.",
        error.MissingReviewDigest => "The coordinator build is missing its review digest.",
        error.PackageDestinationMustBeAbsolute => "The package destination must be an absolute path.",
        error.MissingPackageDestination => "The package destination option requires a directory.",
        error.Cancelled => "The build was cancelled.",
        else => @errorName(err),
    };
}

fn writeBuildJson(
    writer: *std.Io.Writer,
    result: ?BuildCommandResult,
    failure: ?anyerror,
    isolated_hint: bool,
) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    try json.objectField("schemaVersion");
    try json.write(1);
    try json.objectField("success");
    try json.write(failure == null);
    try json.objectField("packageBase");
    if (result) |value| try json.write(value.package_base) else try json.write(null);
    try json.objectField("reviewDigest");
    if (result) |value| {
        if (value.review_digest) |digest| {
            const encoded = std.fmt.bytesToHex(digest, .lower);
            try json.write(&encoded);
        } else try json.write(null);
    } else try json.write(null);
    try json.objectField("isolated");
    try json.write(if (result) |value| value.isolated else isolated_hint);
    try json.objectField("artifacts");
    try json.beginArray();
    if (failure == null) if (result) |value| {
        for (value.artifacts) |artifact| {
            try json.beginObject();
            try json.objectField("packageName");
            try json.write(artifact.package_name);
            try json.objectField("path");
            try json.write(artifact.path);
            try json.endObject();
        }
    };
    try json.endArray();
    try json.objectField("error");
    if (failure) |err| {
        const stored = if (result) |value| value.failure else null;
        try json.beginObject();
        try json.objectField("code");
        try json.write(if (stored) |value| value.code else @errorName(err));
        try json.objectField("message");
        try json.write(if (stored) |value| value.message else buildErrorMessage(err));
        try json.endObject();
    } else try json.write(null);
    try json.endObject();
}

fn writeReviewOnlyJson(writer: *std.Io.Writer, result: *ReviewOnlyResult) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    try json.objectField("schemaVersion");
    try json.write(1);
    try json.objectField("packageBase");
    try json.write(result.package_base);
    try json.objectField("packageNames");
    try json.write(result.package_names);
    try json.objectField("reviewDigest");
    const digest = std.fmt.bytesToHex(result.review.digest, .lower);
    try json.write(&digest);
    try json.objectField("findings");
    try json.beginArray();
    for (result.review.findings) |finding| {
        try json.beginObject();
        try json.objectField("tool");
        try json.write(finding.tool);
        try json.objectField("severity");
        try json.write(@tagName(finding.severity));
        try json.objectField("hook");
        try json.write(finding.hook);
        try json.objectField("matchedLine");
        try json.write(finding.matched_line);
        try json.objectField("message");
        try json.write(finding.message);
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("relatedFiles");
    try json.beginArray();
    for (result.review.reviewed_files) |file| {
        try json.beginObject();
        try json.objectField("name");
        try json.write(file.name);
        try json.objectField("permissions");
        try json.write(file.permissions);
        const is_text = std.unicode.utf8ValidateSlice(file.contents);
        try json.objectField("content");
        try json.write(if (is_text)
            file.contents
        else
            "Binary reviewed file; exact bytes are available in contentBase64.");
        if (!is_text) {
            try json.objectField("contentBase64");
            const encoded_size = std.base64.standard.Encoder.calcSize(file.contents.len);
            const encoded = try result.review.arena.allocator().alloc(u8, encoded_size);
            defer result.review.arena.allocator().free(encoded);
            _ = std.base64.standard.Encoder.encode(encoded, file.contents);
            try json.write(encoded);
        }
        try json.endObject();
    }
    try json.endArray();
    if (result.dependency_plan) |plan| {
        try json.objectField("repositoryDependencies");
        try json.beginArray();
        for (plan.repo_dependencies) |dependency| try json.write(dependency.name);
        try json.endArray();
        try json.objectField("aurDependencies");
        try json.write(plan.aur_dependencies);
    }
    try json.endObject();
}

const CoordinatorReviewDependencyMode = enum {
    host,
    isolated,
};

fn coordinatorReviewArguments(
    allocator: std.mem.Allocator,
    invocation: *const parser.Invocation,
    pkgbuild_path: []const u8,
    dependency_mode: CoordinatorReviewDependencyMode,
) ![]const []const u8 {
    var arguments: std.ArrayList([]const u8) = .empty;
    defer arguments.deinit(allocator);
    try arguments.appendSlice(allocator, &.{ "build", "--review-only", "--review-dependencies", "--json", "--no-confirm" });
    if (dependency_mode == .host)
        try arguments.append(allocator, "--review-host-dependencies");
    for (invocation.options) |option| {
        if (!std.mem.eql(u8, option.name, "--package")) continue;
        try arguments.append(allocator, "--package");
        try arguments.append(allocator, option.value orelse return error.MissingPackageName);
    }
    try arguments.append(allocator, pkgbuild_path);
    return arguments.toOwnedSlice(allocator);
}

fn captureCoordinatorReview(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
    pkgbuild_path: []const u8,
    dependency_mode: CoordinatorReviewDependencyMode,
) !CapturedReview {
    const arguments = try coordinatorReviewArguments(
        context.allocator,
        invocation,
        pkgbuild_path,
        dependency_mode,
    );
    defer context.allocator.free(arguments);
    const captured = (try elevation.runAsInvokingUserCapture(context, arguments, operation_context)) orelse
        return error.InvokingUserUnavailable;
    defer captured.deinit(context.allocator);
    if (captured.exit_code != 0) return error.PkgbuildReviewFailed;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        context.allocator,
        captured.stdout,
        .{},
    );
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidReviewResult;
    const object = parsed.value.object;
    const package_base = jsonString(object, "packageBase") orelse return error.InvalidReviewResult;
    const digest_text = jsonString(object, "reviewDigest") orelse return error.InvalidReviewResult;
    const digest = try parseReviewDigest(digest_text);
    const names_value = object.get("packageNames") orelse return error.InvalidReviewResult;
    if (names_value != .array) return error.InvalidReviewResult;
    const package_names = try context.allocator.alloc([]const u8, names_value.array.items.len);
    errdefer context.allocator.free(package_names);
    for (names_value.array.items, package_names) |value, *name| {
        if (value != .string) return error.InvalidReviewResult;
        name.* = value.string;
    }

    const findings_value = object.get("findings") orelse return error.InvalidReviewResult;
    if (findings_value != .array) return error.InvalidReviewResult;
    const findings = try context.allocator.alloc(Zigalpm.OperationReviewFinding, findings_value.array.items.len);
    errdefer context.allocator.free(findings);
    for (findings_value.array.items, findings) |value, *finding| {
        if (value != .object) return error.InvalidReviewResult;
        const severity_text = jsonString(value.object, "severity") orelse return error.InvalidReviewResult;
        finding.* = .{
            .tool = jsonString(value.object, "tool") orelse return error.InvalidReviewResult,
            .severity = std.meta.stringToEnum(Zigalpm.OperationReviewSeverity, severity_text) orelse return error.InvalidReviewResult,
            .hook = jsonString(value.object, "hook") orelse return error.InvalidReviewResult,
            .matched_line = jsonString(value.object, "matchedLine") orelse return error.InvalidReviewResult,
            .message = jsonString(value.object, "message") orelse return error.InvalidReviewResult,
        };
    }

    const files_value = object.get("relatedFiles") orelse return error.InvalidReviewResult;
    if (files_value != .array) return error.InvalidReviewResult;
    const reviewed_files = try context.allocator.alloc(
        Zigalpm.builder.pkgbuild_review.ReviewedFile,
        files_value.array.items.len,
    );
    errdefer context.allocator.free(reviewed_files);
    const attachments = try context.allocator.alloc(
        Zigalpm.OperationQuestionAttachment,
        files_value.array.items.len,
    );
    errdefer context.allocator.free(attachments);
    var decoded_count: usize = 0;
    errdefer for (reviewed_files[0..decoded_count]) |file|
        context.allocator.free(file.contents);
    for (files_value.array.items, reviewed_files, attachments) |value, *file, *attachment| {
        if (value != .object) return error.InvalidReviewResult;
        const name = jsonString(value.object, "name") orelse return error.InvalidReviewResult;
        const display_content = jsonString(value.object, "content") orelse return error.InvalidReviewResult;
        const content = if (jsonString(value.object, "contentBase64")) |encoded_content| blk: {
            const decoded_size = try std.base64.standard.Decoder.calcSizeForSlice(encoded_content);
            const decoded = try context.allocator.alloc(u8, decoded_size);
            errdefer context.allocator.free(decoded);
            try std.base64.standard.Decoder.decode(decoded, encoded_content);
            break :blk decoded;
        } else try context.allocator.dupe(u8, display_content);
        const permissions_value = value.object.get("permissions") orelse return error.InvalidReviewResult;
        if (permissions_value != .integer or permissions_value.integer < 0) return error.InvalidReviewResult;
        file.* = .{
            .name = name,
            .contents = content,
            .permissions = @intCast(permissions_value.integer),
        };
        decoded_count += 1;
        attachment.* = .{ .name = name, .content = display_content };
    }
    const repository_dependencies = try jsonStringArray(
        context.allocator,
        object,
        "repositoryDependencies",
    );
    errdefer context.allocator.free(repository_dependencies);
    const aur_dependencies = try jsonStringArray(
        context.allocator,
        object,
        "aurDependencies",
    );
    errdefer context.allocator.free(aur_dependencies);
    return .{
        .parsed = parsed,
        .package_base = package_base,
        .package_names = package_names,
        .digest = digest,
        .findings = findings,
        .attachments = attachments,
        .reviewed_files = reviewed_files,
        .repository_dependencies = repository_dependencies,
        .aur_dependencies = aur_dependencies,
    };
}

fn jsonString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn jsonStringArray(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    name: []const u8,
) ![]const []const u8 {
    const value = object.get(name) orelse return error.InvalidReviewResult;
    if (value != .array) return error.InvalidReviewResult;
    const strings = try allocator.alloc([]const u8, value.array.items.len);
    errdefer allocator.free(strings);
    for (value.array.items, strings) |item, *string| {
        if (item != .string) return error.InvalidReviewResult;
        string.* = item.string;
    }
    return strings;
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
            "install=''\nchangelog=\"\"\n" ++
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
        false,
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
    try std.testing.expectEqual(expected.len, child.len);
    for (expected, child) |wanted, actual| try std.testing.expectEqualStrings(wanted, actual);
}

test "isolated source key transport preserves approval policy and guest verification" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const manifest = try @import("../cli/spec.zig").Manifest.load(arena.allocator());
    const digest = "5a" ** std.crypto.hash.sha2.Sha256.digest_length;
    const unattended = try parser.parse(arena.allocator(), &manifest, &.{ "build", "--isolated", "--no-confirm", "--package", "demo", "/host/PKGBUILD" });
    const arguments = try sourcePgpPreparationArguments(allocator, &unattended.dispatch, "/host/PKGBUILD", digest);
    defer allocator.free(arguments);
    const prepared = try parser.parse(arena.allocator(), &manifest, arguments);
    try std.testing.expect(optionEnabled(&prepared.dispatch, "--prepare-isolated-source-keys"));
    try std.testing.expect(prepared.dispatch.globals.no_confirm);
    try std.testing.expectEqualStrings(digest, optionValue(&prepared.dispatch, "--review-digest").?);
    try std.testing.expectEqualStrings("demo", optionValue(&prepared.dispatch, "--package").?);

    const interactive = try parser.parse(arena.allocator(), &manifest, &.{ "build", "--isolated" });
    const interactive_arguments = try sourcePgpPreparationArguments(allocator, &interactive.dispatch, "/host/PKGBUILD", digest);
    defer allocator.free(interactive_arguments);
    try std.testing.expect(!containsString(interactive_arguments, "--no-confirm"));
    const guest = try buildIsolatedChildArguments(allocator, &.{ "build", "--isolated", "--no-confirm", "/host/PKGBUILD" }, "/host/PKGBUILD", digest, true);
    defer allocator.free(guest);
    const guest_invocation = try parser.parse(arena.allocator(), &manifest, guest);
    try std.testing.expect(optionEnabled(&guest_invocation.dispatch, "--isolated-source-keys"));
    try std.testing.expect(!optionEnabled(&guest_invocation.dispatch, "--skip-source-pgp-verification"));
    try std.testing.expectEqualStrings(digest, optionValue(&guest_invocation.dispatch, "--review-digest").?);
}

test "isolated source key preparation checks the digest and refuses unapproved imports" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var context: test_support.TestContext = .{};
    context.init();
    defer context.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    const path = try std.fs.path.join(allocator, &.{ directory, "PKGBUILD" });
    defer allocator.free(path);
    const content =
        \\pkgname=pgp-preparation
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\validpgpkeys=('2E37DFCC9287C8A2F84B2519241A5B24548FAC70')
        \\package() { touch lifecycle-ran; }
    ;
    try temporary.dir.writeFile(io, .{ .sub_path = "PKGBUILD", .data = content });
    const environ = try testEnvironWithHome(allocator, directory);
    defer environ.block.deinit(allocator);
    context.context.environ = environ;
    try temporary.dir.createDir(io, ".gnupg", .fromMode(0o700));
    try temporary.dir.writeFile(io, .{ .sub_path = ".gnupg/gpg.conf", .data = "no-autostart\n" });
    var operations = Zigalpm.OperationContext.init(allocator, io);
    defer operations.deinit();
    const manifest = try @import("../cli/spec.zig").Manifest.load(context.arena.allocator());
    const wrong = try parser.parse(context.arena.allocator(), &manifest, &.{ "build", "--prepare-isolated-source-keys", "--no-confirm", "--review-digest", "5a" ** 32, path });
    try std.testing.expectError(error.ReviewedPkgbuildChanged, prepareSourcePgpKeyExport(&context.context, &wrong.dispatch, &operations));
    const digest = Zigalpm.builder.pkgbuild_review.digestPreparedReview(content, @as([]const Zigalpm.builder.pkgbuild_review.ReviewedFile, &.{}));
    const hex = std.fmt.bytesToHex(digest, .lower);
    const approved = try parser.parse(context.arena.allocator(), &manifest, &.{ "build", "--prepare-isolated-source-keys", "--no-confirm", "--review-digest", &hex, path });
    try std.testing.expectError(error.PgpKeyImportDeclined, prepareSourcePgpKeyExport(&context.context, &approved.dispatch, &operations));
    try std.testing.expectEqual(@as(u8, 1), try executeSourcePgpKeyPreparation(&context.context, &approved.dispatch));
    const declined = try std.json.parseFromSlice(SourcePgpKeyResult, allocator, context.stdout.written(), .{});
    defer declined.deinit();
    try std.testing.expectEqualStrings("PgpKeyImportDeclined", declined.value.failure.?);
    try std.testing.expectEqualStrings("", declined.value.public_keys);
    try std.testing.expect(std.mem.indexOf(u8, context.stderr.written(), "shelly keyring recv --user 2E37DFCC9287C8A2F84B2519241A5B24548FAC70") != null);
    try std.testing.expectError(error.FileNotFound, temporary.dir.access(io, "lifecycle-ran", .{}));
    try temporary.dir.writeFile(io, .{ .sub_path = "public.asc", .data = @embedFile("fixtures/source-pgp/public.asc") });
    const public_path = try std.fs.path.join(allocator, &.{ directory, "public.asc" });
    defer allocator.free(public_path);
    try source_pgp_transport.importKeys(allocator, io, environ, public_path);
    const keys = try prepareSourcePgpKeyExport(&context.context, &approved.dispatch, &operations);
    defer context.context.allocator.free(keys);
    try std.testing.expect(std.mem.startsWith(u8, keys, "-----BEGIN PGP PUBLIC KEY BLOCK-----"));
    try temporary.dir.writeFile(io, .{ .sub_path = "PKGBUILD", .data = content ++ "\n# changed\n" });
    try std.testing.expectError(error.ReviewedPkgbuildChanged, prepareSourcePgpKeyExport(&context.context, &approved.dispatch, &operations));
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

test "isolated dependency review refreshes local repositories without changing host metadata" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    try temporary.dir.createDirPath(io, "host/sync");
    try temporary.dir.createDir(io, "mirror", .default_dir);
    const fixture = struct {
        fn writeDatabase(dir: std.Io.Dir, path: []const u8, name: []const u8) !void {
            const desc = try std.fmt.allocPrint(std.testing.allocator, "%FILENAME%\n{s}-2-1-any.pkg.tar.zst\n\n%NAME%\n{s}\n\n" ++
                "%VERSION%\n2-1\n\n%ARCH%\nany\n\n%PROVIDES%\naqueous-provider=2\n\n", .{ name, name });
            defer std.testing.allocator.free(desc);
            var file = try dir.createFile(std.testing.io, path, .{});
            defer file.close(std.testing.io);
            var buffer: [4096]u8 = undefined;
            var writer = file.writer(std.testing.io, &buffer);
            var archive: std.tar.Writer = .{ .underlying_writer = &writer.interface };
            const entry = try std.fmt.allocPrint(std.testing.allocator, "{s}-2-1/desc", .{name});
            defer std.testing.allocator.free(entry);
            try archive.writeFileBytes(entry, desc, .{ .mode = 0o644 });
            try archive.finishPedantically();
            try writer.interface.flush();
        }
    };
    try fixture.writeDatabase(temporary.dir, "host/sync/local-builds.db", "old-package");
    try fixture.writeDatabase(temporary.dir, "mirror/local-builds.db", "dms-aqueous");
    const old_database = try temporary.dir.readFileAlloc(io, "host/sync/local-builds.db", allocator, .limited(1024 * 1024));
    defer allocator.free(old_database);
    const configuration = try std.fmt.allocPrint(allocator, "[options]\nArchitecture = auto\nDBPath = {s}/host\nSigLevel = Never\n" ++
        "[local-builds]\nServer = file://{s}/mirror\n", .{ directory, directory });
    defer allocator.free(configuration);
    try temporary.dir.writeFile(io, .{ .sub_path = "pacman.conf", .data = configuration });
    const config_path = try std.fs.path.join(allocator, &.{ directory, "pacman.conf" });
    defer allocator.free(config_path);
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = allocator,
        .io = io,
        .environ = std.testing.environ,
        .stdout = &output.writer,
        .stderr = &output.writer,
    };
    var build = try (Zigalpm.pkgbuild.Parser{ .allocator = allocator, .io = io }).parser_content("pkgname=aqueous-git\npkgver=1\npkgrel=1\narch=('any')\n" ++
        "depends=('dms-aqueous>=2' 'aqueous-provider>=2')\n", null);
    defer build.deinit(allocator);
    const database_path = blk: {
        var repositories = try ReviewRepositories.init(&context, null, false, config_path);
        defer repositories.deinit(&context);
        var resolver: IsolatedResolverContext = .{ .manager = repositories.manager };
        var plan = try resolveSyncDependencies(allocator, &.{build}, false, resolver.backend());
        defer plan.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 0), plan.aur_dependencies.len);
        try std.testing.expectEqual(@as(usize, 1), plan.repo_dependencies.len);
        try std.testing.expectEqualStrings("dms-aqueous", plan.repo_dependencies[0].name);
        break :blk try allocator.dupe(u8, repositories.database_path.?);
    };
    defer allocator.free(database_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, database_path, .{}));
    const unchanged = try temporary.dir.readFileAlloc(io, "host/sync/local-builds.db", allocator, .limited(1024 * 1024));
    defer allocator.free(unchanged);
    try std.testing.expectEqualSlices(u8, old_database, unchanged);
    try std.testing.expectError(error.FileNotFound, temporary.dir.access(io, "host/local", .{}));
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

test "build JSON success owns one artifact and emits the versioned envelope" {
    const allocator = std.testing.allocator;
    var runner: Real = .{};
    defer runner.deinit(allocator);
    const native = [_]struct { package_name: []const u8, path: []const u8 }{.{
        .package_name = "demo",
        .path = "/var/lib/remora/jobs/42/packages/demo-1-1-any.pkg.tar.zst",
    }};
    const digest = [_]u8{0x5a} ** std.crypto.hash.sha2.Sha256.digest_length;
    try runner.ownResult(allocator, "demo", digest, true, &native);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writeBuildJson(&output.writer, runner.result, null, true);
    const rendered = output.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"schemaVersion\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"success\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"packageName\":\"demo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Built demo") == null);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

test "build JSON preserves every split package artifact" {
    const allocator = std.testing.allocator;
    var runner: Real = .{};
    defer runner.deinit(allocator);
    const native = [_]struct { package_name: []const u8, path: []const u8 }{
        .{ .package_name = "demo", .path = "/tmp/demo.pkg.tar.zst" },
        .{ .package_name = "demo-docs", .path = "/tmp/demo-docs.pkg.tar.zst" },
    };
    try runner.ownResult(allocator, "demo", null, false, &native);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writeBuildJson(&output.writer, runner.result, null, false);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output.written(), "\"packageName\""));
}

test "build JSON failure uses the same envelope and structured error" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeBuildJson(&output.writer, null, error.ReviewedPkgbuildChanged, true);
    const rendered = output.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"success\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"artifacts\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"code\":\"ReviewedPkgbuildChanged\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "The reviewed PKGBUILD inputs changed.") != null);
}

test "cancelled initial elevation emits one JSON envelope without child output" {
    const allocator = std.testing.allocator;
    var stdout = std.Io.Writer.Allocating.init(allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = allocator,
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    const exit_code = try finishElevatedJsonBuild(&context, .{
        .exit_code = 130,
        .stdout = null,
        .cancelled = true,
    }, true);
    try std.testing.expectEqual(@as(u8, 130), exit_code);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, stdout.written(), .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.object.get("success").?.bool);
    try std.testing.expect(parsed.value.object.get("isolated").?.bool);
    try std.testing.expectEqualStrings(
        "Cancelled",
        parsed.value.object.get("error").?.object.get("code").?.string,
    );
}

test "cancelled initial elevation replaces partial child JSON" {
    const allocator = std.testing.allocator;
    var stdout = std.Io.Writer.Allocating.init(allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = allocator,
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    const partial = try allocator.dupe(u8, "{\"schemaVersion\":1");
    const elevated: elevation.CancellableRelaunchResult = .{
        .exit_code = 130,
        .stdout = partial,
        .cancelled = true,
    };
    defer elevated.deinit(allocator);
    try std.testing.expectEqual(
        @as(u8, 130),
        try finishElevatedJsonBuild(&context, elevated, true),
    );
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, stdout.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "Cancelled",
        parsed.value.object.get("error").?.object.get("code").?.string,
    );
    try std.testing.expect(std.mem.count(u8, stdout.written(), "\"schemaVersion\"") == 1);
}

test "complete elevated cancellation JSON is forwarded unchanged" {
    const allocator = std.testing.allocator;
    var stdout = std.Io.Writer.Allocating.init(allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = allocator,
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    const document =
        "{\"schemaVersion\":1,\"success\":false,\"error\":{\"code\":\"Cancelled\",\"message\":\"cancelled\"}}\n";
    const owned_document = try allocator.dupe(u8, document);
    const elevated: elevation.CancellableRelaunchResult = .{
        .exit_code = 130,
        .stdout = owned_document,
        .cancelled = true,
    };
    defer elevated.deinit(allocator);
    try std.testing.expectEqual(
        @as(u8, 130),
        try finishElevatedJsonBuild(&context, elevated, true),
    );
    try std.testing.expectEqualStrings(document, stdout.written());
}

test "automation review mismatch retains package context without accepting the digest" {
    const allocator = std.testing.allocator;
    var runner: Real = .{};
    defer runner.deinit(allocator);
    const reviewed = [_]u8{0x5a} ** std.crypto.hash.sha2.Sha256.digest_length;
    const supplied = [_]u8{0xa5} ** std.crypto.hash.sha2.Sha256.digest_length;

    try std.testing.expectError(
        error.ReviewedPkgbuildChanged,
        acceptAutomationReview(&runner, allocator, "evaluated-base", reviewed, supplied, false),
    );
    try std.testing.expectEqualStrings("evaluated-base", runner.result.?.package_base);
    try std.testing.expect(runner.result.?.review_digest == null);

    try runner.setFailure(allocator, error.ReviewedPkgbuildChanged);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writeBuildJson(&output.writer, runner.result, error.ReviewedPkgbuildChanged, false);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"packageBase\":\"evaluated-base\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"reviewDigest\":null") != null);
}

test "accepted automation review remains in later coordinator failure JSON" {
    const allocator = std.testing.allocator;
    var runner: Real = .{};
    defer runner.deinit(allocator);
    const digest = [_]u8{0x5a} ** std.crypto.hash.sha2.Sha256.digest_length;
    try acceptAutomationReview(&runner, allocator, "evaluated-base", digest, digest, false);
    try runner.setFailure(allocator, error.SyncDbFailed);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writeBuildJson(&output.writer, runner.result, error.SyncDbFailed, false);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"packageBase\":\"evaluated-base\"") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output.written(),
        "\"reviewDigest\":\"" ++ ("5a" ** std.crypto.hash.sha2.Sha256.digest_length) ++ "\"",
    ) != null);
}

test "coordinator dependency plans own the evaluated review dependencies" {
    const allocator = std.testing.allocator;
    var plan = try dependencyPlanFromReview(
        allocator,
        &.{ "cmake", "ninja" },
        &.{"aur-tool"},
    );
    defer plan.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), plan.repo_dependencies.len);
    try std.testing.expectEqualStrings("cmake", plan.repo_dependencies[0].name);
    try std.testing.expectEqualStrings("ninja", plan.repo_dependencies[1].name);
    try std.testing.expectEqual(@as(usize, 1), plan.aur_dependencies.len);
    try std.testing.expectEqualStrings("aur-tool", plan.aur_dependencies[0]);
}

test "coordinator review arguments select host or isolated dependency state" {
    const spec = @import("../cli/spec.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const digest_text = "5a" ** std.crypto.hash.sha2.Sha256.digest_length;
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "build",
        "--sync-deps",
        "--review-digest",
        digest_text,
        "--package",
        "demo",
        "/host/PKGBUILD",
    });

    const host = try coordinatorReviewArguments(
        std.testing.allocator,
        &outcome.dispatch,
        "/host/PKGBUILD",
        .host,
    );
    defer std.testing.allocator.free(host);
    try std.testing.expect(containsString(host, "--review-dependencies"));
    try std.testing.expect(containsString(host, "--review-host-dependencies"));
    try std.testing.expect(containsString(host, "demo"));
    try std.testing.expect(!containsString(host, "--review-digest"));
    try std.testing.expect(!containsString(host, digest_text));
    const parsed_host = try parser.parse(arena.allocator(), &manifest, host);
    try std.testing.expect(optionEnabled(&parsed_host.dispatch, "--review-only"));
    try std.testing.expect(optionEnabled(&parsed_host.dispatch, "--review-host-dependencies"));

    const isolated = try coordinatorReviewArguments(
        std.testing.allocator,
        &outcome.dispatch,
        "/host/PKGBUILD",
        .isolated,
    );
    defer std.testing.allocator.free(isolated);
    try std.testing.expect(containsString(isolated, "--review-dependencies"));
    try std.testing.expect(!containsString(isolated, "--review-host-dependencies"));
}

test "isolated argument rewriting removes JSON and both package destination spellings" {
    const allocator = std.testing.allocator;
    const digest = "5a" ** std.crypto.hash.sha2.Sha256.digest_length;
    const separate = [_][]const u8{
        "build", "--isolated", "--json", "--package-destination", "/host/job", "--no-check", "/host/PKGBUILD",
    };
    const first = try buildIsolatedChildArguments(allocator, &separate, "/host/PKGBUILD", digest, false);
    defer allocator.free(first);
    try std.testing.expect(!containsString(first, "--json"));
    try std.testing.expect(!containsString(first, "--package-destination"));
    try std.testing.expect(!containsString(first, "/host/job"));
    try std.testing.expect(containsString(first, "--no-check"));

    const joined = [_][]const u8{
        "build", "--isolated", "--package-destination=/host/job", "/host/PKGBUILD",
    };
    const second = try buildIsolatedChildArguments(allocator, &joined, "/host/PKGBUILD", digest, false);
    defer allocator.free(second);
    for (second) |argument|
        try std.testing.expect(!std.mem.startsWith(u8, argument, "--package-destination"));
}

test "review digest exit classification is stable for automation" {
    try std.testing.expectEqual(@as(u8, 2), exitCodeForBuildError(error.InvalidReviewDigest));
    try std.testing.expectEqual(@as(u8, 1), exitCodeForBuildError(error.ReviewedPkgbuildChanged));
    try std.testing.expectEqual(@as(u8, 130), exitCodeForBuildError(error.Cancelled));
}

test "package destination rejects relative paths" {
    try validatePackageDestination("/var/lib/remora/build/jobs/42/packages");
    try std.testing.expectError(
        error.PackageDestinationMustBeAbsolute,
        validatePackageDestination("jobs/42/packages"),
    );
}

test "configured work directories exist before final review and remain command-unowned" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const configured = try std.fs.path.join(allocator, &.{ root, "build", "demo-0123456789abcdef" });
    defer allocator.free(configured);
    const unconfigured = try std.fs.path.join(allocator, &.{ root, "not-created" });
    defer allocator.free(unconfigured);

    try ensureConfiguredWorkDirectory(io, false, unconfigured);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(io, unconfigured, .{}),
    );
    try ensureConfiguredWorkDirectory(io, true, configured);
    try std.Io.Dir.cwd().access(io, configured, .{});
    // Returning from the helper does not remove the directory. Real builds
    // leave retention decisions to PackageBuilder.clean_after_success.
    try std.Io.Dir.cwd().access(io, configured, .{});
}
