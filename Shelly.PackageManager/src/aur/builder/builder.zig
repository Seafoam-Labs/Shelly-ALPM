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
        self.allocator.destroy(self);
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

    fn buildPackage(self: *PackageBuilder, operation: *op_context.Operation) ![]BuildArtifact {
        try security.secureBuilderProcess();
        try self.requireSandboxAvailability();
        if (self.package_builds[0].hasDynamicAssignments())
            try self.resolveDynamicBuilds(operation);
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
            const artifact = try package_file.assemblePackage(self, package_build);
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

    /// Resolves packages that declare top-level command-substitution
    /// assignments. The recorded assignments are evaluated in the sandbox
    /// (post-review), then the PKGBUILD is re-parsed with the resulting values
    /// seeded so downstream stages — source acquisition and lifecycle steps —
    /// see fully resolved metadata. Replaces `package_builds` contents in place.
    fn resolveDynamicBuilds(self: *PackageBuilder, operation: *op_context.Operation) !void {
        var overrides = try steps.evaluateDynamicAssignments(self, operation);
        defer {
            var it = overrides.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            overrides.deinit();
        }

        const pkgbuild_path = self.options.pkgbuild_path orelse
            return error.UnreviewedBuilderRequest;
        const content = try std.Io.Dir.cwd().readFileAlloc(
            self.io,
            pkgbuild_path,
            self.allocator,
            .limited(32 * 1024 * 1024),
        );
        defer self.allocator.free(content);

        for (self.package_builds, self.requested_names) |*package_build, requested_name| {
            const reparsed = try (pkgbuild_parser.PkgbuildParser{
                .allocator = self.allocator,
                .io = self.io,
                .selected_package_name = requested_name,
                .package_carch = self.shellybuild_config.build.carch,
                .dynamic_overrides = &overrides,
            }).parser_content(content, self.options.start_directory);
            package_build.deinit(self.allocator);
            package_build.* = reparsed;
        }
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
