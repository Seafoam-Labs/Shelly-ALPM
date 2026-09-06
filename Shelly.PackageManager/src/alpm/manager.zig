const std = @import("std");
const bindings = @import("bindings.zig");
const events = @import("events.zig");
const configuration = @import("configuration.zig");
const builtin = @import("builtin");
const downloader = @import("../shared/downloader.zig");
const listDictionary = @import("../shared/list_dictionary.zig");
const os_tool = @import("distribution-hooks/os_utilities.zig");
const TransFlag = bindings.libalpm.TransFlag;
const cachyos = @import("distribution-hooks/CachyOS/update_notice.zig");
const operation_api = @import("operation_context");
const user_errors = @import("../shared/user_errors.zig");

const libalpm = bindings.libalpm; // typed aliases (Handle, Database, Config, ...)
const rawLibalpm = bindings.libalpm.alpm;
const single_server_setup_timeout_seconds: u32 = 3;
const multi_server_setup_timeout_seconds: u32 = 1;
const database_file_permissions = std.Io.File.Permissions.fromMode(0o644);
const database_directory_permissions = std.Io.File.Permissions.fromMode(0o755);
var default_download_address_family_policy = std.atomic.Value(u8).init(
    @intFromEnum(downloader.AddressFamilyPolicy.prefer_ipv4),
);

const DatabaseSignaturePolicy = enum {
    disabled,
    optional,
    required,
};

pub const ConfigError = error{
    InitFailed,
    RegisterDbFailed,
};

pub const InitError = error{
    InitFailed,
    RegisterDbFailed,
    ConfigParseFailed,
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
/// `real_name` is borrowed from libalpm and remains valid while the manager's
/// databases remain loaded.
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

    fn deinit(self: *AffectedProcess, allocator: std.mem.Allocator) void {
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

    fn deinit(self: *ServiceRestartFailure, allocator: std.mem.Allocator) void {
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

const RestartCheckOptions = struct {
    proc_root: []const u8 = "/proc",
    modules_root: []const u8 = "/usr/lib/modules",
    systemctl_path: []const u8 = "systemctl",
    restart_services: bool = true,
};

pub const InitOptions = struct {
    config_path: ?[]const u8 = null,
    use_root: bool = false,
    temp_root_path: ?[]const u8 = null,
    operation_context: ?*operation_api.OperationContext = null,
    /// Explicit libalpm paths used when provisioning a new root. These are
    /// applied after parsing pacman.conf so repository and signature policy is
    /// retained while all mutable transaction state stays under the target.
    root_directory: ?[]const u8 = null,
    database_path: ?[]const u8 = null,
    cache_directory: ?[]const u8 = null,
    log_file: ?[]const u8 = null,
    gpg_directory: ?[]const u8 = null,
};

fn applyInitPathOverrides(
    config: *configuration.Configuration.Config,
    options: InitOptions,
) std.mem.Allocator.Error!void {
    const allocator = config.arena.allocator();
    if (options.root_directory) |value|
        config.root_directory = try allocator.dupeSentinel(u8, value, 0);
    if (options.database_path) |value|
        config.database_path = try allocator.dupeSentinel(u8, value, 0);
    if (options.cache_directory) |value|
        config.cache_directory = try allocator.dupeSentinel(u8, value, 0);
    if (options.log_file) |value|
        config.log_file = try allocator.dupeSentinel(u8, value, 0);
    if (options.gpg_directory) |value|
        config.gpg_directory = try allocator.dupeSentinel(u8, value, 0);
}

pub const Manager = struct {
    handle: libalpm.Handle = null,
    is_initialized: bool = false,
    detected_cachyos: bool = false,
    hooks_disabled: bool = false,
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    config_path: []const u8,
    config: configuration.Configuration.Config,
    dispatcher: events.Dispatcher,
    threaded: std.Io.Threaded,
    local_db: ?bindings.libalpm.Database = null,
    sync_dbs: std.ArrayList(bindings.libalpm.Database) = .empty,
    package_download: bool = false,
    is_root: bool = false,
    temp_root_path: []const u8,
    show_hidden_packages: bool = false,
    download_address_family_policy: downloader.AddressFamilyPolicy = .prefer_ipv4,
    operation_context: ?*operation_api.OperationContext = null,
    unexpected_fetch_reported: std.atomic.Value(bool) = .init(false),

    /// Sets the address-family policy inherited by managers created afterwards.
    pub fn setDefaultDownloadAddressFamilyPolicy(policy: downloader.AddressFamilyPolicy) void {
        default_download_address_family_policy.store(@intFromEnum(policy), .release);
    }

    /// Returns the current process-wide policy for newly created managers.
    pub fn defaultDownloadAddressFamilyPolicy() downloader.AddressFamilyPolicy {
        return @enumFromInt(default_download_address_family_policy.load(.acquire));
    }

    /// If null is passed for config it will use the default /etc/pacman.conf.
    /// The caller owns the returned manager and must call deinit when finished.
    pub fn init(
        allocator: std.mem.Allocator,
        environ: std.process.Environ,
        options: InitOptions,
    ) InitError!*Manager {
        const config_path = options.config_path orelse "/etc/pacman.conf";
        const self = allocator.create(Manager) catch return InitError.InitFailed;
        errdefer allocator.destroy(self);

        var init_operation: ?operation_api.Operation = if (options.operation_context) |context|
            context.begin(.{ .backend = .alpm, .kind = .configure, .subject = "libalpm" })
        else
            null;

        var completion: operation_api.CompletionStatus = .failed;
        defer if (init_operation) |*operation| operation.finish(completion);

        const owned_config_path = allocator.dupe(u8, config_path) catch return InitError.InitFailed;
        errdefer allocator.free(owned_config_path);
        self.* = Manager{
            .handle = null,
            .is_initialized = true,
            .allocator = allocator,
            .environ = environ,
            .config_path = owned_config_path,
            .dispatcher = events.Dispatcher.init(allocator),
            .threaded = .init(allocator, .{ .environ = environ }),
            .config = undefined,
            .is_root = options.use_root,
            .temp_root_path = options.temp_root_path orelse "",
            .download_address_family_policy = defaultDownloadAddressFamilyPolicy(),
            .operation_context = options.operation_context,
        };

        if (init_operation) |*operation| {
            self.dispatcher.setOperation(operation);
        }
        defer self.dispatcher.setOperation(null);

        errdefer self.threaded.deinit();
        errdefer self.dispatcher.deinit();
        self.config = configuration.Configuration.parse(allocator, self.io(), config_path) catch {
            return InitError.ConfigParseFailed;
        };
        errdefer self.config.deinitialize();
        errdefer self.sync_dbs.deinit(self.allocator);
        applyInitPathOverrides(&self.config, options) catch return InitError.InitFailed;
        if (os_tool.prettyName(self.allocator, self.io())) |pretty_name| {
            defer self.allocator.free(pretty_name);
            if (std.ascii.eqlIgnoreCase("cachyos", pretty_name)) self.detected_cachyos = true;
        }

        // Checks to see if the temp path is being used to run in non-root mode
        // for update checking. Symlink the real local database into the temp
        // path so ALPM can see installed packages when checking for updates.
        if (self.temp_root_path.len != 0) {
            const configured_db_path = std.fs.path.resolve(
                self.allocator,
                &.{self.config.database_path},
            ) catch return InitError.InitFailed;
            defer self.allocator.free(configured_db_path);
            const resolved_temp_root = std.fs.path.resolve(
                self.allocator,
                &.{self.temp_root_path},
            ) catch return InitError.InitFailed;
            defer self.allocator.free(resolved_temp_root);
            if (std.mem.eql(u8, configured_db_path, resolved_temp_root))
                return InitError.InitFailed;

            // "{DBPath}/local" for the *real* database, captured before we repoint DBPath.
            const real_local_db = blk: {
                const s = std.fmt.allocPrint(self.allocator, "{s}/local", .{self.config.database_path}) catch {
                    return InitError.InitFailed;
                };
                defer self.allocator.free(s);
                break :blk self.allocator.dupeSentinel(u8, s, 0) catch return InitError.InitFailed;
            };
            defer self.allocator.free(real_local_db);

            // From here on libalpm should read/write the local db under the temp root.
            self.config.database_path = self.config.arena.allocator().dupeSentinel(u8, self.temp_root_path, 0) catch {
                return InitError.InitFailed;
            };

            // "{tempPath}/local" — the symlink we want to (re)create.
            const temp_local_db = blk: {
                const s = std.fmt.allocPrint(self.allocator, "{s}/local", .{self.temp_root_path}) catch {
                    return InitError.InitFailed;
                };
                defer self.allocator.free(s);
                break :blk self.allocator.dupeSentinel(u8, s, 0) catch return InitError.InitFailed;
            };
            defer self.allocator.free(temp_local_db);

            // Only link if the real local database actually exists.
            if (std.Io.Dir.cwd().statFile(self.io(), real_local_db, .{})) |_| {
                // Remove any existing dir/symlink at the temp location so we can create
                // a fresh symlink. deleteTree unlinks a symlink (leaving its target
                // intact) and recursively removes a real directory, covering both of
                // the C# branches; a missing path is not an error we care about.
                std.Io.Dir.cwd().deleteTree(self.io(), temp_local_db) catch {};
                _ = rawLibalpm.symlink(real_local_db.ptr, temp_local_db.ptr);
            } else |_| {}
        }

        var err: rawLibalpm.alpm_errno_t = 0;

        self.handle = rawLibalpm.alpm_initialize(self.config.root_directory, self.config.database_path, &err) orelse {
            const code: c_int = @intCast(err);
            const message = std.fmt.allocPrint(self.allocator, "alpm_initialize failed: {s}", .{std.mem.span(rawLibalpm.alpm_strerror(err))}) catch "Unknown Failure";
            defer self.allocator.free(message);

            if (init_operation) |*operation| {
                operation.reportError(error.InitFailed, message, "alpm", code, false);
            } else {
                std.log.err("alpm_initialize failed: {s}", .{std.mem.span(rawLibalpm.alpm_strerror(err))});
            }
            return error.InitFailed;
        };

        self.is_initialized = true;

        self.applyConfig(self.config);
        self.setupCallbacks();
        completion = .success;
        return self;
    }

    pub fn toggle_hidden_packages(self: *Manager) bool {
        self.show_hidden_packages = !self.show_hidden_packages;
        return self.show_hidden_packages;
    }

    /// Borrows a shared operation context; it must outlive this manager and all
    /// synchronous calls made through it.
    pub fn setOperationContext(self: *Manager, context: ?*operation_api.OperationContext) void {
        self.operation_context = context;
    }

    /// Changes the address-family policy for subsequent repository database and
    /// package downloads. Existing connections are unaffected.
    pub fn setDownloadAddressFamilyPolicy(self: *Manager, policy: downloader.AddressFamilyPolicy) void {
        self.download_address_family_policy = policy;
    }

    pub fn sync(self: *Manager, force: bool) TransactionError!void {
        return self.syncDatabases(force, true);
    }

    /// Synchronizes repository databases for a non-root update preview. This
    /// mirrors the C# temporary-DB path: downloads and reloads the user-owned
    /// databases, but leaves signature enforcement to the eventual root
    /// transaction instead of rejecting an otherwise readable preview cache.
    pub fn sync_for_update_check(self: *Manager, force: bool) TransactionError!void {
        return self.syncDatabases(force, false);
    }

    fn syncDatabases(
        self: *Manager,
        force: bool,
        enforce_signature_verification: bool,
    ) TransactionError!void {
        if (self.handle == null) return TransactionError.SyncDbFailed;
        var operation_scope = OperationScope.init(self, .sync, null);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkOperationCancelled();
        var signature_policies = std.StringHashMap(DatabaseSignaturePolicy).init(self.allocator);
        defer signature_policies.deinit();
        self.package_download = false;
        var databases: libalpm.DatabaseList = rawLibalpm.alpm_get_syncdbs(self.handle);
        if (databases == null) return TransactionError.SyncDbFailed;
        var dict = listDictionary.ListDictionary.init(self.allocator);
        defer dict.deinit();
        while (databases != null) : (databases = databases.?.next) {
            const db = databases.?.data orelse continue;
            var db_struct: libalpm.Database = .{ .ptr = @ptrCast(@alignCast(db)) };
            if (!db_struct.allowUsage(.sync)) continue;
            const db_name: []const u8 = db_struct.name() orelse continue;
            signature_policies.put(db_name, databaseSignaturePolicy(db_struct.sigLevel())) catch {
                return TransactionError.SyncDbFailed;
            };
            var servers = db_struct.servers();
            while (servers.next()) |server| {
                dict.add(db_name, server) catch {
                    return TransactionError.SyncDbFailed;
                };
            }
        }
        const syncDirectory = std.fs.path.join(self.allocator, &.{ self.config.database_path, "sync" }) catch {
            return TransactionError.SyncDbFailed;
        };
        defer self.allocator.free(syncDirectory);

        std.Io.Dir.cwd().createDirPath(self.io(), syncDirectory) catch |err| {
            std.log.err("failed to create database sync directory {s}: {}", .{ syncDirectory, err });
            return TransactionError.SyncDbFailed;
        };
        std.Io.Dir.cwd().setFilePermissions(self.io(), syncDirectory, database_directory_permissions, .{}) catch |err| {
            std.log.err("failed to set database sync directory permissions on {s}: {}", .{ syncDirectory, err });
            return TransactionError.SyncDbFailed;
        };

        const database_future = std.Io.Future(downloader.DownloadError!void);
        var futures: std.ArrayList(database_future) = .empty;
        defer futures.deinit(self.allocator);

        // All repositories in this synchronization share one certificate
        // bundle and HTTP connection pool. Per-repository setup deadlines are
        // still enforced by each lightweight downloader; the session carries
        // the largest permitted address-race deadline.
        var download_session = downloader.DownloadSession.init(
            self.allocator,
            self.io(),
            single_server_setup_timeout_seconds,
            self.download_address_family_policy,
        );
        defer download_session.deinit();

        var failed = false;
        var dict_iterator = dict.map.iterator();
        while (dict_iterator.next()) |entry| {
            const database_name = entry.key_ptr.*;
            const urls = entry.value_ptr.*;
            const signature_policy = signature_policies.get(database_name) orelse .disabled;
            const future = self.io().concurrent(download_database, .{ self, &download_session, database_name, urls, syncDirectory, force, signature_policy }) catch {
                self.download_database(&download_session, database_name, urls, syncDirectory, force, signature_policy) catch {
                    failed = true;
                };
                continue;
            };

            futures.append(self.allocator, future) catch {
                var f = future;
                f.await(self.io()) catch {
                    failed = true;
                };
            };
        }

        for (futures.items) |*future| {
            future.await(self.io()) catch {
                failed = true;
            };
        }

        // Database downloads close and atomically rename their temporary files
        // without individually forcing a filesystem transaction. Commit the
        // directory entries once after every worker has finished instead.
        syncDatabaseDirectory(self.io(), syncDirectory) catch |err| {
            std.log.err("failed to synchronize database directory {s}: {}", .{ syncDirectory, err });
            failed = true;
        };

        if (failed) return TransactionError.UpdateFetchFailed;

        if (enforce_signature_verification) {
            var failed_dbs: std.ArrayList([]const u8) = .empty;
            defer failed_dbs.deinit(self.allocator);
            for (self.sync_dbs.items) |db| {
                if (!db.allowUsage(.sync)) continue;
                if (db.verify()) continue;
                const name = db.name() orelse continue;
                failed_dbs.append(self.allocator, name) catch return TransactionError.OutOfMemory;
                const db_path = std.fmt.allocPrint(self.allocator, "{s}/{s}.db", .{ syncDirectory, name }) catch continue;
                defer self.allocator.free(db_path);
                const sig_path = std.fmt.allocPrint(self.allocator, "{s}.sig", .{db_path}) catch continue;
                defer self.allocator.free(sig_path);
                std.Io.Dir.cwd().deleteFile(self.io(), db_path) catch {};
                std.Io.Dir.cwd().deleteFile(self.io(), sig_path) catch {};
            }
            if (failed_dbs.items.len != 0) {
                const failed_items = std.mem.join(self.allocator, ", ", failed_dbs.items) catch return TransactionError.OutOfMemory;
                defer self.allocator.free(failed_items);
                const error_message = std.fmt.allocPrint(self.allocator, "Failed to verify signature for: {s}", .{failed_items}) catch return TransactionError.OutOfMemory;
                defer self.allocator.free(error_message);
                self.dispatcher.raiseError(.{ .message = error_message });

                return TransactionError.SyncDbFailed;
            }
        }
        try self.refresh();
    }

    pub fn get_installed_packages(self: *Manager) TransactionError![]libalpm.OwnedPackage {
        return self.get_installed_packages_with_reverse_dependencies(.{});
    }

    pub fn get_installed_packages_with_reverse_dependencies(
        self: *Manager,
        reverse_dependencies: ReverseDependencyOptions,
    ) TransactionError![]libalpm.OwnedPackage {
        if (self.handle == null) return TransactionError.NoHandle;
        var operation_scope = OperationScope.init(self, .search, null);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkOperationCancelled();
        const database = rawLibalpm.alpm_get_localdb(self.handle);
        const packages: libalpm.DatabaseList = rawLibalpm.alpm_db_get_pkgcache(database);
        var package_list: std.ArrayList(libalpm.OwnedPackage) = .empty;
        errdefer {
            libalpm.OwnedPackage.deinitItems(self.allocator, package_list.items);
            package_list.deinit(self.allocator);
        }
        var pkg_ptr = packages;
        while (pkg_ptr != null) : (pkg_ptr = pkg_ptr.?.*.next) {
            const package_ptr = pkg_ptr.?.data orelse continue;
            const package = libalpm.Package.from(package_ptr) orelse continue;
            var owned_package = libalpm.OwnedPackage.initWithReverseDependencies(
                self.allocator,
                package,
                reverse_dependencies,
            ) catch return TransactionError.OutOfMemory;
            package_list.append(self.allocator, owned_package) catch {
                owned_package.deinit(self.allocator);
                return TransactionError.OutOfMemory;
            };
        }
        return package_list.toOwnedSlice(self.allocator) catch return TransactionError.OutOfMemory;
    }

    pub fn get_single_installed_package(self: *Manager, package_name: [:0]const u8) TransactionError!?libalpm.Package {
        if (self.handle == null) return TransactionError.NoHandle;
        var operation_scope = OperationScope.init(self, .search, package_name);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkOperationCancelled();
        const database = rawLibalpm.alpm_get_localdb(self.handle);
        const package = rawLibalpm.alpm_db_get_pkg(database, package_name.ptr);
        if (package == null) {
            std.log.debug("Failed to find {s}", .{package_name});
            return null;
        }

        return libalpm.Package.from(package.?);
    }

    pub fn get_foreign_packages(self: *Manager) TransactionError![]libalpm.OwnedPackage {
        if (self.handle == null) return TransactionError.NoHandle;
        var operation_scope = OperationScope.init(self, .search, null);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkOperationCancelled();

        // Foreign packages are installed packages that are not provided by any
        // registered sync database (e.g. AUR or locally built packages).
        var foreign_packages: std.ArrayList(libalpm.OwnedPackage) = .empty;
        errdefer {
            libalpm.OwnedPackage.deinitItems(self.allocator, foreign_packages.items);
            foreign_packages.deinit(self.allocator);
        }

        const sync_databases = rawLibalpm.alpm_get_syncdbs(self.handle);
        const local_database = rawLibalpm.alpm_get_localdb(self.handle);
        var packages = rawLibalpm.alpm_db_get_pkgcache(local_database);
        while (packages != null) : (packages = packages.*.next) {
            const package_data = packages.*.data orelse continue;
            const package = libalpm.Package.from(package_data) orelse continue;
            const package_name = package.name() orelse continue;
            var found_in_sync: bool = false;
            var sync_ptr = sync_databases;
            while (sync_ptr != null) : (sync_ptr = sync_ptr.?.*.next) {
                const db_data = sync_ptr.?.*.data orelse continue;
                const database = libalpm.Database.from(db_data) orelse continue;
                if (database.getPackage(package_name) != null) {
                    found_in_sync = true;
                    break;
                }
            }
            if (found_in_sync) continue;

            if (!self.show_hidden_packages) {
                var ignored = false;
                for (self.config.ignore_package.items) |ignore| {
                    if (std.mem.eql(u8, package_name, ignore)) {
                        ignored = true;
                        break;
                    }
                }
                if (ignored) continue;
            }

            var owned_package = libalpm.OwnedPackage.init(self.allocator, package) catch return TransactionError.OutOfMemory;
            foreign_packages.append(self.allocator, owned_package) catch {
                owned_package.deinit(self.allocator);
                return TransactionError.OutOfMemory;
            };
        }
        return foreign_packages.toOwnedSlice(self.allocator) catch return TransactionError.OutOfMemory;
    }

    pub fn get_available_packages(self: *Manager) TransactionError![]libalpm.OwnedPackage {
        if (self.handle == null) return TransactionError.NoHandle;
        var operation_scope = OperationScope.init(self, .search, null);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkOperationCancelled();
        var packages: std.ArrayList(libalpm.OwnedPackage) = .empty;
        errdefer {
            libalpm.OwnedPackage.deinitItems(self.allocator, packages.items);
            packages.deinit(self.allocator);
        }

        var sync_database: libalpm.DatabaseList = rawLibalpm.alpm_get_syncdbs(self.handle);
        while (sync_database != null) : (sync_database = sync_database.?.*.next) {
            const db_data = sync_database.?.*.data orelse continue;
            const database = libalpm.Database.from(db_data) orelse continue;
            if (!database.allowUsage(.search)) continue;
            var tempPackages = database.packages();
            while (tempPackages.next()) |pkg| {
                var owned_package = libalpm.OwnedPackage.init(self.allocator, pkg) catch return TransactionError.OutOfMemory;
                packages.append(self.allocator, owned_package) catch {
                    owned_package.deinit(self.allocator);
                    return TransactionError.OutOfMemory;
                };
            }
        }
        return packages.toOwnedSlice(self.allocator) catch return TransactionError.OutOfMemory;
    }

    pub fn get_available_packages_from_group(self: *Manager, groupName: [:0]const u8) TransactionError![]libalpm.OwnedPackage {
        if (self.handle == null) return TransactionError.NoHandle;
        var operation_scope = OperationScope.init(self, .search, groupName);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkOperationCancelled();
        var packages: std.ArrayList(libalpm.OwnedPackage) = .empty;
        errdefer {
            libalpm.OwnedPackage.deinitItems(self.allocator, packages.items);
            packages.deinit(self.allocator);
        }

        var sync_database: libalpm.DatabaseList = rawLibalpm.alpm_get_syncdbs(self.handle);
        while (sync_database != null) : (sync_database = sync_database.?.*.next) {
            const db = sync_database.?.*.data orelse continue;
            const database = libalpm.Database.from(db) orelse continue;
            if (!database.allowUsage(.search)) continue;
            const group = database.getGroup(groupName) orelse continue;
            var package_list = group.packages();
            while (package_list.next()) |pkg| {
                const owned_pkg = try libalpm.OwnedPackage.init(self.allocator, pkg);
                packages.append(self.allocator, owned_pkg) catch return TransactionError.OutOfMemory;
            }
            break;
        }
        return packages.toOwnedSlice(self.allocator) catch TransactionError.OutOfMemory;
    }

    pub fn get_updates_available(self: *Manager) TransactionError![]libalpm.OwnedPackageWithUpdate {
        if (self.handle == null) return TransactionError.NoHandle;
        var operation_scope = OperationScope.init(self, .search, null);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkOperationCancelled();
        var package_updates: std.ArrayList(libalpm.OwnedPackageWithUpdate) = .empty;
        errdefer {
            for (package_updates.items) |*update| update.deinit(self.allocator);
            package_updates.deinit(self.allocator);
        }
        var sync_databases = rawLibalpm.alpm_get_syncdbs(self.handle);
        var usable_sync_databases: [*c]rawLibalpm.alpm_list_t = null;
        defer rawLibalpm.alpm_list_free(usable_sync_databases);

        while (sync_databases != null) : (sync_databases = sync_databases.*.next) {
            const db_data = sync_databases.*.data orelse continue;
            const database = libalpm.Database.from(db_data) orelse continue;

            if (!database.allowUsage(.upgrade)) continue;

            const updated = rawLibalpm.alpm_list_add(
                usable_sync_databases,
                @ptrCast(database.ptr),
            );
            if (updated == null) return TransactionError.OutOfMemory;

            usable_sync_databases = updated;
        }

        const local_database = rawLibalpm.alpm_get_localdb(self.handle);
        var local_packages = rawLibalpm.alpm_db_get_pkgcache(local_database);
        while (local_packages != null) : (local_packages = local_packages.*.next) {
            const package_data = local_packages.*.data orelse continue;
            const local_pkg = libalpm.Package.from(package_data) orelse continue;
            const new_version = rawLibalpm.alpm_sync_get_new_version(local_pkg.ptr, usable_sync_databases) orelse continue;
            var owned_update = libalpm.OwnedPackageWithUpdate.init(
                self.allocator,
                local_pkg,
                .{ .ptr = new_version },
            ) catch return TransactionError.OutOfMemory;
            var ignored = false;
            for (self.config.ignore_package.items) |ign_pkg| {
                if (std.ascii.eqlIgnoreCase(ign_pkg, owned_update.new_package.name() orelse "")) {
                    ignored = true;
                    break;
                }
            }
            if (!ignored) {
                for (self.config.ignore_group.items) |ign_group| {
                    for (owned_update.new_package.groups()) |group| {
                        if (std.ascii.eqlIgnoreCase(ign_group, group)) {
                            ignored = true;

                            break;
                        }
                    }
                    if (ignored) {
                        owned_update.deinit(self.allocator);
                        break;
                    }
                }
            }
            if (ignored) continue;
            package_updates.append(self.allocator, owned_update) catch {
                owned_update.deinit(self.allocator);
                return TransactionError.OutOfMemory;
            };
        }
        return package_updates.toOwnedSlice(self.allocator) catch return TransactionError.OutOfMemory;
    }

    pub fn install_packages(
        self: *Manager,
        package_names: [][:0]const u8,
        trans_flags_arg: TransFlag,
    ) TransactionError!void {
        if (self.handle == null) return TransactionError.NoHandle;
        var operation_scope = OperationScope.init(self, .install, if (package_names.len == 0) null else package_names[0]);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkOperationCancelled();
        const sync_databases = rawLibalpm.alpm_get_syncdbs(self.handle);
        var packages: std.ArrayList(*rawLibalpm.alpm_pkg_t) = .empty;
        defer packages.deinit(self.allocator);
        var optional_names: std.ArrayList([:0]const u8) = .empty;
        defer optional_names.deinit(self.allocator);

        for (package_names) |target| {
            const slash = std.mem.indexOfScalar(u8, target, '/');
            if (slash) |i| {
                if (i == 0 or i + 1 >= target.len) return TransactionError.PackageFetchFailed;
                const repo = target[0..i];
                const name = target[i + 1 ..];
                var node = sync_databases;
                var found: ?*rawLibalpm.alpm_pkg_t = null;
                while (node != null) : (node = node.*.next) {
                    const db_data: ?*anyopaque = node.*.data;
                    const db_ptr: *rawLibalpm.alpm_db_t = @ptrCast(@alignCast(db_data orelse continue));
                    const db_name = libalpm.str(rawLibalpm.alpm_db_get_name(db_ptr)) orelse continue;
                    if (!std.ascii.eqlIgnoreCase(repo, db_name)) continue;
                    found = rawLibalpm.alpm_db_get_pkg(db_ptr, name.ptr);
                    break;
                }
                try packages.append(self.allocator, found orelse return TransactionError.PackageFetchFailed);
            } else {
                var current_packages: std.ArrayList(*rawLibalpm.alpm_pkg_t) = .empty;
                defer current_packages.deinit(self.allocator);
                var node = sync_databases;
                while (node != null) : (node = node.*.next) {
                    const db_data: ?*anyopaque = node.*.data;
                    const db_ptr: *rawLibalpm.alpm_db_t = @ptrCast(@alignCast(db_data orelse continue));
                    const database = libalpm.Database.from(db_ptr) orelse continue;
                    if (!database.allowUsage(.install)) continue;
                    if (rawLibalpm.alpm_db_get_pkg(db_ptr, target.ptr)) |pkg| {
                        if (current_packages.items.len > 0) current_packages.clearRetainingCapacity();
                        current_packages.append(self.allocator, pkg) catch return TransactionError.OutOfMemory;
                        break;
                    }
                    if (current_packages.items.len != 0) continue;
                    if (rawLibalpm.alpm_db_get_group(db_ptr, target.ptr)) |group| {
                        var pkg_node = group.*.packages;
                        while (pkg_node != null) : (pkg_node = pkg_node.*.next) {
                            const pkg_data: ?*anyopaque = pkg_node.*.data;
                            const pkg: *rawLibalpm.alpm_pkg_t = @ptrCast(@alignCast(pkg_data orelse continue));
                            current_packages.append(self.allocator, pkg) catch return TransactionError.OutOfMemory;
                        }
                    }

                    if (current_packages.items.len != 0) continue;
                    if (rawLibalpm.alpm_find_satisfier(rawLibalpm.alpm_db_get_pkgcache(db_ptr), target.ptr)) |pkg| {
                        current_packages.append(self.allocator, pkg) catch return TransactionError.OutOfMemory;
                    }
                }
                for (current_packages.items) |pkg| {
                    packages.append(self.allocator, pkg) catch return TransactionError.OutOfMemory;
                }
            }
        }
        if (packages.items.len == 0) return TransactionError.PackageFetchFailed;

        // Ask once per package. Shared callers return every selected option index;
        // legacy handlers may still return a single package name in `pkg`.
        const initial_count = packages.items.len;
        for (packages.items[0..initial_count]) |pkg| {
            var names: std.ArrayList([]const u8) = .empty;
            defer names.deinit(self.allocator);
            var options: std.ArrayList(events.ProviderOption) = .empty;
            defer options.deinit(self.allocator);
            var deps = (libalpm.Package{ .ptr = pkg }).optional_depends();
            while (deps.next()) |dep| {
                const name = dep.name() orelse continue;
                if (!(self.get_opt_depend_if_available(name) catch false)) continue;
                const local_cache = rawLibalpm.alpm_db_get_pkgcache(rawLibalpm.alpm_get_localdb(self.handle));
                try names.append(self.allocator, name);
                try options.append(self.allocator, .{
                    .name = name,
                    .description = dep.description() orelse "No description found",
                    .is_installed = rawLibalpm.alpm_find_satisfier(local_cache, name.ptr) != null,
                });
            }
            if (options.items.len == 0 or
                (self.dispatcher.operation == null and self.dispatcher.question.items.len == 0)) continue;
            const pkg_name = libalpm.str(rawLibalpm.alpm_pkg_get_name(pkg)) orelse "package";
            const prompt = try std.fmt.allocPrint(self.allocator, "Select an optional dependency for {s}", .{pkg_name});
            defer self.allocator.free(prompt);
            const response = self.dispatcher.raiseQuestion(self.io(), .{
                .question = prompt,
                .question_type = @intFromEnum(libalpm.QuestionType.select_optional_dependencies),
                .options = names.items,
                .provider_options = options.items,
            });
            var selected_names: std.ArrayList([]const u8) = .empty;
            defer selected_names.deinit(self.allocator);
            for (response.selected_indices) |index| {
                if (index >= names.items.len) continue;
                try selected_names.append(self.allocator, names.items[index]);
            }
            if (response.selected_indices.len == 0) {
                if (response.pkg) |selected| try selected_names.append(self.allocator, selected);
            }

            for (selected_names.items) |selected| {
                const selected_z = try self.allocator.dupeZ(u8, selected);
                defer self.allocator.free(selected_z);
                if (rawLibalpm.alpm_find_satisfier(rawLibalpm.alpm_db_get_pkgcache(rawLibalpm.alpm_get_localdb(self.handle)), selected_z.ptr) != null) continue;
                var node = sync_databases;
                while (node != null) : (node = node.*.next) {
                    const db_data: ?*anyopaque = node.*.data;
                    const db_ptr: *rawLibalpm.alpm_db_t = @ptrCast(@alignCast(db_data orelse continue));
                    const database = libalpm.Database.from(db_ptr) orelse continue;
                    if (!database.allowUsage(.install)) continue;
                    const selected_pkg = rawLibalpm.alpm_find_satisfier(rawLibalpm.alpm_db_get_pkgcache(db_ptr), selected_z.ptr) orelse continue;
                    var already_scheduled = false;
                    for (packages.items) |scheduled| {
                        if (scheduled == selected_pkg) {
                            already_scheduled = true;
                            break;
                        }
                    }
                    if (!already_scheduled) {
                        try packages.append(self.allocator, selected_pkg);
                        if (libalpm.str(rawLibalpm.alpm_pkg_get_name(selected_pkg))) |resolved_name|
                            try optional_names.append(self.allocator, resolved_name);
                    }
                    break;
                }
            }
        }

        // Starts transaction impleentation
        var trans_flags = trans_flags_arg;
        if (trans_flags.dbonly) trans_flags.nodeps = true;
        if (rawLibalpm.alpm_trans_init(self.handle, @bitCast(trans_flags.to_trans_flag())) != 0) {
            self.handleErrorMessage(@intCast(rawLibalpm.alpm_errno(self.handle)), null) catch {};
            return TransactionError.TransInitFailed;
        }
        defer _ = rawLibalpm.alpm_trans_release(self.handle);

        for (packages.items) |pkg| {
            if (rawLibalpm.alpm_add_pkg(self.handle, pkg) == 0) continue;
            if (rawLibalpm.alpm_errno(self.handle) == rawLibalpm.ALPM_ERR_TRANS_DUP_TARGET) continue;
            return TransactionError.PrepareFailed;
        }
        var data: [*c]rawLibalpm.alpm_list_t = null;
        if (rawLibalpm.alpm_trans_prepare(self.handle, &data) != 0) {
            self.handleErrorMessage(@intCast(rawLibalpm.alpm_errno(self.handle)), data) catch {};
            return TransactionError.PrepareFailed;
        }
        try self.confirmPreparedInstall(packages.items, optional_names.items, trans_flags);
        try self.predownloadPreparedPackages(trans_flags);

        // The prepare error list does not belong to the commit call.
        data = null;
        if (rawLibalpm.alpm_trans_commit(self.handle, &data) != 0) {
            self.handleErrorMessage(@intCast(rawLibalpm.alpm_errno(self.handle)), data) catch {};
            return TransactionError.CommitFailed;
        }
        const local_db = rawLibalpm.alpm_get_localdb(self.handle);
        for (optional_names.items) |name| {
            const installed = rawLibalpm.alpm_db_get_pkg(local_db, name.ptr) orelse continue;
            _ = rawLibalpm.alpm_pkg_set_reason(installed, rawLibalpm.ALPM_PKG_REASON_DEPEND);
        }
    }

    pub fn remove_packages(self: *Manager, packages_names: [][:0]const u8, flags: TransFlag, keep_optional_dependencis: bool) TransactionError!void {
        if (self.handle == null) return TransactionError.NoHandle;
        var operation_scope = OperationScope.init(self, .remove, if (packages_names.len == 0) null else packages_names[0]);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkOperationCancelled();
        if (packages_names.len == 0) return TransactionError.NoPackageFound;

        for (self.config.hold_packages.items) |hold_pkg| {
            for (packages_names) |pkg| {
                if (std.ascii.eqlIgnoreCase(hold_pkg, pkg)) {
                    const prompt = try std.fmt.allocPrint(self.allocator, "Are you sure you want to remove {s}? It is listed as a held package.", .{pkg});
                    defer self.allocator.free(prompt);
                    const response = self.askYesNo(self.io(), @intFromEnum(libalpm.QuestionType.remove_packages), prompt);
                    if (!response) {
                        self.dispatcher.raiseError(.{ .message = "Held package removal cancelled." });
                        return TransactionError.PrepareFailed;
                    }
                }
            }
        }

        const local_db = rawLibalpm.alpm_get_localdb(self.handle);
        var package_pointers: std.ArrayList(*rawLibalpm.alpm_pkg_t) = .empty;
        defer package_pointers.deinit(self.allocator);
        for (packages_names) |pkg| {
            // Check for regular package
            const package = rawLibalpm.alpm_db_get_pkg(local_db, pkg.ptr) orelse {
                // Check for group name
                const group_ptr = rawLibalpm.alpm_db_get_group(local_db, pkg.ptr) orelse {
                    const satisfier = rawLibalpm.alpm_find_satisfier(rawLibalpm.alpm_db_get_pkgcache(local_db), pkg.ptr) orelse {
                        const message = std.fmt.allocPrint(self.allocator, "Could not remove \"{s}\" because it is not installed. Check the package name and try again.", .{pkg}) catch return TransactionError.OutOfMemory;
                        defer self.allocator.free(message);
                        self.dispatcher.raiseError(.{ .message = message });
                        return TransactionError.NoPackageFound;
                    };
                    package_pointers.append(self.allocator, satisfier) catch {
                        return TransactionError.OutOfMemory;
                    };
                    continue;
                };
                const group = libalpm.AlpmPackageGroup{ .ptr = group_ptr };
                var packages = group.packages();

                while (packages.next()) |package| {
                    package_pointers.append(self.allocator, package.ptr) catch {
                        return TransactionError.OutOfMemory;
                    };
                }
                continue;
            };

            package_pointers.append(self.allocator, package) catch {
                return TransactionError.OutOfMemory;
            };
        }

        if (!keep_optional_dependencis) {
            const current_count = package_pointers.items.len;
            var package_index: usize = 0;
            while (package_index < current_count) : (package_index += 1) {
                const package = libalpm.Package{ .ptr = package_pointers.items[package_index] };
                var optional_deps = package.optional_depends();
                while (optional_deps.next()) |deps| {
                    const dep_name = deps.name() orelse continue;
                    // looks for local package, then the satisfier, continues on if failes to find.
                    const local_ptr = rawLibalpm.alpm_db_get_pkg(local_db, dep_name.ptr) orelse rawLibalpm.alpm_find_satisfier(rawLibalpm.alpm_db_get_pkgcache(local_db), dep_name.ptr) orelse {
                        const message = try std.fmt.allocPrint(self.allocator, "Failed to find {s} in local database. Skipping...", .{dep_name});
                        defer self.allocator.free(message);
                        self.dispatcher.raiseInformational(.{
                            .event_type = libalpm.EventType.failed_optional_dependency_operation,
                            .message = message,
                        });
                        continue;
                    };
                    const local_pkg = libalpm.Package{ .ptr = local_ptr };
                    // checks reason and continues loop if explicit
                    const pkg_reason = local_pkg.install_reason();
                    if (pkg_reason == libalpm.PackageReason.Explicit) {
                        const message = try std.fmt.allocPrint(self.allocator, "Package {s} is explicit. Skipping...", .{dep_name});
                        defer self.allocator.free(message);
                        self.dispatcher.raiseInformational(.{
                            .event_type = libalpm.EventType.package_explicit,
                            .message = message,
                        });
                        continue;
                    }

                    // checks if package is still in use by other applications
                    var required_by = local_pkg.required_by();
                    var still_required: bool = false;
                    while (required_by.next()) |package_name| {
                        const requiring_package = rawLibalpm.alpm_db_get_pkg(local_db, package_name.ptr) orelse {
                            // continuing on as this package is not installed and we can ignore.
                            continue;
                        };
                        if (std.mem.findScalar(
                            *rawLibalpm.alpm_pkg_t,
                            package_pointers.items[0..current_count],
                            requiring_package,
                        ) != null) continue;
                        const message = try std.fmt.allocPrint(self.allocator, "Found {s} is still needed. Skipping removal...", .{package_name});
                        defer self.allocator.free(message);
                        self.dispatcher.raiseInformational(.{ .event_type = libalpm.EventType.failed_optional_dependency_operation, .message = message });
                        still_required = true;
                        break;
                    }
                    // skips optional dependency removal as the package is still required
                    if (still_required) {
                        continue;
                    }
                    const package_name = package.name() orelse "unknown package";
                    const message = try std.fmt.allocPrint(self.allocator, "Found {s} is unneeded after removal. queuing for removal", .{package_name});
                    defer self.allocator.free(message);
                    self.dispatcher.raiseInformational(.{ .event_type = libalpm.EventType.optdep_removal, .message = message });
                    package_pointers.append(self.allocator, local_ptr) catch return TransactionError.OutOfMemory;
                }
            }
        }

        var trans_flags = flags;
        if (trans_flags.dbonly) trans_flags.nodeps = true;

        if (rawLibalpm.alpm_trans_init(self.handle, @bitCast(trans_flags.to_trans_flag())) != 0) {
            self.handleErrorMessage(@intCast(rawLibalpm.alpm_errno(self.handle)), null) catch {};
            return TransactionError.TransInitFailed;
        }
        defer _ = rawLibalpm.alpm_trans_release(self.handle);

        for (package_pointers.items) |pkg_ptr| {
            if (rawLibalpm.alpm_remove_pkg(self.handle, pkg_ptr) == 0) continue;
            const errno = rawLibalpm.alpm_errno(self.handle);
            const reason = libalpm.str(rawLibalpm.alpm_strerror(errno)) orelse
                "Unknown libalpm error";
            const name = libalpm.str(rawLibalpm.alpm_pkg_get_name(pkg_ptr)) orelse
                "unknown package";

            const message = std.fmt.allocPrint(
                self.allocator,
                "Failed to queue {s} for removal: {s}",
                .{ name, reason },
            ) catch {
                self.dispatcher.raiseError(.{
                    .message = "Failed to queue package for removal.",
                });
                return TransactionError.RemovalFailed;
            };
            defer self.allocator.free(message);

            self.dispatcher.raiseError(.{ .message = message });
            return TransactionError.RemovalFailed;
        }

        var data: [*c]rawLibalpm.alpm_list_t = null;
        if (rawLibalpm.alpm_trans_prepare(self.handle, &data) != 0) {
            self.handleErrorMessage(@intCast(rawLibalpm.alpm_errno(self.handle)), data) catch {};
            return TransactionError.PrepareFailed;
        }
        if (rawLibalpm.alpm_trans_commit(self.handle, &data) != 0) {
            self.handleErrorMessage(@intCast(rawLibalpm.alpm_errno(self.handle)), data) catch {};
            return TransactionError.CommitFailed;
        }
    }

    /// Performs a full system upgrade and then checks the running system for
    /// processes and services which still use replaced libraries. The returned
    /// report is owned by the caller and must be deinitialized.
    pub fn sync_system_update(self: *Manager, flags: TransFlag) TransactionError!RestartReport {
        if (self.handle == null) return TransactionError.NoHandle;
        var operation_scope = OperationScope.init(self, .update, null);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkOperationCancelled();

        // This is first before updating so it can bail before database is downloaded
        if (self.detected_cachyos) {
            const update_notice = cachyos.UpdateNotice.init(self.allocator, self.io());
            if (!update_notice.check(self.environ, &self.dispatcher)) return RestartReport.empty(self.allocator);
        }
        self.sync(true) catch return TransactionError.SyncDbFailed;

        self.package_download = true;

        var trans_flags = flags;
        if (trans_flags.dbonly) trans_flags.nodeps = true;

        if (rawLibalpm.alpm_trans_init(self.handle, @bitCast(trans_flags.to_trans_flag())) != 0) {
            self.handleErrorMessage(@intCast(rawLibalpm.alpm_errno(self.handle)), null) catch {};
            return TransactionError.TransInitFailed;
        }
        var transaction_active = true;
        defer {
            if (transaction_active) _ = rawLibalpm.alpm_trans_release(self.handle);
        }

        // Potentially could allow downgrade here
        if (rawLibalpm.alpm_sync_sysupgrade(self.handle, @intFromBool(false)) != 0) {
            self.handleErrorMessage(@intCast(rawLibalpm.alpm_errno(self.handle)), null) catch {
                // Dropping here cause this is super screwed.
            };
            return TransactionError.UpdateFetchFailed;
        }

        var data: [*c]rawLibalpm.alpm_list_t = null;

        // Fully calculate dependencies, replacements, and conflicts,
        // collects data for concurrent downloading
        if (rawLibalpm.alpm_trans_prepare(self.handle, &data) != 0) {
            self.handleErrorMessage(@intCast(rawLibalpm.alpm_errno(self.handle)), data) catch {
                // drop here has now use
            };
            return TransactionError.PrepareFailed;
        }

        try self.predownloadPreparedPackages(trans_flags);

        data = null;
        if (rawLibalpm.alpm_trans_commit(self.handle, &data) != 0) {
            self.handleErrorMessage(@intCast(rawLibalpm.alpm_errno(self.handle)), data) catch {
                // Abandon hope all yee who enter here
            };
            return TransactionError.CommitFailed;
        }

        // Do not hold the pacman database lock while inspecting processes or
        // invoking systemctl.
        _ = rawLibalpm.alpm_trans_release(self.handle);
        transaction_active = false;

        if (trans_flags.dbonly) return RestartReport.empty(self.allocator);
        return self.checkForRequiredRestarts(.{}) catch TransactionError.OutOfMemory;
    }

    /// Detects stale runtime state and restarts mapped systemd services. File
    /// access races and permission failures under procfs are non-fatal and are
    /// reflected by `process_scan_complete`/`skipped_processes`. Allocation is
    /// the only error because restart command failures belong in the report.
    fn checkForRequiredRestarts(self: *Manager, options: RestartCheckOptions) error{OutOfMemory}!RestartReport {
        if (builtin.os.tag != .linux) return RestartReport.empty(self.allocator);

        var running_kernel: ?[]u8 = null;
        errdefer if (running_kernel) |kernel| self.allocator.free(kernel);
        var running_kernel_modules_present: ?bool = null;
        var needs_reboot = false;
        var process_scan_complete = true;
        var skipped_processes: usize = 0;

        var affected_processes: std.ArrayList(AffectedProcess) = .empty;
        errdefer {
            for (affected_processes.items) |*process| process.deinit(self.allocator);
            affected_processes.deinit(self.allocator);
        }
        var affected_services: std.ArrayList([]u8) = .empty;
        errdefer {
            for (affected_services.items) |service| self.allocator.free(service);
            affected_services.deinit(self.allocator);
        }
        var restarted_services: std.ArrayList([]u8) = .empty;
        errdefer {
            for (restarted_services.items) |service| self.allocator.free(service);
            restarted_services.deinit(self.allocator);
        }
        var failures: std.ArrayList(ServiceRestartFailure) = .empty;
        errdefer {
            for (failures.items) |*failure| failure.deinit(self.allocator);
            failures.deinit(self.allocator);
        }

        const osrelease_path = std.fs.path.join(
            self.allocator,
            &.{ options.proc_root, "sys", "kernel", "osrelease" },
        ) catch return error.OutOfMemory;
        defer self.allocator.free(osrelease_path);

        if (std.Io.Dir.cwd().readFileAlloc(
            self.io(),
            osrelease_path,
            self.allocator,
            .limited(4096),
        )) |contents| {
            defer self.allocator.free(contents);
            const trimmed = std.mem.trim(u8, contents, " \t\r\n");
            if (trimmed.len != 0) {
                running_kernel = self.allocator.dupe(u8, trimmed) catch return error.OutOfMemory;
                const modules_path = std.fs.path.join(
                    self.allocator,
                    &.{ options.modules_root, trimmed },
                ) catch return error.OutOfMemory;
                defer self.allocator.free(modules_path);

                if (std.Io.Dir.cwd().statFile(self.io(), modules_path, .{})) |stat| {
                    running_kernel_modules_present = stat.kind == .directory;
                    needs_reboot = !running_kernel_modules_present.?;
                } else |err| switch (err) {
                    error.FileNotFound, error.NotDir => {
                        running_kernel_modules_present = false;
                        needs_reboot = true;
                    },
                    else => running_kernel_modules_present = null,
                }
            }
        } else |_| {}

        var proc_dir = std.Io.Dir.cwd().openDir(
            self.io(),
            options.proc_root,
            .{ .iterate = true },
        ) catch {
            process_scan_complete = false;
            return .{
                .allocator = self.allocator,
                .running_kernel = running_kernel,
                .running_kernel_modules_present = running_kernel_modules_present,
                .needs_reboot = needs_reboot,
                .process_scan_complete = process_scan_complete,
                .skipped_processes = skipped_processes,
                .affected_processes = &.{},
                .affected_services = &.{},
                .restarted_services = &.{},
                .failures = &.{},
            };
        };
        defer proc_dir.close(self.io());

        var iterator = proc_dir.iterateAssumeFirstIteration();
        while (true) {
            const next_entry = iterator.next(self.io()) catch {
                process_scan_complete = false;
                break;
            };
            const entry = next_entry orelse break;
            if (entry.kind != .directory and entry.kind != .sym_link) continue;
            const pid = std.fmt.parseInt(u32, entry.name, 10) catch continue;

            const maps_path = std.fs.path.join(
                self.allocator,
                &.{ options.proc_root, entry.name, "maps" },
            ) catch return error.OutOfMemory;
            defer self.allocator.free(maps_path);
            const maps = std.Io.Dir.cwd().readFileAlloc(
                self.io(),
                maps_path,
                self.allocator,
                .limited(16 * 1024 * 1024),
            ) catch {
                skipped_processes += 1;
                continue;
            };
            defer self.allocator.free(maps);
            if (!hasDeletedSharedLibrary(maps)) continue;

            var command: ?[]u8 = null;
            const comm_path = std.fs.path.join(
                self.allocator,
                &.{ options.proc_root, entry.name, "comm" },
            ) catch return error.OutOfMemory;
            defer self.allocator.free(comm_path);
            if (std.Io.Dir.cwd().readFileAlloc(
                self.io(),
                comm_path,
                self.allocator,
                .limited(4096),
            )) |comm_contents| {
                defer self.allocator.free(comm_contents);
                const comm = std.mem.trim(u8, comm_contents, " \t\r\n");
                if (comm.len != 0) {
                    command = self.allocator.dupe(u8, comm) catch return error.OutOfMemory;
                    if (isCriticalRestartProcess(comm)) needs_reboot = true;
                }
            } else |_| {}

            var service: ?[]u8 = null;
            const cgroup_path = std.fs.path.join(
                self.allocator,
                &.{ options.proc_root, entry.name, "cgroup" },
            ) catch {
                if (command) |owned| self.allocator.free(owned);
                return error.OutOfMemory;
            };
            defer self.allocator.free(cgroup_path);
            if (std.Io.Dir.cwd().readFileAlloc(
                self.io(),
                cgroup_path,
                self.allocator,
                .limited(1024 * 1024),
            )) |cgroup| {
                defer self.allocator.free(cgroup);
                if (serviceFromCgroup(cgroup)) |service_name| {
                    service = self.allocator.dupe(u8, service_name) catch {
                        if (command) |owned| self.allocator.free(owned);
                        return error.OutOfMemory;
                    };

                    var seen = false;
                    for (affected_services.items) |known| {
                        if (std.mem.eql(u8, known, service_name)) {
                            seen = true;
                            break;
                        }
                    }
                    if (!seen) {
                        const owned_service = self.allocator.dupe(u8, service_name) catch {
                            if (command) |owned| self.allocator.free(owned);
                            if (service) |owned| self.allocator.free(owned);
                            return error.OutOfMemory;
                        };
                        affected_services.append(self.allocator, owned_service) catch {
                            self.allocator.free(owned_service);
                            if (command) |owned| self.allocator.free(owned);
                            if (service) |owned| self.allocator.free(owned);
                            return error.OutOfMemory;
                        };
                    }
                }
            } else |_| {}

            affected_processes.append(self.allocator, .{
                .pid = pid,
                .command = command,
                .service = service,
            }) catch {
                if (command) |owned| self.allocator.free(owned);
                if (service) |owned| self.allocator.free(owned);
                return error.OutOfMemory;
            };
        }

        std.mem.sort([]u8, affected_services.items, {}, stringBefore);

        if (options.restart_services and !needs_reboot) {
            for (affected_services.items) |service| {
                const result = std.process.run(self.allocator, self.io(), .{
                    .argv = &.{ options.systemctl_path, "restart", service },
                    .stdout_limit = .limited(4096),
                    .stderr_limit = .limited(64 * 1024),
                }) catch |err| {
                    const failure_service = self.allocator.dupe(u8, service) catch return error.OutOfMemory;
                    const failure_message = self.allocator.dupe(u8, @errorName(err)) catch {
                        self.allocator.free(failure_service);
                        return error.OutOfMemory;
                    };
                    failures.append(self.allocator, .{
                        .service = failure_service,
                        .kind = .spawn,
                        .exit_code = null,
                        .message = failure_message,
                    }) catch {
                        self.allocator.free(failure_service);
                        self.allocator.free(failure_message);
                        return error.OutOfMemory;
                    };
                    continue;
                };
                defer self.allocator.free(result.stdout);
                defer self.allocator.free(result.stderr);

                const succeeded = switch (result.term) {
                    .exited => |code| code == 0,
                    else => false,
                };
                if (succeeded) {
                    const restarted = self.allocator.dupe(u8, service) catch return error.OutOfMemory;
                    restarted_services.append(self.allocator, restarted) catch {
                        self.allocator.free(restarted);
                        return error.OutOfMemory;
                    };
                    continue;
                }

                const failure_kind: ServiceRestartFailureKind = switch (result.term) {
                    .exited => .exit_status,
                    else => .terminated,
                };
                const exit_code: ?u8 = switch (result.term) {
                    .exited => |code| code,
                    else => null,
                };
                const stderr = std.mem.trim(u8, result.stderr, " \t\r\n");
                const failure_message = if (stderr.len != 0)
                    self.allocator.dupe(u8, stderr) catch return error.OutOfMemory
                else if (exit_code) |code|
                    std.fmt.allocPrint(self.allocator, "systemctl exited with status {d}", .{code}) catch return error.OutOfMemory
                else
                    self.allocator.dupe(
                        u8,
                        "systemctl was terminated before it exited",
                    ) catch return error.OutOfMemory;
                const failure_service = self.allocator.dupe(u8, service) catch {
                    self.allocator.free(failure_message);
                    return error.OutOfMemory;
                };
                failures.append(self.allocator, .{
                    .service = failure_service,
                    .kind = failure_kind,
                    .exit_code = exit_code,
                    .message = failure_message,
                }) catch {
                    self.allocator.free(failure_service);
                    self.allocator.free(failure_message);
                    return error.OutOfMemory;
                };
            }
        }

        const process_slice: []AffectedProcess = if (affected_processes.items.len == 0)
            &.{}
        else
            affected_processes.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
        errdefer {
            for (process_slice) |*process| process.deinit(self.allocator);
            if (process_slice.len != 0) self.allocator.free(process_slice);
        }
        const affected_service_slice: [][]u8 = if (affected_services.items.len == 0)
            &.{}
        else
            affected_services.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
        errdefer {
            for (affected_service_slice) |service| self.allocator.free(service);
            if (affected_service_slice.len != 0) self.allocator.free(affected_service_slice);
        }
        const restarted_service_slice: [][]u8 = if (restarted_services.items.len == 0)
            &.{}
        else
            restarted_services.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
        errdefer {
            for (restarted_service_slice) |service| self.allocator.free(service);
            if (restarted_service_slice.len != 0) self.allocator.free(restarted_service_slice);
        }
        const failure_slice: []ServiceRestartFailure = if (failures.items.len == 0)
            &.{}
        else
            failures.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
        errdefer {
            for (failure_slice) |*failure| failure.deinit(self.allocator);
            if (failure_slice.len != 0) self.allocator.free(failure_slice);
        }

        return .{
            .allocator = self.allocator,
            .running_kernel = running_kernel,
            .running_kernel_modules_present = running_kernel_modules_present,
            .needs_reboot = needs_reboot,
            .process_scan_complete = process_scan_complete,
            .skipped_processes = skipped_processes,
            .affected_processes = process_slice,
            .affected_services = affected_service_slice,
            .restarted_services = restarted_service_slice,
            .failures = failure_slice,
        };
    }

    pub fn update_package_reason(self: *Manager, pkg_name: [:0]const u8, reason: libalpm.PackageReason) TransactionError!void {
        if (self.handle == null) return TransactionError.NoHandle;
        var operation_scope = OperationScope.init(self, .configure, pkg_name);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkOperationCancelled();
        const local_database = rawLibalpm.alpm_get_localdb(self.handle) orelse return TransactionError.DatabaseReadFailed;
        const pkg = rawLibalpm.alpm_db_get_pkg(local_database, pkg_name) orelse return TransactionError.PackageFetchFailed;
        if (rawLibalpm.alpm_pkg_set_reason(pkg, @intCast(@intFromEnum(reason))) != 0) return TransactionError.SetReasonFailed;
    }

    pub fn install_local_packages(self: *Manager, paths: []const []const u8, flags: TransFlag) TransactionError!void {
        if (self.handle == null) return TransactionError.NoHandle;
        var operation_scope = OperationScope.init(self, .install, if (paths.len == 0) null else paths[0]);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkOperationCancelled();
        if (paths.len == 0) return TransactionError.NoPackageFound;

        var package_ptrs: std.ArrayList(libalpm.Package) = .empty;
        defer package_ptrs.deinit(self.allocator);
        const sig_level = rawLibalpm.ALPM_SIG_PACKAGE_OPTIONAL | rawLibalpm.ALPM_SIG_DATABASE_OPTIONAL;
        for (paths) |path| {
            const path_z = self.allocator.dupeZ(u8, path) catch {
                for (package_ptrs.items) |pkg| _ = rawLibalpm.alpm_pkg_free(pkg.ptr);
                return TransactionError.OutOfMemory;
            };
            defer self.allocator.free(path_z);

            var temp_pkg: ?*rawLibalpm.alpm_pkg_t = null;
            if (rawLibalpm.alpm_pkg_load(self.handle, path_z.ptr, @intFromBool(true), sig_level, &temp_pkg) != 0 or temp_pkg == null) {
                const errno = rawLibalpm.alpm_errno(self.handle);
                if (temp_pkg) |pkg| _ = rawLibalpm.alpm_pkg_free(pkg);
                for (package_ptrs.items) |pkg| _ = rawLibalpm.alpm_pkg_free(pkg.ptr);
                self.handleErrorMessage(@intCast(errno), null) catch {};
                return TransactionError.PackageLoadFailed;
            }
            package_ptrs.append(self.allocator, .{ .ptr = temp_pkg.? }) catch {
                _ = rawLibalpm.alpm_pkg_free(temp_pkg);
                for (package_ptrs.items) |pkg| _ = rawLibalpm.alpm_pkg_free(pkg.ptr);
                return TransactionError.OutOfMemory;
            };
        }

        if (rawLibalpm.alpm_trans_init(self.handle, @bitCast(flags.to_trans_flag())) != 0) {
            for (package_ptrs.items) |pkg| _ = rawLibalpm.alpm_pkg_free(pkg.ptr);
            self.handleErrorMessage(@intCast(rawLibalpm.alpm_errno(self.handle)), null) catch {};
            return TransactionError.TransInitFailed;
        }
        defer _ = rawLibalpm.alpm_trans_release(self.handle);

        for (package_ptrs.items, 0..) |pkg, index| {
            if (rawLibalpm.alpm_add_pkg(self.handle, pkg.ptr) != 0) {
                const errno = rawLibalpm.alpm_errno(self.handle);
                _ = rawLibalpm.alpm_pkg_free(pkg.ptr);
                if (errno == rawLibalpm.ALPM_ERR_TRANS_DUP_TARGET) {
                    self.handleInformationMessage(libalpm.EventType.failed_add_local_package);
                    continue;
                }
                for (package_ptrs.items[index + 1 ..]) |remaining_pkg| _ = rawLibalpm.alpm_pkg_free(remaining_pkg.ptr);
                self.handleErrorMessage(@intCast(errno), null) catch {};
                return TransactionError.PackageAddFailed;
            }
        }

        var data: [*c]rawLibalpm.alpm_list_t = null;
        if (rawLibalpm.alpm_trans_prepare(self.handle, &data) != 0) {
            self.handleErrorMessage(@intCast(rawLibalpm.alpm_errno(self.handle)), data) catch {
                // drop here has now use
            };
            return TransactionError.PrepareFailed;
        }

        try self.predownloadPreparedPackages(flags);

        data = null;
        if (rawLibalpm.alpm_trans_commit(self.handle, &data) != 0) {
            self.handleErrorMessage(@intCast(rawLibalpm.alpm_errno(self.handle)), data) catch {
                // Abandon hope all yee who enter here
            };
            return TransactionError.CommitFailed;
        }
    }

    /// Prevents transaction hooks from running, persisting across handle
    /// refreshes that re-initialize libalpm and re-apply the configuration.
    /// Hook directories are replaced with a nonexistent path because
    /// clearing the list falls back to libalpm's compiled-in default
    /// directory. Intended for hermetic tests and initial root provisioning,
    /// which must not execute host system hooks in a foreign or empty root.
    pub fn disable_transaction_hooks(self: *Manager) void {
        self.hooks_disabled = true;
        if (self.handle) |handle| {
            self.replaceHookDirsWithSentinel(handle);
        }
    }

    const no_hooks_sentinel_dir: [:0]const u8 = "/nonexistent/shelly-no-hooks";

    fn replaceHookDirsWithSentinel(self: *Manager, handle: libalpm.Handle) void {
        _ = self;
        const list = rawLibalpm.alpm_list_add(null, @ptrCast(@constCast(no_hooks_sentinel_dir.ptr))) orelse return;
        _ = rawLibalpm.alpm_option_set_hookdirs(handle, list);
    }

    pub fn get_package_from_provides(self: *Manager, provides: [:0]const u8) QueryError![:0]const u8 {
        if (self.handle == null) return QueryError.NoHandle;
        var operation_scope = OperationScope.init(self, .search, provides);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkOperationCancelled();
        var sync_dbs = rawLibalpm.alpm_get_syncdbs(self.handle);
        while (sync_dbs != null) : (sync_dbs = sync_dbs.*.next) {
            const db_ptr = sync_dbs.*.data orelse continue;
            const db: libalpm.Database = libalpm.Database.from(db_ptr) orelse continue;
            if (!db.allowUsage(.install)) continue;
            const pkg_cache = db.package_cache();
            const satisfier = rawLibalpm.alpm_find_satisfier(pkg_cache, provides.ptr) orelse continue;
            const pkg = libalpm.Package.from(satisfier) orelse continue;
            return pkg.name() orelse return QueryError.PkgNotFound;
        }
        return QueryError.PkgNotFound;
    }

    pub fn is_dependency_satisfied_by_installed_packages(self: *Manager, dependency: [:0]const u8) QueryError!bool {
        if (self.handle == null) return QueryError.NoHandle;
        var operation_scope = OperationScope.init(self, .search, dependency);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkOperationCancelled();
        const local_db = rawLibalpm.alpm_get_localdb(self.handle);
        const db = libalpm.Database.from(local_db.?) orelse return QueryError.DbNotFound;
        _ = rawLibalpm.alpm_find_satisfier(db.package_cache(), dependency) orelse return false;
        return true;
    }

    pub fn find_remote_satisfier_for_dependency(self: *Manager, dependency: [:0]const u8) QueryError![:0]const u8 {
        if (self.handle == null) return QueryError.NoHandle;
        var operation_scope = OperationScope.init(self, .search, dependency);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkOperationCancelled();
        return (try self.find_remote_satisfier_for_dependency_details(dependency)).real_name;
    }

    /// Finds a remote dependency satisfier and reports whether the match was
    /// made through a `provides` entry instead of the package's real name.
    pub fn find_remote_satisfier_for_dependency_details(
        self: *Manager,
        dependency: [:0]const u8,
    ) QueryError!DependencySatisfier {
        if (self.handle == null) return QueryError.NoHandle;
        var operation_scope = OperationScope.init(self, .search, dependency);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkOperationCancelled();
        const requested_name = dependencyName(dependency);

        // Search every configured repository for a literal package before
        // considering providers. Calling alpm_find_satisfier independently on
        // each database lets a provider shadow a literal package in that cache
        // or a later repository (for example, gcc-go's `provides=go` shadowing
        // the real `go` package).
        const parsed_dependency = rawLibalpm.alpm_dep_from_string(dependency.ptr) orelse
            return QueryError.PkgNotFound;
        defer rawLibalpm.alpm_dep_free(parsed_dependency);
        const requested_name_z = self.allocator.dupeZ(u8, requested_name) catch
            return QueryError.OutOfMemory;
        defer self.allocator.free(requested_name_z);

        var sync_dbs = rawLibalpm.alpm_get_syncdbs(self.handle);
        while (sync_dbs != null) : (sync_dbs = sync_dbs.*.next) {
            const db_ptr = sync_dbs.*.data orelse continue;
            const db = libalpm.Database.from(db_ptr) orelse continue;
            if (!db.allowUsage(.install)) continue;
            const pkg_ptr = rawLibalpm.alpm_db_get_pkg(db.ptr, requested_name_z.ptr) orelse continue;
            if (!literalPackageSatisfiesDependency(pkg_ptr, parsed_dependency)) continue;
            const pkg = libalpm.Package.from(pkg_ptr) orelse continue;
            return .{
                .real_name = pkg.name() orelse continue,
                .via_provides = false,
            };
        }

        // No satisfying literal exists in any configured repository. Preserve
        // the historical first-provider behavior as a separate second pass.
        sync_dbs = rawLibalpm.alpm_get_syncdbs(self.handle);
        while (sync_dbs != null) : (sync_dbs = sync_dbs.*.next) {
            const db_ptr = sync_dbs.*.data orelse continue;
            const db = libalpm.Database.from(db_ptr) orelse continue;
            if (!db.allowUsage(.install)) continue;
            const pkg_cache = db.package_cache();
            const satisfier = rawLibalpm.alpm_find_satisfier(pkg_cache, dependency) orelse continue;
            const pkg = libalpm.Package.from(satisfier) orelse continue;
            const real_name = pkg.name() orelse continue;
            return .{
                .real_name = real_name,
                .via_provides = !std.mem.eql(u8, real_name, requested_name),
            };
        }
        return QueryError.PkgNotFound;
    }

    pub fn install_dependencies_only(self: *Manager, package_name: [:0]const u8, include_make_deps: bool, flags: TransFlag) TransactionError!void {
        if (self.handle == null) return TransactionError.NoHandle;
        var operation_scope = OperationScope.init(self, .install, package_name);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkOperationCancelled();
        const local_db = rawLibalpm.alpm_get_localdb(self.handle);
        var deps_to_install: std.ArrayList(libalpm.Dependency) = .empty;
        defer deps_to_install.deinit(self.allocator);
        const pkg_ptr = rawLibalpm.alpm_db_get_pkg(local_db, package_name) orelse find_pkg: {
            var sync_dbs = rawLibalpm.alpm_get_syncdbs(self.handle);
            while (sync_dbs != null) : (sync_dbs = sync_dbs.*.next) {
                const db = libalpm.Database.from(sync_dbs.*.data.?) orelse continue;
                if (!db.allowUsage(.install)) continue;
                const sync_pkg = rawLibalpm.alpm_db_get_pkg(db.ptr, package_name) orelse continue;
                break :find_pkg sync_pkg;
            }
            return TransactionError.NoPackageFound;
        };
        const pkg = libalpm.Package.from(pkg_ptr) orelse return TransactionError.PackageFetchFailed;
        var dependencies = pkg.depends();
        while (dependencies.next()) |dep| {
            deps_to_install.append(self.allocator, dep) catch return TransactionError.OutOfMemory;
        }
        if (include_make_deps) {
            var make_dependencies = pkg.make_depends();
            while (make_dependencies.next()) |dep| {
                deps_to_install.append(self.allocator, dep) catch return TransactionError.OutOfMemory;
            }
        }

        var pkgs_to_install: std.ArrayList([:0]const u8) = .empty;
        defer {
            for (pkgs_to_install.items) |pkg_name| {
                self.allocator.free(pkg_name);
            }
            pkgs_to_install.deinit(self.allocator);
        }

        for (deps_to_install.items) |dep| {
            const dep_string = dep.computed_dependency_string(self.allocator) orelse continue;
            errdefer self.allocator.free(dep_string);
            pkgs_to_install.append(self.allocator, dep_string) catch return TransactionError.OutOfMemory;
        }
        if (pkgs_to_install.items.len > 0) {
            self.install_packages(pkgs_to_install.items, flags) catch |err| return err;
        }
    }

    pub fn update_packages(self: *Manager, package_list: [][:0]const u8, flags: libalpm.TransFlag) TransactionError!void {
        if (self.handle == null) return TransactionError.NoHandle;
        var operation_scope = OperationScope.init(self, .update, if (package_list.len == 0) null else package_list[0]);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkOperationCancelled();
        self.sync(false) catch |err| return err;
        var sync_databases = rawLibalpm.alpm_get_syncdbs(self.handle);
        var usable_sync_databases: [*c]rawLibalpm.alpm_list_t = null;
        defer rawLibalpm.alpm_list_free(usable_sync_databases);

        while (sync_databases != null) : (sync_databases = sync_databases.*.next) {
            const db_data = sync_databases.*.data orelse continue;
            const database = libalpm.Database.from(db_data) orelse continue;

            if (!database.allowUsage(.upgrade)) continue;

            const updated = rawLibalpm.alpm_list_add(
                usable_sync_databases,
                @ptrCast(database.ptr),
            );
            if (updated == null) return TransactionError.OutOfMemory;

            usable_sync_databases = updated;
        }
        const local_db = rawLibalpm.alpm_get_localdb(self.handle);

        var trans_flags = flags;
        if (trans_flags.dbonly) trans_flags.nodeps = true;

        if (rawLibalpm.alpm_trans_init(self.handle, @bitCast(trans_flags.to_trans_flag())) != 0) {
            self.handleErrorMessage(@intCast(rawLibalpm.alpm_errno(self.handle)), null) catch {};
            return TransactionError.TransInitFailed;
        }
        defer _ = rawLibalpm.alpm_trans_release(self.handle);

        for (package_list) |pkg_name| {
            const pkg_ptr = rawLibalpm.alpm_db_get_pkg(local_db, pkg_name) orelse continue;
            const new_pkg_ptr = rawLibalpm.alpm_sync_get_new_version(pkg_ptr, usable_sync_databases) orelse continue;
            if (rawLibalpm.alpm_add_pkg(self.handle, new_pkg_ptr) != 0) {
                return TransactionError.PackageAddFailed;
            }
        }

        var data: [*c]rawLibalpm.alpm_list_t = null;
        if (rawLibalpm.alpm_trans_prepare(self.handle, &data) != 0) {
            self.handleErrorMessage(@intCast(rawLibalpm.alpm_errno(self.handle)), data) catch {
                // drop here has now use
            };
            data = null;
            return TransactionError.PrepareFailed;
        }

        try self.predownloadPreparedPackages(trans_flags);

        data = null;
        if (rawLibalpm.alpm_trans_commit(self.handle, &data) != 0) {
            self.handleErrorMessage(@intCast(rawLibalpm.alpm_errno(self.handle)), data) catch {
                // drop here has now use
            };
            data = null;
            return TransactionError.CommitFailed;
        }
    }

    pub fn purify(self: *Manager, dry_run: bool, shoot_orphans: bool, purge_corruption: bool) TransactionError![][:0]const u8 {
        if (self.handle == null) return TransactionError.NoHandle;
        var operation_scope = OperationScope.init(self, .cleanup, null);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkOperationCancelled();
        var target_names: std.ArrayList([:0]const u8) = .empty;
        errdefer {
            for (target_names.items) |target_name| self.allocator.free(target_name);
            target_names.deinit(self.allocator);
        }
        if (shoot_orphans) {
            const orphans = self.get_orphans(false) catch return TransactionError.OrphanShootFailed;
            defer libalpm.OwnedPackage.deinitSlice(self.allocator, orphans);

            for (orphans) |orphan| {
                const target_name = self.allocator.dupeZ(u8, orphan.name() orelse "") catch return TransactionError.OutOfMemory;
                target_names.append(self.allocator, target_name) catch {
                    self.allocator.free(target_name);
                    return TransactionError.OutOfMemory;
                };
            }
            if (!dry_run) {
                self.remove_packages(target_names.items, TransFlag{
                    .nosave = true,
                    .recurse = true,
                    .unneeded = true,
                }, true) catch |err| {
                    return err;
                };
            }
        }

        if (purge_corruption) {
            var dir = std.Io.Dir.cwd().openDir(self.io(), self.config.cache_directory, .{ .iterate = true }) catch return TransactionError.DirectoryReadFailed;
            defer dir.close(self.io());
            var file_walker = dir.walk(self.allocator) catch return TransactionError.DirectoryReadFailed;
            defer file_walker.deinit();
            while (file_walker.next(self.io()) catch return TransactionError.DatabaseReadFailed) |entry| {
                if (entry.kind != .file) continue;
                if (std.mem.indexOf(u8, entry.basename, ".pkg.tar") == null) continue;
                if (std.mem.endsWith(u8, entry.basename, ".sig")) continue;
                const full_path_z = std.fs.path.joinZ(
                    self.allocator,
                    &.{ self.config.cache_directory, entry.path },
                ) catch return TransactionError.OutOfMemory;
                defer self.allocator.free(full_path_z);
                var pkg_ptr: ?*rawLibalpm.alpm_pkg_t = null;
                const sig_level = (libalpm.SigLevel{ .package_optional = true, .database_optional = true }).to_sig_level();
                const pkg_load = rawLibalpm.alpm_pkg_load(self.handle, full_path_z, @intFromBool(false), sig_level, &pkg_ptr);
                _ = rawLibalpm.alpm_pkg_free(pkg_ptr);
                if (pkg_load != -1) continue;

                const name = self.allocator.dupeZ(u8, entry.basename) catch return TransactionError.OutOfMemory;
                target_names.append(self.allocator, name) catch {
                    self.allocator.free(name);
                    return TransactionError.OutOfMemory;
                };
                if (!dry_run) {
                    std.Io.Dir.cwd().deleteFile(self.io(), full_path_z) catch |err| switch (err) {
                        error.FileNotFound => {}, // Already deleted
                        else => return TransactionError.RemovalFailed,
                    };
                }
            }
        }

        return target_names.toOwnedSlice(self.allocator);
    }

    pub fn is_package_installed(self: *Manager, package_name: [:0]const u8) bool {
        if (self.handle == null) return false;
        var operation_scope = OperationScope.init(self, .search, package_name);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        if (self.operation_context) |context| {
            if (context.isCancelled()) {
                operation_scope.finish(.cancelled);
                return false;
            }
        }
        const local_db = rawLibalpm.alpm_get_localdb(self.handle);
        const pkg = rawLibalpm.alpm_db_get_pkg(local_db, package_name);
        return pkg != null;
    }

    pub fn ignore_package(self: *Manager, package_name: []const u8) IgnorePackageError!void {
        var operation_scope = OperationScope.init(self, .configure, package_name);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try configuration.Configuration.add_ignore_package(
            &self.config,
            self.io(),
            self.allocator,
            self.config_path,
            package_name,
        );
    }

    pub fn ignore_packages(self: *Manager, package_names: []const []const u8) IgnorePackageError!void {
        var operation_scope = OperationScope.init(self, .configure, if (package_names.len == 0) null else package_names[0]);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try configuration.Configuration.add_ignore_packages(
            &self.config,
            self.io(),
            self.allocator,
            self.config_path,
            package_names,
        );
    }

    pub fn unignore_package(self: *Manager, package_name: []const u8) IgnorePackageError!void {
        var operation_scope = OperationScope.init(self, .configure, package_name);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try configuration.Configuration.remove_ignore_package(
            &self.config,
            self.io(),
            self.allocator,
            self.config_path,
            package_name,
        );
    }

    pub fn unignore_packages(self: *Manager, package_names: []const []const u8) IgnorePackageError!void {
        var operation_scope = OperationScope.init(self, .configure, if (package_names.len == 0) null else package_names[0]);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try configuration.Configuration.remove_ignore_packages(
            &self.config,
            self.io(),
            self.allocator,
            self.config_path,
            package_names,
        );
    }

    /// Returns a normalized list whose strings are borrowed from `self.config`.
    /// The caller must deinitialize the returned list, but must not free its items.
    pub fn get_ignored_packages(self: *Manager) IgnorePackageError!std.ArrayList([:0]const u8) {
        var operation_scope = OperationScope.init(self, .search, null);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        return configuration.Configuration.get_ignored_packages(&self.config, self.allocator);
    }

    pub fn hold_package(self: *Manager, package_name: []const u8) HoldPackageError!void {
        var operation_scope = OperationScope.init(self, .configure, package_name);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try configuration.Configuration.add_hold_package(
            &self.config,
            self.io(),
            self.allocator,
            self.config_path,
            package_name,
        );
    }

    pub fn hold_packages(self: *Manager, package_names: []const []const u8) HoldPackageError!void {
        var operation_scope = OperationScope.init(self, .configure, if (package_names.len == 0) null else package_names[0]);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try configuration.Configuration.add_hold_packages(
            &self.config,
            self.io(),
            self.allocator,
            self.config_path,
            package_names,
        );
    }

    pub fn unhold_package(self: *Manager, package_name: []const u8) HoldPackageError!void {
        var operation_scope = OperationScope.init(self, .configure, package_name);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try configuration.Configuration.remove_hold_package(
            &self.config,
            self.io(),
            self.allocator,
            self.config_path,
            package_name,
        );
    }

    pub fn unhold_packages(self: *Manager, package_names: []const []const u8) HoldPackageError!void {
        var operation_scope = OperationScope.init(self, .configure, if (package_names.len == 0) null else package_names[0]);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try configuration.Configuration.remove_hold_packages(
            &self.config,
            self.io(),
            self.allocator,
            self.config_path,
            package_names,
        );
    }

    /// Returns a normalized list whose strings are borrowed from `self.config`.
    /// The caller must deinitialize the returned list, but must not free its items.
    pub fn get_held_packages(self: *Manager) HoldPackageError!std.ArrayList([:0]const u8) {
        var operation_scope = OperationScope.init(self, .search, null);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        return configuration.Configuration.get_held_packages(&self.config, self.allocator);
    }

    /// Adds a repository to the configuration and appends its `[name]` section
    /// to the config file. `sig_level` and `usage` are raw config strings such
    /// as "Required DatabaseOptional" and "Sync Search"; empty strings omit the
    /// directive and keep the `Repository` defaults.
    pub fn add_repository(
        self: *Manager,
        name: []const u8,
        servers: []const []const u8,
        sig_level: []const u8,
        usage: []const u8,
    ) RepositoryError!void {
        var operation_scope = OperationScope.init(self, .configure, name);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try configuration.Configuration.add_repository(
            &self.config,
            self.io(),
            self.allocator,
            self.config_path,
            name,
            servers,
            sig_level,
            usage,
        );
    }

    /// Removes every repository named `name` from the configuration and deletes
    /// its section from the config file. Unknown names leave everything untouched.
    pub fn remove_repository(
        self: *Manager,
        name: []const u8,
    ) RepositoryError!void {
        var operation_scope = OperationScope.init(self, .configure, name);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try configuration.Configuration.remove_repository(
            &self.config,
            self.io(),
            self.allocator,
            self.config_path,
            name,
        );
    }

    /// Returns repository names borrowed from the parsed configuration in
    /// declaration order. Deinitialize the list, but do not free its items.
    pub fn get_repository_names(self: *Manager) QueryError!std.ArrayList([]const u8) {
        var operation_scope = OperationScope.init(self, .search, null);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkOperationCancelled();
        return configuration.Configuration.get_repository_names(&self.config, self.allocator);
    }

    /// Finds a parsed repository by its exact ALPM database name.
    pub fn find_configured_repository(
        self: *const Manager,
        name: []const u8,
    ) ?*const configuration.Configuration.Repository {
        return configuration.Configuration.find_repository(&self.config, name);
    }

    /// Returns cache directories currently configured on the libalpm handle.
    /// Strings are borrowed from libalpm; deinitialize only the returned list.
    pub fn get_configured_cache_directories(self: *Manager) QueryError!std.ArrayList([:0]const u8) {
        if (self.handle == null) return QueryError.NoHandle;
        var operation_scope = OperationScope.init(self, .search, null);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkOperationCancelled();

        var result: std.ArrayList([:0]const u8) = .empty;
        errdefer result.deinit(self.allocator);

        var directories = rawLibalpm.alpm_option_get_cachedirs(self.handle);
        while (directories != null) : (directories = directories.*.next) {
            const data = directories.*.data orelse continue;
            const directory = libalpm.str(@as([*c]const u8, @ptrCast(data))) orelse continue;
            result.append(self.allocator, directory) catch return QueryError.OutOfMemory;
        }
        return result;
    }

    pub fn get_cache_directories(self: *Manager) QueryError!std.ArrayList([:0]const u8) {
        if (self.handle == null) return QueryError.NoHandle;
        var operation_scope = OperationScope.init(self, .search, null);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkOperationCancelled();
        return self.get_configured_cache_directories();
    }

    /// Compares package versions using libalpm semantics. Returns a negative
    /// value when `a < b`, zero when equal, and a positive value when `a > b`.
    pub fn compare_package_versions(a: [:0]const u8, b: [:0]const u8) c_int {
        return rawLibalpm.alpm_pkg_vercmp(a.ptr, b.ptr);
    }

    pub fn version_compare(a: [:0]const u8, b: [:0]const u8) c_int {
        return compare_package_versions(a, b);
    }

    /// Reports whether the initialized host was detected as CachyOS.
    pub fn is_cachyos(self: *const Manager) bool {
        return self.detected_cachyos;
    }

    pub fn get_allowed_architecture(self: *Manager) QueryError![][:0]const u8 {
        if (self.handle == null) return QueryError.NoHandle;
        var operation_scope = OperationScope.init(self, .search, null);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkOperationCancelled();
        var arches = rawLibalpm.alpm_option_get_architectures(self.handle);
        var arch_list: std.ArrayList([:0]const u8) = .empty;
        errdefer {
            for (arch_list.items) |owned_arch| {
                self.allocator.free(owned_arch);
            }
            arch_list.deinit(self.allocator);
        }

        while (arches != null) : (arches = arches.*.next) {
            const data = arches.*.data orelse continue;
            const arch: [:0]const u8 =
                std.mem.span(@as([*c]const u8, @ptrCast(data)));
            const owned_arch = self.allocator.dupeZ(u8, arch) catch return QueryError.OutOfMemory;
            arch_list.append(self.allocator, owned_arch) catch
                {
                    self.allocator.free(owned_arch);
                    return QueryError.OutOfMemory;
                };
        }
        return arch_list.toOwnedSlice(self.allocator);
    }

    fn get_orphans(self: *Manager, remove_optional_for: bool) TransactionError![]libalpm.OwnedPackage {
        // TODO: implement A <-> B circular dependency removal
        if (self.handle == null) return TransactionError.NoHandle;
        const local_db = rawLibalpm.alpm_get_localdb(self.handle);
        var pkgs_list = rawLibalpm.alpm_db_get_pkgcache(local_db) orelse return TransactionError.DatabaseReadFailed;
        var orphans: std.ArrayList(libalpm.OwnedPackage) = .empty;
        errdefer {
            libalpm.OwnedPackage.deinitItems(self.allocator, orphans.items);
            orphans.deinit(self.allocator);
        }
        while (pkgs_list != null) : (pkgs_list = pkgs_list.*.next) {
            const pkg = libalpm.Package.from(pkgs_list.*.data.?) orelse continue;
            if (pkg.install_reason() == .Explicit) continue;
            var required_by = pkg.required_by();
            var bool_required_by = false;
            while (required_by.next()) |_| {
                bool_required_by = true;
                break;
            }
            if (!remove_optional_for) {
                var optional_for = pkg.optional_for();
                while (optional_for.next()) |_| {
                    bool_required_by = true;
                    break;
                }
            }
            if (bool_required_by) continue;
            var owned_package = libalpm.OwnedPackage.init(self.allocator, pkg) catch return TransactionError.OutOfMemory;
            orphans.append(self.allocator, owned_package) catch {
                owned_package.deinit(self.allocator);
                return TransactionError.OutOfMemory;
            };
        }
        return orphans.toOwnedSlice(self.allocator) catch return TransactionError.OutOfMemory;
    }

    // Determines if a single package is available for optional dependency install.
    fn get_opt_depend_if_available(self: *Manager, pkg_name: [:0]const u8) TransactionError!bool {
        if (self.handle == null) return TransactionError.NoHandle;
        const sync_database = rawLibalpm.alpm_get_syncdbs(self.handle);
        var sync_dbs = sync_database;
        // Essentially same as above but iterates just for a single package name
        // Discarding the results as we don't need them here and it removes unnecessary allocations.
        while (sync_dbs != null) : (sync_dbs = sync_dbs.*.next) {
            const db_data: ?*anyopaque = sync_dbs.*.data;
            const db: *rawLibalpm.alpm_db_t = @ptrCast(@alignCast(db_data orelse continue));
            const database = libalpm.Database.from(db) orelse continue;
            if (!database.allowUsage(.install)) continue;
            if (rawLibalpm.alpm_db_get_pkg(db, pkg_name.ptr) != null) return true;
            if (rawLibalpm.alpm_db_get_group(db, pkg_name.ptr) != null) return true;
            if (rawLibalpm.alpm_find_satisfier(rawLibalpm.alpm_db_get_pkgcache(db), pkg_name.ptr) != null) return true;
        }
        return false;
    }

    pub fn refresh(self: *Manager) TransactionError!void {
        var operation_scope = OperationScope.init(self, .sync, null);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkOperationCancelled();
        if (self.handle != null) {
            const refresh_result = rawLibalpm.alpm_release(self.handle);
            if (refresh_result != 0) {
                self.dispatcher.raiseError(.{
                    .message = "Failed to release the ALPM handle while reloading package databases",
                });
                return TransactionError.RefreshFailed;
            }
            self.handle = null;
        }

        self.sync_dbs.clearRetainingCapacity();

        var err2: rawLibalpm.alpm_errno_t = 0;
        self.handle = rawLibalpm.alpm_initialize(self.config.root_directory, self.config.database_path, &err2);
        if (self.handle == null) {
            var message_buffer: [512]u8 = undefined;
            const message = std.fmt.bufPrint(
                &message_buffer,
                "Failed to reinitialize ALPM while reloading package databases: {s}",
                .{std.mem.span(rawLibalpm.alpm_strerror(err2))},
            ) catch "Failed to reinitialize ALPM while reloading package databases";
            self.dispatcher.raiseError(.{ .message = message });
            return TransactionError.RefreshFailed;
        }

        self.applyConfig(self.config);
        self.setupCallbacks();
    }

    /// Returns owned names of packages that require `packageName` in the named
    /// database. The caller owns both the returned slice and every name in it.
    pub fn get_required_packages(self: *Manager, packageName: []const u8, databaseName: []const u8) TransactionError![][]const u8 {
        if (self.handle == null) return TransactionError.NoHandle;
        if (databaseName.len == 0 or packageName.len == 0) return TransactionError.NoPackageFound;
        var required_names: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (required_names.items) |item| self.allocator.free(item);
            required_names.deinit(self.allocator);
        }

        const db: libalpm.Database = if (std.ascii.eqlIgnoreCase(databaseName, "local")) blk: {
            const local_db = rawLibalpm.alpm_get_localdb(self.handle) orelse return TransactionError.DatabaseReadFailed;
            break :blk .{ .ptr = local_db };
        } else blk: {
            var dbs = rawLibalpm.alpm_get_syncdbs(self.handle);
            while (dbs != null) : (dbs = dbs.*.next) {
                const data = dbs.*.data orelse continue;
                const sync_db = libalpm.Database.from(data) orelse continue;
                const name = sync_db.name() orelse continue;
                if (std.ascii.eqlIgnoreCase(databaseName, name)) break :blk sync_db;
            }
            return TransactionError.DatabaseReadFailed;
        };

        var pkgs = db.packages();
        while (pkgs.next()) |pkg| {
            const pkg_name = pkg.name() orelse continue;
            if (std.ascii.eqlIgnoreCase(pkg_name, packageName)) {
                const required_by = rawLibalpm.alpm_pkg_compute_requiredby(pkg.ptr);
                defer {
                    rawLibalpm.alpm_list_free_inner(required_by, rawLibalpm.free);
                    rawLibalpm.alpm_list_free(required_by);
                }
                var node = required_by;
                while (node != null) : (node = node.*.next) {
                    const data = node.*.data orelse continue;
                    const req_by = std.mem.span(@as([*c]const u8, @ptrCast(data)));
                    const owned_name = self.allocator.dupe(u8, req_by) catch return TransactionError.OutOfMemory;
                    required_names.append(self.allocator, owned_name) catch {
                        self.allocator.free(owned_name);
                        return TransactionError.OutOfMemory;
                    };
                }
                break;
            }
        }
        return required_names.toOwnedSlice(self.allocator) catch return TransactionError.OutOfMemory;
    }

    fn download_database(
        self: *Manager,
        download_session: *downloader.DownloadSession,
        database_name: []const u8,
        urls: std.ArrayList([]const u8),
        sync_directory: []const u8,
        force_download: bool,
        signature_policy: DatabaseSignaturePolicy,
    ) downloader.DownloadError!void {
        const download_config = databaseDownloadConfiguration(
            urls.items.len,
            self.download_address_family_policy,
        );
        var downloader_instance = download_session.downloader(download_config);
        defer downloader_instance.deinit();
        downloader_instance.quiet = true;
        if (self.dispatcher.operation) |operation| downloader_instance.setParentOperation(operation) else downloader_instance.setOperationContext(self.operation_context);
        downloader_instance.setEventCallback(onDownloadEvent, self);
        const dest = std.fmt.allocPrint(self.allocator, "{s}/{s}.db", .{ sync_directory, database_name }) catch return;
        defer self.allocator.free(dest);
        const sig_dest = std.fmt.allocPrint(self.allocator, "{s}.sig", .{dest}) catch return;
        defer self.allocator.free(sig_dest);

        var download_scope = MirrorDownloadScope.init(self, dest);
        defer download_scope.finish();
        download_scope.attach(&downloader_instance);

        var last_failure: ?downloader.DownloadError = null;
        for (urls.items) |url_base| {
            const db_url = std.fmt.allocPrint(self.allocator, "{s}/{s}.db", .{ url_base, database_name }) catch continue;
            defer self.allocator.free(db_url);

            const database_updated = switch (downloader_instance.downloadToFile(db_url, dest, force_download)) {
                .succes => true,
                .skipped => false,
                .failure => |err| {
                    if (err == downloader.DownloadError.Cancelled) return err;
                    last_failure = err;
                    continue;
                },
            };

            if (signature_policy == .disabled) {
                // A replaced unsigned database must not retain a signature for
                // its predecessor. An unchanged database can keep its existing
                // sibling because libalpm will not inspect it under this policy.
                if (database_updated) std.Io.Dir.cwd().deleteFile(self.io(), sig_dest) catch {};
                download_scope.succeed();
                return;
            }

            const sig_url = std.fmt.allocPrint(self.allocator, "{s}.sig", .{db_url}) catch return;
            defer self.allocator.free(sig_url);
            downloader_instance.quiet = true;
            const signature_result = downloader_instance.downloadToFile(sig_url, sig_dest, if (database_updated) force_download else false);
            downloader_instance.quiet = false;
            switch (signature_result) {
                .succes, .skipped => {
                    download_scope.succeed();
                    return;
                },
                .failure => |err| {
                    if (err == downloader.DownloadError.Cancelled) return err;
                    if (err == downloader.DownloadError.NotFound and signature_policy == .optional) {
                        // Optional means an absent signature is accepted, not
                        // that available signatures should be discarded.
                        std.Io.Dir.cwd().deleteFile(self.io(), sig_dest) catch {};
                        download_scope.succeed();
                        return;
                    }
                    last_failure = err;
                    // Do not leave a freshly downloaded database paired with a
                    // stale signature while trying the next mirror.
                    if (database_updated) {
                        std.Io.Dir.cwd().deleteFile(self.io(), dest) catch {};
                        std.Io.Dir.cwd().deleteFile(self.io(), sig_dest) catch {};
                    }
                    continue;
                },
            }
        }
        const final_error = last_failure orelse downloader.DownloadError.FailedDownload;
        self.reportAllMirrorsFailed(database_name, final_error);
        return final_error;
    }

    fn databaseSignaturePolicy(level: i32) DatabaseSignaturePolicy {
        if (level & rawLibalpm.ALPM_SIG_DATABASE == 0) return .disabled;
        if (level & rawLibalpm.ALPM_SIG_DATABASE_OPTIONAL != 0) return .optional;
        return .required;
    }

    /// Downloads every repository package selected by a prepared transaction
    fn confirmPreparedInstall(
        self: *Manager,
        requested_packages: []const *rawLibalpm.alpm_pkg_t,
        optional_names: []const [:0]const u8,
        trans_flags: TransFlag,
    ) TransactionError!void {
        const operation = self.dispatcher.operation orelse return;

        var plan_packages: std.ArrayList(operation_api.TransactionPackage) = .empty;
        defer plan_packages.deinit(self.allocator);

        var total_download: ?u64 = 0;
        var total_installed: ?u64 = 0;
        var net_installed: ?i64 = 0;
        const local_db = rawLibalpm.alpm_get_localdb(self.handle);
        var packages = rawLibalpm.alpm_trans_get_add(self.handle);
        while (packages != null) : (packages = packages.*.next) {
            const data = packages.*.data orelse continue;
            const package = libalpm.Package{ .ptr = @ptrCast(@alignCast(data)) };
            const name = package.name() orelse "unknown";
            const download_size = nonNegativeSize(package.download_size());
            const installed_size = nonNegativeSize(package.install_size());

            total_download = addOptionalSize(total_download, download_size);
            total_installed = addOptionalSize(total_installed, installed_size);

            const old_size: i64 = if (rawLibalpm.alpm_db_get_pkg(local_db, name.ptr)) |local_package|
                (libalpm.Package{ .ptr = local_package }).install_size()
            else
                0;
            net_installed = addOptionalDelta(
                net_installed,
                std.math.sub(i64, package.install_size(), old_size) catch null,
            );

            try plan_packages.append(self.allocator, .{
                .name = name,
                .version = package.version(),
                .repository = package.repository(),
                .source = .repository,
                .role = preparedPackageRole(
                    name,
                    requested_packages,
                    optional_names,
                    trans_flags.alldeps,
                ),
                .download_size = download_size,
                .installed_size = installed_size,
            });
        }

        var answer = operation.ask(.{
            .kind = .confirm_transaction,
            .prompt = "Proceed with package installation?",
            .transaction_plan = .{
                .action = .install,
                .packages = plan_packages.items,
                .total_download_size = total_download,
                .total_installed_size = total_installed,
                .net_installed_size = net_installed,
            },
            .default_response = .accepted,
        }) catch |err| switch (err) {
            error.Cancelled => return TransactionError.Cancelled,
            else => return TransactionError.OutOfMemory,
        };
        defer answer.deinit(self.allocator);
        if (answer.response == .accepted) return;

        operation.context.cancel();
        return TransactionError.Cancelled;
    }

    fn predownloadPreparedPackages(self: *Manager, trans_flags: TransFlag) TransactionError!void {
        if (trans_flags.dbonly) return;
        self.unexpected_fetch_reported.store(false, .release);
        try self.download_prepared_packages();
    }

    fn stalePartSweep(self: *Manager, max_age: std.Io.Duration) void {
        var cache_directories = self.get_cache_directories() catch return;
        defer cache_directories.deinit(self.allocator);

        for (cache_directories.items) |cache_directory| {
            stalePartSweepDirectory(self.allocator, self.io(), cache_directory, max_age);
        }
    }

    fn download_prepared_packages(self: *Manager) TransactionError!void {
        self.stalePartSweep(std.Io.Duration.fromSeconds(500));
        const download_future = std.Io.Future(downloader.DownloadError!void);

        var futures: std.ArrayList(download_future) = .empty;
        defer futures.deinit(self.allocator);

        var failed = false;
        var packages = rawLibalpm.alpm_trans_get_add(self.handle);

        while (packages != null) : (packages = packages.*.next) {
            const data = packages.*.data orelse continue;
            const package = libalpm.Package{ .ptr = @ptrCast(@alignCast(data)) };

            // File-origin packages are already available at their caller-supplied
            // path. Only dependencies selected from a sync database need to be
            // copied into libalpm's package cache before commit.
            if (rawLibalpm.alpm_pkg_get_origin(package.ptr) != rawLibalpm.ALPM_PKG_FROM_SYNCDB) continue;

            const database = package.database() orelse {
                failed = true;
                continue;
            };

            var future = self.io().concurrent(download_package, .{ self, package, database }) catch {
                // Fall back to a synchronous download when concurrency fails to allocate
                self.download_package(package, database) catch {
                    failed = true;
                };
                continue;
            };

            futures.append(self.allocator, future) catch {
                future.await(self.io()) catch {
                    failed = true;
                };
            };
        }

        for (futures.items) |*future_item| {
            future_item.await(self.io()) catch {
                failed = true;
            };
        }

        if (failed) return TransactionError.UpdateFetchFailed;
    }

    fn download_package(self: *Manager, package: libalpm.Package, database: libalpm.Database) downloader.DownloadError!void {
        const download_config = mirrorDownloadConfiguration(
            databaseServerCount(database),
            self.download_address_family_policy,
        );
        var downloader_instance = downloader.CoreDownloader.init(self.allocator, self.io(), download_config);
        defer downloader_instance.deinit();
        downloader_instance.quiet = true;
        if (self.dispatcher.operation) |operation| downloader_instance.setParentOperation(operation) else downloader_instance.setOperationContext(self.operation_context);
        downloader_instance.setEventCallback(onDownloadEvent, self);
        const dest = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.config.cache_directory, package.file_name() }) catch return;
        defer self.allocator.free(dest);
        const sig_dest = std.fmt.allocPrint(self.allocator, "{s}.sig", .{dest}) catch return;
        defer self.allocator.free(sig_dest);

        var download_scope = MirrorDownloadScope.init(self, dest);
        defer download_scope.finish();
        download_scope.attach(&downloader_instance);

        var last_failure: ?downloader.DownloadError = null;
        var urls = database.servers();
        while (urls.next()) |url| {
            const file_url = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ url, package.file_name() }) catch return downloader.DownloadError.InvalidUrl;
            defer self.allocator.free(file_url);

            switch (downloader_instance.downloadToFile(file_url, dest, true)) {
                .succes => {
                    const sig_url = std.fmt.allocPrint(self.allocator, "{s}.sig", .{file_url}) catch return downloader.DownloadError.InvalidUrl;
                    defer self.allocator.free(sig_url);
                    downloader_instance.quiet = true;
                    const signature_result = downloader_instance.downloadToFile(sig_url, sig_dest, true);
                    downloader_instance.quiet = false;
                    try propagateSignatureCancellation(signature_result);
                    download_scope.succeed();
                    return;
                },
                .failure => |err| {
                    if (err == downloader.DownloadError.Cancelled) return err;
                    last_failure = err;
                    continue;
                },
                .skipped => continue,
            }
        }
        const final_error = last_failure orelse downloader.DownloadError.FailedDownload;
        self.reportAllMirrorsFailed(package.file_name(), final_error);
        return final_error;
    }

    fn reportAllMirrorsFailed(self: *Manager, subject: []const u8, err: downloader.DownloadError) void {
        const message = downloader.failureMessage(self.allocator, .{
            .event_type = .Error,
            .destination_path = subject,
            .download_error = err,
        }) catch {
            self.dispatcher.raiseError(.{ .message = "Could not download the required files from any configured mirror. Check your internet connection and try again." });
            return;
        };
        defer self.allocator.free(message);
        self.dispatcher.raiseError(.{ .message = message });
    }

    pub fn io(self: *Manager) std.Io {
        return self.threaded.io();
    }

    fn checkOperationCancelled(self: *Manager) error{Cancelled}!void {
        if (self.dispatcher.operation) |operation| try operation.checkCancelled();
        if (self.operation_context) |context| {
            if (context.isCancelled()) return error.Cancelled;
        }
    }

    pub fn deinit(self: *Manager) void {
        const allocator = self.allocator;
        if (self.handle) |h| _ = libalpm.alpm.alpm_release(h);
        self.handle = null;
        self.is_initialized = false;
        self.sync_dbs.deinit(self.allocator);
        self.config.deinitialize();
        allocator.free(self.config_path);
        self.dispatcher.deinit();
        self.threaded.deinit();
        allocator.destroy(self);
    }

    fn setupCallbacks(self: *Manager) void {
        const h = self.handle;
        _ = rawLibalpm.alpm_option_set_progresscb(h, progressCallback, self);
        _ = rawLibalpm.alpm_option_set_eventcb(h, eventCallback, self);
        _ = rawLibalpm.alpm_option_set_questioncb(h, questionCallback, self);
        _ = rawLibalpm.alpm_option_set_fetchcb(h, fetchCallback, self);
    }

    fn applyConfig(self: *Manager, config: configuration.Configuration.Config) void {
        const h = self.handle;

        for (config.ignore_package.items) |pkg_name| {
            self.check("ignore_package", rawLibalpm.alpm_option_add_ignorepkg(h, pkg_name.ptr));
        }

        for (config.ignore_group.items) |group_name| {
            self.check("ignore_group", rawLibalpm.alpm_option_add_ignoregroup(h, group_name.ptr));
        }

        if (self.hooks_disabled) {
            self.replaceHookDirsWithSentinel(h);
        } else {
            for (config.hook_directory.items) |hook_dir| {
                self.check("hook_directory", rawLibalpm.alpm_option_add_hookdir(h, hook_dir.ptr));
            }
        }

        self.check("gpgdir", rawLibalpm.alpm_option_set_gpgdir(h, config.gpg_directory.ptr));

        if (config.signature_level != 0) {
            self.check("default_sig_level", rawLibalpm.alpm_option_set_default_siglevel(h, @intCast(config.signature_level)));
            self.check("local_file_sig_level", rawLibalpm.alpm_option_set_local_file_siglevel(h, @intCast(config.local_file_signature_level)));
        }
        self.check("remote_file_sig_level", rawLibalpm.alpm_option_set_remote_file_siglevel(h, @intCast(config.remote_file_signature_level)));

        if (config.cache_directory.len != 0) {
            self.check("cachedir", rawLibalpm.alpm_option_add_cachedir(h, config.cache_directory.ptr));
        }

        if (config.log_file.len != 0) {
            self.check("logfile", rawLibalpm.alpm_option_set_logfile(h, config.log_file.ptr));
        }

        self.check("check_space", rawLibalpm.alpm_option_set_checkspace(h, @as(c_int, if (config.check_space) 1 else 0)));

        const resolved_arch = resolveArchitecture(config.architecture);
        const resolved_arch_z = self.allocator.dupeSentinel(u8, resolved_arch, 0) catch {
            std.log.err("out of memory resolving architecture; skipping repository registration", .{});
            return;
        };
        defer self.allocator.free(resolved_arch_z);

        self.check("add_arch", rawLibalpm.alpm_option_add_architecture(h, resolved_arch_z.ptr));
        self.check("add_arch_any", rawLibalpm.alpm_option_add_architecture(h, "any"));

        var registered_arches: std.ArrayList([]const u8) = .empty;
        defer {
            for (registered_arches.items) |a| self.allocator.free(a);
            registered_arches.deinit(self.allocator);
        }

        for (config.repositories.items) |repo| {
            self.registerRepository(repo, resolved_arch_z, &registered_arches);
        }
    }

    fn check(self: *Manager, what: [:0]const u8, ret: c_int) void {
        if (ret != 0) {
            std.log.warn("alpm option '{s}' failed: {s}", .{
                what,
                std.mem.span(rawLibalpm.alpm_strerror(rawLibalpm.alpm_errno(self.handle))),
            });
        }
    }

    fn resolveArchitecture(architecture: []const u8) []const u8 {
        var it = std.mem.tokenizeScalar(u8, architecture, ' ');
        const first = it.next() orelse "auto";
        if (std.ascii.eqlIgnoreCase(first, "auto")) {
            return switch (builtin.cpu.arch) {
                .x86_64 => "x86_64",
                .aarch64 => "aarch64",
                else => "x86_64",
            };
        }
        return first;
    }

    fn registerRepository(
        self: *Manager,
        repo: configuration.Configuration.Repository,
        resolved_arch: []const u8,
        registered_arches: *std.ArrayList([]const u8),
    ) void {
        const use_default: u32 = @bitCast((libalpm.SigLevel{ .use_default = true }).to_sig_level());
        const effective_sig: c_int = if (repo.sig_level == 0 or repo.sig_level == use_default)
            @intCast(self.config.signature_level)
        else
            @intCast(repo.sig_level);

        // alpm copies the treename, so a temporary null-terminated name is fine.
        const name_z = self.allocator.dupeSentinel(u8, repo.name, 0) catch return;
        defer self.allocator.free(name_z);

        const db = rawLibalpm.alpm_register_syncdb(self.handle, name_z.ptr, effective_sig) orelse {
            std.log.err("alpm_register_syncdb('{s}') failed: {s}", .{
                repo.name,
                std.mem.span(rawLibalpm.alpm_strerror(rawLibalpm.alpm_errno(self.handle))),
            });
            return;
        };

        if (repo.usage != 0) {
            self.check("db_set_usage", rawLibalpm.alpm_db_set_usage(db, @intCast(repo.usage)));
        }

        for (repo.servers.items) |server| {
            self.registerMicroArchitectures(server, resolved_arch, registered_arches);

            const resolved = self.resolveServer(server, repo.name, resolved_arch) orelse continue;
            defer self.allocator.free(resolved);
            self.check("db_add_server", rawLibalpm.alpm_db_add_server(db, resolved.ptr));
        }

        self.sync_dbs.append(self.allocator, .{ .ptr = db }) catch {};
    }

    fn registerMicroArchitectures(
        self: *Manager,
        server: []const u8,
        resolved_arch: []const u8,
        registered_arches: *std.ArrayList([]const u8),
    ) void {
        const marker = "$arch";
        const marker_idx = std.mem.indexOf(u8, server, marker) orelse return;
        const after = server[marker_idx + marker.len ..];
        const suffix_end = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
        const suffix = after[0..suffix_end];

        const v_idx = std.mem.indexOfScalar(u8, suffix, 'v') orelse return;
        const level = std.fmt.parseInt(u8, suffix[v_idx + 1 ..], 10) catch return;

        var i: u8 = level;
        while (i >= 2) : (i -= 1) {
            const arch_name = std.fmt.allocPrint(self.allocator, "{s}_v{d}", .{ resolved_arch, i }) catch return;

            var already = false;
            for (registered_arches.items) |a| {
                if (std.mem.eql(u8, a, arch_name)) {
                    already = true;
                    break;
                }
            }
            if (already) {
                self.allocator.free(arch_name);
                continue;
            }

            const arch_z = self.allocator.dupeSentinel(u8, arch_name, 0) catch {
                self.allocator.free(arch_name);
                return;
            };
            defer self.allocator.free(arch_z);

            self.check("add_arch", rawLibalpm.alpm_option_add_architecture(self.handle, arch_z.ptr));
            registered_arches.append(self.allocator, arch_name) catch self.allocator.free(arch_name);
        }
    }

    fn resolveServer(self: *Manager, template: []const u8, repo_name: []const u8, resolved_arch: []const u8) ?[:0]const u8 {
        const step1 = std.mem.replaceOwned(u8, self.allocator, template, "$repo", repo_name) catch return null;
        defer self.allocator.free(step1);
        const step2 = std.mem.replaceOwned(u8, self.allocator, step1, "$arch", resolved_arch) catch return null;
        defer self.allocator.free(step2);
        return self.allocator.dupeSentinel(u8, step2, 0) catch null;
    }

    // libalpm invokes an external fetch callback even when a prepared artifact
    // is already cached. Validate that predownload populated the directory and
    // report the file as current; never perform network or filesystem writes
    // from this callback.
    fn fetchCallback(
        ctx: ?*anyopaque,
        url: [*c]const u8,
        local_path: [*c]const u8,
        force: c_int,
    ) callconv(.c) c_int {
        _ = force;
        if (ctx == null or url == null or local_path == null) return -1;

        const self: *Manager = @ptrCast(@alignCast(ctx.?));
        const file_name = fetchUrlBasename(std.mem.span(url)) orelse {
            self.reportUnexpectedFetch();
            return -1;
        };
        const cached_path = std.fs.path.join(
            self.allocator,
            &.{ std.mem.span(local_path), file_name },
        ) catch {
            self.reportUnexpectedFetch();
            return -1;
        };
        defer self.allocator.free(cached_path);

        std.Io.Dir.cwd().access(self.io(), cached_path, .{}) catch {
            self.reportUnexpectedFetch();
            return -1;
        };
        return 1;
    }

    fn reportUnexpectedFetch(self: *Manager) void {
        if (self.unexpected_fetch_reported.swap(true, .acq_rel)) return;
        self.dispatcher.raiseError(.{
            .message = "Unexpected libalpm fetch request: prepared package is missing from the cache.",
        });
    }

    fn fetchUrlBasename(url: []const u8) ?[]const u8 {
        var end = url.len;
        if (std.mem.indexOfScalar(u8, url, '?')) |index| end = @min(end, index);
        if (std.mem.indexOfScalar(u8, url, '#')) |index| end = @min(end, index);
        const path = url[0..end];
        const slash = std.mem.lastIndexOfScalar(u8, path, '/');
        const file_name = if (slash) |index| path[index + 1 ..] else path;
        if (file_name.len == 0 or
            std.mem.eql(u8, file_name, ".") or
            std.mem.eql(u8, file_name, "..")) return null;
        return file_name;
    }

    fn onDownloadEvent(ctx: ?*anyopaque, event: downloader.DownloadEvent) void {
        const self: *Manager = @ptrCast(@alignCast(ctx));
        self.handleDownloadEvent(event) catch return;
    }

    fn handleDownloadEvent(
        self: *Manager,
        event: downloader.DownloadEvent,
    ) TransactionError!void {
        const path = event.destination_path orelse "";

        switch (event.event_type) {
            .Start => {
                const message = std.fmt.allocPrint(
                    self.allocator,
                    "Retrieving package: {s}",
                    .{std.fs.path.basename(path)},
                ) catch return TransactionError.OutOfMemory;

                defer self.allocator.free(message);

                self.dispatcher.raiseInformational(.{
                    .event_type = .pkg_retrieve_start,
                    .message = message,
                });
            },

            .Progress => if (event.progress) |p| {
                // CoreDownloader forwards rich byte progress to the logical
                // download operation. Retain this fallback only for legacy
                // callers that do not attach a common operation.
                if (self.dispatcher.operation == null) {
                    self.dispatcher.raiseProgress(.{
                        .progress_type = @intCast(rawLibalpm.ALPM_PROGRESS_ADD_START),
                        .pkg_name = std.fs.path.basename(path),
                        .percent = p.percent,
                        .howmany = 1,
                        .current = 1,
                    });
                }
            },

            .Complete => {
                const message = std.fmt.allocPrint(
                    self.allocator,
                    "Package retrieval completed: {s}",
                    .{std.fs.path.basename(path)},
                ) catch return TransactionError.OutOfMemory;

                defer self.allocator.free(message);

                self.dispatcher.raiseInformational(.{
                    .event_type = .pkg_retrieve_done,
                    .message = message,
                });
            },

            .Error => {
                if (event.download_error) |err| if (err == error.Cancelled) return;
                const message = downloader.failureMessage(self.allocator, event) catch return TransactionError.OutOfMemory;
                defer self.allocator.free(message);
                self.dispatcher.raiseError(.{ .message = message });
            },

            .Skipped => {},
        }
    }

    fn progressCallback(
        ctx: ?*anyopaque,
        progress: rawLibalpm.alpm_progress_t,
        pkg: [*c]const u8,
        percent: c_int,
        howmany: usize,
        current: usize,
    ) callconv(.c) void {
        const self: *Manager = @ptrCast(@alignCast(ctx));
        self.dispatcher.raiseProgress(.{
            .progress_type = @intCast(progress),
            .pkg_name = spanC(pkg),
            .percent = percent,
            .howmany = @intCast(howmany),
            .current = @intCast(current),
        });
    }

    fn eventCallback(
        ctx: ?*anyopaque,
        event: [*c]rawLibalpm.alpm_event_t,
    ) callconv(.c) void {
        const self: *Manager = @ptrCast(@alignCast(ctx));
    
        self.handleEvent(event) catch return;
    }

    fn handleEvent(
        self: *Manager,
        event: [*c]rawLibalpm.alpm_event_t,
    ) TransactionError!void { 

        if (event == null) return;
        const type_value: u32 = @intCast(event.*.type);
        if (type_value < rawLibalpm.ALPM_EVENT_CHECKDEPS_START or type_value > rawLibalpm.ALPM_EVENT_HOOK_RUN_DONE) return;

        const event_type = libalpm.EventType.from_libalpm(@intCast(type_value));
        switch (event_type) {
            .scriptlet_info => {
                const line = spanC(event.*.scriptlet_info.line) orelse return;
                if (line.len != 0) self.dispatcher.raiseScriptlet(.{ .line = line });
            },
            .package_operation_start => {
                const operation = event.*.package_operation;
            
                const message = (switch (operation.operation) {
                    rawLibalpm.ALPM_PACKAGE_INSTALL => blk: {
                        const pkg = operation.newpkg orelse return;
                        const name = libalpm.str(rawLibalpm.alpm_pkg_get_name(pkg)) orelse return;
                        const version = libalpm.str(rawLibalpm.alpm_pkg_get_version(pkg)) orelse return;
            
                        break :blk std.fmt.allocPrint(
                            self.allocator,
                            "Installing package: {s}-{s}",
                            .{ name, version },
                        );
                    },
            
                    rawLibalpm.ALPM_PACKAGE_UPGRADE => blk: {
                        const oldpkg = operation.oldpkg orelse return;
                        const newpkg = operation.newpkg orelse return;
            
                        const name = libalpm.str(rawLibalpm.alpm_pkg_get_name(newpkg)) orelse return;
                        const old_version = libalpm.str(rawLibalpm.alpm_pkg_get_version(oldpkg)) orelse return;
                        const new_version = libalpm.str(rawLibalpm.alpm_pkg_get_version(newpkg)) orelse return;
            
                        break :blk std.fmt.allocPrint(
                            self.allocator,
                            "Upgrading package: {s} {s} -> {s}",
                            .{ name, old_version, new_version },
                        );
                    },
            
                    rawLibalpm.ALPM_PACKAGE_REINSTALL => blk: {
                        const pkg = operation.newpkg orelse return;
                        const name = libalpm.str(rawLibalpm.alpm_pkg_get_name(pkg)) orelse return;
                        const version = libalpm.str(rawLibalpm.alpm_pkg_get_version(pkg)) orelse return;
            
                        break :blk std.fmt.allocPrint(
                            self.allocator,
                            "Reinstalling package: {s}-{s}",
                            .{ name, version },
                        );
                    },
            
                    rawLibalpm.ALPM_PACKAGE_DOWNGRADE => blk: {
                        const oldpkg = operation.oldpkg orelse return;
                        const newpkg = operation.newpkg orelse return;
            
                        const name = libalpm.str(rawLibalpm.alpm_pkg_get_name(newpkg)) orelse return;
                        const old_version = libalpm.str(rawLibalpm.alpm_pkg_get_version(oldpkg)) orelse return;
                        const new_version = libalpm.str(rawLibalpm.alpm_pkg_get_version(newpkg)) orelse return;
            
                        break :blk std.fmt.allocPrint(
                            self.allocator,
                            "Downgrading package: {s} {s} -> {s}",
                            .{ name, old_version, new_version },
                        );
                    },
            
                    rawLibalpm.ALPM_PACKAGE_REMOVE => blk: {
                        const pkg = operation.oldpkg orelse return;
                        const name = libalpm.str(rawLibalpm.alpm_pkg_get_name(pkg)) orelse return;
                        const version = libalpm.str(rawLibalpm.alpm_pkg_get_version(pkg)) orelse return;
            
                        break :blk std.fmt.allocPrint(
                            self.allocator,
                            "Removing package: {s}-{s}",
                            .{ name, version },
                        );
                    },
            
                    else => return,
                }) catch return TransactionError.OutOfMemory;
            
                defer self.allocator.free(message);
            
                self.dispatcher.raiseInformational(.{
                    .event_type = event_type,
                    .message = message,
                });
            },
            .hook_run_start => {
                const hook = event.*.hook_run;
                const name = spanC(hook.name);
                const description = spanC(hook.desc);
                var message_buffer: [512]u8 = undefined;
                const message = if (description) |desc|
                    std.fmt.bufPrint(&message_buffer, "({d}/{d}) {s}", .{ hook.position, hook.total, desc }) catch desc
                else if (name) |hook_name|
                    std.fmt.bufPrint(&message_buffer, "({d}/{d}) {s}", .{ hook.position, hook.total, hook_name }) catch hook_name
                else
                    std.fmt.bufPrint(&message_buffer, "({d}/{d}) Running hook...", .{ hook.position, hook.total }) catch "Running hook...";

                self.dispatcher.raiseHook(.{
                    .description = message,
                    .position = @intCast(hook.position),
                    .total = @intCast(hook.total),
                });

                self.dispatcher.raiseInformational(.{
                    .event_type = event_type,
                    .message = message,
                });

            },
            .pacnew_created => self.dispatcher.raisePacnew(.{
                .file = spanC(event.*.pacnew_created.file),
            }),
            .pacsave_created => {
                const pacsave = event.*.pacsave_created;
                const pkg_name = if (pacsave.oldpkg) |pkg|
                    (libalpm.Package{ .ptr = pkg }).name()
                else
                    null;
                self.dispatcher.raisePacsave(.{
                    .pkg_name = pkg_name,
                    .file = spanC(pacsave.file),
                });
            },
            else => self.handleInformationMessage(event_type),
        }

    }
    fn handleInformationMessage(self: *Manager, event_type: libalpm.EventType) void {
        const message = switch (event_type) {
            .checkdeps_start => "Checking dependencies...",
            .checkdeps_done => "Dependency check finished.",
            .fileconflicts_start => "Checking for file conflicts...",
            .fileconflicts_done => "File conflict check finished.",
            .resolvedeps_start => "Resolving dependencies...",
            .resolvedeps_done => "Dependency resolution finished.",
            .interconflicts_start => "Checking for package conflicts...",
            .interconflicts_done => "Package conflict check finished.",
            .transaction_start => "Starting transaction...",
            .transaction_done => "Transaction completed.",
            .package_operation_done => "Package operation completed.",
            .integrity_start => "Checking package integrity...",
            .integrity_done => "Package integrity check finished.",
            .load_start => "Loading packages...",
            .load_done => "Packages loaded.",
            .db_retrieve_start => "Retrieving database...",
            .db_retrieve_done => "Database retrieved.",
            .db_retrieve_failed => "Failed to retrieve database.",
            .pkg_retrieve_start => "Retrieving package...",
            .pkg_retrieve_done => "Package retrieved.",
            .pkg_retrieve_failed => "Package retrieval failed.",
            .diskspace_start => "Checking disk space...",
            .diskspace_done => "Disk space check finished.",
            .optdep_removal => "Removing optional dependencies...",
            .database_missing => "Database missing. Please run `shelly keyring init` to initialize the keyring.",
            .keyring_start => "Checking keyring...",
            .keyring_done => "Keyring check finished.",
            .key_download_start => "Downloading key...",
            .key_download_done => "Key download finished.",
            .hook_start => "Running hooks...",
            .hook_done => "Finished running hooks.",
            .hook_run_done => "Finished running hook.",
            .scriptlet_info, .pacnew_created, .pacsave_created, .hook_run_start => return,
            .failed_optional_dependency_operation => "Failed to remove optional dependency.",
            .package_explicit => "Package marked as explicitly installed.",
            .failed_add_local_package => "Failed to add local package.",
            else => return,
        };

        self.dispatcher.raiseInformational(.{
            .event_type = event_type,
            .message = message,
        });
    }

    fn questionCallback(ctx: ?*anyopaque, question: [*c]rawLibalpm.alpm_question_t) callconv(.c) void {
        const self: *Manager = @ptrCast(@alignCast(ctx));
        const manager_io = self.io();

        const data: *anyopaque = @ptrCast(question);
        const qtype: c_int = @intCast(question.*.type);

        var buf: [512]u8 = undefined;

        switch (libalpm.QuestionType.fromQuestionType(question.*.type)) {
            .install_ignore => {
                const q = libalpm.InstallIgnoredQuestion.from(data).?;
                const text = std.fmt.bufPrint(&buf, "Install ignored package: {s}?", .{
                    q.package().name() orelse "unknown",
                }) catch "Install ignored package?";
                q.confirm_install(self.askYesNo(manager_io, qtype, text));
            },
            .replace_package => {
                const q = libalpm.ReplacePackageQuestion.from(data).?;
                const old_pkg = q.old_package();
                const new_pkg = q.new_package();
                const text = std.fmt.bufPrint(&buf, "Replace {s}-{s} with {s}-{s}?", .{
                    old_pkg.name() orelse "unknown",
                    old_pkg.version() orelse "?",
                    new_pkg.name() orelse "unknown",
                    new_pkg.version() orelse "?",
                }) catch "Replace package?";
                q.confirm_replace(self.askYesNo(manager_io, qtype, text));
            },
            .conflict_package => {
                const q = libalpm.ConflictQuestion.from(data).?;
                const conflict = q.conflict();
                const text = std.fmt.bufPrint(&buf, "{s} conflicts with {s}. Remove?", .{
                    conflict.packageOne().name() orelse "unknown",
                    conflict.packageTwo().name() orelse "unknown",
                }) catch "Remove the conflicting package?";
                q.confirm_removal(self.askYesNo(manager_io, qtype, text));
            },
            .corrupted_package => {
                const q = libalpm.RemoveCorruptedPackagesQuestion.from(data).?;
                const text = std.fmt.bufPrint(&buf, "Corrupted package {s}. Delete?", .{
                    q.filepath(),
                }) catch "Delete the corrupted package file?";
                q.confirm_remove(self.askYesNo(manager_io, qtype, text));
            },
            .remove_packages => {
                const q = libalpm.RemovePackagesQuestion.from(data).?;
                q.skipRemoval(self.askYesNo(
                    manager_io,
                    qtype,
                    "Some packages must be removed to proceed. Skip them instead?",
                ));
            },
            .import_key => {
                const q = libalpm.ImportKeyQuestion.from(data).?;
                const text = std.fmt.bufPrint(&buf, "Import PGP key {s}?", .{
                    q.uid() orelse "unknown",
                }) catch "Import the PGP key?";
                q.import(self.askYesNo(manager_io, qtype, text));
            },
            .select_provider => {
                self.handleSelectProvider(libalpm.SelectProviderQuestion.from(data).?, qtype);
            },
            else => {
                // Leave alpm's default answer (0) untouched.
            },
        }
    }

    fn askYesNo(self: *Manager, manager_io: std.Io, qtype: c_int, text: []const u8) bool {
        const yes_no = [_][]const u8{ "yes", "no" };
        const resp = self.dispatcher.raiseQuestion(manager_io, .{
            .question = text,
            .question_type = qtype,
            .options = &yes_no,
        });
        return (resp.answer orelse 0) != 0;
    }

    fn handleSelectProvider(
        self: *Manager,
        q: libalpm.SelectProviderQuestion,
        qtype: c_int,
    ) void {
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.allocator);
        var providers: std.ArrayList(events.ProviderOption) = .empty;
        defer providers.deinit(self.allocator);

        var node = q.ptr.providers;
        while (node != null) : (node = node.*.next) {
            const item = node.*.data orelse continue;
            const pkg = libalpm.Package{ .ptr = @ptrCast(@alignCast(item)) };
            const pkg_name = pkg.name() orelse continue;
            names.append(self.allocator, pkg_name) catch break;
            providers.append(self.allocator, .{
                .name = pkg_name,
                .description = pkg.description() orelse "",
                .is_installed = false,
            }) catch break;
        }

        var dep_string: [*c]u8 = null;
        defer if (dep_string != null) std.c.free(dep_string);
        const dependency_name: ?[]const u8 = if (q.ptr.depend == null) null else blk: {
            dep_string = rawLibalpm.alpm_dep_compute_string(q.ptr.depend);
            break :blk spanC(dep_string);
        };

        const resp = self.dispatcher.raiseQuestion(self.io(), .{
            .question = "Select a provider",
            .question_type = qtype,
            .options = names.items,
            .provider_options = providers.items,
            .dependency_name = dependency_name,
        });

        q.selected_choice(@intCast(resp.choice orelse 0));
    }

    fn handleErrorMessage(self: *Manager, error_number: c_int, data_ptr: bindings.libalpm.List) !void {
        const error_msg = std.mem.span(rawLibalpm.alpm_strerror(@intCast(error_number)));
        var details: std.ArrayList(u8) = .empty;
        defer details.deinit(self.allocator);

        const max_err = @intFromEnum(libalpm.Error.SandboxFailed);
        if (error_number < 0 or error_number > max_err) {
            try details.print(self.allocator, "Unknown error: {d}\n", .{error_number});
        } else switch (@as(libalpm.Error, @enumFromInt(error_number))) {
            .Ok => {},
            .Memory => try details.appendSlice(self.allocator, "Memory allocation failed.\n"),
            .System => try details.appendSlice(self.allocator, "System error.\n"),
            .BadPerms => try details.appendSlice(self.allocator, "Could not access the package database or required files. Check that you have permission to access them.\n"),
            .NotAFile => try details.appendSlice(self.allocator, "Expected a file at the supplied path. Check the path and try again.\n"),
            .NotADir => try details.appendSlice(self.allocator, "Expected a directory at the supplied path. Check the path and try again.\n"),
            .WrongArgs => try details.appendSlice(self.allocator, "Could not start the package operation because a required argument is missing or invalid.\n"),
            .DiskSpace => try details.appendSlice(self.allocator, "There is not enough free space to continue. Free up space on the destination filesystem, then try again.\n"),
            .HandleNull => try details.appendSlice(self.allocator, "Could not access the package database because it has not been initialized.\n"),
            .HandleNotNull => try details.appendSlice(self.allocator, "Could not initialize the package database because it is already open.\n"),
            .HandleLock => {
                const message = try user_errors.databaseLocked(self.allocator, self.config.database_path);
                defer self.allocator.free(message);
                try details.appendSlice(self.allocator, message);
                try details.appendSlice(self.allocator, "\n");
            },
            .DbOpen => try details.appendSlice(self.allocator, "Failed to open the database.\n"),
            .DbCreate => try details.appendSlice(self.allocator, "Failed to create the database.\n"),
            .DbNull => try details.appendSlice(self.allocator, "Could not access the package database because it has not been opened.\n"),
            .DbNotNull => try details.appendSlice(self.allocator, "Could not open the package database because it is already registered.\n"),
            .DbNotFound => try details.appendSlice(self.allocator, "Database not found.\n"),
            .DbInvalid => try details.appendSlice(self.allocator, "Database is invalid.\n"),
            .DbInvalidSig => try details.appendSlice(self.allocator, "Could not verify the repository database signature. Refresh the package signing keys and package lists. If verification still fails, contact the repository.\n"),
            .DbVersion => try details.appendSlice(self.allocator, "Database version is invalid.\n"),
            .DbWrite => try details.appendSlice(self.allocator, "Failed to write to the database.\n"),
            .DbRemove => try details.appendSlice(self.allocator, "Failed to remove the database.\n"),
            .ServerBadUrl => try details.appendSlice(self.allocator, "Server URL is invalid.\n"),
            .ServerNone => try details.appendSlice(self.allocator, "No server found.\n"),
            .TransNotNull => try details.appendSlice(self.allocator, "Could not start the package operation because another transaction is already active.\n"),
            .TransNull => try details.appendSlice(self.allocator, "Could not continue because there is no active package transaction.\n"),
            .TransDupTarget => try details.appendSlice(self.allocator, "Transaction target is duplicated.\n"),
            .TransDupFilename => try details.appendSlice(self.allocator, "Transaction filename is duplicated.\n"),
            .TransNotInitialized => try details.appendSlice(self.allocator, "Transaction is not initialized.\n"),
            .TransNotPrepared => try details.appendSlice(self.allocator, "Transaction is not prepared.\n"),
            .TransAbort => try details.appendSlice(self.allocator, "Transaction aborted.\n"),
            .TransType => try details.appendSlice(self.allocator, "Transaction type is invalid.\n"),
            .TransNotLocked => try details.appendSlice(self.allocator, "Transaction is not locked.\n"),
            .TransHookFailed => try details.appendSlice(self.allocator, "Transaction hook failed.\n"),
            .PkgNotFound => try details.appendSlice(self.allocator, "Could not find the requested package in the selected package sources. Check the package name or search for it in another source.\n"),
            .PkgIgnored => try details.appendSlice(self.allocator, "Package ignored.\n"),
            .PkgInvalid => try details.appendSlice(self.allocator, "Package is invalid.\n"),
            .PkgInvalidChecksum => try details.appendSlice(self.allocator, "Package checksum is invalid.\n"),
            .PkgInvalidSig => try details.appendSlice(self.allocator, "Could not verify the package signature. Refresh the package signing keys and download the package again. If verification still fails, contact the package source.\n"),
            .PkgMissingSig => try details.appendSlice(self.allocator, "Package signature is missing.\n"),
            .PkgOpen => try details.appendSlice(self.allocator, "Failed to open package.\n"),
            .PkgCantRemove => try details.appendSlice(self.allocator, "Failed to remove package.\n"),
            .PkgInvalidName => {
                var node = data_ptr;
                while (node != null) : (node = node.?.next) {
                    if (node.?.data) |d| {
                        const s = std.mem.span(@as([*c]const u8, @ptrCast(d)));
                        try details.appendSlice(self.allocator, s);
                        try details.appendSlice(self.allocator, "\n");
                    }
                }
            },
            .PkgInvalidArch => try details.appendSlice(self.allocator, "Package architecture is invalid.\n"),
            .SigMissing => try details.appendSlice(self.allocator, "Signature is missing.\n"),
            .SigInvalid => try details.appendSlice(self.allocator, "Could not verify the signature. Refresh the package signing keys and download the file again. If verification still fails, contact the package source.\n"),
            .UnsatisfiedDeps => {
                if (data_ptr == null) try details.appendSlice(self.allocator, "Could not continue because a required dependency is unavailable. Review the package dependencies and try again.\n");
                var node = data_ptr;
                while (node != null) : (node = node.?.next) {
                    const data = node.?.data orelse continue;
                    const miss: *rawLibalpm.alpm_depmissing_t = @ptrCast(@alignCast(data));
                    const target = spanC(miss.target) orelse "unknown";
                    const dep_str = rawLibalpm.alpm_dep_compute_string(miss.depend);
                    defer if (dep_str != null) std.c.free(dep_str);
                    const dependency = spanC(dep_str) orelse "an unknown dependency";
                    const removing = if (self.dispatcher.operation) |operation| operation.envelope.kind == .remove else false;
                    if (removing) {
                        try details.print(self.allocator, "Could not remove the selected packages because \"{s}\" still requires \"{s}\". Review the dependent packages before continuing.\n", .{ target, dependency });
                    } else if (spanC(miss.causingpkg)) |cause| {
                        try details.print(self.allocator, "Could not install \"{s}\" because it would remove a package that provides \"{s}\", which \"{s}\" requires. Review the affected packages before continuing.\n", .{ cause, dependency, target });
                    } else {
                        try details.print(self.allocator, "Could not install \"{s}\" because it requires \"{s}\", which is unavailable. Refresh the package lists and try again.\n", .{ target, dependency });
                    }
                }
            },
            .ConflictingDeps => {
                if (data_ptr == null) try details.appendSlice(self.allocator, "The selected packages cannot be installed together. Review which packages you want to keep before continuing.\n");
                var node = data_ptr;
                while (node != null) : (node = node.?.next) {
                    const data = node.?.data orelse continue;
                    const conflict = bindings.libalpm.PackageConflict.from(data) orelse continue;
                    const pkg1_name = conflict.packageOne().name() orelse "unknown";
                    const pkg2_name = conflict.packageTwo().name() orelse "unknown";
                    if (conflict.ptr.reason) |rp| {
                        const computed = rawLibalpm.alpm_dep_compute_string(rp);
                        defer if (computed != null) std.c.free(computed);
                        try details.print(self.allocator, "\"{s}\" cannot be installed alongside \"{s}\" (conflict: {s}). Review which package you want to keep before continuing.\n", .{ pkg1_name, pkg2_name, std.mem.span(computed) });
                    } else {
                        try details.print(self.allocator, "\"{s}\" cannot be installed alongside \"{s}\". Review which package you want to keep before continuing.\n", .{ pkg1_name, pkg2_name });
                    }
                }
            },
            .FileConflicts => {
                if (data_ptr == null) try details.appendSlice(self.allocator, "Could not install the selected packages because their files conflict. Review the conflicting files before replacing or removing them.\n");
                var node = data_ptr;
                while (node != null) : (node = node.?.next) {
                    const data = node.?.data orelse continue;
                    const fc: *rawLibalpm.alpm_fileconflict_t = @ptrCast(@alignCast(data));
                    const target = spanC(fc.target) orelse "unknown";
                    const file = spanC(fc.file) orelse "";
                    if (fc.type == rawLibalpm.ALPM_FILECONFLICT_TARGET) {
                        try details.print(self.allocator, "\"{s}\" and \"{s}\" both install \"{s}\". Review which package you want to keep before continuing.\n", .{ target, spanC(fc.ctarget) orelse "another package", file });
                    } else {
                        try details.print(self.allocator, "Could not install \"{s}\" because \"{s}\" already exists. Check which package owns this file before replacing or removing it.\n", .{ target, file });
                    }
                }
            },
            .DownloadFailed => try details.appendSlice(self.allocator, "Could not download the required files. Check your internet connection and try again. If the problem continues, the server may be unavailable.\n"),
            .Gpgme => try details.appendSlice(self.allocator, "Gpgme error.\n"),
            .ExternalDownload => try details.appendSlice(self.allocator, "External download failed.\n"),
            .SandboxFailed => try details.appendSlice(self.allocator, "Sandbox failed.\n"),
        }

        const full_error = try std.fmt.allocPrint(self.allocator, "{s}\nTechnical details: {s}", .{ details.items, error_msg });
        defer self.allocator.free(full_error);
        self.dispatcher.raiseError(.{ .message = full_error });
    }

    fn spanC(ptr: [*c]const u8) ?[]const u8 {
        if (ptr == null) return null;
        return std.mem.span(ptr);
    }
};

fn databaseServerCount(database: libalpm.Database) usize {
    var count: usize = 0;
    var servers = database.servers();
    while (servers.next() != null) count += 1;
    return count;
}

fn syncDatabaseDirectory(io: std.Io, path: []const u8) !void {
    // Zig uses O_PATH for non-iterable directory handles on Linux, and fsync
    // rejects those descriptors. Request a normal readable directory handle.
    var directory = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer directory.close(io);

    // File and directory handles share the same native representation. Borrow
    // the directory descriptor for one fsync without transferring ownership.
    const directory_file: std.Io.File = .{
        .handle = directory.handle,
        .flags = .{ .nonblocking = false },
    };
    try directory_file.sync(io);
}

fn stalePartSweepDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    cache_directory: []const u8,
    max_age: std.Io.Duration,
) void {
    var dir = std.Io.Dir.cwd().openDir(io, cache_directory, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var walker = dir.walk(allocator) catch return;
    defer walker.deinit();

    const now = std.Io.Timestamp.now(io, .real).nanoseconds;
    while (walker.next(io) catch return) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.indexOf(u8, entry.path, ".part.") == null) continue;

        const stat = dir.statFile(io, entry.path, .{}) catch continue;
        if (stat.mtime.nanoseconds > now) continue;
        const age_ns = now - stat.mtime.nanoseconds;
        if (age_ns < max_age.nanoseconds) continue;
        dir.deleteFile(io, entry.path) catch {};
    }
}

fn mirrorDownloadConfiguration(
    configured_server_count: usize,
    address_family_policy: downloader.AddressFamilyPolicy,
) downloader.DownloadConfiguration {
    return .{
        .user_agent = "Shelly-ALPM/3",
        .timeout_in_seconds = if (configured_server_count == 1)
            single_server_setup_timeout_seconds
        else
            multi_server_setup_timeout_seconds,
        .address_family_policy = address_family_policy,
        // A failed candidate should immediately advance to the next mirror.
        .max_retries = if (configured_server_count == 1)
            2
        else
            0,
        .retry_delay_secs = 1,
    };
}

fn databaseDownloadConfiguration(
    configured_server_count: usize,
    address_family_policy: downloader.AddressFamilyPolicy,
) downloader.DownloadConfiguration {
    var config = mirrorDownloadConfiguration(configured_server_count, address_family_policy);
    config.file_durability = .caller_managed;
    config.final_permissions = database_file_permissions;
    return config;
}

fn propagateSignatureCancellation(result: downloader.DownloadResult) downloader.DownloadError!void {
    switch (result) {
        .failure => |err| if (err == downloader.DownloadError.Cancelled) return err,
        else => {},
    }
}

test "single-server repositories receive a three second setup timeout" {
    const config = mirrorDownloadConfiguration(1, .prefer_ipv4);
    try std.testing.expectEqual(single_server_setup_timeout_seconds, config.timeout_in_seconds);
    try std.testing.expectEqual(@as(u32, 30), config.response_header_timeout_in_seconds);
    try std.testing.expectEqual(@as(u8, 2), config.max_retries);
    try std.testing.expectEqual(@as(u32, 1), config.retry_delay_secs);
    try std.testing.expectEqual(downloader.AddressFamilyPolicy.prefer_ipv4, config.address_family_policy);
    try std.testing.expectEqual(downloader.FileDurability.sync_before_rename, config.file_durability);
}

test "multi-mirror repositories receive a one second setup timeout" {
    for ([_]usize{ 0, 2, 8 }) |server_count| {
        const config = mirrorDownloadConfiguration(server_count, .ipv4_only);
        try std.testing.expectEqual(multi_server_setup_timeout_seconds, config.timeout_in_seconds);
        try std.testing.expectEqual(@as(u32, 30), config.response_header_timeout_in_seconds);
        try std.testing.expectEqual(@as(u8, 0), config.max_retries);
        try std.testing.expectEqual(@as(u32, 1), config.retry_delay_secs);
        try std.testing.expectEqual(downloader.AddressFamilyPolicy.ipv4_only, config.address_family_policy);
        try std.testing.expectEqual(downloader.FileDurability.sync_before_rename, config.file_durability);
    }
}

test "database downloads defer file durability to the batch barrier" {
    const config = databaseDownloadConfiguration(4, .prefer_ipv4);
    try std.testing.expectEqual(downloader.FileDurability.caller_managed, config.file_durability);
    try std.testing.expectEqual(@as(u32, 0o644), config.final_permissions.?.toMode() & 0o7777);
}

test "database batch barrier synchronizes its directory" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try temporary.dir.realPath(io, &path_buffer);
    try syncDatabaseDirectory(io, path_buffer[0..path_length]);
}

test "stale part sweep removes only expired partial downloads" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "nested");

    const old_part = "nested/package.pkg.tar.zst.part.old";
    const fresh_part = "package.pkg.tar.zst.part.fresh";
    const old_complete = "package.pkg.tar.zst";
    for ([_][]const u8{ old_part, fresh_part, old_complete }) |path| {
        var file = try temporary.dir.createFile(io, path, .{});
        file.close(io);
    }

    const now = std.Io.Timestamp.now(io, .real);
    const old_timestamp = now.subDuration(std.Io.Duration.fromSeconds(600));
    try temporary.dir.setTimestamps(io, old_part, .{ .modify_timestamp = .{ .new = old_timestamp } });
    try temporary.dir.setTimestamps(io, old_complete, .{ .modify_timestamp = .{ .new = old_timestamp } });

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try temporary.dir.realPath(io, &path_buffer);
    stalePartSweepDirectory(
        std.testing.allocator,
        io,
        path_buffer[0..path_length],
        std.Io.Duration.fromSeconds(500),
    );

    try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(io, old_part, .{}));
    _ = try temporary.dir.statFile(io, fresh_part, .{});
    _ = try temporary.dir.statFile(io, old_complete, .{});
}

test "process-wide address-family default is configurable" {
    const previous = Manager.defaultDownloadAddressFamilyPolicy();
    defer Manager.setDefaultDownloadAddressFamilyPolicy(previous);

    Manager.setDefaultDownloadAddressFamilyPolicy(.ipv6_only);
    try std.testing.expectEqual(
        downloader.AddressFamilyPolicy.ipv6_only,
        Manager.defaultDownloadAddressFamilyPolicy(),
    );
}

/// Tracks one logical package or database download across all mirror attempts.
/// Individual attempts remain quiet, while callers still receive a correlated
/// download lifecycle and can cancel before any network work begins.
const MirrorDownloadScope = struct {
    operation: ?operation_api.Operation = null,
    successful: bool = false,

    fn init(manager: *Manager, subject: []const u8) MirrorDownloadScope {
        if (manager.dispatcher.operation) |parent| {
            return .{ .operation = parent.child(.{
                .backend = .download,
                .kind = .download,
                .subject = subject,
            }) };
        }
        if (manager.operation_context) |context| {
            return .{ .operation = context.begin(.{
                .backend = .download,
                .kind = .download,
                .subject = subject,
            }) };
        }
        return .{};
    }

    fn attach(self: *MirrorDownloadScope, downloader_instance: *downloader.CoreDownloader) void {
        if (self.operation) |*operation| downloader_instance.setParentOperation(operation);
    }

    fn succeed(self: *MirrorDownloadScope) void {
        self.successful = true;
    }

    fn finish(self: *MirrorDownloadScope) void {
        if (self.operation) |*operation| {
            const status: operation_api.CompletionStatus = if (operation.isCancelled())
                .cancelled
            else if (self.successful)
                .success
            else
                .failed;
            operation.finish(status);
        }
    }
};

const OperationScope = struct {
    manager: *Manager,
    operation: ?operation_api.Operation = null,
    previous: ?*operation_api.Operation = null,
    cancellation_subscription: ?operation_api.SubscriptionId = null,
    attached: bool = false,
    initial_error_generation: usize,

    fn init(manager: *Manager, kind: operation_api.OperationKind, subject: ?[]const u8) OperationScope {
        var scope: OperationScope = .{
            .manager = manager,
            .previous = manager.dispatcher.operation,
            .initial_error_generation = manager.dispatcher.errorGeneration(),
        };
        if (scope.previous) |parent| {
            scope.operation = parent.child(.{ .backend = .alpm, .kind = kind, .subject = subject });
        } else if (manager.operation_context) |context| {
            scope.operation = context.begin(.{ .backend = .alpm, .kind = kind, .subject = subject });
        }
        return scope;
    }

    fn attach(self: *OperationScope) void {
        if (self.operation) |*operation| {
            self.manager.dispatcher.setOperation(operation);
            self.cancellation_subscription = operation.context.subscribeCancellation(.{
                .function = interruptTransaction,
                .data = self.manager,
            }) catch null;
        }
        self.attached = true;
    }

    fn fail(self: *OperationScope) void {
        if (self.operation) |*operation| {
            if (!operation.isCancelled() and
                self.manager.dispatcher.errorGeneration() == self.initial_error_generation)
            {
                self.manager.dispatcher.raiseError(.{ .message = "ALPM operation failed" });
            }
        }
        const status: operation_api.CompletionStatus = if (self.operation) |*operation|
            if (operation.isCancelled()) .cancelled else .failed
        else
            .failed;
        self.finish(status);
    }

    fn finish(self: *OperationScope, status: operation_api.CompletionStatus) void {
        if (self.operation) |*operation| {
            if (self.cancellation_subscription) |subscription| {
                _ = operation.context.unsubscribeCancellation(subscription);
                self.cancellation_subscription = null;
            }
            operation.finish(status);
        }
        if (self.attached) {
            self.manager.dispatcher.setOperation(self.previous);
            self.attached = false;
        }
    }

    fn interruptTransaction(data: ?*anyopaque) void {
        const manager: *Manager = @ptrCast(@alignCast(data orelse return));
        if (manager.handle) |handle| _ = rawLibalpm.alpm_trans_interrupt(handle);
    }
};

test "OperationScope does not duplicate a detailed ALPM error" {
    const Capture = struct {
        failures: usize = 0,
        last_message: []const u8 = "",

        fn event(data: ?*anyopaque, value: operation_api.Event) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            switch (value) {
                .failure => |failure| {
                    self.failures += 1;
                    self.last_message = failure.message;
                },
                else => {},
            }
        }
    };

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var context = operation_api.OperationContext.init(testing.allocator, threaded.io());
    defer context.deinit();
    var capture: Capture = .{};
    const subscription = try context.subscribe(.{ .function = Capture.event, .data = &capture });
    defer _ = context.unsubscribe(subscription);

    var manager: Manager = undefined;
    manager.handle = null;
    manager.dispatcher = events.Dispatcher.init(testing.allocator);
    defer manager.dispatcher.deinit();
    manager.operation_context = &context;

    var scope = OperationScope.init(&manager, .install, "example");
    scope.attach();
    manager.dispatcher.raiseError(.{ .message = "detailed ALPM failure" });
    scope.fail();

    try testing.expectEqual(@as(usize, 1), capture.failures);
    try testing.expectEqualStrings("detailed ALPM failure", capture.last_message);
}

test "OperationScope emits one generic ALPM error when no detail was reported" {
    const Capture = struct {
        failures: usize = 0,
        last_message: []const u8 = "",

        fn event(data: ?*anyopaque, value: operation_api.Event) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            switch (value) {
                .failure => |failure| {
                    self.failures += 1;
                    self.last_message = failure.message;
                },
                else => {},
            }
        }
    };

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var context = operation_api.OperationContext.init(testing.allocator, threaded.io());
    defer context.deinit();
    var capture: Capture = .{};
    const subscription = try context.subscribe(.{ .function = Capture.event, .data = &capture });
    defer _ = context.unsubscribe(subscription);

    var manager: Manager = undefined;
    manager.handle = null;
    manager.dispatcher = events.Dispatcher.init(testing.allocator);
    defer manager.dispatcher.deinit();
    manager.operation_context = &context;

    var scope = OperationScope.init(&manager, .install, "example");
    scope.attach();
    scope.fail();

    try testing.expectEqual(@as(usize, 1), capture.failures);
    try testing.expectEqualStrings("ALPM operation failed", capture.last_message);
}

test "OperationScope turns best-effort ALPM failures into contextual recoverable errors" {
    const Capture = struct {
        failures: usize = 0,
        contextual: bool = false,
        recoverable: bool = false,

        fn event(data: ?*anyopaque, value: operation_api.Event) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            switch (value) {
                .failure => |failure| {
                    self.failures += 1;
                    self.contextual = std.mem.eql(
                        u8,
                        failure.message,
                        "Failed to remove build-only dependencies: ALPM operation failed",
                    );
                    self.recoverable = failure.recoverable;
                },
                else => {},
            }
        }
    };

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var context = operation_api.OperationContext.init(testing.allocator, threaded.io());
    defer context.deinit();
    var capture: Capture = .{};
    const subscription = try context.subscribe(.{ .function = Capture.event, .data = &capture });
    defer _ = context.unsubscribe(subscription);

    var manager: Manager = undefined;
    manager.handle = null;
    manager.dispatcher = events.Dispatcher.init(testing.allocator);
    defer manager.dispatcher.deinit();
    manager.operation_context = &context;

    var recoverable_errors = manager.dispatcher.beginRecoverableErrors("Failed to remove build-only dependencies");
    defer recoverable_errors.deinit();
    var scope = OperationScope.init(&manager, .remove, "build-tool");
    scope.attach();
    scope.fail();

    try testing.expectEqual(@as(usize, 1), capture.failures);
    try testing.expect(capture.contextual);
    try testing.expect(capture.recoverable);
}

test "nested OperationScopes do not duplicate a detailed ALPM error" {
    const Capture = struct {
        failures: usize = 0,
        last_message: []const u8 = "",

        fn event(data: ?*anyopaque, value: operation_api.Event) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            switch (value) {
                .failure => |failure| {
                    self.failures += 1;
                    self.last_message = failure.message;
                },
                else => {},
            }
        }
    };

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var context = operation_api.OperationContext.init(testing.allocator, threaded.io());
    defer context.deinit();
    var capture: Capture = .{};
    const subscription = try context.subscribe(.{ .function = Capture.event, .data = &capture });
    defer _ = context.unsubscribe(subscription);

    var manager: Manager = undefined;
    manager.handle = null;
    manager.dispatcher = events.Dispatcher.init(testing.allocator);
    defer manager.dispatcher.deinit();
    manager.operation_context = &context;

    var parent = OperationScope.init(&manager, .update, null);
    parent.attach();
    var child = OperationScope.init(&manager, .sync, null);
    child.attach();
    manager.dispatcher.raiseError(.{ .message = "nested detailed ALPM failure" });
    child.fail();
    parent.fail();

    try testing.expectEqual(@as(usize, 1), capture.failures);
    try testing.expectEqualStrings("nested detailed ALPM failure", capture.last_message);
}

fn hasDeletedSharedLibrary(maps: []const u8) bool {
    var lines = std.mem.splitScalar(u8, maps, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "(deleted)") != null and
            std.mem.indexOf(u8, line, ".so") != null)
        {
            return true;
        }
    }
    return false;
}

fn serviceFromCgroup(cgroup: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, cgroup, '\n');
    while (lines.next()) |line| {
        const marker = "/system.slice/";
        const marker_index = std.mem.indexOf(u8, line, marker) orelse continue;
        var components = std.mem.splitScalar(u8, line[marker_index + marker.len ..], '/');
        while (components.next()) |component| {
            const trimmed = std.mem.trim(u8, component, " \t\r");
            if (trimmed.len > ".service".len and std.mem.endsWith(u8, trimmed, ".service")) {
                return trimmed;
            }
        }
    }
    return null;
}

fn isCriticalRestartProcess(command: []const u8) bool {
    return std.mem.eql(u8, command, "systemd") or
        std.mem.eql(u8, command, "dbus-daemon") or
        std.mem.eql(u8, command, "dbus-broker");
}

fn stringBefore(_: void, lhs: []u8, rhs: []u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn dependencyName(dependency: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, dependency, "<>=") orelse dependency.len;
    return std.mem.trim(u8, dependency[0..end], " \t\r\n");
}

fn literalPackageSatisfiesDependency(
    package: *rawLibalpm.alpm_pkg_t,
    dependency: *rawLibalpm.alpm_depend_t,
) bool {
    if (dependency.mod == rawLibalpm.ALPM_DEP_MOD_ANY) return true;
    const package_version = rawLibalpm.alpm_pkg_get_version(package) orelse return false;
    const dependency_version = dependency.version orelse return false;
    const comparison = rawLibalpm.alpm_pkg_vercmp(package_version, dependency_version);
    return switch (dependency.mod) {
        rawLibalpm.ALPM_DEP_MOD_EQ => comparison == 0,
        rawLibalpm.ALPM_DEP_MOD_GE => comparison >= 0,
        rawLibalpm.ALPM_DEP_MOD_LE => comparison <= 0,
        rawLibalpm.ALPM_DEP_MOD_GT => comparison > 0,
        rawLibalpm.ALPM_DEP_MOD_LT => comparison < 0,
        else => false,
    };
}

fn nonNegativeSize(value: i64) ?u64 {
    if (value < 0) return null;
    return @intCast(value);
}

fn addOptionalSize(total: ?u64, value: ?u64) ?u64 {
    return std.math.add(u64, total orelse return null, value orelse return null) catch null;
}

fn addOptionalDelta(total: ?i64, value: ?i64) ?i64 {
    return std.math.add(i64, total orelse return null, value orelse return null) catch null;
}

fn preparedPackageRole(
    name: []const u8,
    requested_packages: []const *rawLibalpm.alpm_pkg_t,
    optional_names: []const [:0]const u8,
    all_dependencies: bool,
) operation_api.TransactionPackageRole {
    for (optional_names) |optional_name|
        if (std.mem.eql(u8, name, optional_name)) return .optional_dependency;
    if (all_dependencies) return .dependency;
    for (requested_packages) |requested| {
        const requested_name = libalpm.str(rawLibalpm.alpm_pkg_get_name(requested)) orelse continue;
        if (std.mem.eql(u8, name, requested_name)) return .requested;
    }
    return .dependency;
}

const testing = std.testing;

test "public ALPM query helpers expose typed results" {
    _ = Manager.get_repository_names;
    _ = Manager.find_configured_repository;
    _ = Manager.get_configured_cache_directories;
    _ = Manager.get_cache_directories;
    _ = Manager.find_remote_satisfier_for_dependency_details;
    _ = DependencySatisfier;
}

test "compare_package_versions uses libalpm ordering" {
    try testing.expect(Manager.compare_package_versions("1.0-1", "2.0-1") < 0);
    try testing.expectEqual(@as(c_int, 0), Manager.compare_package_versions("2.0-1", "2.0-1"));
    try testing.expect(Manager.compare_package_versions("2.0-2", "2.0-1") > 0);
    try testing.expect(Manager.compare_package_versions("10.0-1", "2.0-1") > 0);
}

test "dependencyName strips constraints used to detect provides matches" {
    try testing.expectEqualStrings("python", dependencyName("python>=3.10"));
    try testing.expectEqualStrings("libgl", dependencyName("libgl"));
    try testing.expectEqualStrings("virtual-feature", dependencyName("  virtual-feature = 2  "));
}

test "is_cachyos exposes the detected manager state" {
    var manager: Manager = undefined;
    manager.detected_cachyos = false;
    try testing.expect(!manager.is_cachyos());
    manager.detected_cachyos = true;
    try testing.expect(manager.is_cachyos());
}

test "restart parsing identifies deleted shared libraries and system services" {
    try testing.expect(hasDeletedSharedLibrary(
        "7f00-7f01 r-xp /usr/lib/libdemo.so.1 (deleted)\n",
    ));
    try testing.expect(!hasDeletedSharedLibrary(
        "7f00-7f01 r-xp /usr/lib/libdemo.so.1\n" ++
            "7f02-7f03 r-xp /usr/bin/demo (deleted)\n",
    ));
    try testing.expectEqualStrings(
        "demo.service",
        serviceFromCgroup("0::/system.slice/system-demo.slice/demo.service/tasks\n").?,
    );
    try testing.expect(serviceFromCgroup("0::/user.slice/session-1.scope\n") == null);
    try testing.expect(isCriticalRestartProcess("systemd"));
    try testing.expect(isCriticalRestartProcess("dbus-broker"));
    try testing.expect(!isCriticalRestartProcess("demo"));
}

test "restart report detects kernels and records structured service results" {
    const anchor: u8 = 0;
    const root = try std.fmt.allocPrint(testing.allocator, "/tmp/shelly-restart-test-{x}", .{@intFromPtr(&anchor)});
    defer testing.allocator.free(root);
    std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};

    const proc_root = try std.fs.path.join(testing.allocator, &.{ root, "proc" });
    defer testing.allocator.free(proc_root);
    const modules_root = try std.fs.path.join(testing.allocator, &.{ root, "modules" });
    defer testing.allocator.free(modules_root);
    const kernel_dir = try std.fs.path.join(testing.allocator, &.{ modules_root, "6.12.1-test" });
    defer testing.allocator.free(kernel_dir);
    const kernel_parent = try std.fs.path.join(testing.allocator, &.{ proc_root, "sys", "kernel" });
    defer testing.allocator.free(kernel_parent);
    const process_dir = try std.fs.path.join(testing.allocator, &.{ proc_root, "123" });
    defer testing.allocator.free(process_dir);
    const kernel_file = try std.fs.path.join(testing.allocator, &.{ kernel_parent, "osrelease" });
    defer testing.allocator.free(kernel_file);
    const maps_file = try std.fs.path.join(testing.allocator, &.{ process_dir, "maps" });
    defer testing.allocator.free(maps_file);
    const comm_file = try std.fs.path.join(testing.allocator, &.{ process_dir, "comm" });
    defer testing.allocator.free(comm_file);
    const cgroup_file = try std.fs.path.join(testing.allocator, &.{ process_dir, "cgroup" });
    defer testing.allocator.free(cgroup_file);

    try std.Io.Dir.cwd().createDirPath(testing.io, kernel_parent);
    try std.Io.Dir.cwd().createDirPath(testing.io, process_dir);
    try std.Io.Dir.cwd().createDirPath(testing.io, modules_root);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = kernel_file, .data = "6.12.1-test\n" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = maps_file,
        .data = "7f00-7f01 r-xp 00000000 00:00 0 /usr/lib/libdemo.so.1 (deleted)\n",
    });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = comm_file, .data = "demo\n" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = cgroup_file,
        .data = "0::/system.slice/system-demo.slice/demo.service\n",
    });

    var manager: Manager = undefined;
    manager.allocator = testing.allocator;
    manager.threaded = .init(testing.allocator, .{});
    defer manager.threaded.deinit();

    var reboot_report = try manager.checkForRequiredRestarts(.{
        .proc_root = proc_root,
        .modules_root = modules_root,
        .systemctl_path = "/bin/false",
    });
    defer reboot_report.deinit();
    try testing.expectEqualStrings("6.12.1-test", reboot_report.running_kernel.?);
    try testing.expectEqual(false, reboot_report.running_kernel_modules_present.?);
    try testing.expect(reboot_report.needs_reboot);
    try testing.expect(reboot_report.process_scan_complete);
    try testing.expectEqual(@as(usize, 1), reboot_report.affected_processes.len);
    try testing.expectEqual(@as(u32, 123), reboot_report.affected_processes[0].pid);
    try testing.expectEqualStrings("demo", reboot_report.affected_processes[0].command.?);
    try testing.expectEqualStrings("demo.service", reboot_report.affected_processes[0].service.?);
    try testing.expectEqual(@as(usize, 1), reboot_report.affected_services.len);
    try testing.expectEqualStrings("demo.service", reboot_report.affected_services[0]);
    try testing.expectEqual(@as(usize, 0), reboot_report.failures.len);

    try std.Io.Dir.cwd().createDirPath(testing.io, kernel_dir);
    var failure_report = try manager.checkForRequiredRestarts(.{
        .proc_root = proc_root,
        .modules_root = modules_root,
        .systemctl_path = "/bin/false",
    });
    defer failure_report.deinit();
    try testing.expect(!failure_report.needs_reboot);
    try testing.expectEqual(true, failure_report.running_kernel_modules_present.?);
    try testing.expectEqual(@as(usize, 0), failure_report.restarted_services.len);
    try testing.expectEqual(@as(usize, 1), failure_report.failures.len);
    try testing.expectEqualStrings("demo.service", failure_report.failures[0].service);
    try testing.expectEqual(ServiceRestartFailureKind.exit_status, failure_report.failures[0].kind);
    try testing.expectEqual(@as(?u8, 1), failure_report.failures[0].exit_code);

    var spawn_failure_report = try manager.checkForRequiredRestarts(.{
        .proc_root = proc_root,
        .modules_root = modules_root,
        .systemctl_path = "/definitely/missing/systemctl",
    });
    defer spawn_failure_report.deinit();
    try testing.expectEqual(@as(usize, 1), spawn_failure_report.failures.len);
    try testing.expectEqual(ServiceRestartFailureKind.spawn, spawn_failure_report.failures[0].kind);
    try testing.expect(spawn_failure_report.failures[0].exit_code == null);

    var success_report = try manager.checkForRequiredRestarts(.{
        .proc_root = proc_root,
        .modules_root = modules_root,
        .systemctl_path = "/bin/true",
    });
    defer success_report.deinit();
    try testing.expect(!success_report.needs_reboot);
    try testing.expectEqual(@as(usize, 1), success_report.restarted_services.len);
    try testing.expectEqualStrings("demo.service", success_report.restarted_services[0]);
    try testing.expectEqual(@as(usize, 0), success_report.failures.len);
}

// ---------------------------------------------------------------------------
// spanC
// ---------------------------------------------------------------------------

test "spanC returns null for a null pointer" {
    try testing.expect(Manager.spanC(null) == null);
}

test "spanC spans a null-terminated C string" {
    const c: [*c]const u8 = "package";
    const span = Manager.spanC(c) orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("package", span);
    try testing.expectEqual(@as(usize, 7), span.len);
}

test "spanC spans an empty C string" {
    const c: [*c]const u8 = "";
    const span = Manager.spanC(c) orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("", span);
    try testing.expectEqual(@as(usize, 0), span.len);
}

// ---------------------------------------------------------------------------
// resolveArchitecture
// ---------------------------------------------------------------------------

fn expectedAutoArch() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => "x86_64",
    };
}

test "resolveArchitecture returns an explicit architecture verbatim" {
    try testing.expectEqualStrings("x86_64", Manager.resolveArchitecture("x86_64"));
    try testing.expectEqualStrings("aarch64", Manager.resolveArchitecture("aarch64"));
}

test "resolveArchitecture resolves 'auto' to the host architecture" {
    try testing.expectEqualStrings(expectedAutoArch(), Manager.resolveArchitecture("auto"));
}

test "resolveArchitecture treats 'auto' case-insensitively" {
    try testing.expectEqualStrings(expectedAutoArch(), Manager.resolveArchitecture("AUTO"));
    try testing.expectEqualStrings(expectedAutoArch(), Manager.resolveArchitecture("Auto"));
}

test "resolveArchitecture falls back to 'auto' for empty input" {
    try testing.expectEqualStrings(expectedAutoArch(), Manager.resolveArchitecture(""));
    // Whitespace-only input tokenizes to nothing and also falls back.
    try testing.expectEqualStrings(expectedAutoArch(), Manager.resolveArchitecture("   "));
}

test "resolveArchitecture uses only the first token" {
    try testing.expectEqualStrings("x86_64", Manager.resolveArchitecture("x86_64 aarch64"));
    // A leading space is skipped by the tokenizer.
    try testing.expectEqualStrings("i686", Manager.resolveArchitecture(" i686 x86_64"));
}

test "resolveArchitecture passes unknown architectures through" {
    try testing.expectEqualStrings("riscv64", Manager.resolveArchitecture("riscv64"));
}

// ---------------------------------------------------------------------------
// resolveServer
// ---------------------------------------------------------------------------

test "resolveServer substitutes $repo and $arch" {
    var mgr: Manager = undefined;
    mgr.allocator = testing.allocator;

    const resolved = mgr.resolveServer("https://mirror/$repo/os/$arch", "core", "x86_64") orelse
        return error.TestUnexpectedNull;
    defer mgr.allocator.free(resolved);

    try testing.expectEqualStrings("https://mirror/core/os/x86_64", resolved);
    // The result must be null-terminated for the C API.
    try testing.expectEqual(@as(u8, 0), resolved[resolved.len]);
}

test "resolveServer substitutes only $repo when $arch is absent" {
    var mgr: Manager = undefined;
    mgr.allocator = testing.allocator;

    const resolved = mgr.resolveServer("https://mirror/$repo/os", "extra", "x86_64") orelse
        return error.TestUnexpectedNull;
    defer mgr.allocator.free(resolved);

    try testing.expectEqualStrings("https://mirror/extra/os", resolved);
}

test "resolveServer substitutes only $arch when $repo is absent" {
    var mgr: Manager = undefined;
    mgr.allocator = testing.allocator;

    const resolved = mgr.resolveServer("https://mirror/os/$arch", "core", "aarch64") orelse
        return error.TestUnexpectedNull;
    defer mgr.allocator.free(resolved);

    try testing.expectEqualStrings("https://mirror/os/aarch64", resolved);
}

test "resolveServer leaves a template without markers unchanged" {
    var mgr: Manager = undefined;
    mgr.allocator = testing.allocator;

    const resolved = mgr.resolveServer("https://mirror/static/os", "core", "x86_64") orelse
        return error.TestUnexpectedNull;
    defer mgr.allocator.free(resolved);

    try testing.expectEqualStrings("https://mirror/static/os", resolved);
}

test "resolveServer replaces every occurrence of each marker" {
    var mgr: Manager = undefined;
    mgr.allocator = testing.allocator;

    const resolved = mgr.resolveServer("$repo/$arch/$repo/$arch", "core", "x86_64") orelse
        return error.TestUnexpectedNull;
    defer mgr.allocator.free(resolved);

    try testing.expectEqualStrings("core/x86_64/core/x86_64", resolved);
}

test "resolveServer returns null and releases intermediates on allocation failure" {
    for (0..3) |fail_index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        var mgr: Manager = undefined;
        mgr.allocator = failing.allocator();

        try testing.expect(mgr.resolveServer(
            "https://mirror/$repo/os/$arch",
            "core",
            "x86_64",
        ) == null);
        try testing.expect(failing.has_induced_failure);
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "fetchCallback accepts prepared cache entries and rejects missing artifacts" {
    var mgr: Manager = undefined;
    mgr.allocator = testing.allocator;
    mgr.dispatcher = events.Dispatcher.init(testing.allocator);
    defer mgr.dispatcher.deinit();
    mgr.threaded = .init(testing.allocator, .{});
    defer mgr.threaded.deinit();
    mgr.unexpected_fetch_reported = .init(false);

    var capture = ErrorCapture{};
    _ = try mgr.dispatcher.addErrorHandler(.{
        .function = captureError,
        .data = @ptrCast(&capture),
    });

    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_length = try temporary.dir.realPath(testing.io, &absolute_buffer);
    const cache_path = try testing.allocator.dupeZ(u8, absolute_buffer[0..absolute_length]);
    defer testing.allocator.free(cache_path);
    var cached_file = try temporary.dir.createFile(testing.io, "prepared.pkg.tar.zst", .{});
    cached_file.close(testing.io);

    try testing.expectEqual(@as(c_int, 1), Manager.fetchCallback(
        @ptrCast(&mgr),
        "https://example.invalid/prepared.pkg.tar.zst?mirror=primary",
        cache_path.ptr,
        0,
    ));
    try testing.expectEqual(@as(usize, 0), capture.len);

    try testing.expectEqual(@as(c_int, -1), Manager.fetchCallback(
        @ptrCast(&mgr),
        null,
        "/tmp",
        0,
    ));
    try testing.expectEqual(@as(c_int, -1), Manager.fetchCallback(
        @ptrCast(&mgr),
        "https://example.invalid/package",
        null,
        0,
    ));
    try testing.expectEqual(@as(c_int, -1), Manager.fetchCallback(
        null,
        "https://example.invalid/package",
        "/tmp",
        0,
    ));
    try testing.expectEqual(@as(c_int, -1), Manager.fetchCallback(
        @ptrCast(&mgr),
        "https://example.invalid/missing.pkg.tar.zst",
        cache_path.ptr,
        0,
    ));
    try testing.expectEqual(@as(c_int, -1), Manager.fetchCallback(
        @ptrCast(&mgr),
        "https://backup.example.invalid/still-missing.pkg.tar.zst",
        cache_path.ptr,
        0,
    ));
    try testing.expectEqualStrings(
        "Unexpected libalpm fetch request: prepared package is missing from the cache.",
        capture.text(),
    );
    try testing.expectEqual(@as(usize, 1), capture.count);
}

// ---------------------------------------------------------------------------
// check
// ---------------------------------------------------------------------------

test "check is a no-op for a success return code" {
    var mgr: Manager = undefined;
    mgr.handle = null;
    // ret == 0 means success: check must return without touching the handle.
    mgr.check("noop", 0);
}

// ---------------------------------------------------------------------------
// progressCallback
// ---------------------------------------------------------------------------

test "progressCallback dispatches a progress event with the forwarded args" {
    var mgr: Manager = undefined;
    mgr.dispatcher = events.Dispatcher.init(testing.allocator);
    defer mgr.dispatcher.deinit();

    var cap = ProgressCapture{};
    _ = mgr.dispatcher.addProgressHandler(.{
        .function = captureProgress,
        .data = @ptrCast(&cap),
    }) catch unreachable;

    Manager.progressCallback(@ptrCast(&mgr), 2, "pkg", 42, 7, 3);

    const args = cap.args orelse return error.TestFailed;
    try testing.expectEqual(@as(c_int, 2), args.progress_type);
    try testing.expectEqual(@as(c_int, 42), args.percent);
    try testing.expectEqual(@as(c_ulong, 7), args.howmany);
    try testing.expectEqual(@as(c_ulong, 3), args.current);
    try testing.expectEqualStrings("pkg", args.pkg_name orelse return error.TestFailed);
}

test "progressCallback forwards a null package name as null" {
    var mgr: Manager = undefined;
    mgr.dispatcher = events.Dispatcher.init(testing.allocator);
    defer mgr.dispatcher.deinit();

    var cap = ProgressCapture{};
    _ = mgr.dispatcher.addProgressHandler(.{
        .function = captureProgress,
        .data = @ptrCast(&cap),
    }) catch unreachable;

    Manager.progressCallback(@ptrCast(&mgr), 0, null, 0, 0, 0);

    const args = cap.args orelse return error.TestFailed;
    try testing.expect(args.pkg_name == null);
}

// ---------------------------------------------------------------------------
// handleInformationMessage + eventCallback
// ---------------------------------------------------------------------------

test "handleInformationMessage emits a known informational description" {
    var mgr: Manager = undefined;
    mgr.dispatcher = events.Dispatcher.init(testing.allocator);
    defer mgr.dispatcher.deinit();

    var cap = InfoCapture{};
    _ = mgr.dispatcher.addInformationalHandler(.{
        .function = captureInfo,
        .data = @ptrCast(&cap),
    }) catch unreachable;
    defer cap.deinit(testing.allocator);

    mgr.handleInformationMessage(.transaction_start);

    const args = cap.args orelse return error.TestFailed;
    try testing.expectEqual(libalpm.EventType.transaction_start, args.event_type);
    try testing.expectEqualStrings("Starting transaction...", args.message);
}

test "handleInformationMessage ignores specialized event types" {
    var mgr: Manager = undefined;
    mgr.dispatcher = events.Dispatcher.init(testing.allocator);
    defer mgr.dispatcher.deinit();

    var cap = InfoCapture{};
    _ = mgr.dispatcher.addInformationalHandler(.{
        .function = captureInfo,
        .data = @ptrCast(&cap),
    }) catch unreachable;
    defer cap.deinit(testing.allocator);

    mgr.handleInformationMessage(.scriptlet_info);

    try testing.expect(cap.args == null);
}

test "handleInformationMessage ignores application-only event types" {
    var mgr: Manager = undefined;
    mgr.dispatcher = events.Dispatcher.init(testing.allocator);
    defer mgr.dispatcher.deinit();

    var cap = InfoCapture{};
    _ = try mgr.dispatcher.addInformationalHandler(.{
        .function = captureInfo,
        .data = @ptrCast(&cap),
    });
    defer cap.deinit(testing.allocator);
    mgr.handleInformationMessage(.download_start);
    mgr.handleInformationMessage(.validation_failed);
    mgr.handleInformationMessage(.rollback_complete);

    try testing.expect(cap.args == null);
}

test "handleInformationMessage emits every generic informational description" {
    const Case = struct {
        event_type: libalpm.EventType,
        message: []const u8,
    };
    const cases = [_]Case{
        .{ .event_type = .checkdeps_start, .message = "Checking dependencies..." },
        .{ .event_type = .checkdeps_done, .message = "Dependency check finished." },
        .{ .event_type = .fileconflicts_start, .message = "Checking for file conflicts..." },
        .{ .event_type = .fileconflicts_done, .message = "File conflict check finished." },
        .{ .event_type = .resolvedeps_start, .message = "Resolving dependencies..." },
        .{ .event_type = .resolvedeps_done, .message = "Dependency resolution finished." },
        .{ .event_type = .interconflicts_start, .message = "Checking for package conflicts..." },
        .{ .event_type = .interconflicts_done, .message = "Package conflict check finished." },
        .{ .event_type = .transaction_start, .message = "Starting transaction..." },
        .{ .event_type = .transaction_done, .message = "Transaction completed." },
        .{ .event_type = .integrity_start, .message = "Checking package integrity..." },
        .{ .event_type = .integrity_done, .message = "Package integrity check finished." },
        .{ .event_type = .load_start, .message = "Loading packages..." },
        .{ .event_type = .load_done, .message = "Packages loaded." },
        .{ .event_type = .db_retrieve_start, .message = "Retrieving database..." },
        .{ .event_type = .db_retrieve_done, .message = "Database retrieved." },
        .{ .event_type = .db_retrieve_failed, .message = "Failed to retrieve database." },
        .{ .event_type = .pkg_retrieve_start, .message = "Retrieving package..." },
        .{ .event_type = .pkg_retrieve_done, .message = "Package retrieved." },
        .{ .event_type = .pkg_retrieve_failed, .message = "Package retrieval failed." },
        .{ .event_type = .diskspace_start, .message = "Checking disk space..." },
        .{ .event_type = .diskspace_done, .message = "Disk space check finished." },
        .{ .event_type = .optdep_removal, .message = "Removing optional dependencies..." },
        .{ .event_type = .database_missing, .message = "Database missing. Please run `shelly keyring init` to initialize the keyring." },
        .{ .event_type = .keyring_start, .message = "Checking keyring..." },
        .{ .event_type = .keyring_done, .message = "Keyring check finished." },
        .{ .event_type = .key_download_start, .message = "Downloading key..." },
        .{ .event_type = .key_download_done, .message = "Key download finished." },
        .{ .event_type = .hook_start, .message = "Running hooks..." },
        .{ .event_type = .hook_done, .message = "Finished running hooks." },
        .{ .event_type = .hook_run_done, .message = "Finished running hook." },
        .{ .event_type = .failed_optional_dependency_operation, .message = "Failed to remove optional dependency." },
        .{ .event_type = .package_explicit, .message = "Package marked as explicitly installed." },
        .{ .event_type = .failed_add_local_package, .message = "Failed to add local package." },
    };

    var mgr: Manager = undefined;
    mgr.dispatcher = events.Dispatcher.init(testing.allocator);
    defer mgr.dispatcher.deinit();

    var cap = InfoCapture{};
    defer cap.deinit(testing.allocator);
    _ = try mgr.dispatcher.addInformationalHandler(.{
        .function = captureInfo,
        .data = @ptrCast(&cap),
    });

    for (cases) |case| {
        cap.args = null;
        mgr.handleInformationMessage(case.event_type);
        const args = cap.args orelse return error.TestExpectedEqual;
        try testing.expectEqual(case.event_type, args.event_type);
        try testing.expectEqualStrings(case.message, args.message);
    }
}

test "eventCallback dispatches the informational message for an event type" {
    var mgr: Manager = undefined;
    mgr.dispatcher = events.Dispatcher.init(testing.allocator);
    defer mgr.dispatcher.deinit();

    var cap = InfoCapture{};
    _ = mgr.dispatcher.addInformationalHandler(.{
        .function = captureInfo,
        .data = @ptrCast(&cap),
    }) catch unreachable;
    defer cap.deinit(testing.allocator);
    var ev: rawLibalpm.alpm_event_t = .{ .type = @intCast(rawLibalpm.ALPM_EVENT_TRANSACTION_START) };
    Manager.eventCallback(@ptrCast(&mgr), &ev);

    const args = cap.args orelse return error.TestFailed;
    try testing.expectEqual(libalpm.EventType.transaction_start, args.event_type);
    try testing.expectEqualStrings("Starting transaction...", args.message);
}

test "eventCallback dispatches scriptlet output to the scriptlet handlers" {
    var mgr: Manager = undefined;
    mgr.dispatcher = events.Dispatcher.init(testing.allocator);
    defer mgr.dispatcher.deinit();

    var cap = ScriptletCapture{};
    _ = mgr.dispatcher.addScriptletHandler(.{
        .function = captureScriptlet,
        .data = @ptrCast(&cap),
    }) catch unreachable;

    var ev: rawLibalpm.alpm_event_t = .{ .scriptlet_info = .{
        .type = @intCast(rawLibalpm.ALPM_EVENT_SCRIPTLET_INFO),
        .line = "Running post-install script",
    } };
    Manager.eventCallback(@ptrCast(&mgr), &ev);

    const args = cap.args orelse return error.TestFailed;
    try testing.expectEqualStrings("Running post-install script", args.line);
}

test "eventCallback formats and dispatches hook progress" {
    var mgr: Manager = undefined;
    mgr.dispatcher = events.Dispatcher.init(testing.allocator);
    defer mgr.dispatcher.deinit();

    var cap = HookCapture{};
    _ = mgr.dispatcher.addHookHandler(.{
        .function = captureHook,
        .data = @ptrCast(&cap),
    }) catch unreachable;

    var ev: rawLibalpm.alpm_event_t = .{ .hook_run = .{
        .type = @intCast(rawLibalpm.ALPM_EVENT_HOOK_RUN_START),
        .name = "update-cache.hook",
        .desc = "Updating package cache",
        .position = 2,
        .total = 4,
    } };
    Manager.eventCallback(@ptrCast(&mgr), &ev);

    try testing.expectEqualStrings("(2/4) Updating package cache", cap.text());
    try testing.expectEqual(@as(c_ulong, 2), cap.position);
    try testing.expectEqual(@as(c_ulong, 4), cap.total);
}

test "eventCallback dispatches pacnew and pacsave paths" {
    var mgr: Manager = undefined;
    mgr.dispatcher = events.Dispatcher.init(testing.allocator);
    defer mgr.dispatcher.deinit();

    var pacnew_cap = PacnewCapture{};
    var pacsave_cap = PacsaveCapture{};
    _ = mgr.dispatcher.addPacnewHandler(.{
        .function = capturePacnew,
        .data = @ptrCast(&pacnew_cap),
    }) catch unreachable;
    _ = mgr.dispatcher.addPacsaveHandler(.{
        .function = capturePacsave,
        .data = @ptrCast(&pacsave_cap),
    }) catch unreachable;

    var pacnew_event: rawLibalpm.alpm_event_t = .{ .pacnew_created = .{
        .type = @intCast(rawLibalpm.ALPM_EVENT_PACNEW_CREATED),
        .file = "/etc/example.conf.pacnew",
    } };
    Manager.eventCallback(@ptrCast(&mgr), &pacnew_event);

    var pacsave_event: rawLibalpm.alpm_event_t = .{ .pacsave_created = .{
        .type = @intCast(rawLibalpm.ALPM_EVENT_PACSAVE_CREATED),
        .file = "/etc/example.conf.pacsave",
    } };
    Manager.eventCallback(@ptrCast(&mgr), &pacsave_event);

    try testing.expectEqualStrings("/etc/example.conf.pacnew", pacnew_cap.file orelse return error.TestFailed);
    try testing.expect(pacsave_cap.pkg_name == null);
    try testing.expectEqualStrings("/etc/example.conf.pacsave", pacsave_cap.file orelse return error.TestFailed);
}

test "eventCallback ignores null out-of-range and empty scriptlet events" {
    var mgr: Manager = undefined;
    mgr.dispatcher = events.Dispatcher.init(testing.allocator);
    defer mgr.dispatcher.deinit();

    var info_cap = InfoCapture{};
    defer info_cap.deinit(testing.allocator);
    var scriptlet_cap = ScriptletCapture{};
    _ = try mgr.dispatcher.addInformationalHandler(.{
        .function = captureInfo,
        .data = @ptrCast(&info_cap),
    });
    _ = try mgr.dispatcher.addScriptletHandler(.{
        .function = captureScriptlet,
        .data = @ptrCast(&scriptlet_cap),
    });

    Manager.eventCallback(@ptrCast(&mgr), null);

    var out_of_range: rawLibalpm.alpm_event_t = .{ .type = 0 };
    Manager.eventCallback(@ptrCast(&mgr), &out_of_range);

    var empty_scriptlet: rawLibalpm.alpm_event_t = .{ .scriptlet_info = .{
        .type = @intCast(rawLibalpm.ALPM_EVENT_SCRIPTLET_INFO),
        .line = "",
    } };
    Manager.eventCallback(@ptrCast(&mgr), &empty_scriptlet);

    try testing.expect(info_cap.args == null);
    try testing.expect(scriptlet_cap.args == null);
}

test "eventCallback ignores event values above the libalpm range" {
    var mgr: Manager = undefined;
    mgr.dispatcher = events.Dispatcher.init(testing.allocator);
    defer mgr.dispatcher.deinit();

    var cap = InfoCapture{};
    _ = try mgr.dispatcher.addInformationalHandler(.{
        .function = captureInfo,
        .data = @ptrCast(&cap),
    });
    defer cap.deinit(testing.allocator);

    var event: rawLibalpm.alpm_event_t = .{
        .type = @intCast(rawLibalpm.ALPM_EVENT_HOOK_RUN_DONE + 1),
    };
    Manager.eventCallback(@ptrCast(&mgr), &event);

    try testing.expect(cap.args == null);
}

test "eventCallback forwards nullable pacnew and pacsave payloads" {
    var mgr: Manager = undefined;
    mgr.dispatcher = events.Dispatcher.init(testing.allocator);
    defer mgr.dispatcher.deinit();

    var pacnew_cap = PacnewCapture{};
    var pacsave_cap = PacsaveCapture{};
    _ = try mgr.dispatcher.addPacnewHandler(.{
        .function = capturePacnew,
        .data = @ptrCast(&pacnew_cap),
    });
    _ = try mgr.dispatcher.addPacsaveHandler(.{
        .function = capturePacsave,
        .data = @ptrCast(&pacsave_cap),
    });

    var pacnew: rawLibalpm.alpm_event_t = .{ .pacnew_created = .{
        .type = @intCast(rawLibalpm.ALPM_EVENT_PACNEW_CREATED),
        .file = null,
    } };
    Manager.eventCallback(@ptrCast(&mgr), &pacnew);

    var pacsave: rawLibalpm.alpm_event_t = .{ .pacsave_created = .{
        .type = @intCast(rawLibalpm.ALPM_EVENT_PACSAVE_CREATED),
        .oldpkg = null,
        .file = null,
    } };
    Manager.eventCallback(@ptrCast(&mgr), &pacsave);

    try testing.expect(pacnew_cap.file == null);
    try testing.expect(pacsave_cap.pkg_name == null);
    try testing.expect(pacsave_cap.file == null);
}

test "eventCallback falls back from hook description to name and generic text" {
    var mgr: Manager = undefined;
    mgr.dispatcher = events.Dispatcher.init(testing.allocator);
    defer mgr.dispatcher.deinit();

    var cap = HookCapture{};
    _ = try mgr.dispatcher.addHookHandler(.{
        .function = captureHook,
        .data = @ptrCast(&cap),
    });

    var named: rawLibalpm.alpm_event_t = .{ .hook_run = .{
        .type = @intCast(rawLibalpm.ALPM_EVENT_HOOK_RUN_START),
        .name = "named-hook",
        .desc = null,
        .position = 1,
        .total = 2,
    } };
    Manager.eventCallback(@ptrCast(&mgr), &named);
    try testing.expectEqualStrings("(1/2) named-hook", cap.text());

    var generic: rawLibalpm.alpm_event_t = .{ .hook_run = .{
        .type = @intCast(rawLibalpm.ALPM_EVENT_HOOK_RUN_START),
        .name = null,
        .desc = null,
        .position = 2,
        .total = 2,
    } };
    Manager.eventCallback(@ptrCast(&mgr), &generic);
    try testing.expectEqualStrings("(2/2) Running hook...", cap.text());
}

test "onDownloadEvent translates start progress and completion events" {
    var mgr: Manager = undefined;
    mgr.allocator = testing.allocator;
    mgr.dispatcher = events.Dispatcher.init(testing.allocator);
    defer mgr.dispatcher.deinit();

    var info_cap = InfoCapture{};
    defer info_cap.deinit(testing.allocator);
    var progress_cap = ProgressCapture{};
    _ = try mgr.dispatcher.addInformationalHandler(.{
        .function = captureInfo,
        .data = @ptrCast(&info_cap),
    });
    _ = try mgr.dispatcher.addProgressHandler(.{
        .function = captureProgress,
        .data = @ptrCast(&progress_cap),
    });

    Manager.onDownloadEvent(@ptrCast(&mgr), .{
        .event_type = .Start,
        .destination_path = "/tmp/example.pkg.tar.zst",
    });
    var info = info_cap.args orelse return error.TestFailed;
    try testing.expectEqual(libalpm.EventType.pkg_retrieve_start, info.event_type);
    try testing.expectEqualStrings("Retrieving package: example.pkg.tar.zst", info_cap.message orelse return error.TestFailed);

    Manager.onDownloadEvent(@ptrCast(&mgr), .{
        .event_type = .Progress,
        .destination_path = "/tmp/example.pkg.tar.zst",
        .progress = .{
            .bytes_downloaded = 50,
            .bytes_total = 100,
            .percent = 50,
            .speed_bytes_per_sec = 25,
        },
    });
    const progress = progress_cap.args orelse return error.TestFailed;
    try testing.expectEqualStrings("example.pkg.tar.zst", progress.pkg_name orelse return error.TestFailed);
    try testing.expectEqual(@as(c_int, 50), progress.percent);
    try testing.expectEqual(@as(c_ulong, 1), progress.howmany);
    try testing.expectEqual(@as(c_ulong, 1), progress.current);

    Manager.onDownloadEvent(@ptrCast(&mgr), .{
        .event_type = .Complete,
        .destination_path = "/tmp/example.pkg.tar.zst",
    });
    info = info_cap.args orelse return error.TestFailed;
    try testing.expectEqual(libalpm.EventType.pkg_retrieve_done, info.event_type);
    try testing.expectEqualStrings("Package retrieval completed: example.pkg.tar.zst", info_cap.message orelse return error.TestFailed);
}

test "onDownloadEvent does not duplicate progress when a common operation is attached" {
    var mgr: Manager = undefined;
    mgr.dispatcher = events.Dispatcher.init(testing.allocator);
    defer mgr.dispatcher.deinit();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var context = operation_api.OperationContext.init(testing.allocator, threaded.io());
    defer context.deinit();
    var operation = context.begin(.{ .backend = .alpm, .kind = .update });
    defer operation.finish(.success);
    mgr.dispatcher.setOperation(&operation);

    var progress_cap = ProgressCapture{};
    _ = try mgr.dispatcher.addProgressHandler(.{
        .function = captureProgress,
        .data = @ptrCast(&progress_cap),
    });
    Manager.onDownloadEvent(@ptrCast(&mgr), .{
        .event_type = .Progress,
        .destination_path = "/tmp/example.pkg.tar.zst",
        .progress = .{
            .bytes_downloaded = 50,
            .bytes_total = 100,
            .percent = 50,
            .speed_bytes_per_sec = 25,
        },
    });

    try testing.expect(progress_cap.args == null);
}

test "onDownloadEvent reports concrete and fallback errors and ignores skipped events" {
    var mgr: Manager = undefined;
    mgr.allocator = testing.allocator;
    mgr.dispatcher = events.Dispatcher.init(testing.allocator);
    defer mgr.dispatcher.deinit();

    var error_cap = ErrorCapture{};
    var info_cap = InfoCapture{};
    defer info_cap.deinit(testing.allocator);

    _ = try mgr.dispatcher.addErrorHandler(.{
        .function = captureError,
        .data = @ptrCast(&error_cap),
    });
    _ = try mgr.dispatcher.addInformationalHandler(.{
        .function = captureInfo,
        .data = @ptrCast(&info_cap),
    });

    Manager.onDownloadEvent(@ptrCast(&mgr), .{
        .event_type = .Error,
        .download_error = downloader.DownloadError.NetworkError,
    });
    try testing.expect(std.mem.indexOf(u8, error_cap.text(), "Technical details: NetworkError") != null);

    Manager.onDownloadEvent(@ptrCast(&mgr), .{ .event_type = .Error });
    try testing.expect(std.mem.startsWith(u8, error_cap.text(), "Could not download"));

    error_cap.len = 0;
    Manager.onDownloadEvent(@ptrCast(&mgr), .{
        .event_type = .Skipped,
        .destination_path = "/tmp/skipped.pkg.tar.zst",
    });
    try testing.expectEqual(@as(usize, 0), error_cap.len);
    try testing.expect(info_cap.args == null);
}

test "onDownloadEvent handles missing paths and missing progress payloads" {
    var mgr: Manager = undefined;
    mgr.allocator = testing.allocator;
    mgr.dispatcher = events.Dispatcher.init(testing.allocator);
    defer mgr.dispatcher.deinit();

    var info_cap = InfoCapture{};
    defer info_cap.deinit(testing.allocator);
    var progress_cap = ProgressCapture{};
    _ = try mgr.dispatcher.addInformationalHandler(.{
        .function = captureInfo,
        .data = @ptrCast(&info_cap),
    });
    _ = try mgr.dispatcher.addProgressHandler(.{
        .function = captureProgress,
        .data = @ptrCast(&progress_cap),
    });

    Manager.onDownloadEvent(@ptrCast(&mgr), .{ .event_type = .Start });
    const info = info_cap.args orelse return error.TestFailed;
    try testing.expectEqual(libalpm.EventType.pkg_retrieve_start, info.event_type);
    try testing.expectEqualStrings("Retrieving package: ", info_cap.message orelse return error.TestFailed);

    Manager.onDownloadEvent(@ptrCast(&mgr), .{ .event_type = .Progress });
    try testing.expect(progress_cap.args == null);
}

test "database signature policy distinguishes disabled optional and required" {
    try testing.expectEqual(DatabaseSignaturePolicy.disabled, Manager.databaseSignaturePolicy(0));
    try testing.expectEqual(DatabaseSignaturePolicy.required, Manager.databaseSignaturePolicy(rawLibalpm.ALPM_SIG_DATABASE));
    try testing.expectEqual(DatabaseSignaturePolicy.optional, Manager.databaseSignaturePolicy(
        rawLibalpm.ALPM_SIG_DATABASE | rawLibalpm.ALPM_SIG_DATABASE_OPTIONAL,
    ));
}

// ---------------------------------------------------------------------------
// askYesNo
// ---------------------------------------------------------------------------

test "askYesNo returns true for a non-zero answer" {
    var mgr: Manager = undefined;
    mgr.dispatcher = events.Dispatcher.init(testing.allocator);
    defer mgr.dispatcher.deinit();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const tio = threaded.io();

    var ctx = AskResponder{ .disp = &mgr.dispatcher, .io = tio, .answer = 1 };
    _ = mgr.dispatcher.addQuestionHandler(.{
        .function = askResponder,
        .data = @ptrCast(&ctx),
    }) catch unreachable;

    try testing.expect(mgr.askYesNo(tio, 0, "proceed?"));
}

test "askYesNo returns false for a zero answer" {
    var mgr: Manager = undefined;
    mgr.dispatcher = events.Dispatcher.init(testing.allocator);
    defer mgr.dispatcher.deinit();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const tio = threaded.io();

    var ctx = AskResponder{ .disp = &mgr.dispatcher, .io = tio, .answer = 0 };
    _ = mgr.dispatcher.addQuestionHandler(.{
        .function = askResponder,
        .data = @ptrCast(&ctx),
    }) catch unreachable;

    try testing.expect(!mgr.askYesNo(tio, 0, "proceed?"));
}

test "askYesNo maps shared confirmation responses" {
    const CommonResponder = struct {
        response: operation_api.QuestionResponse,

        fn answer(data: ?*anyopaque, question: operation_api.Question) operation_api.QuestionResponse {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            testing.expect(question.kind == .confirmation) catch unreachable;
            return self.response;
        }
    };

    var mgr: Manager = undefined;
    mgr.dispatcher = events.Dispatcher.init(testing.allocator);
    defer mgr.dispatcher.deinit();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const tio = threaded.io();
    var context = operation_api.OperationContext.init(testing.allocator, tio);
    defer context.deinit();
    var responder: CommonResponder = .{ .response = .accepted };
    context.setQuestionHandler(.{ .function = CommonResponder.answer, .data = &responder });
    var operation = context.begin(.{ .backend = .alpm, .kind = .install });
    defer operation.finish(.success);
    mgr.dispatcher.setOperation(&operation);

    const question_type = @intFromEnum(libalpm.QuestionType.install_ignore);
    try testing.expect(mgr.askYesNo(tio, question_type, "proceed?"));
    responder.response = .declined;
    try testing.expect(!mgr.askYesNo(tio, question_type, "proceed?"));
}

test "questionCallback applies affirmative answers to simple libalpm questions" {
    var mgr: Manager = undefined;
    mgr.allocator = testing.allocator;
    mgr.dispatcher = events.Dispatcher.init(testing.allocator);
    defer mgr.dispatcher.deinit();
    mgr.threaded = .init(testing.allocator, .{});
    defer mgr.threaded.deinit();

    var responder = AskResponder{
        .disp = &mgr.dispatcher,
        .io = mgr.io(),
        .answer = 1,
    };
    _ = try mgr.dispatcher.addQuestionHandler(.{
        .function = askResponder,
        .data = @ptrCast(&responder),
    });

    var corrupted: rawLibalpm.alpm_question_t = .{ .corrupted = .{
        .type = rawLibalpm.ALPM_QUESTION_CORRUPTED_PKG,
        .filepath = "/tmp/corrupt.pkg.tar.zst",
    } };
    Manager.questionCallback(@ptrCast(&mgr), &corrupted);
    try testing.expectEqual(@as(c_int, 1), corrupted.corrupted.remove);

    var remove: rawLibalpm.alpm_question_t = .{ .remove_pkgs = .{
        .type = rawLibalpm.ALPM_QUESTION_REMOVE_PKGS,
    } };
    Manager.questionCallback(@ptrCast(&mgr), &remove);
    try testing.expectEqual(@as(c_int, 1), remove.remove_pkgs.skip);

    var import_key: rawLibalpm.alpm_question_t = .{ .import_key = .{
        .type = rawLibalpm.ALPM_QUESTION_IMPORT_KEY,
        .uid = "Shelly Test Key",
    } };
    Manager.questionCallback(@ptrCast(&mgr), &import_key);
    try testing.expectEqual(@as(c_int, 1), import_key.import_key.import);
}

test "questionCallback keeps unknown answers and applies selected provider choices" {
    var mgr: Manager = undefined;
    mgr.allocator = testing.allocator;
    mgr.dispatcher = events.Dispatcher.init(testing.allocator);
    defer mgr.dispatcher.deinit();
    mgr.threaded = .init(testing.allocator, .{});
    defer mgr.threaded.deinit();

    var unknown: rawLibalpm.alpm_question_t = .{ .any = .{
        .type = 0,
        .answer = 7,
    } };
    Manager.questionCallback(@ptrCast(&mgr), &unknown);
    try testing.expectEqual(@as(c_int, 7), unknown.any.answer);

    var responder = ChoiceResponder{
        .disp = &mgr.dispatcher,
        .io = mgr.io(),
        .choice = 3,
    };
    _ = try mgr.dispatcher.addQuestionHandler(.{
        .function = choiceResponder,
        .data = @ptrCast(&responder),
    });

    var provider: rawLibalpm.alpm_question_t = .{ .select_provider = .{
        .type = rawLibalpm.ALPM_QUESTION_SELECT_PROVIDER,
        .providers = null,
        .depend = null,
    } };
    Manager.questionCallback(@ptrCast(&mgr), &provider);
    try testing.expectEqual(@as(c_int, 3), provider.select_provider.use_index);
}

test "questionCallback defaults provider selection to the first entry without handlers" {
    var mgr: Manager = undefined;
    mgr.allocator = testing.allocator;
    mgr.dispatcher = events.Dispatcher.init(testing.allocator);
    defer mgr.dispatcher.deinit();
    mgr.threaded = .init(testing.allocator, .{});
    defer mgr.threaded.deinit();

    var provider: rawLibalpm.alpm_question_t = .{ .select_provider = .{
        .type = rawLibalpm.ALPM_QUESTION_SELECT_PROVIDER,
        .use_index = 9,
        .providers = null,
        .depend = null,
    } };
    Manager.questionCallback(@ptrCast(&mgr), &provider);

    try testing.expectEqual(@as(c_int, 0), provider.select_provider.use_index);
}

// ---------------------------------------------------------------------------
// handleErrorMessage
// ---------------------------------------------------------------------------

fn newErrorManager() Manager {
    var mgr: Manager = undefined;
    mgr.allocator = testing.allocator;
    mgr.dispatcher = events.Dispatcher.init(testing.allocator);
    mgr.config.database_path = "/var/lib/pacman/";
    return mgr;
}

test "handleErrorMessage emits a known error description" {
    var mgr = newErrorManager();
    defer mgr.dispatcher.deinit();

    var cap = ErrorCapture{};
    _ = mgr.dispatcher.addErrorHandler(.{
        .function = captureError,
        .data = @ptrCast(&cap),
    }) catch unreachable;

    try mgr.handleErrorMessage(@intFromEnum(libalpm.Error.Memory), null);

    try testing.expect(std.mem.indexOf(u8, cap.text(), "Memory allocation failed.") != null);
}

test "handleErrorMessage emits the expected database lock error" {
    var mgr = newErrorManager();
    defer mgr.dispatcher.deinit();

    var cap = ErrorCapture{};
    _ = try mgr.dispatcher.addErrorHandler(.{
        .function = captureError,
        .data = @ptrCast(&cap),
    });

    try mgr.handleErrorMessage(@intFromEnum(libalpm.Error.HandleLock), null);

    try testing.expect(std.mem.startsWith(u8, cap.text(), "Could not start the package operation because the package database is locked."));
    try testing.expect(std.mem.indexOf(u8, cap.text(), "Lock file: /var/lib/pacman/db.lck") != null);
    try testing.expect(std.mem.indexOf(u8, cap.text(), "sudo rm -- '/var/lib/pacman/db.lck'") != null);
    try testing.expect(std.mem.indexOf(u8, cap.text(), "If no package manager is running") != null);
}

test "handleErrorMessage handles the Ok error without details" {
    var mgr = newErrorManager();
    defer mgr.dispatcher.deinit();

    var cap = ErrorCapture{};
    _ = mgr.dispatcher.addErrorHandler(.{
        .function = captureError,
        .data = @ptrCast(&cap),
    }) catch unreachable;

    try mgr.handleErrorMessage(@intFromEnum(libalpm.Error.Ok), null);

    // Ok produces no extra detail line, but the strerror header is still emitted.
    try testing.expect(cap.len != 0);
}

test "handleErrorMessage reports an out-of-range error number as unknown" {
    var mgr = newErrorManager();
    defer mgr.dispatcher.deinit();

    var cap = ErrorCapture{};
    _ = mgr.dispatcher.addErrorHandler(.{
        .function = captureError,
        .data = @ptrCast(&cap),
    }) catch unreachable;

    try mgr.handleErrorMessage(9999, null);

    try testing.expect(std.mem.indexOf(u8, cap.text(), "Unknown error: 9999") != null);
}

test "handleErrorMessage propagates allocation failures without dispatching" {
    for (0..2) |fail_index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        var mgr = newErrorManager();
        defer mgr.dispatcher.deinit();
        mgr.allocator = failing.allocator();

        var cap = ErrorCapture{};
        _ = try mgr.dispatcher.addErrorHandler(.{
            .function = captureError,
            .data = @ptrCast(&cap),
        });

        try testing.expectError(
            error.OutOfMemory,
            mgr.handleErrorMessage(@intFromEnum(libalpm.Error.Memory), null),
        );
        try testing.expectEqual(@as(usize, 0), cap.len);
        try testing.expect(failing.has_induced_failure);
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "handleErrorMessage tolerates a null list for list-based errors" {
    var mgr = newErrorManager();
    defer mgr.dispatcher.deinit();

    var cap = ErrorCapture{};
    _ = mgr.dispatcher.addErrorHandler(.{
        .function = captureError,
        .data = @ptrCast(&cap),
    }) catch unreachable;

    // These branches walk `data_ptr`; a null list means the loop body never
    // runs, so only the strerror header is emitted and nothing crashes.
    try mgr.handleErrorMessage(@intFromEnum(libalpm.Error.UnsatisfiedDeps), null);
    try testing.expect(cap.len != 0);

    cap.len = 0;
    try mgr.handleErrorMessage(@intFromEnum(libalpm.Error.ConflictingDeps), null);
    try testing.expect(cap.len != 0);

    cap.len = 0;
    try mgr.handleErrorMessage(@intFromEnum(libalpm.Error.FileConflicts), null);
    try testing.expect(cap.len != 0);

    cap.len = 0;
    try mgr.handleErrorMessage(@intFromEnum(libalpm.Error.PkgInvalidName), null);
    try testing.expect(cap.len != 0);
}

test "handleErrorMessage includes invalid package names from a populated list" {
    var mgr = newErrorManager();
    defer mgr.dispatcher.deinit();

    var cap = ErrorCapture{};
    _ = try mgr.dispatcher.addErrorHandler(.{
        .function = captureError,
        .data = @ptrCast(&cap),
    });

    var invalid_name = [_:0]u8{ 'b', 'a', 'd', ' ', 'n', 'a', 'm', 'e' };
    var node: rawLibalpm.alpm_list_t = .{
        .data = @ptrCast(&invalid_name),
    };

    try mgr.handleErrorMessage(@intFromEnum(libalpm.Error.PkgInvalidName), &node);

    try testing.expect(std.mem.indexOf(u8, cap.text(), "bad name\n") != null);
}

test "handleErrorMessage formats populated unsatisfied dependency details" {
    var mgr = newErrorManager();
    defer mgr.dispatcher.deinit();

    var cap = ErrorCapture{};
    _ = try mgr.dispatcher.addErrorHandler(.{
        .function = captureError,
        .data = @ptrCast(&cap),
    });

    var dependency: rawLibalpm.alpm_depend_t = .{
        .name = @ptrCast(@constCast("libexample")),
        .version = @ptrCast(@constCast("2")),
        .mod = @intCast(rawLibalpm.ALPM_DEP_MOD_GE),
    };
    var missing: rawLibalpm.alpm_depmissing_t = .{
        .target = @ptrCast(@constCast("target-package")),
        .depend = &dependency,
    };
    var node: rawLibalpm.alpm_list_t = .{
        .data = @ptrCast(&missing),
    };

    try mgr.handleErrorMessage(@intFromEnum(libalpm.Error.UnsatisfiedDeps), &node);

    try testing.expect(std.mem.indexOf(
        u8,
        cap.text(),
        "Could not install \"target-package\" because it requires \"libexample>=2\", which is unavailable.",
    ) != null);
}

test "handleErrorMessage formats populated file conflict details" {
    var mgr = newErrorManager();
    defer mgr.dispatcher.deinit();

    var cap = ErrorCapture{};
    _ = try mgr.dispatcher.addErrorHandler(.{
        .function = captureError,
        .data = @ptrCast(&cap),
    });

    var conflict: rawLibalpm.alpm_fileconflict_t = .{
        .target = @ptrCast(@constCast("target-package")),
        .type = @intCast(rawLibalpm.ALPM_FILECONFLICT_FILESYSTEM),
        .file = @ptrCast(@constCast("/usr/bin/example")),
    };
    var node: rawLibalpm.alpm_list_t = .{
        .data = @ptrCast(&conflict),
    };

    try mgr.handleErrorMessage(@intFromEnum(libalpm.Error.FileConflicts), &node);

    try testing.expect(std.mem.indexOf(
        u8,
        cap.text(),
        "Could not install \"target-package\" because \"/usr/bin/example\" already exists. Check which package owns this file before replacing or removing it.\n",
    ) != null);
}

test "handleDownloadEvent returns out of memory when message allocation fails" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 0,
    });

    var mgr: Manager = undefined;
    mgr.allocator = failing.allocator();
    mgr.dispatcher = events.Dispatcher.init(testing.allocator);
    defer mgr.dispatcher.deinit();

    try testing.expectError(
        TransactionError.OutOfMemory,
        mgr.handleDownloadEvent(.{
            .event_type = .Start,
            .destination_path = "/tmp/example.pkg.tar.zst",
        }),
    );

    try testing.expect(failing.has_induced_failure);
}

test "handleErrorMessage emits descriptions for every scalar libalpm error" {
    const Case = struct {
        err: libalpm.Error,
        detail: []const u8,
    };
    const cases = [_]Case{
        .{ .err = .Memory, .detail = "Memory allocation failed." },
        .{ .err = .System, .detail = "System error." },
        .{ .err = .BadPerms, .detail = "Could not access the package database or required files. Check that you have permission to access them." },
        .{ .err = .NotAFile, .detail = "Expected a file at the supplied path." },
        .{ .err = .NotADir, .detail = "Expected a directory at the supplied path." },
        .{ .err = .WrongArgs, .detail = "Could not start the package operation because a required argument is missing or invalid." },
        .{ .err = .DiskSpace, .detail = "There is not enough free space" },
        .{ .err = .HandleNull, .detail = "Could not access the package database because it has not been initialized." },
        .{ .err = .HandleNotNull, .detail = "Could not initialize the package database because it is already open." },
        .{ .err = .HandleLock, .detail = "Lock file: /var/lib/pacman/db.lck" },
        .{ .err = .DbOpen, .detail = "Failed to open the database." },
        .{ .err = .DbCreate, .detail = "Failed to create the database." },
        .{ .err = .DbNull, .detail = "Could not access the package database because it has not been opened." },
        .{ .err = .DbNotNull, .detail = "Could not open the package database because it is already registered." },
        .{ .err = .DbNotFound, .detail = "Database not found." },
        .{ .err = .DbInvalid, .detail = "Database is invalid." },
        .{ .err = .DbInvalidSig, .detail = "Could not verify the repository database signature. Refresh the package signing keys and package lists. If verification still fails, contact the repository." },
        .{ .err = .DbVersion, .detail = "Database version is invalid." },
        .{ .err = .DbWrite, .detail = "Failed to write to the database." },
        .{ .err = .DbRemove, .detail = "Failed to remove the database." },
        .{ .err = .ServerBadUrl, .detail = "Server URL is invalid." },
        .{ .err = .ServerNone, .detail = "No server found." },
        .{ .err = .TransNotNull, .detail = "Could not start the package operation because another transaction is already active." },
        .{ .err = .TransNull, .detail = "Could not continue because there is no active package transaction." },
        .{ .err = .TransDupTarget, .detail = "Transaction target is duplicated." },
        .{ .err = .TransDupFilename, .detail = "Transaction filename is duplicated." },
        .{ .err = .TransNotInitialized, .detail = "Transaction is not initialized." },
        .{ .err = .TransNotPrepared, .detail = "Transaction is not prepared." },
        .{ .err = .TransAbort, .detail = "Transaction aborted." },
        .{ .err = .TransType, .detail = "Transaction type is invalid." },
        .{ .err = .TransNotLocked, .detail = "Transaction is not locked." },
        .{ .err = .TransHookFailed, .detail = "Transaction hook failed." },
        .{ .err = .PkgNotFound, .detail = "Could not find the requested package in the selected package sources. Check the package name or search for it in another source." },
        .{ .err = .PkgIgnored, .detail = "Package ignored." },
        .{ .err = .PkgInvalid, .detail = "Package is invalid." },
        .{ .err = .PkgInvalidChecksum, .detail = "Package checksum is invalid." },
        .{ .err = .PkgInvalidSig, .detail = "Could not verify the package signature. Refresh the package signing keys and download the package again. If verification still fails, contact the package source." },
        .{ .err = .PkgMissingSig, .detail = "Package signature is missing." },
        .{ .err = .PkgOpen, .detail = "Failed to open package." },
        .{ .err = .PkgCantRemove, .detail = "Failed to remove package." },
        .{ .err = .PkgInvalidArch, .detail = "Package architecture is invalid." },
        .{ .err = .SigMissing, .detail = "Signature is missing." },
        .{ .err = .SigInvalid, .detail = "Could not verify the signature. Refresh the package signing keys and download the file again. If verification still fails, contact the package source." },
        .{ .err = .DownloadFailed, .detail = "Could not download the required files. Check your internet connection and try again. If the problem continues, the server may be unavailable." },
        .{ .err = .Gpgme, .detail = "Gpgme error." },
        .{ .err = .ExternalDownload, .detail = "External download failed." },
        .{ .err = .SandboxFailed, .detail = "Sandbox failed." },
    };

    var mgr = newErrorManager();
    defer mgr.dispatcher.deinit();

    var cap = ErrorCapture{};
    _ = try mgr.dispatcher.addErrorHandler(.{
        .function = captureError,
        .data = @ptrCast(&cap),
    });

    for (cases) |case| {
        cap.len = 0;
        try mgr.handleErrorMessage(@intFromEnum(case.err), null);
        try testing.expect(std.mem.indexOf(u8, cap.text(), case.detail) != null);
    }
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

const ProgressCapture = struct {
    args: ?events.ProgressArgs = null,
};

fn captureProgress(data: ?*anyopaque, args: events.ProgressArgs) void {
    const cap: *ProgressCapture = @ptrCast(@alignCast(data));
    cap.args = args;
}

const InfoCapture = struct {
    args: ?events.InformationalArgs = null,
    message: ?[]u8 = null,

    fn deinit(self: *InfoCapture, allocator: std.mem.Allocator) void {
        if (self.message) |message| {
            allocator.free(message);
        }

        self.message = null;
        self.args = null;
    }
};

fn captureInfo(data: ?*anyopaque, args: events.InformationalArgs) void {
    const cap: *InfoCapture = @ptrCast(@alignCast(data));

    if (cap.message) |message| {
        testing.allocator.free(message);
    }

    const message = testing.allocator.dupe(u8, args.message) catch unreachable;

    cap.message = message;
    cap.args = args;
    cap.args.?.message = message;
}

const ScriptletCapture = struct {
    args: ?events.ScriptletArgs = null,
};

fn captureScriptlet(data: ?*anyopaque, args: events.ScriptletArgs) void {
    const cap: *ScriptletCapture = @ptrCast(@alignCast(data));
    cap.args = args;
}

const HookCapture = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,
    position: c_ulong = 0,
    total: c_ulong = 0,

    fn text(self: *const HookCapture) []const u8 {
        return self.buf[0..self.len];
    }
};

fn captureHook(data: ?*anyopaque, args: events.HookArgs) void {
    const cap: *HookCapture = @ptrCast(@alignCast(data));
    if (args.description) |description| {
        cap.len = @min(description.len, cap.buf.len);
        @memcpy(cap.buf[0..cap.len], description[0..cap.len]);
    }
    cap.position = args.position;
    cap.total = args.total;
}

const PacnewCapture = struct {
    file: ?[]const u8 = null,
};

fn capturePacnew(data: ?*anyopaque, args: events.PacnewArgs) void {
    const cap: *PacnewCapture = @ptrCast(@alignCast(data));
    cap.file = args.file;
}

const PacsaveCapture = struct {
    pkg_name: ?[]const u8 = null,
    file: ?[]const u8 = null,
};

fn capturePacsave(data: ?*anyopaque, args: events.PacsaveArgs) void {
    const cap: *PacsaveCapture = @ptrCast(@alignCast(data));
    cap.pkg_name = args.pkg_name;
    cap.file = args.file;
}

const ErrorCapture = struct {
    buf: [2048]u8 = undefined,
    len: usize = 0,
    count: usize = 0,
    err: ?anyerror = null,

    fn text(self: *const ErrorCapture) []const u8 {
        return self.buf[0..self.len];
    }
};

fn captureError(data: ?*anyopaque, args: events.ErrorArgs) void {
    const cap: *ErrorCapture = @ptrCast(@alignCast(data));
    cap.count += 1;
    const n = @min(args.message.len, cap.buf.len);
    @memcpy(cap.buf[0..n], args.message[0..n]);
    cap.len = n;
}

const AskResponder = struct {
    disp: *events.Dispatcher,
    io: std.Io,
    answer: c_int,
};

fn askResponder(data: ?*anyopaque, args: events.QuestionArgs) void {
    _ = args;
    const ctx: *AskResponder = @ptrCast(@alignCast(data));
    ctx.disp.respond(ctx.io, .{ .answer = ctx.answer, .pkg = null, .choice = null });
}

const ChoiceResponder = struct {
    disp: *events.Dispatcher,
    io: std.Io,
    choice: c_int,
};

fn choiceResponder(data: ?*anyopaque, args: events.QuestionArgs) void {
    _ = args;
    const ctx: *ChoiceResponder = @ptrCast(@alignCast(data));
    ctx.disp.respond(ctx.io, .{ .choice = ctx.choice });
}

test "ALPM init path overrides replace parsed host paths for target provisioning" {
    const arena = try testing.allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(testing.allocator);
    var config = try configuration.Configuration.Config.initialize_with_defaults(arena);
    defer config.deinitialize();

    try applyInitPathOverrides(&config, .{
        .root_directory = "/target",
        .database_path = "/target/var/lib/pacman",
        .cache_directory = "/target/var/cache/pacman/pkg",
        .log_file = "/target/var/log/pacman.log",
        .gpg_directory = "/target/etc/pacman.d/gnupg",
    });

    try testing.expectEqualStrings("/target", config.root_directory);
    try testing.expectEqualStrings("/target/var/lib/pacman", config.database_path);
    try testing.expectEqualStrings("/target/var/cache/pacman/pkg", config.cache_directory);
    try testing.expectEqualStrings("/target/var/log/pacman.log", config.log_file);
    try testing.expectEqualStrings("/target/etc/pacman.d/gnupg", config.gpg_directory);
}

test "database lock error uses the configured database directory" {
    var mgr = newErrorManager();
    defer mgr.dispatcher.deinit();
    mgr.config.database_path = "/custom/pacman database/";
    var cap = ErrorCapture{};
    _ = try mgr.dispatcher.addErrorHandler(.{ .function = captureError, .data = @ptrCast(&cap) });
    try mgr.handleErrorMessage(@intFromEnum(libalpm.Error.HandleLock), null);
    try testing.expect(std.mem.indexOf(u8, cap.text(), "Lock file: /custom/pacman database/db.lck") != null);
    try testing.expect(std.mem.indexOf(u8, cap.text(), "sudo rm -- '/custom/pacman database/db.lck'") != null);
    try testing.expect(std.mem.indexOf(u8, cap.text(), "/var/lib/pacman") == null);
}

test "dependency errors explain the dependent package during removal" {
    var mgr = newErrorManager();
    defer mgr.dispatcher.deinit();
    var context = operation_api.OperationContext.init(testing.allocator, std.testing.io);
    defer context.deinit();
    var operation = context.begin(.{ .backend = .alpm, .kind = .remove, .subject = "libexample" });
    defer operation.finish(.failed);
    mgr.dispatcher.operation = &operation;
    var cap = ErrorCapture{};
    _ = try mgr.dispatcher.addErrorHandler(.{ .function = captureError, .data = @ptrCast(&cap) });
    var dependency: rawLibalpm.alpm_depend_t = .{
        .name = @ptrCast(@constCast("libexample")),
        .mod = @intCast(rawLibalpm.ALPM_DEP_MOD_ANY),
    };
    var missing: rawLibalpm.alpm_depmissing_t = .{
        .target = @ptrCast(@constCast("installed-app")),
        .depend = &dependency,
    };
    var node: rawLibalpm.alpm_list_t = .{ .data = @ptrCast(&missing) };
    try mgr.handleErrorMessage(@intFromEnum(libalpm.Error.UnsatisfiedDeps), &node);
    try testing.expect(std.mem.indexOf(u8, cap.text(), "Could not remove the selected packages because \"installed-app\" still requires \"libexample\"") != null);
    try testing.expect(std.mem.indexOf(u8, cap.text(), "Could not install") == null);
}
