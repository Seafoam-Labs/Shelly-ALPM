const std = @import("std");
const backend_selection = @import("backend.zig");
const configuration = @import("configuration.zig");
const operation_api = @import("operation_context");
const libalpm = @import("types.zig");
pub const ConfigError = error{
    InitFailed,
    RegisterDbFailed,
};

pub const InitError = error{
    InitFailed,
    RegisterDbFailed,
    ConfigParseFailed,
    BackendUnavailable,
    InvalidBackend,
    InvalidPreviewRoot,
    InvalidLocalDatabaseEntry,
};
pub const TransactionError = error{
    NoHandle,
    TransInitFailed,
    PrepareFailed,
    CommitFailed,
    UnsatisfiedDeps,
    ConflictingDeps,
    FileConflicts,
    SyncDbFailed,
    PackageFetchFailed,
    DatabaseReadFailed,
    RefreshFailed,
    OutOfMemory,
    NoPackageFound,
    RemovalFailed,
    UpdateFetchFailed,
    SetReasonFailed,
    PackageLoadFailed,
    PackageAddFailed,
    OrphanShootFailed,
    DirectoryReadFailed,
    Cancelled,
};

pub const QueryError = error{ DbNotFound, PkgNotFound, NoHandle, OutOfMemory, Cancelled };
pub const ReverseDependencyOptions = libalpm.ReverseDependencyOptions;

pub const IgnorePackageError = configuration.IgnorePackageError;
pub const HoldPackageError = configuration.HoldPackageError;
pub const RepositoryError = configuration.RepositoryError;

/// A package that satisfies a dependency in a configured sync database.
/// `real_name` is borrowed from the selected backend and remains valid until
/// the manager refreshes or is deinitialized.
pub const DependencySatisfier = struct {
    real_name: [:0]const u8,
    via_provides: bool,
};

/// Why restarting a systemd service failed after a system upgrade.
pub const ServiceRestartFailureKind = enum {
    spawn,
    exit_status,
    terminated,
};

/// A process which still has a deleted shared library mapped into its address
/// space. All strings are owned by the containing `RestartReport`.
pub const AffectedProcess = struct {
    pid: u32,
    command: ?[]u8,
    service: ?[]u8,

    pub fn deinit(self: *AffectedProcess, allocator: std.mem.Allocator) void {
        if (self.command) |command| allocator.free(command);
        if (self.service) |service| allocator.free(service);
        self.* = undefined;
    }
};

/// A structured failure returned when `systemctl restart` could not restart a
/// service. `exit_code` is populated only when systemctl exited normally.
pub const ServiceRestartFailure = struct {
    service: []u8,
    kind: ServiceRestartFailureKind,
    exit_code: ?u8,
    message: []u8,

    pub fn deinit(self: *ServiceRestartFailure, allocator: std.mem.Allocator) void {
        allocator.free(self.service);
        allocator.free(self.message);
        self.* = undefined;
    }
};

/// Owned restart information collected immediately after a successful system
/// upgrade. Call `deinit` when the report is no longer needed.
pub const RestartReport = struct {
    allocator: std.mem.Allocator,
    /// Null when `/proc/sys/kernel/osrelease` could not be read.
    running_kernel: ?[]u8,
    /// Null when the running kernel or module directory could not be inspected.
    running_kernel_modules_present: ?bool,
    needs_reboot: bool,
    process_scan_complete: bool,
    skipped_processes: usize,
    affected_processes: []AffectedProcess,
    affected_services: [][]u8,
    restarted_services: [][]u8,
    failures: []ServiceRestartFailure,

    pub fn empty(allocator: std.mem.Allocator) RestartReport {
        return .{
            .allocator = allocator,
            .running_kernel = null,
            .running_kernel_modules_present = null,
            .needs_reboot = false,
            .process_scan_complete = false,
            .skipped_processes = 0,
            .affected_processes = &.{},
            .affected_services = &.{},
            .restarted_services = &.{},
            .failures = &.{},
        };
    }

    pub fn deinit(self: *RestartReport) void {
        if (self.running_kernel) |running_kernel| self.allocator.free(running_kernel);
        for (self.affected_processes) |*process| process.deinit(self.allocator);
        if (self.affected_processes.len != 0) self.allocator.free(self.affected_processes);
        for (self.affected_services) |service| self.allocator.free(service);
        if (self.affected_services.len != 0) self.allocator.free(self.affected_services);
        for (self.restarted_services) |service| self.allocator.free(service);
        if (self.restarted_services.len != 0) self.allocator.free(self.restarted_services);
        for (self.failures) |*failure| failure.deinit(self.allocator);
        if (self.failures.len != 0) self.allocator.free(self.failures);
        self.* = undefined;
    }
};

pub const RestartCheckOptions = struct {
    proc_root: []const u8 = "/proc",
    modules_root: []const u8 = "/usr/lib/modules",
    systemctl_path: []const u8 = "systemctl",
    restart_services: bool = true,
};

pub const InitOptions = struct {
    backend: ?backend_selection.Backend = null,
    config_path: ?[]const u8 = null,
    use_root: bool = false,
    temp_root_path: ?[]const u8 = null,
    operation_context: ?*operation_api.OperationContext = null,
    /// Explicit native package paths used when provisioning a new root. These are
    /// applied after parsing pacman.conf so repository and signature policy is
    /// retained while all mutable transaction state stays under the target.
    root_directory: ?[]const u8 = null,
    database_path: ?[]const u8 = null,
    cache_directory: ?[]const u8 = null,
    log_file: ?[]const u8 = null,
    gpg_directory: ?[]const u8 = null,
    /// Read only the target root's hooks, including hooks installed by the
    /// current transaction. Host HookDir entries must not reach provisioning.
    root_hooks_only: bool = false,
    /// RLPM host executable with internal worker dispatch; null re-executes self.
    worker_executable: ?[]const u8 = null,
};

pub fn applyInitPathOverrides(
    config: *configuration.Configuration.Config,
    options: InitOptions,
) std.mem.Allocator.Error!void {
    const allocator = config.arena.allocator();
    if (options.root_directory) |value|
        config.root_directory = try allocator.dupeSentinel(u8, value, 0);
    if (options.database_path) |value|
        config.database_path = try allocator.dupeSentinel(u8, value, 0);
    if (options.cache_directory) |value| {
        config.cache_directory = try allocator.dupeSentinel(u8, value, 0);
        config.cache_directories.clearRetainingCapacity();
        try config.cache_directories.append(allocator, config.cache_directory);
    }
    if (options.log_file) |value|
        config.log_file = try allocator.dupeSentinel(u8, value, 0);
    if (options.gpg_directory) |value|
        config.gpg_directory = try allocator.dupeSentinel(u8, value, 0);
    if (options.root_hooks_only) {
        config.hook_directory.clearRetainingCapacity();
        for ([_][]const u8{ "usr/share/libalpm/hooks", "etc/pacman.d/hooks" }) |relative| {
            const path = try std.fs.path.join(allocator, &.{ config.root_directory, relative });
            try config.hook_directory.append(allocator, try allocator.dupeSentinel(u8, path, 0));
        }
    }
}

pub const RemovalConfirmation = enum { required, already_approved };
