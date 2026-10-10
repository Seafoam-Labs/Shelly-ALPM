//! Stable native package facade. Each instance owns exactly one backend.
const std = @import("std");
const libalpm_manager = @import("libalpm_manager.zig");
const rlpm_module = @import("Shelly_Rlpm");
const contract = @import("contract.zig");
const selection = @import("backend.zig");
const libalpm = @import("types.zig");
const downloader = @import("../shared/downloader.zig");
const operation_api = @import("operation_context");
const Native = if (selection.libalpm_enabled) libalpm_manager.Manager else void;
const Rlpm = @import("../rlpm/manager.zig").Manager;
pub const ConfigError = contract.ConfigError;
pub const InitError = contract.InitError;
pub const TransactionError = contract.TransactionError;
pub const QueryError = contract.QueryError;
pub const ReverseDependencyOptions = contract.ReverseDependencyOptions;
pub const IgnorePackageError = contract.IgnorePackageError;
pub const HoldPackageError = contract.HoldPackageError;
pub const RepositoryError = contract.RepositoryError;
pub const DependencySatisfier = contract.DependencySatisfier;
pub const ServiceRestartFailureKind = contract.ServiceRestartFailureKind;
pub const AffectedProcess = contract.AffectedProcess;
pub const ServiceRestartFailure = contract.ServiceRestartFailure;
pub const RestartReport = contract.RestartReport;
pub const RestartCheckOptions = contract.RestartCheckOptions;
pub const InitOptions = contract.InitOptions;

pub const Manager = struct {
    pub const build_transaction = @import("build_transaction.zig");
    pub const build_plan = @import("build_plan.zig");
    pub const bootstrap = @import("bootstrap.zig");
    pub const types = @import("types.zig");
    pub const Backend = @import("backend.zig").Backend;
    pub const default_backend = @import("backend.zig").default_backend;
    pub const libalpm_enabled = @import("backend.zig").libalpm_enabled;
    pub const events = @import("events.zig");
    pub const configuration = @import("configuration.zig");
    pub const cache_manager = @import("cache_manager.zig");
    pub const archive_manager = @import("archive_manager.zig");
    pub const pacfile_manager = @import("pacfile_manager.zig");

    pub const InitOptions = contract.InitOptions;
    pub const BootstrapOptions = bootstrap.Options;
    pub const BootstrapResult = bootstrap.Result;
    pub const TransFlag = types.TransFlag;
    pub const SigLevel = types.SigLevel;
    pub const OwnedPackage = types.OwnedPackage;
    pub const OwnedPackageWithUpdate = types.OwnedPackageWithUpdate;
    pub const ReverseDependencyOptions = contract.ReverseDependencyOptions;
    pub const DependencySatisfier = contract.DependencySatisfier;
    pub const RestartReport = contract.RestartReport;
    pub const AffectedProcess = contract.AffectedProcess;
    pub const ServiceRestartFailure = contract.ServiceRestartFailure;
    pub const ServiceRestartFailureKind = contract.ServiceRestartFailureKind;
    pub const Repository = configuration.Configuration.Repository;
    pub const ArchiveManager = archive_manager.ArchiveManager;
    pub const ArchiveManagerOptions = archive_manager.Options;
    pub const ArchiveError = archive_manager.Error;
    pub const ArchiveDiscoveryError = archive_manager.DiscoveryError;
    pub const ArchiveInstallError = archive_manager.InstallError;
    pub const ArchiveSource = archive_manager.Source;
    pub const ArchiveEndpoint = archive_manager.ArchiveEndpoint;
    pub const DowngradeCandidate = archive_manager.DowngradeCandidate;
    pub const PreparedDowngradePackage = archive_manager.PreparedPackage;
    pub const parse_archive_listing = archive_manager.parseArchiveListing;
    pub const CacheManager = cache_manager.CacheManager;
    pub const CacheManagerOptions = cache_manager.Options;
    pub const CacheCleanOptions = cache_manager.CleanOptions;
    pub const CacheInstalledFilter = cache_manager.InstalledFilter;
    pub const CacheEntry = cache_manager.Entry;
    pub const CacheRemovalItem = cache_manager.RemovalItem;
    pub const CacheRemovalPlan = cache_manager.RemovalPlan;
    pub const CacheExecutionResult = cache_manager.ExecutionResult;
    pub const CacheError = cache_manager.Error;
    pub const parse_cache_package_filename = cache_manager.parsePackageFilename;
    pub const PacfileManager = pacfile_manager.PacfileManager;
    pub const PacfileManagerOptions = pacfile_manager.Options;
    pub const PacfileError = pacfile_manager.Error;
    pub const PacfileSearchMode = pacfile_manager.SearchMode;
    pub const PacfileKind = pacfile_manager.Kind;
    pub const PacfileState = pacfile_manager.State;
    pub const PacfileDiffMode = pacfile_manager.DiffMode;
    pub const ParsedPacfilePath = pacfile_manager.ParsedPath;
    pub const Pacfile = pacfile_manager.Pacfile;
    pub const PacfileToolResult = pacfile_manager.ToolResult;
    pub const PacfileViewResult = pacfile_manager.ViewResult;
    pub const PreparedPacfileMerge = pacfile_manager.PreparedMerge;
    pub const parse_pacfile_path = pacfile_manager.parsePacfilePath;

    const Engine = union(selection.Backend) { libalpm: if (selection.libalpm_enabled) *Native else void, rlpm: *Rlpm };
    engine: ?Engine = null,
    allocator: std.mem.Allocator,
    config: *configuration.Configuration.Config,
    dispatcher: *events.Dispatcher,
    show_hidden_packages: bool = false,
    pub const RemovalConfirmation = contract.RemovalConfirmation;

    pub fn init(allocator: std.mem.Allocator, environ: std.process.Environ, options: contract.InitOptions) InitError!*Manager {
        const chosen = options.backend orelse selection.selectedDefault();
        try chosen.validate();
        const self = allocator.create(Manager) catch return error.InitFailed;
        errdefer allocator.destroy(self);
        switch (chosen) {
            .libalpm => if (comptime selection.libalpm_enabled) {
                const native = try Native.init(allocator, environ, options);
                self.* = .{ .engine = .{ .libalpm = native }, .allocator = allocator, .config = &native.config, .dispatcher = &native.dispatcher };
            } else return error.BackendUnavailable,
            .rlpm => {
                const native = Rlpm.init(allocator, environ, options) catch |err| return switch (err) {
                    error.OutOfMemory => error.InitFailed,
                    error.ConfigParseFailed => error.ConfigParseFailed,
                    error.InvalidPreviewRoot => error.InvalidPreviewRoot,
                    error.InvalidLocalDatabaseEntry => error.InvalidLocalDatabaseEntry,
                    else => error.InitFailed,
                };
                self.* = .{ .engine = .{ .rlpm = native }, .allocator = allocator, .config = &native.config, .dispatcher = &native.dispatcher };
            },
        }
        return self;
    }
    pub fn packageSetupFailed(self: *const Manager) bool {
        return switch (self.engine.?) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.package_setup_failed else unreachable,
            .rlpm => |value| value.package_setup_failed,
        };
    }
    pub fn backend(self: *const Manager) selection.Backend {
        return std.meta.activeTag(self.engine.?);
    }
    pub const defaultBackend = selection.selectedDefault;
    pub fn setDefaultBackend(value: selection.Backend) !void {
        try selection.setDefault(value);
    }
    pub fn setDefaultDownloadAddressFamilyPolicy(value: downloader.AddressFamilyPolicy) void {
        Rlpm.setDefaultDownloadAddressFamilyPolicy(value);
        if (comptime selection.libalpm_enabled) Native.setDefaultDownloadAddressFamilyPolicy(value);
    }
    pub fn defaultDownloadAddressFamilyPolicy() downloader.AddressFamilyPolicy {
        return Rlpm.defaultDownloadAddressFamilyPolicy();
    }
    pub fn setDefaultParallelDownloadCount(value: u8) void {
        Rlpm.setDefaultParallelDownloadCount(value);
        if (comptime selection.libalpm_enabled) Native.setDefaultParallelDownloadCount(value);
    }
    pub fn defaultParallelDownloadCount() u8 {
        return Rlpm.defaultParallelDownloadCount();
    }
    pub fn compare_package_versions(a: [:0]const u8, b: [:0]const u8) c_int {
        if (comptime selection.libalpm_enabled) {
            if (selection.selectedDefault() == .libalpm) return Native.compare_package_versions(a, b);
        }
        return @intFromEnum(rlpm_module.Version.compareStrings(a, b));
    }
    pub const version_compare = compare_package_versions;
    pub fn toggle_hidden_packages(self: *Manager) bool {
        self.show_hidden_packages = !self.show_hidden_packages;
        switch (self.engine.?) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) {
                value.show_hidden_packages = self.show_hidden_packages;
            },
            .rlpm => |value| value.show_hidden_packages = self.show_hidden_packages,
        }
        return self.show_hidden_packages;
    }
    pub fn deinit(self: *Manager) void {
        if (self.engine) |engine| switch (engine) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.deinit(),
            .rlpm => |value| value.deinit(),
        };
        self.allocator.destroy(self);
    }
    /// Caller owns the returned snapshot, including archive metadata.
    pub fn load_archive(self: *Manager, path: []const u8) !libalpm.OwnedPackage {
        return switch (self.engine orelse return error.NoHandle) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.load_archive(path) else unreachable,
            .rlpm => |value| value.load_archive(path),
        };
    }
    pub fn setOperationContext(self: *Manager, context: ?*operation_api.OperationContext) void {
        return switch (self.engine orelse {
            unreachable;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.setOperationContext(context) else unreachable,
            .rlpm => |value| value.setOperationContext(context),
        };
    }
    pub fn setDownloadAddressFamilyPolicy(self: *Manager, policy: downloader.AddressFamilyPolicy) void {
        return switch (self.engine orelse {
            unreachable;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.setDownloadAddressFamilyPolicy(policy) else unreachable,
            .rlpm => |value| value.setDownloadAddressFamilyPolicy(policy),
        };
    }
    pub fn sync(self: *Manager, force: bool) TransactionError!void {
        return switch (self.engine orelse {
            return error.NoHandle;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.sync(force) else unreachable,
            .rlpm => |value| value.sync(force) catch |err| return mapTransaction(err),
        };
    }
    pub fn sync_for_update_check(self: *Manager, force: bool) TransactionError!void {
        return switch (self.engine orelse {
            return error.NoHandle;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.sync_for_update_check(force) else unreachable,
            .rlpm => |value| value.sync_for_update_check(force) catch |err| return mapTransaction(err),
        };
    }
    pub fn get_installed_packages(self: *Manager) TransactionError![]libalpm.OwnedPackage {
        return switch (self.engine orelse {
            return error.NoHandle;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.get_installed_packages() else unreachable,
            .rlpm => |value| value.get_installed_packages() catch |err| return mapTransaction(err),
        };
    }
    pub fn get_installed_packages_with_reverse_dependencies(
        self: *Manager,
        reverse_dependencies: contract.ReverseDependencyOptions,
    ) TransactionError![]libalpm.OwnedPackage {
        return switch (self.engine orelse {
            return error.NoHandle;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.get_installed_packages_with_reverse_dependencies(reverse_dependencies) else unreachable,
            .rlpm => |value| value.get_installed_packages_with_reverse_dependencies(reverse_dependencies) catch |err| return mapTransaction(err),
        };
    }
    pub fn get_single_installed_package(self: *Manager, package_name: [:0]const u8) TransactionError!?libalpm.OwnedPackage {
        return switch (self.engine orelse {
            return error.NoHandle;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) blk: {
                const package = try value.get_single_installed_package(package_name) orelse break :blk null;
                break :blk try libalpm.OwnedPackage.initWithReverseDependencies(self.allocator, package, .{ .required_by = true, .optional_for = true });
            } else unreachable,
            .rlpm => |value| value.get_single_installed_package(package_name) catch |err| return mapTransaction(err),
        };
    }
    pub fn get_foreign_packages(self: *Manager) TransactionError![]libalpm.OwnedPackage {
        return switch (self.engine orelse {
            return error.NoHandle;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.get_foreign_packages() else unreachable,
            .rlpm => |value| value.get_foreign_packages() catch |err| return mapTransaction(err),
        };
    }
    pub fn get_available_packages(self: *Manager) TransactionError![]libalpm.OwnedPackage {
        return switch (self.engine orelse {
            return error.NoHandle;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.get_available_packages() else unreachable,
            .rlpm => |value| value.get_available_packages() catch |err| return mapTransaction(err),
        };
    }
    pub fn get_available_packages_from_group(self: *Manager, groupName: [:0]const u8) TransactionError![]libalpm.OwnedPackage {
        return switch (self.engine orelse {
            return error.NoHandle;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.get_available_packages_from_group(groupName) else unreachable,
            .rlpm => |value| value.get_available_packages_from_group(groupName) catch |err| return mapTransaction(err),
        };
    }
    pub fn get_updates_available(self: *Manager) TransactionError![]libalpm.OwnedPackageWithUpdate {
        return switch (self.engine orelse {
            return error.NoHandle;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.get_updates_available() else unreachable,
            .rlpm => |value| value.get_updates_available() catch |err| return mapTransaction(err),
        };
    }
    /// Prepare using the same native transaction as installation, without committing.
    /// Caller supplies a private, empty database and an arena for the snapshot.
    pub fn prepare_build_packages(self: *Manager, allocator: std.mem.Allocator, targets: [][:0]const u8) ![]const build_transaction.Package {
        var issues: []const build_transaction.Issue = &.{};
        return self.prepare_build_packages_report(allocator, targets, &issues);
    }

    pub fn prepare_build_packages_report(self: *Manager, allocator: std.mem.Allocator, targets: [][:0]const u8, issues: *[]const build_transaction.Issue) ![]const build_transaction.Package {
        var output: []const build_transaction.Package = &.{};
        try self.buildTransaction(targets, .{ .nolock = true }, .{ .allocator = allocator, .output = &output, .issues = issues });
        return output;
    }

    pub fn install_build_packages(self: *Manager, targets: [][:0]const u8, expected: []const build_transaction.Package) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        self.buildTransaction(targets, .{}, .{ .allocator = arena.allocator(), .expected = expected }) catch |err| switch (err) {
            error.PrepareFailed, error.NoPackageFound, error.PackageFetchFailed, error.TargetNotFound, error.UnsatisfiedDependencies, error.ConflictingDependencies => return error.DependencyPlanMismatch,
            else => return err,
        };
        const installed = try self.get_installed_packages();
        defer OwnedPackage.deinitSlice(self.allocator, installed);
        if (installed.len != expected.len) return error.DependencyPlanMismatch;
        for (expected) |pinned| {
            var found = false;
            for (installed) |actual| if (std.mem.eql(u8, actual.name_value, pinned.name)) {
                if (!std.mem.eql(u8, actual.version_value, pinned.version) or
                    !std.mem.eql(u8, actual.architecture_value orelse "", pinned.architecture)) return error.DependencyPlanMismatch;
                found = true;
                break;
            };
            if (!found) return error.DependencyPlanMismatch;
        }
    }

    fn buildTransaction(self: *Manager, targets: [][:0]const u8, flags: TransFlag, request: build_transaction.Request) !void {
        switch (self.engine.?) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) try value.installBuildTransaction(targets, flags, request) else unreachable,
            .rlpm => |value| try value.installBuildTransaction(targets, flags, request),
        }
    }

    pub fn install_packages(
        self: *Manager,
        package_names: [][:0]const u8,
        trans_flags_arg: TransFlag,
    ) TransactionError!void {
        return switch (self.engine orelse {
            return error.NoHandle;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.install_packages(package_names, trans_flags_arg) else unreachable,
            .rlpm => |value| value.install_packages(package_names, trans_flags_arg) catch |err| return mapTransaction(err),
        };
    }
    pub fn remove_packages(self: *Manager, packages_names: [][:0]const u8, flags: TransFlag, keep_optional_dependencis: bool) TransactionError!void {
        return switch (self.engine orelse {
            return error.NoHandle;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.remove_packages(packages_names, flags, keep_optional_dependencis) else unreachable,
            .rlpm => |value| value.remove_packages(packages_names, flags, keep_optional_dependencis) catch |err| return mapTransaction(err),
        };
    }
    pub fn remove_packages_with_confirmation(self: *Manager, packages_names: [][:0]const u8, flags: TransFlag, keep_optional_dependencis: bool, confirmation: RemovalConfirmation) TransactionError!void {
        return switch (self.engine orelse {
            return error.NoHandle;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.remove_packages_with_confirmation(packages_names, flags, keep_optional_dependencis, confirmation) else unreachable,
            .rlpm => |value| value.remove_packages_with_confirmation(packages_names, flags, keep_optional_dependencis, confirmation) catch |err| return mapTransaction(err),
        };
    }
    pub fn sync_system_update(self: *Manager, flags: TransFlag) TransactionError!contract.RestartReport {
        return switch (self.engine orelse {
            return error.NoHandle;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.sync_system_update(flags) else unreachable,
            .rlpm => |value| value.sync_system_update(flags) catch |err| return mapTransaction(err),
        };
    }
    pub fn update_package_reason(self: *Manager, pkg_name: [:0]const u8, reason: libalpm.PackageReason) TransactionError!void {
        return switch (self.engine orelse {
            return error.NoHandle;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.update_package_reason(pkg_name, reason) else unreachable,
            .rlpm => |value| value.update_package_reason(pkg_name, reason) catch |err| return mapTransaction(err),
        };
    }
    pub fn install_local_packages(self: *Manager, paths: []const []const u8, flags: TransFlag) TransactionError!void {
        return switch (self.engine orelse {
            return error.NoHandle;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.install_local_packages(paths, flags) else unreachable,
            .rlpm => |value| value.install_local_packages(paths, flags) catch |err| return mapTransaction(err),
        };
    }
    pub fn disable_transaction_hooks(self: *Manager) void {
        return switch (self.engine orelse {
            unreachable;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.disable_transaction_hooks() else unreachable,
            .rlpm => |value| value.disable_transaction_hooks(),
        };
    }
    pub fn get_package_from_provides(self: *Manager, provides: [:0]const u8) QueryError![:0]const u8 {
        return switch (self.engine orelse {
            return error.NoHandle;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.get_package_from_provides(provides) else unreachable,
            .rlpm => |value| value.get_package_from_provides(provides) catch |err| return mapQuery(err),
        };
    }
    pub fn is_dependency_satisfied_by_installed_packages(self: *Manager, dependency: [:0]const u8) QueryError!bool {
        return switch (self.engine orelse {
            return error.NoHandle;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.is_dependency_satisfied_by_installed_packages(dependency) else unreachable,
            .rlpm => |value| value.is_dependency_satisfied_by_installed_packages(dependency) catch |err| return mapQuery(err),
        };
    }
    pub fn find_remote_satisfier_for_dependency(self: *Manager, dependency: [:0]const u8) QueryError![:0]const u8 {
        return switch (self.engine orelse {
            return error.NoHandle;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.find_remote_satisfier_for_dependency(dependency) else unreachable,
            .rlpm => |value| value.find_remote_satisfier_for_dependency(dependency) catch |err| return mapQuery(err),
        };
    }
    pub fn find_remote_satisfier_for_dependency_details(
        self: *Manager,
        dependency: [:0]const u8,
    ) QueryError!contract.DependencySatisfier {
        return switch (self.engine orelse {
            return error.NoHandle;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.find_remote_satisfier_for_dependency_details(dependency) else unreachable,
            .rlpm => |value| value.find_remote_satisfier_for_dependency_details(dependency) catch |err| return mapQuery(err),
        };
    }
    pub fn install_dependencies_only(self: *Manager, package_name: [:0]const u8, include_make_deps: bool, flags: TransFlag) TransactionError!void {
        return switch (self.engine orelse {
            return error.NoHandle;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.install_dependencies_only(package_name, include_make_deps, flags) else unreachable,
            .rlpm => |value| value.install_dependencies_only(package_name, include_make_deps, flags) catch |err| return mapTransaction(err),
        };
    }
    pub fn update_packages(self: *Manager, package_list: [][:0]const u8, flags: libalpm.TransFlag) TransactionError!void {
        return switch (self.engine orelse {
            return error.NoHandle;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.update_packages(package_list, flags) else unreachable,
            .rlpm => |value| value.update_packages(package_list, flags) catch |err| return mapTransaction(err),
        };
    }
    pub fn purify(self: *Manager, dry_run: bool, shoot_orphans: bool, purge_corruption: bool) TransactionError![][:0]const u8 {
        return switch (self.engine orelse {
            return error.NoHandle;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.purify(dry_run, shoot_orphans, purge_corruption) else unreachable,
            .rlpm => |value| value.purify(dry_run, shoot_orphans, purge_corruption) catch |err| return mapTransaction(err),
        };
    }
    pub fn is_package_installed(self: *Manager, package_name: [:0]const u8) bool {
        return switch (self.engine orelse {
            return false;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.is_package_installed(package_name) else unreachable,
            .rlpm => |value| value.is_package_installed(package_name),
        };
    }
    pub fn ignore_package(self: *Manager, package_name: []const u8) IgnorePackageError!void {
        return switch (self.engine orelse {
            return error.ConfigReadFailed;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.ignore_package(package_name) else unreachable,
            .rlpm => |value| value.ignore_package(package_name),
        };
    }
    pub fn ignore_packages(self: *Manager, package_names: []const []const u8) IgnorePackageError!void {
        return switch (self.engine orelse {
            return error.ConfigReadFailed;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.ignore_packages(package_names) else unreachable,
            .rlpm => |value| value.ignore_packages(package_names),
        };
    }
    pub fn unignore_package(self: *Manager, package_name: []const u8) IgnorePackageError!void {
        return switch (self.engine orelse {
            return error.ConfigReadFailed;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.unignore_package(package_name) else unreachable,
            .rlpm => |value| value.unignore_package(package_name),
        };
    }
    pub fn unignore_packages(self: *Manager, package_names: []const []const u8) IgnorePackageError!void {
        return switch (self.engine orelse {
            return error.ConfigReadFailed;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.unignore_packages(package_names) else unreachable,
            .rlpm => |value| value.unignore_packages(package_names),
        };
    }
    pub fn get_ignored_packages(self: *Manager) IgnorePackageError!std.ArrayList([:0]const u8) {
        return switch (self.engine orelse {
            unreachable;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.get_ignored_packages() else unreachable,
            .rlpm => |value| value.get_ignored_packages(),
        };
    }
    pub fn hold_package(self: *Manager, package_name: []const u8) HoldPackageError!void {
        return switch (self.engine orelse {
            return error.ConfigReadFailed;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.hold_package(package_name) else unreachable,
            .rlpm => |value| value.hold_package(package_name),
        };
    }
    pub fn hold_packages(self: *Manager, package_names: []const []const u8) HoldPackageError!void {
        return switch (self.engine orelse {
            return error.ConfigReadFailed;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.hold_packages(package_names) else unreachable,
            .rlpm => |value| value.hold_packages(package_names),
        };
    }
    pub fn unhold_package(self: *Manager, package_name: []const u8) HoldPackageError!void {
        return switch (self.engine orelse {
            return error.ConfigReadFailed;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.unhold_package(package_name) else unreachable,
            .rlpm => |value| value.unhold_package(package_name),
        };
    }
    pub fn unhold_packages(self: *Manager, package_names: []const []const u8) HoldPackageError!void {
        return switch (self.engine orelse {
            return error.ConfigReadFailed;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.unhold_packages(package_names) else unreachable,
            .rlpm => |value| value.unhold_packages(package_names),
        };
    }
    pub fn get_held_packages(self: *Manager) HoldPackageError!std.ArrayList([:0]const u8) {
        return switch (self.engine orelse {
            unreachable;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.get_held_packages() else unreachable,
            .rlpm => |value| value.get_held_packages(),
        };
    }
    pub fn add_repository(
        self: *Manager,
        name: []const u8,
        servers: []const []const u8,
        sig_level: []const u8,
        usage: []const u8,
    ) RepositoryError!void {
        return switch (self.engine orelse {
            return error.ConfigReadFailed;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.add_repository(name, servers, sig_level, usage) else unreachable,
            .rlpm => |value| value.add_repository(name, servers, sig_level, usage),
        };
    }
    pub fn remove_repository(
        self: *Manager,
        name: []const u8,
    ) RepositoryError!void {
        return switch (self.engine orelse {
            return error.ConfigReadFailed;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.remove_repository(name) else unreachable,
            .rlpm => |value| value.remove_repository(name),
        };
    }
    pub fn get_repository_names(self: *Manager) QueryError!std.ArrayList([]const u8) {
        return switch (self.engine orelse {
            return error.NoHandle;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.get_repository_names() else unreachable,
            .rlpm => |value| value.get_repository_names(),
        };
    }
    pub fn find_configured_repository(
        self: *const Manager,
        name: []const u8,
    ) ?*const configuration.Configuration.Repository {
        return switch (self.engine orelse {
            return null;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.find_configured_repository(name) else unreachable,
            .rlpm => |value| value.find_configured_repository(name),
        };
    }
    pub fn get_configured_cache_directories(self: *Manager) QueryError!std.ArrayList([:0]const u8) {
        return switch (self.engine orelse {
            return error.NoHandle;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.get_configured_cache_directories() else unreachable,
            .rlpm => |value| value.get_configured_cache_directories(),
        };
    }
    pub fn get_cache_directories(self: *Manager) QueryError!std.ArrayList([:0]const u8) {
        return switch (self.engine orelse {
            return error.NoHandle;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.get_cache_directories() else unreachable,
            .rlpm => |value| value.get_cache_directories(),
        };
    }
    pub fn is_cachyos(self: *const Manager) bool {
        return switch (self.engine orelse {
            return false;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.is_cachyos() else unreachable,
            .rlpm => |value| value.is_cachyos(),
        };
    }
    pub fn get_allowed_architecture(self: *Manager) QueryError![][:0]const u8 {
        return switch (self.engine orelse {
            return error.NoHandle;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.get_allowed_architecture() else unreachable,
            .rlpm => |value| value.get_allowed_architecture() catch |err| return mapQuery(err),
        };
    }
    pub fn refresh(self: *Manager) TransactionError!void {
        return switch (self.engine orelse {
            return error.NoHandle;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.refresh() else unreachable,
            .rlpm => |value| value.refresh() catch |err| return mapTransaction(err),
        };
    }
    pub fn get_required_packages(self: *Manager, packageName: []const u8, databaseName: []const u8) TransactionError![][]const u8 {
        return switch (self.engine orelse {
            return error.NoHandle;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.get_required_packages(packageName, databaseName) else unreachable,
            .rlpm => |value| value.get_required_packages(packageName, databaseName) catch |err| return mapTransaction(err),
        };
    }
    pub fn io(self: *Manager) std.Io {
        return switch (self.engine orelse {
            unreachable;
        }) {
            .libalpm => |value| if (comptime selection.libalpm_enabled) value.io() else unreachable,
            .rlpm => |value| value.io(),
        };
    }
};
fn mapQuery(err: anyerror) QueryError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Cancelled => error.Cancelled,
        error.PkgNotFound => error.PkgNotFound,
        error.NoHandle => error.NoHandle,
        else => error.DbNotFound,
    };
}
fn mapTransaction(err: anyerror) TransactionError {
    if (err == error.DatabaseLocked or err == error.LockExists) return error.TransInitFailed;
    inline for (@typeInfo(TransactionError).error_set.?) |field| {
        if (err == @field(TransactionError, field.name)) return @field(TransactionError, field.name);
    }
    return error.CommitFailed;
}
