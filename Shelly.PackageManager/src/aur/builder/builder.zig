//! Non-root AUR package build engine. Orchestrates the build lifecycle
//! (review check, sources, lifecycle steps, package assembly) through the
//! focused sibling modules and keeps the public builder API.
const std = @import("std");
const builtin = @import("builtin");
pub const ShellyBuildConfiguration = @import("../shellybuild.zig").ShellyBuildConfiguration;
const pkgbuild_parser = @import("../../pkgbuild/pkgbuild_parser.zig");
const PackageBuild = pkgbuild_parser.Pkgbuild;
const op_context = @import("operation_context");
const install_script = @import("../../pkgbuild/install_script.zig");
const metadata = @import("metadata.zig");
const security = @import("security.zig");
const steps = @import("steps.zig");
const sources = @import("sources.zig");
const package_file = @import("package_file.zig");
const virtual_ownership = @import("virtual_ownership.zig");
const srcinfo = @import("../srcinfo.zig");

pub const pkgbuild_validation = @import("pkgbuild_validation.zig");
pub const PkgbuildValidation = pkgbuild_validation.PkgbuildValidation;
pub const pkgbuild_review = @import("pkgbuild_review.zig");
pub const PreparedPkgbuildReview = pkgbuild_review.PreparedPkgbuildReview;
pub const preparePkgbuildReview = pkgbuild_review.preparePkgbuildReview;
pub const sandbox = @import("sandbox.zig");

pub const requireNonRootEffectiveUid = security.requireNonRootEffectiveUid;
pub const uniqueWorkDirectory = security.uniqueWorkDirectory;
pub const secureBuilderProcess = security.secureBuilderProcess;
pub const setNoNewPrivs = security.setNoNewPrivs;

test {
    _ = @import("source_spec.zig");
    _ = @import("checksums.zig");
    _ = @import("metadata.zig");
    _ = @import("security.zig");
    _ = @import("sandbox.zig");
    _ = @import("steps.zig");
    _ = @import("sources.zig");
    _ = @import("package_file.zig");
    _ = @import("virtual_ownership.zig");
}

pub const BuildArtifact = struct {
    path: [:0]u8,
    package_name: []const u8,

    pub fn deinit(self: BuildArtifact, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.package_name);
    }
};

pub fn deinitArtifacts(allocator: std.mem.Allocator, artifacts: []BuildArtifact) void {
    for (artifacts) |artifact| artifact.deinit(allocator);
    allocator.free(artifacts);
}

pub const BuildOptions = struct {
    run_check: bool,
    run_verify: bool = true,
    overwrite: bool,
    clean_after_success: bool,
    skip_source_pgp_verification: bool = false,
    /// Optional keyring override for isolated builds and tests. Production
    /// callers normally leave this null so GnuPG uses the invoking user's
    /// keyring through the builder's sanitized environment.
    source_pgp_gnupg_home: ?[]const u8 = null,
    /// Signs each published package archive with a detached binary OpenPGP
    /// signature, matching makepkg's --sign behavior.
    sign: bool = false,
    /// Key id or fingerprint passed to GPG's --local-user when signing; null
    /// selects the default key from the invoking user's keyring, matching
    /// makepkg's GPGKEY.
    sign_key: ?[]const u8 = null,
    /// Optional signing keyring override for isolated builds and tests.
    /// Production callers normally leave this null so GnuPG uses the
    /// invoking user's keyring through the builder's sanitized environment.
    sign_gnupg_home: ?[]const u8 = null,
    start_directory: []const u8,
    work_directory: []const u8,
    package_destination: []const u8,
    source_destination: []const u8,
    log_destination: []const u8,
    /// Exact PKGBUILD path used for the final in-process integrity check.
    /// It may be omitted only by unit-test fixtures.
    pkgbuild_path: ?[]const u8 = null,
    /// Allows callers with an already-verified source tree to use the custom
    /// packaging machinery without reacquiring sources. Normal AUR builds must
    /// leave this false so PackageBuilder creates $srcdir itself.
    sources_prepared: bool = false,
    /// Digest of the PKGBUILD and its reviewed local/install files. Every
    /// caller must prepare and verify this snapshot before execution.
    reviewed_pkgbuild_digest: ?[std.crypto.hash.sha2.Sha256.digest_length]u8 = null,
    /// SHA-256 of only the PKGBUILD, for BUILDINFO v2.
    pkgbuild_sha256sum: ?[std.crypto.hash.sha2.Sha256.digest_length]u8 = null,
    /// Optional deterministic build-environment snapshot. Production callers
    /// leave this null and the builder reads libalpm's local database.
    installed_packages: ?[]const []const u8 = null,
    /// Byte-exact install scripts retained by the approved package review.
    install_scripts: []const install_script.Script = &.{},
    /// Byte-exact local and auxiliary files retained by package review.
    reviewed_files: []const pkgbuild_review.ReviewedFile = &.{},
    /// Build every member in the final, sandbox-evaluated `pkgname` array.
    /// Direct PKGBUILD builds set this when no explicit `--package` selection
    /// was supplied. AUR/install callers keep the default and build only the
    /// names in `requested_names`.
    build_all_members: bool = false,
    /// Wrapper command prefix used to confine lifecycle steps with Landlock
    /// when `[sandbox] enabled` is set. Production callers leave this null so
    /// steps re-execute the current executable's `__sandbox-exec` entry
    /// point; tests inject a passthrough stub.
    sandbox_wrapper_prefix: ?[]const []const u8 = null,
};

pub const BuilderErrors = error{
    BuildFailed,
    OutOfMemory,
    Cancelled,
    AlreadyBuilt,
    BuilderMustNotRunAsRoot,
    UnreviewedBuilderRequest,
    ReviewedPkgbuildChanged,
    BuildDirectoryNotWritable,
    PrivilegedPackageOperationUnsupported,
    SandboxUnsupported,
    InvalidSourceDateEpoch,
};

pub const FailureLocation = struct {
    package_name: ?[]const u8 = null,
    step_name: ?[]const u8 = null,
};

/// Non-root standalone package build engine.
pub const PackageBuilder = struct {
    allocator: std.mem.Allocator,
    package_builds: []PackageBuild,
    operation_context: *op_context.OperationContext,
    shellybuild_config: ShellyBuildConfiguration,
    requested_names: []const []const u8,
    options: BuildOptions,
    environ: std.process.Environ,
    io: std.Io,
    failure_location: FailureLocation = .{},
    active_operation: ?*op_context.Operation = null,
    active_log: ?*steps.BuildLog = null,
    /// Resolved once before any PKGBUILD code runs. A caller-provided value is
    /// retained; otherwise this is the native builder's start timestamp.
    source_date_epoch: ?i64 = null,
    /// Owned package names produced when sandboxed top-level evaluation turns
    /// statically unresolved split-package names into their final values.
    evaluated_requested_names: ?[][]const u8 = null,
    /// Owned replacement builds used when runtime evaluation changes the
    /// number of selected split-package members. The inputs passed to init are
    /// borrowed, so only this replacement slice is released by deinit.
    evaluated_package_builds: ?[]PackageBuild = null,
    /// Ownership requested by the currently executing package step. This is
    /// converted to archive metadata and cleared before the next split member.
    virtual_ownership_tracker: ?virtual_ownership.Tracker = null,

    pub fn init(
        allocator: std.mem.Allocator,
        package_builds: []PackageBuild,
        operation_context: *op_context.OperationContext,
        shellybuild_configuration: ShellyBuildConfiguration,
        requested_names: []const []const u8,
        options: BuildOptions,
        environ: std.process.Environ,
        io: std.Io,
    ) !*PackageBuilder {
        if (package_builds.len == 0 or package_builds.len != requested_names.len)
            return error.InvalidBuildInput;
        const self = allocator.create(PackageBuilder) catch |err| {
            return err;
        };

        self.* = PackageBuilder{
            .allocator = allocator,
            .package_builds = package_builds,
            .operation_context = operation_context,
            .shellybuild_config = shellybuild_configuration,
            .requested_names = requested_names,
            .options = options,
            .environ = environ,
            .io = io,
        };

        return self;
    }

    pub fn deinit(self: *PackageBuilder) void {
        self.clearVirtualOwnership();
        if (self.evaluated_package_builds) |builds| {
            for (builds) |*package_build| package_build.deinit(self.allocator);
            self.allocator.free(builds);
        }
        if (self.evaluated_requested_names) |names| {
            for (names) |name| self.allocator.free(name);
            self.allocator.free(names);
        }
        self.allocator.destroy(self);
    }

    pub fn clearVirtualOwnership(self: *PackageBuilder) void {
        if (self.virtual_ownership_tracker) |*tracker| tracker.deinit();
        self.virtual_ownership_tracker = null;
    }

    fn resolveSourceDateEpoch(self: *PackageBuilder) !void {
        if (self.source_date_epoch != null) return;

        if (self.environ.getPosix("SOURCE_DATE_EPOCH")) |value| {
            // makepkg treats an empty variable like an unset one, but rejects
            // every non-empty value containing anything except decimal digits.
            if (value.len > 0) {
                for (value) |byte| if (!std.ascii.isDigit(byte))
                    return error.InvalidSourceDateEpoch;
                self.source_date_epoch = std.fmt.parseInt(i64, value, 10) catch
                    return error.InvalidSourceDateEpoch;
                return;
            }
        }

        const now = std.Io.Clock.real.now(self.io).toSeconds();
        if (now < 0) return error.InvalidSourceDateEpoch;
        self.source_date_epoch = now;
    }

    pub fn BuildPackage(self: *PackageBuilder) BuilderErrors![]BuildArtifact {
        const artifacts = self.run() catch |err|
            return security.narrowBuilderError(err);
        return artifacts;
    }

    /// Compatibility entry point that owns its operation lifecycle. Commands
    /// with an existing operation should call `runWithOperation` instead.
    pub fn run(self: *PackageBuilder) ![]BuildArtifact {
        var operation = self.operation_context.begin(op_context.OperationDescriptor{ .backend = .aur, .kind = .build, .subject = "Package Build" });
        var completion: op_context.CompletionStatus = .failed;
        defer operation.finish(completion);
        const artifacts = self.runWithOperation(&operation) catch |err| {
            if (err == error.Cancelled) {
                completion = .cancelled;
                return err;
            }
            operation.reportError(err, "Failed to build package", "build", null, false);
            return err;
        };
        completion = .success;
        return artifacts;
    }

    /// Runs the standalone build core inside a caller-owned operation.
    pub fn runWithOperation(
        self: *PackageBuilder,
        operation: *op_context.Operation,
    ) ![]BuildArtifact {
        const reviewed_digest = self.options.reviewed_pkgbuild_digest orelse
            return error.UnreviewedBuilderRequest;
        if (self.options.pkgbuild_path) |pkgbuild_path| {
            const current_pkgbuild = try std.Io.Dir.cwd().readFileAlloc(
                self.io,
                pkgbuild_path,
                self.allocator,
                .limited(32 * 1024 * 1024),
            );
            defer self.allocator.free(current_pkgbuild);
            var current_review = try preparePkgbuildReview(
                self.allocator,
                self.io,
                self.options.start_directory,
                current_pkgbuild,
                self.package_builds,
            );
            defer current_review.deinit();
            if (!std.mem.eql(u8, &reviewed_digest, &current_review.digest))
                return error.ReviewedPkgbuildChanged;
            if (!package_file.installScriptsMatch(self, current_review.install_scripts))
                return error.ReviewedPkgbuildChanged;
            if (!package_file.reviewedFilesMatch(self, current_review.reviewed_files))
                return error.ReviewedPkgbuildChanged;
            self.options.pkgbuild_sha256sum = current_review.pkgbuild_digest;
        } else if (!builtin.is_test) return error.UnreviewedBuilderRequest;
        if (self.active_operation != null) return error.BuildAlreadyRunning;
        self.active_operation = operation;
        defer self.active_operation = null;
        try self.resolveSourceDateEpoch();
        try steps.validateBuildDirectories(self);
        var log = try steps.openBuildLog(self);
        defer log.close();
        self.active_log = &log;
        defer self.active_log = null;
        try log.writeRecord("build", "started");
        const artifacts = self.buildPackage(operation) catch |err| {
            log.writeRecord("status", if (err == error.Cancelled) "cancelled" else "failed") catch {};
            return err;
        };
        log.writeRecord("status", "success") catch |err| {
            deinitArtifacts(self.allocator, artifacts);
            return err;
        };
        return artifacts;
    }

    /// Resolves reviewed top-level PKGBUILD metadata in the normal lifecycle
    /// sandbox and writes SRCINFO without acquiring sources or invoking
    /// verify(), prepare(), pkgver(), build(), check(), or package().
    pub fn writeSrcinfoWithOperation(
        self: *PackageBuilder,
        operation: *op_context.Operation,
        writer: *std.Io.Writer,
    ) !void {
        const reviewed_digest = self.options.reviewed_pkgbuild_digest orelse
            return error.UnreviewedBuilderRequest;
        const pkgbuild_path = self.options.pkgbuild_path orelse
            return error.UnreviewedBuilderRequest;
        const current_pkgbuild = try std.Io.Dir.cwd().readFileAlloc(
            self.io,
            pkgbuild_path,
            self.allocator,
            .limited(32 * 1024 * 1024),
        );
        defer self.allocator.free(current_pkgbuild);
        var current_review = try preparePkgbuildReview(
            self.allocator,
            self.io,
            self.options.start_directory,
            current_pkgbuild,
            self.package_builds,
        );
        defer current_review.deinit();
        if (!std.mem.eql(u8, &reviewed_digest, &current_review.digest))
            return error.ReviewedPkgbuildChanged;
        if (!package_file.installScriptsMatch(self, current_review.install_scripts))
            return error.ReviewedPkgbuildChanged;
        if (!package_file.reviewedFilesMatch(self, current_review.reviewed_files))
            return error.ReviewedPkgbuildChanged;

        if (self.active_operation != null) return error.BuildAlreadyRunning;
        self.active_operation = operation;
        defer self.active_operation = null;
        try security.secureBuilderProcess();
        try self.requireSandboxAvailability();
        try self.resolveSourceDateEpoch();

        var evaluated = try self.resolveEvaluatedBuilds(operation);
        defer evaluated.deinit(self.allocator);
        var resolved_review = try preparePkgbuildReview(
            self.allocator,
            self.io,
            self.options.start_directory,
            current_pkgbuild,
            self.package_builds,
        );
        defer resolved_review.deinit();
        if (!std.mem.eql(u8, &reviewed_digest, &resolved_review.digest)) {
            var answer = try operation.ask(.{
                .kind = .review_changes,
                .prompt = "Review files discovered by sandboxed PKGBUILD evaluation?",
                .review = .{
                    .subject = self.requested_names[0],
                    .old_content = current_pkgbuild,
                    .new_content = current_pkgbuild,
                    .findings = resolved_review.findings,
                    .related_files = resolved_review.related_files,
                },
                .default_response = .declined,
            });
            defer answer.deinit(self.allocator);
            if (answer.response != .accepted) return error.PkgbuildReviewDeclined;
        }
        try resolved_review.verifyCurrent(
            self.allocator,
            self.io,
            pkgbuild_path,
            self.options.start_directory,
        );
        try self.validatePackageFunctions();
        try srcinfo.writePkgbuild(
            self.allocator,
            self.io,
            writer,
            current_pkgbuild,
            .{
                .package_carch = self.shellybuild_config.build.carch,
                .dynamic_overrides = if (evaluated.scalars.count() > 0) &evaluated.scalars else null,
                .dynamic_unsets = if (evaluated.unset_scalars.count() > 0) &evaluated.unset_scalars else null,
                .dynamic_array_overrides = &evaluated.arrays,
                .dynamic_array_unsets = if (evaluated.unset_arrays.count() > 0) &evaluated.unset_arrays else null,
            },
        );
    }

    fn buildPackage(self: *PackageBuilder, operation: *op_context.Operation) ![]BuildArtifact {
        try security.secureBuilderProcess();
        try self.requireSandboxAvailability();
        var resolved_review: ?PreparedPkgbuildReview = null;
        defer if (resolved_review) |*review| review.deinit();
        const original_review_digest = self.options.reviewed_pkgbuild_digest;
        const original_install_scripts = self.options.install_scripts;
        const original_reviewed_files = self.options.reviewed_files;
        defer {
            self.options.reviewed_pkgbuild_digest = original_review_digest;
            self.options.install_scripts = original_install_scripts;
            self.options.reviewed_files = original_reviewed_files;
        }
        // Production builds always have a reviewed PKGBUILD path. Source it
        // once in the lifecycle sandbox so shell-created scalar state (not
        // just statically recognizable assignments) is reflected in the
        // execution plan. Path-less unit fixtures retain their lightweight
        // static-only behavior.
        if (self.options.pkgbuild_path != null and self.package_builds[0].execution != null) {
            var evaluated = try self.resolveEvaluatedBuilds(operation);
            defer evaluated.deinit(self.allocator);
            const pkgbuild_path = self.options.pkgbuild_path orelse
                return error.UnreviewedBuilderRequest;
            const content = try std.Io.Dir.cwd().readFileAlloc(
                self.io,
                pkgbuild_path,
                self.allocator,
                .limited(32 * 1024 * 1024),
            );
            defer self.allocator.free(content);
            resolved_review = try preparePkgbuildReview(
                self.allocator,
                self.io,
                self.options.start_directory,
                content,
                self.package_builds,
            );
            const review = &resolved_review.?;
            const prior_digest = original_review_digest orelse
                return error.UnreviewedBuilderRequest;
            if (!std.mem.eql(u8, &prior_digest, &review.digest)) {
                var answer = try operation.ask(.{
                    .kind = .review_changes,
                    .prompt = "Review files discovered by sandboxed PKGBUILD evaluation?",
                    .review = .{
                        .subject = self.requested_names[0],
                        .old_content = content,
                        .new_content = content,
                        .findings = review.findings,
                        .related_files = review.related_files,
                    },
                    .default_response = .declined,
                });
                defer answer.deinit(self.allocator);
                if (answer.response != .accepted)
                    return error.PkgbuildReviewDeclined;
            }
            try review.verifyCurrent(
                self.allocator,
                self.io,
                pkgbuild_path,
                self.options.start_directory,
            );
            self.options.reviewed_pkgbuild_digest = review.digest;
            self.options.install_scripts = review.install_scripts;
            self.options.reviewed_files = review.reviewed_files;
        }
        try self.validatePackageFunctions();
        if (!self.options.sources_prepared) try sources.prepareSources(self, operation);
        const shared_execution = self.package_builds[0].execution orelse
            return error.MissingExecutionSteps;
        for (shared_execution.steps) |step| {
            if (steps.isPackageStep(step.name)) continue;
            if (std.mem.eql(u8, step.name, "check") and !self.options.run_check) continue;
            try steps.runStep(
                self,
                operation,
                self.requested_names[0],
                step.name,
                shared_execution.shared_prelude,
                shared_execution.shared_helpers,
                step.body,
                null,
            );
        }

        var artifacts: std.ArrayList(BuildArtifact) = .empty;
        errdefer {
            for (artifacts.items) |artifact| {
                package_file.removePublishedArtifact(self, artifact.path);
                artifact.deinit(self.allocator);
            }
            artifacts.deinit(self.allocator);
        }

        for (self.package_builds, self.requested_names) |*package_build, requested_name| {
            if (!package_file.packageSupportsArchitecture(self, package_build)) continue;
            try package_file.preparePackageDirectory(self, package_build);
            const approved_install = if (package_build.install_file) |value|
                try self.allocator.dupe(u8, value)
            else
                null;
            defer if (approved_install) |value| self.allocator.free(value);
            const approved_changelog = if (package_build.changelog_file) |value|
                try self.allocator.dupe(u8, value)
            else
                null;
            defer if (approved_changelog) |value| self.allocator.free(value);
            const package_execution = package_build.execution orelse
                return error.MissingExecutionSteps;
            const package_step = steps.findPackageStep(package_execution.steps) orelse
                return error.MissingPackageStep;
            const artifact = artifact: {
                self.clearVirtualOwnership();
                defer self.clearVirtualOwnership();
                try steps.runStep(
                    self,
                    operation,
                    requested_name,
                    package_step.name,
                    package_execution.package_prelude,
                    package_execution.package_helpers,
                    package_step.body,
                    null,
                );
                if (!metadata.reviewedAuxiliarySelectionMatches(approved_install, package_build.install_file) or
                    !metadata.reviewedAuxiliarySelectionMatches(approved_changelog, package_build.changelog_file))
                    return error.ReviewedPkgbuildChanged;
                break :artifact try package_file.assemblePackage(self, package_build);
            };
            artifacts.append(self.allocator, artifact) catch |err| {
                package_file.removePublishedArtifact(self, artifact.path);
                artifact.deinit(self.allocator);
                return err;
            };
        }

        if (self.options.clean_after_success) {
            for ([_][]const u8{ "src", "pkg" }) |name| {
                const path = try std.fs.path.join(self.allocator, &.{ self.options.work_directory, name });
                defer self.allocator.free(path);
                std.Io.Dir.cwd().deleteTree(self.io, path) catch {};
            }
        }

        return artifacts.toOwnedSlice(self.allocator);
    }

    /// Sources the reviewed PKGBUILD in the sandbox and reparses it with the
    /// resulting scalar and indexed-array state. This makes
    /// source acquisition and lifecycle steps share one coherent top-level
    /// shell state. Replaces `package_builds` contents in place.
    fn resolveEvaluatedBuilds(
        self: *PackageBuilder,
        operation: *op_context.Operation,
    ) !steps.DynamicMetadataOverrides {
        var evaluated = try steps.evaluateDynamicMetadata(self, operation);
        errdefer evaluated.deinit(self.allocator);
        try self.resolveEvaluatedRequestedNames(
            if (evaluated.scalars.count() > 0) &evaluated.scalars else null,
            if (evaluated.unset_scalars.count() > 0) &evaluated.unset_scalars else null,
            &evaluated.arrays,
            if (evaluated.unset_arrays.count() > 0) &evaluated.unset_arrays else null,
        );
        try self.reparseEvaluatedBuilds(
            if (evaluated.scalars.count() > 0) &evaluated.scalars else null,
            if (evaluated.unset_scalars.count() > 0) &evaluated.unset_scalars else null,
            &evaluated.arrays,
            if (evaluated.unset_arrays.count() > 0) &evaluated.unset_arrays else null,
        );
        try self.applyShellOptionDelta(evaluated.shell_options);
        return evaluated;
    }

    fn applyShellOptionDelta(
        self: *PackageBuilder,
        delta: steps.ShellOptionDelta,
    ) !void {
        if (delta.isEmpty()) return;

        var replay: std.Io.Writer.Allocating = .init(self.allocator);
        defer replay.deinit();
        const writer = &replay.writer;
        // Apply regular shell options first because modes such as `posix` can
        // affect shopt defaults. Reapplying the shopt delta last restores the
        // exact state observed after sourcing the PKGBUILD.
        for (delta.shell_disable) |name| try writer.print("set +o {s}\n", .{name});
        for (delta.shell_enable) |name| try writer.print("set -o {s}\n", .{name});
        for (delta.shopt_disable) |name| try writer.print("shopt -u {s}\n", .{name});
        for (delta.shopt_enable) |name| try writer.print("shopt -s {s}\n", .{name});

        for (self.package_builds) |*package_build| {
            const execution = &(package_build.execution orelse continue);
            const shared_prelude = try std.mem.concat(
                self.allocator,
                u8,
                &.{ replay.written(), execution.shared_prelude },
            );
            errdefer self.allocator.free(shared_prelude);
            const package_prelude = try std.mem.concat(
                self.allocator,
                u8,
                &.{ replay.written(), execution.package_prelude },
            );
            self.allocator.free(execution.shared_prelude);
            self.allocator.free(execution.package_prelude);
            execution.shared_prelude = shared_prelude;
            execution.package_prelude = package_prelude;
        }
    }

    /// Keeps explicit package selections stable when top-level shell state
    /// resolves a dynamic pkgbase/pkgname. A name already present in the final
    /// list is retained; otherwise a statically discovered placeholder maps to
    /// the final name at the same split-package index.
    fn resolveEvaluatedRequestedNames(
        self: *PackageBuilder,
        overrides: ?*const std.StringHashMap([]const u8),
        unset_overrides: ?*const steps.DynamicScalarUnsets,
        array_overrides: ?*const steps.DynamicArrayOverrides,
        unset_array_overrides: ?*const steps.DynamicArrayUnsets,
    ) !void {
        const pkgbuild_path = self.options.pkgbuild_path orelse
            return error.UnreviewedBuilderRequest;
        const content = try std.Io.Dir.cwd().readFileAlloc(
            self.io,
            pkgbuild_path,
            self.allocator,
            .limited(32 * 1024 * 1024),
        );
        defer self.allocator.free(content);

        var static_names = try (pkgbuild_parser.PkgbuildParser{
            .allocator = self.allocator,
            .io = self.io,
            .package_carch = self.shellybuild_config.build.carch,
        }).package_names_content(content);
        defer static_names.deinit(self.allocator);
        var evaluated_names = try (pkgbuild_parser.PkgbuildParser{
            .allocator = self.allocator,
            .io = self.io,
            .package_carch = self.shellybuild_config.build.carch,
            .dynamic_overrides = overrides,
            .dynamic_unsets = unset_overrides,
            .dynamic_array_overrides = array_overrides,
            .dynamic_array_unsets = unset_array_overrides,
        }).package_names_content(content);
        defer evaluated_names.deinit(self.allocator);
        const target_count = if (self.options.build_all_members)
            evaluated_names.items.len
        else
            self.requested_names.len;
        const mapped = try self.allocator.alloc([]const u8, target_count);
        var mapped_count: usize = 0;
        errdefer {
            for (mapped[0..mapped_count]) |name| self.allocator.free(name);
            self.allocator.free(mapped);
        }
        if (self.options.build_all_members) {
            for (evaluated_names.items, mapped) |name, *destination| {
                destination.* = try self.allocator.dupe(u8, name);
                mapped_count += 1;
            }
        } else {
            for (self.requested_names, mapped) |requested_name, *destination| {
                var selected: ?[]const u8 = null;
                for (evaluated_names.items) |name| {
                    if (std.mem.eql(u8, name, requested_name)) {
                        selected = name;
                        break;
                    }
                }
                if (selected == null) {
                    for (static_names.items, 0..) |name, index| {
                        if (!std.mem.eql(u8, name, requested_name)) continue;
                        if (index >= evaluated_names.items.len)
                            return error.SelectedPackageNotFound;
                        selected = evaluated_names.items[index];
                        break;
                    }
                }
                destination.* = try self.allocator.dupe(
                    u8,
                    selected orelse return error.SelectedPackageNotFound,
                );
                mapped_count += 1;
            }
        }

        if (self.evaluated_requested_names) |old_names| {
            for (old_names) |name| self.allocator.free(name);
            self.allocator.free(old_names);
        }
        self.evaluated_requested_names = mapped;
        self.requested_names = mapped;
    }

    fn reparseEvaluatedBuilds(
        self: *PackageBuilder,
        overrides: ?*const std.StringHashMap([]const u8),
        unset_overrides: ?*const steps.DynamicScalarUnsets,
        array_overrides: ?*const steps.DynamicArrayOverrides,
        unset_array_overrides: ?*const steps.DynamicArrayUnsets,
    ) !void {
        const pkgbuild_path = self.options.pkgbuild_path orelse
            return error.UnreviewedBuilderRequest;
        const content = try std.Io.Dir.cwd().readFileAlloc(
            self.io,
            pkgbuild_path,
            self.allocator,
            .limited(32 * 1024 * 1024),
        );
        defer self.allocator.free(content);

        if (self.package_builds.len == self.requested_names.len) {
            for (self.package_builds, self.requested_names) |*package_build, requested_name| {
                const reparsed = try (pkgbuild_parser.PkgbuildParser{
                    .allocator = self.allocator,
                    .io = self.io,
                    .selected_package_name = requested_name,
                    .package_carch = self.shellybuild_config.build.carch,
                    .dynamic_overrides = overrides,
                    .dynamic_unsets = unset_overrides,
                    .dynamic_array_overrides = array_overrides,
                    .dynamic_array_unsets = unset_array_overrides,
                }).parser_content(content, self.options.start_directory);
                package_build.deinit(self.allocator);
                package_build.* = reparsed;
            }
            return;
        }

        const reparsed_builds = try self.allocator.alloc(PackageBuild, self.requested_names.len);
        var parsed_count: usize = 0;
        errdefer {
            for (reparsed_builds[0..parsed_count]) |*package_build|
                package_build.deinit(self.allocator);
            self.allocator.free(reparsed_builds);
        }
        for (self.requested_names, reparsed_builds) |requested_name, *package_build| {
            package_build.* = try (pkgbuild_parser.PkgbuildParser{
                .allocator = self.allocator,
                .io = self.io,
                .selected_package_name = requested_name,
                .package_carch = self.shellybuild_config.build.carch,
                .dynamic_overrides = overrides,
                .dynamic_unsets = unset_overrides,
                .dynamic_array_overrides = array_overrides,
                .dynamic_array_unsets = unset_array_overrides,
            }).parser_content(content, self.options.start_directory);
            parsed_count += 1;
        }
        if (self.evaluated_package_builds) |old_builds| {
            for (old_builds) |*package_build| package_build.deinit(self.allocator);
            self.allocator.free(old_builds);
        }
        self.evaluated_package_builds = reparsed_builds;
        self.package_builds = reparsed_builds;
    }

    /// Sandboxed builds hard-fail when the kernel cannot confine the steps:
    /// silently dropping the sandbox would run untrusted PKGBUILD code with
    /// full user access despite the explicit configuration.
    fn requireSandboxAvailability(self: *const PackageBuilder) !void {
        if (!self.shellybuild_config.sandbox.enabled) return;
        if (sandbox.abiVersion() < 1) return error.SandboxUnsupported;
    }

    fn validatePackageFunctions(self: *const PackageBuilder) !void {
        for (self.package_builds) |package_build| {
            if (package_build.has_invalid_package_assignment)
                return error.InvalidPackageFunctionVariable;
            if (package_build.is_split) {
                if (package_build.has_generic_package_function)
                    return error.ExtraSplitPackageFunction;
                if (!package_build.has_complete_split_functions or
                    !package_build.has_selected_package_function)
                    return error.MissingSplitPackageFunction;
                continue;
            }
            if (package_build.has_generic_package_function and
                package_build.has_selected_package_function)
                return error.ConflictingPackageFunctions;
            if (package_build.has_build_function and
                !package_build.has_generic_package_function and
                !package_build.has_selected_package_function)
                return error.MissingPackageFunction;
        }
    }
};
