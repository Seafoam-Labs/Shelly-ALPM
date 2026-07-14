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

const libalpm = bindings.libalpm; // typed aliases (Handle, Database, Config, ...)
const rawLibalpm = bindings.libalpm.alpm;

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
};

pub const QueryError = error{ DbNotFound, PkgNotFound, NoHandle };

pub const Manager = struct {
    handle: libalpm.Handle = null,
    is_initialized: bool = false,
    is_cachyos: bool = false,
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    config: configuration.Configuration.Config,
    dispatcher: events.Dispatcher,
    threaded: std.Io.Threaded,
    local_db: ?bindings.libalpm.Database = null,
    sync_dbs: std.ArrayList(bindings.libalpm.Database) = .empty,
    package_download: bool = false,
    is_root: bool = false,
    temp_root_path: []const u8,
    show_hidden_packages: bool = false,

    /// If null is passed for config it will use the default /etc/pacman.conf.
    /// The caller owns the returned manager and must call deinit when finished.
    pub fn init(
        allocator: std.mem.Allocator,
        environ: std.process.Environ,
        configPath: ?[]const u8,
        use_root: bool,
        temp_root_path: ?[]const u8,
    ) InitError!*Manager {
        const config_path = configPath orelse "/etc/pacman.conf";
        const self = allocator.create(Manager) catch return InitError.InitFailed;
        errdefer allocator.destroy(self);
        self.* = Manager{
            .handle = null,
            .is_initialized = true,
            .allocator = allocator,
            .environ = environ,
            .dispatcher = events.Dispatcher.init(allocator),
            .threaded = .init(allocator, .{ .environ = environ }),
            .config = undefined,
            .is_root = use_root,
            .temp_root_path = temp_root_path orelse "",
        };
        errdefer self.threaded.deinit();
        errdefer self.dispatcher.deinit();
        self.config = configuration.Configuration.parse(allocator, self.io(), config_path) catch {
            return InitError.ConfigParseFailed;
        };
        errdefer self.config.deinitialize();
        errdefer self.sync_dbs.deinit(self.allocator);
        if (os_tool.prettyName(self.allocator, self.io())) |pretty_name| {
            defer self.allocator.free(pretty_name);
            if (std.ascii.eqlIgnoreCase("cachyos", pretty_name)) self.is_cachyos = true;
        }

        // Checks to see if the temp path is being used to run in non-root mode
        // for update checking. Symlink the real local database into the temp
        // path so ALPM can see installed packages when checking for updates.
        if (self.temp_root_path.len != 0) {
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

        const handle = rawLibalpm.alpm_initialize(self.config.root_directory, self.config.database_path, &err) orelse {
            std.log.err("alpm_initialize failed: {s}", .{std.mem.span(rawLibalpm.alpm_strerror(err))});
            return error.InitFailed;
        };
        self.handle = handle;
        self.is_initialized = true;

        self.applyConfig(self.config, self.is_root);
        self.setupCallbacks();
        return self;
    }

    pub fn toggle_hidden_packages(self: *Manager) bool {
        self.show_hidden_packages = !self.show_hidden_packages;
        return self.show_hidden_packages;
    }

    pub fn sync(self: *Manager, force: bool) TransactionError!void {
        var databaseMap = std.StringHashMap(std.ArrayList([]const u8)).init(self.allocator);
        defer databaseMap.deinit();
        self.package_download = false;
        if (self.handle == null) return TransactionError.SyncDbFailed;
        var databases: libalpm.DatabaseList = rawLibalpm.alpm_get_syncdbs(self.handle);
        if (databases == null) return TransactionError.SyncDbFailed;
        var dict = listDictionary.ListDictionary.init(self.allocator);
        defer dict.deinit();
        while (databases != null) : (databases = databases.?.next) {
            const db = databases.?.data orelse continue;
            var db_struct: libalpm.Database = .{ .ptr = @ptrCast(@alignCast(db)) };
            const db_name: []const u8 = db_struct.name() orelse continue;
            var servers = db_struct.servers();
            while (servers.next()) |server| {
                dict.add(db_name, server) catch {
                    return TransactionError.SyncDbFailed;
                };
            }
        }
        const syncDirectory = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.config.database_path, "/sync" }) catch {
            return TransactionError.SyncDbFailed;
        };
        defer self.allocator.free(syncDirectory);

        //Dropping the response as we don't care if it was successful or not just that it was done.
        // This will never come back to bite me right?
        if (std.Io.Dir.cwd().createDirPath(self.io(), syncDirectory)) |_| {} else |_| {}

        const database_future = std.Io.Future(downloader.DownloadError!void);
        var futures: std.ArrayList(database_future) = .empty;
        defer futures.deinit(self.allocator);

        var failed = false;
        var dict_iterator = dict.map.iterator();
        while (dict_iterator.next()) |entry| {
            const database_name = entry.key_ptr.*;
            const urls = entry.value_ptr.*;
            const future = self.io().concurrent(download_database, .{ self, database_name, urls, syncDirectory, force }) catch {
                self.download_database(database_name, urls, syncDirectory, force) catch {
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

        if (failed) return TransactionError.UpdateFetchFailed;

        for (self.sync_dbs.items) |db| {
            if (db.verify()) continue;
            const name = db.name() orelse continue;
            const db_path = std.fmt.allocPrint(self.allocator, "{s}/{s}.db", .{ syncDirectory, name }) catch continue;
            defer self.allocator.free(db_path);
            const sig_path = std.fmt.allocPrint(self.allocator, "{s}.sig", .{db_path}) catch continue;
            defer self.allocator.free(sig_path);
            std.Io.Dir.cwd().deleteFile(self.io(), db_path) catch {};
            std.Io.Dir.cwd().deleteFile(self.io(), sig_path) catch {};
            return TransactionError.SyncDbFailed;
        }
        try self.refresh();
    }

    pub fn get_installed_packages(self: *Manager) TransactionError!std.ArrayList(libalpm.Package) {
        if (self.handle == null) return TransactionError.NoHandle;
        const database = rawLibalpm.alpm_get_localdb(self.handle);
        const packages: libalpm.DatabaseList = rawLibalpm.alpm_db_get_pkgcache(database);
        var package_list: std.ArrayList(libalpm.Package) = .empty;
        var pkg_ptr = packages;
        while (pkg_ptr != null) : (pkg_ptr = pkg_ptr.?.*.next) {
            const package_ptr = pkg_ptr.?.data orelse continue;
            const package = libalpm.Package.from(package_ptr) orelse continue;
            package_list.append(self.allocator, package) catch {
                return TransactionError.PackageFetchFailed;
            };
        }
        return package_list;
    }

    pub fn get_single_installed_package(self: *Manager, package_name: [:0]const u8) TransactionError!?libalpm.Package {
        if (self.handle == null) return TransactionError.NoHandle;
        const database = rawLibalpm.alpm_get_localdb(self.handle);
        const package = rawLibalpm.alpm_db_get_pkg(database, package_name.ptr);
        if (package == null) {
            std.log.debug("Failed to find {s}", .{package_name});
            return null;
        }

        return libalpm.Package.from(package.?);
    }

    pub fn get_foreign_packages(self: *Manager) TransactionError!std.ArrayList(libalpm.Package) {
        if (self.handle == null) return TransactionError.NoHandle;

        // Foreign packages are installed packages that are not provided by any
        // registered sync database (e.g. AUR or locally built packages).
        var packages = self.get_installed_packages() catch {
            return TransactionError.PackageFetchFailed;
        };
        defer packages.deinit(self.allocator);

        var foreign_packages: std.ArrayList(libalpm.Package) = .empty;
        defer foreign_packages.deinit(self.allocator);
        errdefer foreign_packages.deinit(self.allocator);

        const sync_databases = rawLibalpm.alpm_get_syncdbs(self.handle);
        for (packages.items) |package| {
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
            if (!found_in_sync) {
                foreign_packages.append(self.allocator, package) catch {
                    return TransactionError.PackageFetchFailed;
                };
            }
        }
        if (!self.show_hidden_packages) {
            var filtered_packages: std.ArrayList(libalpm.Package) = .empty;
            errdefer filtered_packages.deinit(self.allocator);
            for (foreign_packages.items) |*package| {
                var ignored: bool = false;
                const name = package.name() orelse continue;
                for (self.config.ignore_package.items) |ignore| {
                    if (std.mem.eql(u8, name, ignore)) {
                        ignored = true;
                        break;
                    }
                }
                if (!ignored) filtered_packages.append(self.allocator, package.*) catch return TransactionError.PackageFetchFailed;
            }
            return filtered_packages;
        }
        return foreign_packages;
    }

    pub fn get_available_packages(self: *Manager) TransactionError!std.ArrayList(libalpm.Package) {
        if (self.handle == null) return TransactionError.NoHandle;
        var packages: std.ArrayList(libalpm.Package) = .empty;
        errdefer packages.deinit(self.allocator);

        var sync_database: libalpm.DatabaseList = rawLibalpm.alpm_get_syncdbs(self.handle);
        while (sync_database != null) : (sync_database = sync_database.?.*.next) {
            const db_data = sync_database.?.*.data orelse continue;
            const database = libalpm.Database.from(db_data) orelse continue;
            var tempPackages = database.packages();
            while (tempPackages.next()) |pkg| {
                packages.append(self.allocator, pkg) catch {
                    return TransactionError.PackageFetchFailed;
                };
            }
        }
        return packages;
    }

    pub fn get_updates_available(self: *Manager) TransactionError!std.ArrayList(libalpm.PackageWithUpdate) {
        if (self.handle == null) return TransactionError.NoHandle;
        var package_updates: std.ArrayList(libalpm.PackageWithUpdate) = .empty;
        defer package_updates.deinit(self.allocator);
        const sync_databases = rawLibalpm.alpm_get_syncdbs(self.handle);
        const local_packages = self.get_installed_packages() catch {
            return TransactionError.PackageFetchFailed;
        };
        for (local_packages.items) |local_pkg| {
            const new_version = rawLibalpm.alpm_sync_get_new_version(local_pkg.ptr, sync_databases) orelse continue;
            package_updates.append(self.allocator, .{
                .old_package = .{ .ptr = local_pkg.ptr },
                .new_package = .{ .ptr = new_version },
            }) catch {
                return TransactionError.PackageFetchFailed;
            };
        }
        return package_updates;
    }

    pub fn install_packages(
        self: *Manager,
        package_names: [][:0]const u8,
        trans_flags_arg: TransFlag,
    ) TransactionError!bool {
        if (self.handle == null) return TransactionError.NoHandle;
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
                var node = sync_databases;
                var found_any = false;
                while (node != null) : (node = node.*.next) {
                    const db_data: ?*anyopaque = node.*.data;
                    const db_ptr: *rawLibalpm.alpm_db_t = @ptrCast(@alignCast(db_data orelse continue));
                    if (rawLibalpm.alpm_db_get_pkg(db_ptr, target.ptr)) |pkg| {
                        try packages.append(self.allocator, pkg);
                        found_any = true;
                        break;
                    }
                    if (rawLibalpm.alpm_db_get_group(db_ptr, target.ptr)) |group| {
                        var pkg_node = group.*.packages;
                        while (pkg_node != null) : (pkg_node = pkg_node.*.next) {
                            const pkg_data: ?*anyopaque = pkg_node.*.data;
                            const pkg: *rawLibalpm.alpm_pkg_t = @ptrCast(@alignCast(pkg_data orelse continue));
                            try packages.append(self.allocator, pkg);
                        }
                        found_any = true;
                        break;
                    }
                    if (rawLibalpm.alpm_find_satisfier(rawLibalpm.alpm_db_get_pkgcache(db_ptr), target.ptr)) |pkg| {
                        try packages.append(self.allocator, pkg);
                        found_any = true;
                        break;
                    }
                }
                if (!found_any) return TransactionError.PackageFetchFailed;
            }
        }
        if (packages.items.len == 0) return TransactionError.PackageFetchFailed;

        // Ask once per package. The event response's `pkg` is the selected optional
        // dependency; callers may answer repeatedly as each package is inspected.
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
            if (options.items.len == 0 or self.dispatcher.question.items.len == 0) continue;
            const pkg_name = libalpm.str(rawLibalpm.alpm_pkg_get_name(pkg)) orelse "package";
            const prompt = try std.fmt.allocPrint(self.allocator, "Select an optional dependency for {s}", .{pkg_name});
            defer self.allocator.free(prompt);
            const response = self.dispatcher.raiseQuestion(self.io(), .{
                .question = prompt,
                .question_type = @intFromEnum(libalpm.QuestionType.select_optional_dependencies),
                .options = names.items,
                .provider_options = options.items,
            });
            const selected = response.pkg orelse continue;
            const selected_z = try self.allocator.dupeZ(u8, selected);
            defer self.allocator.free(selected_z);
            if (rawLibalpm.alpm_find_satisfier(rawLibalpm.alpm_db_get_pkgcache(rawLibalpm.alpm_get_localdb(self.handle)), selected_z.ptr) != null) continue;
            var node = sync_databases;
            while (node != null) : (node = node.*.next) {
                const db_data: ?*anyopaque = node.*.data;
                const db_ptr: *rawLibalpm.alpm_db_t = @ptrCast(@alignCast(db_data orelse continue));
                const selected_pkg = rawLibalpm.alpm_find_satisfier(rawLibalpm.alpm_db_get_pkgcache(db_ptr), selected_z.ptr) orelse continue;
                try packages.append(self.allocator, selected_pkg);
                if (libalpm.str(rawLibalpm.alpm_pkg_get_name(selected_pkg))) |resolved_name|
                    try optional_names.append(self.allocator, resolved_name);
                break;
            }
        }

        // Starts transaction impleentation
        var trans_flags = trans_flags_arg.to_trans_flag();
        if (trans_flags_arg == .dbonly) trans_flags |= TransFlag.nodeps.to_trans_flag();
        if (rawLibalpm.alpm_trans_init(self.handle, @bitCast(trans_flags)) != 0) return TransactionError.TransInitFailed;
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
        if (rawLibalpm.alpm_trans_commit(self.handle, &data) != 0) {
            self.handleErrorMessage(@intCast(rawLibalpm.alpm_errno(self.handle)), data) catch {};
            return TransactionError.CommitFailed;
        }
        const local_db = rawLibalpm.alpm_get_localdb(self.handle);
        for (optional_names.items) |name| {
            const installed = rawLibalpm.alpm_db_get_pkg(local_db, name.ptr) orelse continue;
            _ = rawLibalpm.alpm_pkg_set_reason(installed, rawLibalpm.ALPM_PKG_REASON_DEPEND);
        }
        return true;
    }

    pub fn remove_packages(self: *Manager, packages_names: [][:0]const u8, flags: TransFlag, keep_optional_dependencis: bool) TransactionError!bool {
        if (self.handle == null) return TransactionError.NoHandle;
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
                        self.dispatcher.raiseError(.{ .message = "Failed to find package" });
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
                    // looks for local package continues on if failes to find.
                    const local_ptr = rawLibalpm.alpm_db_get_pkg(local_db, dep_name.ptr) orelse {
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
                        _ = rawLibalpm.alpm_db_get_pkg(local_db, package_name.ptr) orelse {
                            // continuing on as this package is not installed and we can ignore.
                            continue;
                        };
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

        var trans_flags = flags.to_trans_flag();
        if (TransFlag.contains(trans_flags, .dbonly)) trans_flags |= TransFlag.nodeps.to_trans_flag();

        if (rawLibalpm.alpm_trans_init(self.handle, @bitCast(trans_flags)) != 0) return TransactionError.TransInitFailed;
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
        return true;
    }

    pub fn sync_system_update(self: *Manager, flags: TransFlag) TransactionError!bool {
        if (self.handle == null) return TransactionError.NoHandle;

        // This is first before updating so it can bail before database is downloaded
        if (self.is_cachyos) {
            const update_notice = cachyos.UpdateNotice.init(self.allocator, self.io());
            if (!update_notice.check(self.environ, &self.dispatcher)) return false;
        }
        self.sync(true) orelse return TransactionError.SyncDbFailed;

        self.package_download = true;

        if (TransFlag.contains(flags, .dbonly)) {
            flags |= TransFlag.nodeps;
        }

        if (rawLibalpm.alpm_trans_init(self.handle, @bitCast(flags.to_trans_flag())) != 0) {
            return TransactionError.TransInitFailed;
        }
        defer _ = rawLibalpm.alpm_trans_release(self.handle);

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

        if (!TransFlag.contains(flags, .dbonly)) {
            try self.download_prepared_packages();
        }

        data = null;
        if (rawLibalpm.alpm_trans_commit(self.handle, &data) != 0) {
            self.handleErrorMessage(@intCast(rawLibalpm.alpm_errno(self.handle)), data) catch {
                // Abandon hope all yee who enter here
            };
            return TransactionError.CommitFailed;
        }
        return true;
    }

    pub fn update_package_reason(self: *Manager, pkg_name: [:0]const u8, reason: libalpm.PackageReason) TransactionError!void {
        if (self.handle == null) return TransactionError.NoHandle;
        const local_database = rawLibalpm.alpm_get_localdb(self.handle) orelse return TransactionError.DatabaseReadFailed;
        const pkg = rawLibalpm.alpm_db_get_pkg(local_database, pkg_name) orelse return TransactionError.PackageFetchFailed;
        if (rawLibalpm.alpm_pkg_set_reason(pkg, @intCast(@intFromEnum(reason))) != 0) return TransactionError.SetReasonFailed;
    }

    pub fn install_local_packages(self: *Manager, paths: [][]const u8, flags: TransFlag) TransactionError!void {
        if (self.handle == null) return TransactionError.NoHandle;
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

        data = null;
        if (rawLibalpm.alpm_trans_commit(self.handle, &data) != 0) {
            self.handleErrorMessage(@intCast(rawLibalpm.alpm_errno(self.handle)), data) catch {
                // Abandon hope all yee who enter here
            };
            return TransactionError.CommitFailed;
        }
    }

    pub fn get_package_from_provides(self: *Manager, provides: [:0]const u8) QueryError![:0]const u8 {
        if (self.handle == null) return QueryError.NoHandle;
        const sync_dbs = rawLibalpm.alpm_get_syncdbs(self.handle);
        while (sync_dbs != null) : (sync_dbs = sync_dbs.*.next) {
            const db_ptr = sync_dbs.*.data orelse continue;
            const db: libalpm.Database = libalpm.Database.from(db_ptr) orelse continue;
            const pkg_cache = db.package_cache();
            const satisfier = rawLibalpm.alpm_find_satisfier(pkg_cache, provides.ptr) orelse continue;
            const pkg = libalpm.Package.from(satisfier) orelse continue;
            return pkg.name();
        }
    }

    pub fn is_dependency_satisfied_by_installed_packages(self: *Manager, dependency: [:0]const u8) QueryError!bool {
        if (self.handle == null) return QueryError.NoHandle;
        const local_db = rawLibalpm.alpm_get_localdb(self.handle);
        const db = libalpm.Database.from(local_db) orelse return QueryError.DbNotFound;
        _ = rawLibalpm.alpm_find_satisfier(db.package_cache(), dependency) orelse return false;
        return true;
    }

    pub fn find_remote_satisfier_for_dependency(self: *Manager, dependency: [:0]const u8) QueryError![:0]const u8 {
        _ = self;
        _ = dependency;
        return "";
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
            if (rawLibalpm.alpm_db_get_pkg(db, pkg_name.ptr) != null) return true;
            if (rawLibalpm.alpm_db_get_group(db, pkg_name.ptr) != null) return true;
            if (rawLibalpm.alpm_find_satisfier(rawLibalpm.alpm_db_get_pkgcache(db), pkg_name.ptr) != null) return true;
        }
        return false;
    }

    fn refresh(self: *Manager) TransactionError!void {
        if (self.handle != null) {
            const refresh_result = rawLibalpm.alpm_release(self.handle);
            if (refresh_result != 0) {
                return TransactionError.RefreshFailed;
            }
        }

        self.sync_dbs.clearRetainingCapacity();

        var err2: rawLibalpm.alpm_errno_t = 0;
        self.handle = rawLibalpm.alpm_initialize(self.config.root_directory, self.config.database_path, &err2);
        if (self.handle == null) {
            return TransactionError.RefreshFailed;
        }

        self.applyConfig(self.config, self.is_root);
        self.setupCallbacks();
    }

    fn download_database(self: *Manager, database_name: []const u8, urls: std.ArrayList([]const u8), sync_directory: []const u8, force_download: bool) downloader.DownloadError!void {
        const download_config: downloader.DownloadConfiguration = .{ .user_agent = "Shelly-ALPM/3" };
        var downloader_instance = downloader.CoreDownloader.init(self.allocator, self.io(), download_config);
        defer downloader_instance.deinit();
        downloader_instance.setEventCallback(onDownloadEvent, self);
        const dest = std.fmt.allocPrint(self.allocator, "{s}/{s}.db", .{ sync_directory, database_name }) catch return;
        defer self.allocator.free(dest);
        const sig_dest = std.fmt.allocPrint(self.allocator, "{s}.sig", .{dest}) catch return;
        defer self.allocator.free(sig_dest);

        for (urls.items) |url_base| {
            const db_url = std.fmt.allocPrint(self.allocator, "{s}/{s}.db", .{ url_base, database_name }) catch continue;
            defer self.allocator.free(db_url);

            switch (downloader_instance.downloadToFile(db_url, dest, force_download)) {
                .succes, .skipped => {
                    const sig_url = std.fmt.allocPrint(self.allocator, "{s}.sig", .{db_url}) catch return;
                    defer self.allocator.free(sig_url);
                    // The database signature is best-effort and optional: many
                    // repositories (e.g. Arch's) do not sign databases, so a
                    // missing signature must not be surfaced as an error.
                    downloader_instance.quiet = true;
                    _ = downloader_instance.downloadToFile(sig_url, sig_dest, force_download);
                    downloader_instance.quiet = false;
                    return;
                },
                .failure => continue,
            }
        }
        return downloader.DownloadError.FailedDownload;
    }

    fn download_prepared_packages(self: *Manager) TransactionError!void {
        const download_future = std.Io.Future(downloader.DownloadError!void);

        var futures: std.ArrayList(download_future) = .empty;
        defer futures.deinit(self.allocator);

        var failed = false;
        var packages = rawLibalpm.alpm_trans_get_add(self.handle);

        while (packages != null) : (packages = packages.*.next) {
            const data = packages.*.data orelse continue;
            const package = libalpm.Package{ .ptr = @ptrCast(@alignCast(data)) };

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
        const download_config: downloader.DownloadConfiguration = .{ .user_agent = "Shelly-ALPM/3" };
        var downloader_instance = downloader.CoreDownloader.init(self.allocator, self.io(), download_config);
        defer downloader_instance.deinit();
        downloader_instance.setEventCallback(onDownloadEvent, self);
        const dest = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.config.cache_directory, package.file_name() }) catch return;
        defer self.allocator.free(dest);
        const sig_dest = std.fmt.allocPrint(self.allocator, "{s}.sig", .{dest}) catch return;

        const urls = database.servers();
        for (urls) |url| {
            const file_url = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ url, package.file_name() }) catch return downloader.DownloadError.InvalidUrl;
            defer self.allocator.free(file_url);

            switch (downloader_instance.downloadToFile(file_url, dest, true)) {
                .succes => {
                    const sig_url = std.fmt.allocPrint(self.allocator, "{s}.sig", .{file_url}) catch return downloader.DownloadError.InvalidUrl;
                    defer self.allocator.free(sig_url);
                    downloader_instance.quiet = true;
                    _ = downloader_instance.downloadToFile(sig_url, sig_dest, true);
                    downloader_instance.quiet = false;
                    return;
                },
                .failure, .skipped => continue,
            }
        }
        return downloader.DownloadError.FailedDownload;
    }

    pub fn io(self: *Manager) std.Io {
        return self.threaded.io();
    }

    pub fn deinit(self: *Manager) void {
        const allocator = self.allocator;
        if (self.handle) |h| _ = libalpm.alpm.alpm_release(h);
        self.handle = null;
        self.is_initialized = false;
        self.sync_dbs.deinit(self.allocator);
        self.config.deinitialize();
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

    fn applyConfig(self: *Manager, config: configuration.Configuration.Config, root: bool) void {
        const h = self.handle;

        for (config.ignore_package.items) |pkg_name| {
            self.check("ignore_package", rawLibalpm.alpm_option_add_ignorepkg(h, pkg_name.ptr));
        }

        for (config.ignore_group.items) |group_name| {
            self.check("ignore_group", rawLibalpm.alpm_option_add_ignoregroup(h, group_name.ptr));
        }

        for (config.hook_directory.items) |hook_dir| {
            self.check("hook_directory", rawLibalpm.alpm_option_add_hookdir(h, hook_dir.ptr));
        }

        if (root and config.gpg_directory.len != 0) {
            self.check("gpgdir", rawLibalpm.alpm_option_set_gpgdir(h, config.gpg_directory.ptr));
        }

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
        const use_default: u32 = @intFromEnum(libalpm.SigLevel.use_default);
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

    // Matches libalpm's `alpm_cb_fetch`: receives C strings and an int flag and
    // returns 0 (downloaded), 1 (already up to date), or -1 (error).
    fn fetchCallback(
        ctx: ?*anyopaque,
        url: [*c]const u8,
        local_path: [*c]const u8,
        force: c_int,
    ) callconv(.c) c_int {
        const self: *Manager = @ptrCast(@alignCast(ctx));

        // libalpm may hand us null pointers; treat that as a hard error.
        if (url == null or local_path == null) return -1;
        const url_slice = std.mem.span(url);
        const local_slice = std.mem.span(local_path);

        const download_config: downloader.DownloadConfiguration = .{ .user_agent = "Shelly-ALPM/3" };
        var downloader_instance = downloader.CoreDownloader.init(self.allocator, self.io(), download_config);
        defer downloader_instance.deinit();

        downloader_instance.setEventCallback(onDownloadEvent, self);
        switch (downloader_instance.downloadToFile(url_slice, local_slice, force != 0)) {
            .succes => |succ| {
                self.dispatcher.raiseInformational(.{ .event_type = .pkg_retrieve_done, .message = succ.destination_path });
                return 0;
            },
            .skipped => |skip| {
                self.dispatcher.raiseInformational(.{ .event_type = .pkg_retrieve_done, .message = skip.destination_path });
                return 1;
            },
            .failure => |err| {
                self.dispatcher.raiseError(.{ .message = @errorName(err) });
                return -1;
            },
        }
    }

    fn onDownloadEvent(ctx: ?*anyopaque, event: downloader.DownloadEvent) void {
        const self: *Manager = @ptrCast(@alignCast(ctx));
        const path = event.destination_path orelse "";
        switch (event.event_type) {
            .Start => self.dispatcher.raiseInformational(.{
                .event_type = .pkg_retrieve_start,
                .message = path,
            }),
            .Progress => if (event.progress) |p| self.dispatcher.raiseProgress(.{
                .progress_type = @intCast(rawLibalpm.ALPM_PROGRESS_ADD_START), // pick an appropriate alpm_progress_t
                .pkg_name = std.fs.path.basename(path),
                .percent = p.percent,
                .howmany = 1,
                .current = 1,
            }),
            .Complete => self.dispatcher.raiseInformational(.{
                .event_type = .pkg_retrieve_done,
                .message = path,
            }),
            .Error => self.dispatcher.raiseError(.{
                .message = if (event.download_error) |e| @errorName(e) else "download failed",
            }),
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
        if (event == null) return;

        const self: *Manager = @ptrCast(@alignCast(ctx));
        const type_value: u32 = @intCast(event.*.type);
        if (type_value < rawLibalpm.ALPM_EVENT_CHECKDEPS_START or type_value > rawLibalpm.ALPM_EVENT_HOOK_RUN_DONE) return;

        const event_type = libalpm.EventType.from_libalpm(@intCast(type_value));
        switch (event_type) {
            .scriptlet_info => {
                const line = spanC(event.*.scriptlet_info.line) orelse return;
                if (line.len != 0) self.dispatcher.raiseScriptlet(.{ .line = line });
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
            .package_operation_start => "Starting package operation...",
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
            .BadPerms => try details.appendSlice(self.allocator, "Bad permissions.\n"),
            .NotAFile => try details.appendSlice(self.allocator, "Expected a file, did not receive a file. How did you mess this up?\n"),
            .NotADir => try details.appendSlice(self.allocator, "Expected a directory, did not receive a directory. I'm sorry what?\n"),
            .WrongArgs => try details.appendSlice(self.allocator, "Wrong or NULL arguments\n"),
            .DiskSpace => try details.appendSlice(self.allocator, "Not enough disk space\n Why is your disk so small?\n"),
            .HandleNull => try details.appendSlice(self.allocator, "Lost the handle. Kinda like a plot but more important.\n"),
            .HandleNotNull => try details.appendSlice(self.allocator, "Handle is not null. Normally you would want this but at this point I'm unsure.\n"),
            .HandleLock => try details.appendSlice(self.allocator, "You have a db.lck. It's at /var/lib/pacman/db.lck. You should probably delete that.\n"),
            .DbOpen => try details.appendSlice(self.allocator, "Failed to open the database.\n"),
            .DbCreate => try details.appendSlice(self.allocator, "Failed to create the database.\n"),
            .DbNull => try details.appendSlice(self.allocator, "Database is null.\n"),
            .DbNotNull => try details.appendSlice(self.allocator, "Database is not null.\n"),
            .DbNotFound => try details.appendSlice(self.allocator, "Database not found.\n"),
            .DbInvalid => try details.appendSlice(self.allocator, "Database is invalid.\n"),
            .DbInvalidSig => try details.appendSlice(self.allocator, "Database signature is invalid.\n"),
            .DbVersion => try details.appendSlice(self.allocator, "Database version is invalid.\n"),
            .DbWrite => try details.appendSlice(self.allocator, "Failed to write to the database.\n"),
            .DbRemove => try details.appendSlice(self.allocator, "Failed to remove the database.\n"),
            .ServerBadUrl => try details.appendSlice(self.allocator, "Server URL is invalid.\n"),
            .ServerNone => try details.appendSlice(self.allocator, "No server found.\n"),
            .TransNotNull => try details.appendSlice(self.allocator, "Transaction is not null.\n"),
            .TransNull => try details.appendSlice(self.allocator, "Transaction is null.\n"),
            .TransDupTarget => try details.appendSlice(self.allocator, "Transaction target is duplicated.\n"),
            .TransDupFilename => try details.appendSlice(self.allocator, "Transaction filename is duplicated.\n"),
            .TransNotInitialized => try details.appendSlice(self.allocator, "Transaction is not initialized.\n"),
            .TransNotPrepared => try details.appendSlice(self.allocator, "Transaction is not prepared.\n"),
            .TransAbort => try details.appendSlice(self.allocator, "Transaction aborted.\n"),
            .TransType => try details.appendSlice(self.allocator, "Transaction type is invalid.\n"),
            .TransNotLocked => try details.appendSlice(self.allocator, "Transaction is not locked.\n"),
            .TransHookFailed => try details.appendSlice(self.allocator, "Transaction hook failed.\n"),
            .PkgNotFound => try details.appendSlice(self.allocator, "Package not found.\n"),
            .PkgIgnored => try details.appendSlice(self.allocator, "Package ignored.\n"),
            .PkgInvalid => try details.appendSlice(self.allocator, "Package is invalid.\n"),
            .PkgInvalidChecksum => try details.appendSlice(self.allocator, "Package checksum is invalid.\n"),
            .PkgInvalidSig => try details.appendSlice(self.allocator, "Package signature is invalid.\n"),
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
            .SigInvalid => try details.appendSlice(self.allocator, "Signature is invalid.\n"),
            .UnsatisfiedDeps => {
                var node = data_ptr;
                while (node != null) : (node = node.?.next) {
                    const data = node.?.data orelse continue;
                    const miss: *rawLibalpm.alpm_depmissing_t = @ptrCast(@alignCast(data));
                    const target = spanC(miss.target) orelse "unknown";
                    const dep_str = rawLibalpm.alpm_dep_compute_string(miss.depend);
                    defer if (dep_str != null) std.c.free(dep_str);
                    try details.print(self.allocator, "{s} => {s}\n", .{ target, std.mem.span(dep_str) });
                }
            },
            .ConflictingDeps => {
                var node = data_ptr;
                while (node != null) : (node = node.?.next) {
                    const data = node.?.data orelse continue;
                    const conflict = bindings.libalpm.PackageConflict.from(data) orelse continue;
                    const pkg1_name = conflict.packageOne().name() orelse "unknown";
                    const pkg2_name = conflict.packageTwo().name() orelse "unknown";
                    if (conflict.ptr.reason) |rp| {
                        const computed = rawLibalpm.alpm_dep_compute_string(rp);
                        defer if (computed != null) std.c.free(computed);
                        try details.print(self.allocator, "{s} conflicts with {s} because of {s}\n", .{ pkg1_name, pkg2_name, std.mem.span(computed) });
                    } else {
                        try details.print(self.allocator, "{s} conflicts with {s}\n", .{ pkg1_name, pkg2_name });
                    }
                }
            },
            .FileConflicts => {
                var node = data_ptr;
                while (node != null) : (node = node.?.next) {
                    const data = node.?.data orelse continue;
                    const fc: *rawLibalpm.alpm_fileconflict_t = @ptrCast(@alignCast(data));
                    const target = spanC(fc.target) orelse "unknown";
                    const file = spanC(fc.file) orelse "";
                    try details.print(self.allocator, "{s} in file {s}\n", .{ target, file });
                }
            },
            .DownloadFailed => try details.appendSlice(self.allocator, "Download failed.\n"),
            .Gpgme => try details.appendSlice(self.allocator, "Gpgme error.\n"),
            .ExternalDownload => try details.appendSlice(self.allocator, "External download failed.\n"),
            .SandboxFailed => try details.appendSlice(self.allocator, "Sandbox failed.\n"),
        }

        const full_error = try std.fmt.allocPrint(self.allocator, "{s}\n{s}", .{ error_msg, details.items });
        defer self.allocator.free(full_error);
        self.dispatcher.raiseError(.{ .message = full_error });
    }

    fn spanC(ptr: [*c]const u8) ?[]const u8 {
        if (ptr == null) return null;
        return std.mem.span(ptr);
    }
};

const testing = std.testing;

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

    mgr.handleInformationMessage(.scriptlet_info);

    try testing.expect(cap.args == null);
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

// ---------------------------------------------------------------------------
// handleErrorMessage
// ---------------------------------------------------------------------------

fn newErrorManager() Manager {
    var mgr: Manager = undefined;
    mgr.allocator = testing.allocator;
    mgr.dispatcher = events.Dispatcher.init(testing.allocator);
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
};

fn captureInfo(data: ?*anyopaque, args: events.InformationalArgs) void {
    const cap: *InfoCapture = @ptrCast(@alignCast(data));
    cap.args = args;
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

    fn text(self: *const ErrorCapture) []const u8 {
        return self.buf[0..self.len];
    }
};

fn captureError(data: ?*anyopaque, args: events.ErrorArgs) void {
    const cap: *ErrorCapture = @ptrCast(@alignCast(data));
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
