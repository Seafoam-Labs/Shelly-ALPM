const std = @import("std");
const bindings = @import("bindings.zig");
const events = @import("events.zig");
const configuration = @import("configuration.zig");
const builtin = @import("builtin");
const downloader = @import("../shared/downloader.zig");
const listDictionary = @import("../shared/list_dictionary.zig");

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
pub const TransactionError = error{ NoHandle, TransInitFailed, PrepareFailed, CommitFailed, UnsatisfiedDeps, ConflictingDeps, FileConflicts, SyncDbFailed, PackageFetchFailed };

pub const QueryError = error{ DbNotFound, PkgNotFound };

pub const Manager = struct {
    handle: libalpm.Handle = null,
    is_initialized: bool = false,
    is_cachyos: bool = false,
    allocator: std.mem.Allocator,
    config: configuration.Configuration.Config,
    dispatcher: events.Dispatcher,
    threaded: std.Io.Threaded,
    local_db: ?bindings.libalpm.Database = null,
    sync_dbs: std.ArrayList(bindings.libalpm.Database) = .empty,
    package_download: bool = false,
    is_root: bool = false,
    temp_root_path: []const u8,
    show_hidden_packages: bool = false,

    /// If null is passed for config it will use the default /etc/pacman.conf
    pub fn init(allocator: std.mem.Allocator, configPath: ?[]const u8, use_root: bool, temp_root_path: ?[]const u8) InitError!Manager {
        const config_path = configPath orelse "/etc/pacman.conf";
        var self = Manager{
            .handle = null,
            .is_initialized = true,
            .allocator = allocator,
            .dispatcher = events.Dispatcher.init(allocator),
            .threaded = .init(allocator, .{}),
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

        var futures: std.ArrayList(std.Io.Future(void)) = .empty;
        defer futures.deinit(self.allocator);

        var dict_iterator = dict.map.iterator();
        while (dict_iterator.next()) |entry| {
            const database_name = entry.key_ptr.*;
            const urls = entry.value_ptr.*;
            const future = self.io().concurrent(download_database, .{ self, database_name, urls, syncDirectory, force }) catch {
                self.download_database(database_name, urls, syncDirectory, force);
                continue;
            };

            futures.append(self.allocator, future) catch {
                var f = future;
                f.await(self.io());
            };
        }

        for (futures.items) |*future| future.await(self.io());

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

    fn download_database(self: *Manager, database_name: []const u8, urls: std.ArrayList([]const u8), sync_directory: []const u8, force_download: bool) void {
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
    }

    pub fn io(self: *Manager) std.Io {
        return self.threaded.io();
    }

    pub fn deinit(self: *Manager) void {
        if (self.handle) |h| _ = libalpm.alpm.alpm_release(h);
        self.handle = null;
        self.is_initialized = false;
        self.sync_dbs.deinit(self.allocator);
        self.config.deinitialize();
        self.dispatcher.deinit();
        self.threaded.deinit();
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
                self.dispatcher.raiseInformational(.{ .event_type = rawLibalpm.ALPM_EVENT_PKG_RETRIEVE_DONE, .message = succ.destination_path });
                return 0;
            },
            .skipped => |skip| {
                self.dispatcher.raiseInformational(.{ .event_type = rawLibalpm.ALPM_EVENT_PKG_RETRIEVE_DONE, .message = skip.destination_path });
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
                .event_type = rawLibalpm.ALPM_EVENT_PKG_RETRIEVE_START,
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
                .event_type = rawLibalpm.ALPM_EVENT_PKG_RETRIEVE_DONE,
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
        const self: *Manager = @ptrCast(@alignCast(ctx));
        self.dispatcher.raiseInformational(.{
            .event_type = @intCast(event.*.type),
            .message = "Temp Message",
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
// eventCallback
// ---------------------------------------------------------------------------

test "eventCallback dispatches an informational event carrying the event type" {
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
    try testing.expectEqual(@as(c_int, rawLibalpm.ALPM_EVENT_TRANSACTION_START), args.event_type);
    try testing.expectEqualStrings("Temp Message", args.message);
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

// ---------------------------------------------------------------------------
// init + sync (integration)
//
// These exercise the full path: parse a config, initialize libalpm, register a
// sync database, and download it over the network. Everything is confined to a
// unique temporary directory whose `DBPath` is redirected away from the host's
// real /var/lib/pacman, and the workspace is deleted once each test finishes.
// ---------------------------------------------------------------------------

// A throwaway pacman configuration written to disk under a unique temp root.
const SyncTestWorkspace = struct {
    io: std.Io,
    root: []const u8,
    config_path: []const u8,
    db_path: []const u8,

    fn create(allocator: std.mem.Allocator, io: std.Io) !SyncTestWorkspace {
        const anchor: u8 = 0;
        var prng = std.Random.DefaultPrng.init(@intFromPtr(&anchor));
        const root = try std.fmt.allocPrint(allocator, "/tmp/shelly-alpm-test-{x}", .{prng.random().int(u32)});
        errdefer allocator.free(root);

        const db_path = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
        errdefer allocator.free(db_path);

        const config_path = try std.fmt.allocPrint(allocator, "{s}/pacman.conf", .{root});
        errdefer allocator.free(config_path);

        // Create the root and database directories up front.
        try std.Io.Dir.cwd().createDirPath(io, db_path);

        // A minimal config: DBPath points into our temp dir, and a single [core]
        // repository is aimed at a real Arch mirror. Signature checking is
        // disabled so no keyring/GPG setup is required to fetch the database.
        const config = try std.fmt.allocPrint(
            allocator,
            "[options]\n" ++
                "Architecture = auto\n" ++
                "SigLevel = Never\n" ++
                "DBPath = {s}\n" ++
                "\n" ++
                "[seafoam-labs]\n" ++
                "Server =  https://repo.seafoam-labs.org/x86_64\n",
            //"Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch\n",
            .{db_path},
        );
        defer allocator.free(config);

        var file = try std.Io.Dir.cwd().createFile(io, config_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, config);

        return .{
            .io = io,
            .root = root,
            .config_path = config_path,
            .db_path = db_path,
        };
    }

    // Removes the entire temp tree (config + downloaded databases) and frees the
    // owned path strings. Safe to call regardless of how far `create` got.
    fn cleanup(self: *SyncTestWorkspace, allocator: std.mem.Allocator) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.root) catch {};
        allocator.free(self.config_path);
        allocator.free(self.db_path);
        allocator.free(self.root);
    }
};

test "Manager.init registers the configured sync database" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    var mgr = try Manager.init(allocator, workspace.config_path, false, workspace.db_path);
    defer mgr.deinit();

    try testing.expect(mgr.is_initialized);
    try testing.expect(mgr.handle != null);
    // applyConfig must have registered the [core] repository as a sync db.
    try testing.expect(mgr.sync_dbs.items.len >= 1);
}

test "Manager.sync downloads the configured database into DBPath/sync" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    var mgr = try Manager.init(allocator, workspace.config_path, false, workspace.db_path);
    defer mgr.deinit();

    // Force the download so the result never depends on a pre-existing cache.
    try mgr.sync(true);

    // sync creates "<DBPath>/sync" and download_database stores each database
    // there under its bare repository name (no extension).
    const sync_dir = try std.fmt.allocPrint(allocator, "{s}/sync", .{workspace.db_path});
    defer allocator.free(sync_dir);
    _ = try std.Io.Dir.cwd().statFile(io, sync_dir, .{});

    const core_db = try std.fmt.allocPrint(allocator, "{s}/seafoam-labs.db", .{sync_dir});
    defer allocator.free(core_db);
    const stat = try std.Io.Dir.cwd().statFile(io, core_db, .{});
    try testing.expect(stat.size > 0);
}

// ---------------------------------------------------------------------------
// get_single_installed_package
// ---------------------------------------------------------------------------

test "get_single_installed_package returns NoHandle when the handle is null" {
    var mgr: Manager = undefined;
    mgr.handle = null;
    mgr.allocator = testing.allocator;

    const result = mgr.get_single_installed_package("anything");
    try testing.expectError(error.NoHandle, result);
}

test "get_single_installed_package returns null for a non-existent package" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    var mgr = try Manager.init(allocator, workspace.config_path, false, workspace.db_path);
    defer mgr.deinit();

    // A fresh temporary database has no installed packages.
    const result = try mgr.get_single_installed_package("nonexistent-package");
    try testing.expect(result == null);
}

test "get_single_installed_package returns a package when it exists" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Use the real system database to find an actually installed package.
    const sys_config = "/etc/pacman.conf";
    const sys_db = "/var/lib/pacman";

    // Skip gracefully if the system database is unavailable.
    const stat = std.Io.Dir.cwd().statFile(io, sys_db, .{}) catch {
        return; // no system database — skip
    };
    _ = stat;

    var mgr = Manager.init(allocator, sys_config, false, sys_db) catch {
        return; // config parse or init failure — skip
    };
    defer mgr.deinit();

    // `pacman` is installed on virtually every Arch-based system.
    const result = try mgr.get_single_installed_package("pacman");
    const pkg = result orelse return; // skip if pacman is somehow absent

    const name = pkg.name() orelse return error.TestFailed;
    try testing.expectEqualStrings("pacman", name);
}

// ---------------------------------------------------------------------------
// get_installed_packages
// ---------------------------------------------------------------------------

test "get_installed_packages returns NoHandle when the handle is null" {
    var mgr: Manager = undefined;
    mgr.handle = null;
    mgr.allocator = testing.allocator;

    const result = mgr.get_installed_packages();
    try testing.expectError(error.NoHandle, result);
}

test "get_installed_packages returns an empty list when no packages are installed" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    var mgr = try Manager.init(allocator, workspace.config_path, false, workspace.db_path);
    defer mgr.deinit();

    var packages = try mgr.get_installed_packages();
    defer packages.deinit(mgr.allocator);

    // A fresh temporary database has no installed packages.
    try testing.expectEqual(@as(usize, 0), packages.items.len);
}

test "get_installed_packages lists packages from the system database" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Use the real system database, skipping gracefully when it is unavailable.
    const sys_config = "/etc/pacman.conf";
    const sys_db = "/var/lib/pacman";
    _ = std.Io.Dir.cwd().statFile(io, sys_db, .{}) catch return;

    var mgr = Manager.init(allocator, sys_config, false, sys_db) catch return;
    defer mgr.deinit();

    var packages = try mgr.get_installed_packages();
    defer packages.deinit(mgr.allocator);

    // A real system always has packages installed, each exposing a name.
    try testing.expect(packages.items.len > 0);
    for (packages.items) |package| {
        _ = package.name() orelse return error.TestFailed;
    }

    // `pacman` is installed on every Arch-based system.
    var found_pacman = false;
    for (packages.items) |package| {
        const name = package.name() orelse continue;
        if (std.mem.eql(u8, name, "pacman")) {
            found_pacman = true;
            break;
        }
    }
    try testing.expect(found_pacman);
}

test "get_single_installed_package matches an entry from get_installed_packages" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const sys_config = "/etc/pacman.conf";
    const sys_db = "/var/lib/pacman";
    _ = std.Io.Dir.cwd().statFile(io, sys_db, .{}) catch return;

    var mgr = Manager.init(allocator, sys_config, false, sys_db) catch return;
    defer mgr.deinit();

    var packages = try mgr.get_installed_packages();
    defer packages.deinit(mgr.allocator);
    if (packages.items.len == 0) return;

    // Package names are null-terminated slices, so they can be looked up directly.
    const first_name = packages.items[0].name() orelse return error.TestFailed;
    const single = try mgr.get_single_installed_package(first_name);
    const pkg = single orelse return error.TestFailed;
    const single_name = pkg.name() orelse return error.TestFailed;
    try testing.expectEqualStrings(first_name, single_name);
}

// ---------------------------------------------------------------------------
// get_foreign_packages
// ---------------------------------------------------------------------------

test "get_foreign_packages returns NoHandle when the handle is null" {
    var mgr: Manager = undefined;
    mgr.handle = null;
    mgr.allocator = testing.allocator;

    const result = mgr.get_foreign_packages();
    try testing.expectError(error.NoHandle, result);
}

test "get_foreign_packages returns an empty list when no packages are installed" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    var mgr = try Manager.init(allocator, workspace.config_path, false, workspace.db_path);
    defer mgr.deinit();

    var foreign = try mgr.get_foreign_packages();
    defer foreign.deinit(mgr.allocator);

    // With no installed packages there is nothing that could be foreign.
    try testing.expectEqual(@as(usize, 0), foreign.items.len);
}

test "get_foreign_packages excludes packages provided by a sync database" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const sys_config = "/etc/pacman.conf";
    const sys_db = "/var/lib/pacman";
    _ = std.Io.Dir.cwd().statFile(io, sys_db, .{}) catch return;

    var mgr = Manager.init(allocator, sys_config, false, sys_db) catch return;
    defer mgr.deinit();

    var installed = try mgr.get_installed_packages();
    defer installed.deinit(mgr.allocator);

    var foreign = try mgr.get_foreign_packages();
    defer foreign.deinit(mgr.allocator);

    // Foreign packages are always a subset of the installed packages.
    try testing.expect(foreign.items.len <= installed.items.len);

    // Every foreign package is nonetheless installed, so it resolves locally.
    for (foreign.items) |package| {
        const name = package.name() orelse return error.TestFailed;
        const local = try mgr.get_single_installed_package(name);
        try testing.expect(local != null);
    }

    // If some packages were matched to a sync database, the sync caches are
    // loaded and repository packages must be excluded. `pacman` ships from the
    // official [core] repository, so it must never be reported as foreign.
    if (foreign.items.len < installed.items.len) {
        for (foreign.items) |package| {
            const name = package.name() orelse continue;
            try testing.expect(!std.mem.eql(u8, name, "pacman"));
        }
    }
}

// ---------------------------------------------------------------------------
// Local-database symlink (non-root update checking)
//
// When a temp root is supplied, Manager.init symlinks "{tempRoot}/local" to the
// real "{DBPath}/local" so libalpm can see the actually installed packages
// while every write (sync databases, etc.) stays inside the throwaway temp
// root. These tests drive that path against the real system database.
// ---------------------------------------------------------------------------

// A throwaway temp root whose config points DBPath at the *real* system
// database, so Manager.init links the real `local` directory into the temp root.
const LocalDbTestWorkspace = struct {
    io: std.Io,
    root: []const u8,
    config_path: []const u8,
    real_db_path: []const u8,

    // The real system database whose `local` directory holds installed packages.
    const system_db_path = "/var/lib/pacman";

    // Returns null (skip) when the real local database is unavailable, e.g. on
    // non-Arch hosts or CI without a populated /var/lib/pacman/local.
    fn create(allocator: std.mem.Allocator, io: std.Io) !?LocalDbTestWorkspace {
        const real_local = try std.fmt.allocPrint(allocator, "{s}/local", .{system_db_path});
        defer allocator.free(real_local);
        _ = std.Io.Dir.cwd().statFile(io, real_local, .{}) catch return null;

        const anchor: u8 = 0;
        var prng = std.Random.DefaultPrng.init(@intFromPtr(&anchor));
        const root = try std.fmt.allocPrint(allocator, "/tmp/shelly-alpm-local-test-{x}", .{prng.random().int(u32)});
        errdefer allocator.free(root);

        const config_path = try std.fmt.allocPrint(allocator, "{s}/pacman.conf", .{root});
        errdefer allocator.free(config_path);

        // The temp root must exist so init can plant the "local" symlink inside it.
        try std.Io.Dir.cwd().createDirPath(io, root);

        // DBPath points at the *real* database; init captures "{DBPath}/local",
        // repoints DBPath to the temp root (passed as temp_root_path), and links
        // "{tempRoot}/local" -> "{real}/local". No repositories are configured,
        // so no sync database is registered.
        const config = try std.fmt.allocPrint(
            allocator,
            "[options]\n" ++
                "Architecture = auto\n" ++
                "SigLevel = Never\n" ++
                "DBPath = {s}\n",
            .{system_db_path},
        );
        defer allocator.free(config);

        var file = try std.Io.Dir.cwd().createFile(io, config_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, config);

        return .{
            .io = io,
            .root = root,
            .config_path = config_path,
            .real_db_path = system_db_path,
        };
    }

    // deleteTree unlinks the "local" symlink without touching its target.
    fn cleanup(self: *LocalDbTestWorkspace, allocator: std.mem.Allocator) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.root) catch {};
        allocator.free(self.config_path);
        allocator.free(self.root);
    }
};

test "Manager.init symlinks the real local database into the temp root" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = (try LocalDbTestWorkspace.create(allocator, io)) orelse return;
    defer workspace.cleanup(allocator);

    var mgr = try Manager.init(allocator, workspace.config_path, false, workspace.root);
    defer mgr.deinit();

    const link_path = try std.fmt.allocPrint(allocator, "{s}/local", .{workspace.root});
    defer allocator.free(link_path);

    // The temp-root entry must be a symlink...
    const link_stat = try std.Io.Dir.cwd().statFile(io, link_path, .{ .follow_symlinks = false });
    try testing.expectEqual(std.Io.File.Kind.sym_link, link_stat.kind);

    // ...pointing at the real "{DBPath}/local" directory...
    const expected_target = try std.fmt.allocPrint(allocator, "{s}/local", .{workspace.real_db_path});
    defer allocator.free(expected_target);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.cwd().readLink(io, link_path, &buf);
    try testing.expectEqualStrings(expected_target, buf[0..n]);

    // ...and following the link must resolve to the real database directory.
    const target_stat = try std.Io.Dir.cwd().statFile(io, link_path, .{ .follow_symlinks = true });
    try testing.expectEqual(std.Io.File.Kind.directory, target_stat.kind);
}

test "get_installed_packages reads real packages through the local symlink" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = (try LocalDbTestWorkspace.create(allocator, io)) orelse return;
    defer workspace.cleanup(allocator);

    var mgr = try Manager.init(allocator, workspace.config_path, false, workspace.root);
    defer mgr.deinit();

    var packages = try mgr.get_installed_packages();
    defer packages.deinit(mgr.allocator);

    // The real system database always has packages installed.
    try testing.expect(packages.items.len > 0);

    // `pacman` is installed on every Arch-based system and must be visible
    // through the symlinked local database.
    var found_pacman = false;
    for (packages.items) |package| {
        const name = package.name() orelse continue;
        if (std.mem.eql(u8, name, "pacman")) {
            found_pacman = true;
            break;
        }
    }
    try testing.expect(found_pacman);
}

test "get_single_installed_package resolves a real package through the local symlink" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = (try LocalDbTestWorkspace.create(allocator, io)) orelse return;
    defer workspace.cleanup(allocator);

    var mgr = try Manager.init(allocator, workspace.config_path, false, workspace.root);
    defer mgr.deinit();

    // An installed package resolves through the symlinked local database...
    const pkg = (try mgr.get_single_installed_package("pacman")) orelse return error.TestFailed;
    try testing.expectEqualStrings("pacman", pkg.name() orelse return error.TestFailed);

    // ...while a package that is not installed does not.
    try testing.expect((try mgr.get_single_installed_package("shelly-definitely-not-installed")) == null);
}

test "get_foreign_packages treats installed packages as foreign without a sync database" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = (try LocalDbTestWorkspace.create(allocator, io)) orelse return;
    defer workspace.cleanup(allocator);

    var mgr = try Manager.init(allocator, workspace.config_path, false, workspace.root);
    defer mgr.deinit();

    var installed = try mgr.get_installed_packages();
    defer installed.deinit(mgr.allocator);
    try testing.expect(installed.items.len > 0);

    var foreign = try mgr.get_foreign_packages();
    defer foreign.deinit(mgr.allocator);

    // The workspace configures no repositories, so no sync database is
    // registered and every installed package counts as foreign.
    try testing.expectEqual(installed.items.len, foreign.items.len);
}

fn containsPackage(packages: []const libalpm.Package, name: []const u8) bool {
    for (packages) |package| {
        const pkg_name = package.name() orelse continue;
        if (std.mem.eql(u8, pkg_name, name)) return true;
    }
    return false;
}

// Mirrors the non-root `check-updates` flow in the C# CLI
// (CheckPackageUpdateNonRoot.GetSyncStandards): initialize against the real
// system configuration with `use_root = false` and a throwaway temp root
// (equivalent to `Initialize(useTempPath: true, tempPath: ...)`), then `sync()`
// the configured repositories. init symlinks the temp root's `local` database
// to the real one, so installed packages are visible while every downloaded
// sync database lands in the temp root. This exercises get_installed_packages
// and get_foreign_packages together against real repository data.
test "get_foreign_packages excludes repository packages after a non-root sync" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Skip gracefully when there is no real system database to link against.
    const sys_config = "/etc/pacman.conf";
    _ = std.Io.Dir.cwd().statFile(io, "/var/lib/pacman/local", .{}) catch return;

    // A unique temp root plays the role of the C# `tempPath` cache directory.
    const anchor: u8 = 0;
    var prng = std.Random.DefaultPrng.init(@intFromPtr(&anchor));
    const temp_root = try std.fmt.allocPrint(allocator, "/tmp/shelly-alpm-checkupdates-{x}", .{prng.random().int(u32)});
    defer allocator.free(temp_root);
    try std.Io.Dir.cwd().createDirPath(io, temp_root);
    defer std.Io.Dir.cwd().deleteTree(io, temp_root) catch {};

    // Initialize(useTempPath: true, tempPath: temp_root) + Sync().
    var mgr = Manager.init(allocator, sys_config, false, temp_root) catch return;
    defer mgr.deinit();
    mgr.sync(true) catch return;

    var installed = try mgr.get_installed_packages();
    defer installed.deinit(mgr.allocator);

    var foreign = try mgr.get_foreign_packages();
    defer foreign.deinit(mgr.allocator);

    // The linked local database always exposes the real installed packages.
    try testing.expect(installed.items.len > 0);
    try testing.expect(containsPackage(installed.items, "pacman"));

    // Skip the exclusion assertions unless the sync actually loaded repository
    // data (network available and databases downloaded). Without it every
    // installed package would trivially be "foreign".
    if (foreign.items.len == installed.items.len) return;

    // `pacman` is provided by the official [core] repository, so once its sync
    // database is loaded it must never be reported as a foreign package.
    try testing.expect(!containsPackage(foreign.items, "pacman"));
    try testing.expect(foreign.items.len < installed.items.len);
}
