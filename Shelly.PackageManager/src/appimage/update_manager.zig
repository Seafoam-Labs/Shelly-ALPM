const std = @import("std");
const HttpClient = @import("ShellyHttp");
const appimage = @import("bindings.zig").appimage;
const builtin = @import("builtin");
const appimage_manager = @import("manager.zig");
const events = @import("events.zig");

const downloader = @import("../shared/downloader.zig");
const operation_api = @import("operation_context");

pub const UpdateManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    install_directory: []const u8,
    local_db_path: []const u8,
    dispatcher: ?*events.Dispatcher = null,
    operation_context: ?*operation_api.OperationContext = null,
    owned_dispatcher: ?*events.Dispatcher = null,
    database_commit: appimage_manager.DatabaseCommitFn = appimage_manager.commitDatabase,
    cache_command_run: appimage_manager.CacheCommandRunFn = appimage_manager.runCacheCommand,
    /// Optional local path that, when set, replaces the network download in
    /// `update`. Used by integration tests to exercise the post-download logic
    /// deterministically. Production callers leave this null.
    staged_download_path: ?[]const u8 = null,

    pub fn setEventDispatcher(self: *UpdateManager, dispatcher: ?*events.Dispatcher) void {
        self.dispatcher = dispatcher orelse self.owned_dispatcher;
    }

    /// Borrows a shared context and creates an internal legacy adapter when
    /// needed. The context must outlive this manager and all active calls.
    pub fn setOperationContext(self: *UpdateManager, context: ?*operation_api.OperationContext) !void {
        self.operation_context = context;
        if (context != null and self.dispatcher == null) {
            const dispatcher = try self.allocator.create(events.Dispatcher);
            dispatcher.* = events.Dispatcher.init(self.allocator);
            self.owned_dispatcher = dispatcher;
            self.dispatcher = dispatcher;
        }
    }

    pub fn deinit(self: *UpdateManager) void {
        if (self.owned_dispatcher) |dispatcher| {
            if (self.dispatcher == dispatcher) self.dispatcher = null;
            dispatcher.deinit();
            self.allocator.destroy(dispatcher);
            self.owned_dispatcher = null;
        }
        self.operation_context = null;
    }

    pub fn configure_updates(self: UpdateManager, update_info: []const u8, name: []const u8, update_type: appimage.UpdateType, allow_prerelease: bool) !bool {
        var operation_scope = events.OperationScope.init(self.operation_context, self.dispatcher, .configure, name);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        std.log.info("Configuring updates for {s} {s}, type: {s}, allowPrerelease: {}", .{ name, update_info, @tagName(update_type), allow_prerelease });

        const manager = appimage_manager.AppImageManager{
            .allocator = self.allocator,
            .io = self.io,
            .environ = self.environ,
            .install_directory = self.install_directory,
            .local_db_path = self.local_db_path,
            .dispatcher = self.dispatcher,
            .operation_context = self.operation_context,
        };

        const app_images = try manager.getAppImagesFromLocalDb();
        defer manager.freeAppImages(app_images);

        var found_index: ?usize = null;
        for (app_images, 0..) |app, i| {
            if (std.ascii.eqlIgnoreCase(app.name, name)) {
                found_index = i;
                break;
            }
        }

        const idx = found_index orelse return false;
        var app = app_images[idx];
        try configure_update(update_info, update_type, &app, allow_prerelease);
        try manager.addAppImageToLocalDb(app);
        return true;
    }

    pub fn validate_update_configuration(update_info: []const u8, update_type: appimage.UpdateType) !void {
        var app = appimage.AppImage{ .name = "" };
        try configure_update(update_info, update_type, &app, false);
    }

    fn configure_update(update_info: []const u8, update_type: appimage.UpdateType, app: *appimage.AppImage, allow_prerelease: bool) !void {
        const trimmed = std.mem.trim(u8, update_info, &std.ascii.whitespace);

        switch (update_type) {
            .none => {
                app.update_type = .none;
                app.update_url = "";
                app.repo_owner = null;
                app.repo_name = null;
            },
            .static_url => {
                if (!isHttpUrl(trimmed)) return error.InvalidAppImageUpdateConfiguration;
                app.update_url = trimmed;
                app.update_type = update_type;
                app.repo_owner = null;
                app.repo_name = null;
            },
            .forgejo => {
                const repository = try parseForgejoRepository(trimmed);
                app.update_url = repository.canonical_url;
                app.update_type = update_type;
                app.repo_owner = null;
                app.repo_name = null;
            },
            .github, .gitlab, .codeberg => {
                if (countChar(trimmed, '/') != 1) return error.InvalidAppImageUpdateConfiguration;
                const idx = std.mem.indexOf(u8, trimmed, "/").?;
                if (idx == 0 or idx + 1 == trimmed.len) return error.InvalidAppImageUpdateConfiguration;
                app.update_url = "";
                app.repo_owner = trimmed[0..idx];
                app.repo_name = trimmed[idx + 1 ..];
                app.update_type = update_type;
            },
        }
        app.allow_prerelease = allow_prerelease;
    }

    const ForgejoRepository = struct {
        canonical_url: []const u8,
        origin: []const u8,
        owner: []const u8,
        repo: []const u8,
    };

    fn parseForgejoRepository(update_info: []const u8) !ForgejoRepository {
        const trimmed = std.mem.trim(u8, update_info, &std.ascii.whitespace);
        const uri = std.Uri.parse(trimmed) catch return error.InvalidAppImageUpdateConfiguration;
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and
            !std.ascii.eqlIgnoreCase(uri.scheme, "https"))
        {
            return error.InvalidAppImageUpdateConfiguration;
        }
        if (uri.host == null or uri.user != null or uri.password != null or
            uri.query != null or uri.fragment != null)
        {
            return error.InvalidAppImageUpdateConfiguration;
        }

        const host = componentText(uri.host.?);
        const path = componentText(uri.path);
        if (host.len == 0 or path.len == 0 or path[0] != '/')
            return error.InvalidAppImageUpdateConfiguration;

        var repository_path = path;
        if (repository_path.len > 1 and repository_path[repository_path.len - 1] == '/')
            repository_path = repository_path[0 .. repository_path.len - 1];
        if (countChar(repository_path, '/') == 3 and
            std.mem.endsWith(u8, repository_path, "/releases"))
        {
            repository_path = repository_path[0 .. repository_path.len - "/releases".len];
        }
        if (countChar(repository_path, '/') != 2)
            return error.InvalidAppImageUpdateConfiguration;

        const owner_and_repo = repository_path[1..];
        const separator = std.mem.indexOfScalar(u8, owner_and_repo, '/') orelse
            return error.InvalidAppImageUpdateConfiguration;
        const owner = owner_and_repo[0..separator];
        const repo = owner_and_repo[separator + 1 ..];
        if (owner.len == 0 or repo.len == 0 or
            std.mem.eql(u8, owner, ".") or std.mem.eql(u8, owner, "..") or
            std.mem.eql(u8, repo, ".") or std.mem.eql(u8, repo, ".."))
        {
            return error.InvalidAppImageUpdateConfiguration;
        }

        const removed_path_bytes = path.len - repository_path.len;
        const canonical_url = trimmed[0 .. trimmed.len - removed_path_bytes];
        const origin = trimmed[0 .. trimmed.len - path.len];
        return .{
            .canonical_url = canonical_url,
            .origin = origin,
            .owner = owner,
            .repo = repo,
        };
    }

    fn isHttpUrl(value: []const u8) bool {
        const uri = std.Uri.parse(value) catch return false;
        return (std.ascii.eqlIgnoreCase(uri.scheme, "http") or
            std.ascii.eqlIgnoreCase(uri.scheme, "https")) and uri.host != null;
    }

    fn componentText(component: std.Uri.Component) []const u8 {
        return switch (component) {
            .raw => |value| value,
            .percent_encoded => |value| value,
        };
    }

    fn countChar(haystack: []const u8, needle: u8) usize {
        var count: usize = 0;
        for (haystack) |c| {
            if (c == needle) count += 1;
        }
        return count;
    }

    /// Returns an owned list containing only available updates. Call
    /// `deinit` on the returned value when it is no longer needed.
    pub fn get_updates(self: UpdateManager) !appimage.UpdateList {
        var operation_scope = events.OperationScope.init(self.operation_context, self.dispatcher, .search, null);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        const manager = self.appImageManager();
        const apps = try manager.getAppImagesFromLocalDb();
        defer manager.freeAppImages(apps);

        var updates: std.ArrayList(appimage.AppImageUpdate) = .empty;
        errdefer {
            for (updates.items) |update_result| update_result.deinit(self.allocator);
            updates.deinit(self.allocator);
        }

        self.emitStatus(.information, "Checking for AppImage updates...");
        for (apps, 0..) |*app, app_index| {
            try self.checkCancelled();
            self.emitProgress("check-updates", app.name, app_index, apps.len);
            if (try self.get_update(app)) |update_result| {
                if (update_result.is_update_available) {
                    try updates.append(self.allocator, update_result);
                } else {
                    update_result.deinit(self.allocator);
                }
            }
        }

        const owned = try updates.toOwnedSlice(self.allocator);
        self.emitProgress("check-updates", "AppImage update check complete", apps.len, apps.len);
        self.emitStatusFmt(.success, "Found {d} AppImage update(s).", .{owned.len});
        return appimage.UpdateList.init(self.allocator, owned);
    }

    /// Returns one owned update result, or null when the application has no
    /// valid update configuration/provider result. The caller owns a non-null
    /// result and must call `deinit` on it.
    pub fn get_update(self: UpdateManager, app: *const appimage.AppImage) !?appimage.AppImageUpdate {
        var operation_scope = events.OperationScope.init(self.operation_context, self.dispatcher, .search, app.name);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        switch (app.update_type) {
            .none => return null,
            .static_url => {
                if (app.update_url.len == 0) {
                    self.emitStatusFmt(.warning, "AppImage {s} has no static update URL.", .{app.name});
                    return null;
                }
                return self.guardInstalledRelease(app, try self.check_static_url_update(app.update_url, app.name, app.version));
            },
            .github => {
                const owner = app.repo_owner orelse {
                    self.emitMissingRepository(app.name);
                    return null;
                };
                const repo = app.repo_name orelse {
                    self.emitMissingRepository(app.name);
                    return null;
                };
                return self.providerUpdateOrWarn(
                    app.name,
                    self.guardInstalledRelease(app, try self.check_github_update(owner, repo, app.name, app.version, app.allow_prerelease)),
                );
            },
            .gitlab => {
                const owner = app.repo_owner orelse {
                    self.emitMissingRepository(app.name);
                    return null;
                };
                const repo = app.repo_name orelse {
                    self.emitMissingRepository(app.name);
                    return null;
                };
                return self.providerUpdateOrWarn(
                    app.name,
                    self.guardInstalledRelease(app, try self.check_gitlab_update(owner, repo, app.name, app.version, app.allow_prerelease)),
                );
            },
            .codeberg => {
                const owner = app.repo_owner orelse {
                    self.emitMissingRepository(app.name);
                    return null;
                };
                const repo = app.repo_name orelse {
                    self.emitMissingRepository(app.name);
                    return null;
                };
                return self.providerUpdateOrWarn(
                    app.name,
                    self.guardInstalledRelease(app, try self.check_codeberg_update(owner, repo, app.name, app.version, app.allow_prerelease)),
                );
            },
            .forgejo => {
                if (app.update_url.len == 0) {
                    self.emitStatusFmt(.warning, "AppImage {s} has no Forgejo update URL.", .{app.name});
                    return null;
                }
                return self.providerUpdateOrWarn(
                    app.name,
                    self.guardInstalledRelease(app, try self.check_forgejo_update(app.update_url, app.name, app.version, app.allow_prerelease)),
                );
            },
        }
    }

    fn guardInstalledRelease(self: UpdateManager, app: *const appimage.AppImage, result_in: ?appimage.AppImageUpdate) ?appimage.AppImageUpdate {
        var result = result_in;
        if (result) |*update_result| {
            applyInstalledReleaseGuard(app, update_result);
            if (!update_result.is_update_available) {
                self.emitStatusFmt(.information, "AppImage {s} is already up to date ({s}).", .{ app.name, update_result.version });
            }
        }
        return result;
    }

    pub fn deinit_update(self: UpdateManager, update_result: appimage.AppImageUpdate) void {
        update_result.deinit(self.allocator);
    }

    pub fn deinit_updates(self: UpdateManager, update_results: []appimage.AppImageUpdate) void {
        for (update_results) |update_result| update_result.deinit(self.allocator);
        self.allocator.free(update_results);
    }

    pub fn update(self: UpdateManager, appimage_ptr: *appimage.AppImageUpdate) !bool {
        if (!builtin.is_test and builtin.os.tag == .linux and std.os.linux.geteuid() == 0) {
            return error.RootAppImageMutationDenied;
        }
        var operation_scope = events.OperationScope.init(self.operation_context, self.dispatcher, .update, appimage_ptr.name);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        var manager = appimage_manager.AppImageManager{
            .allocator = self.allocator,
            .io = self.io,
            .environ = self.environ,
            .install_directory = self.install_directory,
            .local_db_path = self.local_db_path,
            .dispatcher = self.dispatcher,
            .operation_context = self.operation_context,
            .database_commit = self.database_commit,
            .cache_command_run = self.cache_command_run,
        };

        const apps = try manager.getAppImagesFromLocalDb();
        defer manager.freeAppImages(apps);

        var found_index: ?usize = null;
        for (apps, 0..) |a, i| {
            if (std.ascii.eqlIgnoreCase(a.name, appimage_ptr.name)) {
                found_index = i;
                break;
            }
        }

        const app_to_update = if (found_index) |i| apps[i] else {
            std.log.debug("AppImage '{s}' not found in local database.", .{appimage_ptr.name});
            self.emitStatusFmt(.err, "AppImage {s} was not found in the local database.", .{appimage_ptr.name});
            return false;
        };

        std.log.info("Updating {s}", .{app_to_update.name});
        self.emitStatusFmt(.information, "Updating AppImage {s}...", .{app_to_update.name});

        if (appimage_ptr.download_url.len == 0) {
            std.log.debug("No download URL found for {s}.", .{appimage_ptr.name});
            self.emitStatusFmt(.err, "No download URL was found for AppImage {s}.", .{appimage_ptr.name});
            return false;
        }

        const current_filename = try std.fmt.allocPrint(self.allocator, "{s}.AppImage", .{app_to_update.name});
        defer self.allocator.free(current_filename);
        const current_path = try std.fs.path.join(self.allocator, &.{ self.install_directory, current_filename });
        defer self.allocator.free(current_path);

        const current_exists = std.Io.Dir.cwd().statFile(self.io, current_path, .{}) catch null;
        if (current_exists == null) {
            std.log.debug("Current AppImage not found at {s}.", .{current_path});
            self.emitStatusFmt(.err, "Current AppImage was not found at {s}.", .{current_path});
            return false;
        }

        const download_path = try manager.uniqueSiblingPath(current_path, "download");
        defer self.allocator.free(download_path);
        defer std.Io.Dir.cwd().deleteFile(self.io, download_path) catch {};

        if (self.staged_download_path) |staged| {
            manager.copyFile(staged, download_path) catch |err| {
                std.log.err("Could not stage update for {s}: {s}", .{ appimage_ptr.name, @errorName(err) });
                self.emitStatusFmt(.err, "Could not stage update for {s}: {s}", .{ appimage_ptr.name, @errorName(err) });
                return false;
            };
        } else {
            std.log.info("Downloading update for {s}...", .{appimage_ptr.name});
            var dl = downloader.CoreDownloader.init(self.allocator, self.io, .default());
            defer dl.deinit();
            if (self.dispatcher) |dispatcher| {
                if (dispatcher.operation) |operation| dl.setParentOperation(operation) else dl.setOperationContext(self.operation_context);
            } else {
                dl.setOperationContext(self.operation_context);
            }
            var download_context = DownloadContext{ .manager = self, .app_name = appimage_ptr.name };
            dl.setEventCallback(onDownloadEvent, &download_context);

            const dl_result = dl.downloadToFile(appimage_ptr.download_url, download_path, false);
            switch (dl_result) {
                .failure => |err| {
                    std.log.err("Failed to download update for {s}: {s}", .{ appimage_ptr.name, @errorName(err) });
                    self.emitStatusFmt(.err, "Failed to download update for {s}: {s}", .{ appimage_ptr.name, @errorName(err) });
                    return false;
                },
                else => {},
            }
        }

        return self.applyDownloadedUpdate(appimage_ptr, app_to_update, current_path, download_path);
    }

    pub fn applyDownloadedUpdate(
        self: UpdateManager,
        appimage_ptr: *const appimage.AppImageUpdate,
        app_to_update: appimage.AppImage,
        current_path: []const u8,
        download_path: []const u8,
    ) !bool {
        var manager = appimage_manager.AppImageManager{
            .allocator = self.allocator,
            .io = self.io,
            .environ = self.environ,
            .install_directory = self.install_directory,
            .local_db_path = self.local_db_path,
            .dispatcher = self.dispatcher,
            .operation_context = self.operation_context,
            .database_commit = self.database_commit,
            .cache_command_run = self.cache_command_run,
        };

        try manager.setExecutable(download_path);

        var content = (try manager.extractMetadataPure(download_path, app_to_update.name, current_path)) orelse {
            self.emitStatusFmt(.err, "Downloaded update for {s} is not a usable AppImage.", .{appimage_ptr.name});
            return false;
        };
        defer content.deinit();
        const new_metadata = content.metadata;

        self.emitStatusFmt(
            .information,
            "Extracted update metadata: desktop name '{s}' -> '{s}', version '{s}' -> '{s}'.",
            .{ app_to_update.desktop_name, new_metadata.desktop_name, app_to_update.version, new_metadata.version },
        );

        const download_filename = std.fs.path.basename(appimage_ptr.download_url);
        if (!isCorrectArchitecture(download_filename)) {
            std.log.warn("The downloaded AppImage might not match your system architecture.", .{});
            self.emitStatus(.warning, "The downloaded AppImage might not match your system architecture.");
        }

        const backup_path = try manager.uniqueSiblingPath(current_path, "binary-backup");
        defer self.allocator.free(backup_path);
        defer std.Io.Dir.cwd().deleteFile(self.io, backup_path) catch {};
        std.log.info("Backing up current version to {s}...", .{backup_path});
        self.emitStatusFmt(.information, "Backing up the current AppImage to {s}...", .{backup_path});
        std.Io.Dir.hardLink(.cwd(), current_path, .cwd(), backup_path, self.io, .{}) catch try manager.copyFile(current_path, backup_path);

        manager.writeFileAtomically(download_path, current_path, "replacement") catch |err| {
            std.log.warn("Error installing new version: {s}.", .{@errorName(err)});
            self.emitStatusFmt(.err, "Could not install the AppImage update: {s}.", .{@errorName(err)});
            return false;
        };
        manager.setExecutable(current_path) catch |err| {
            std.log.warn("Could not make updated AppImage executable: {s}.", .{@errorName(err)});
            self.emitStatusFmt(.err, "Could not make the AppImage update executable: {s}.", .{@errorName(err)});
            manager.writeFileAtomically(backup_path, current_path, "restore") catch {};
            return false;
        };
        self.emitStatus(.information, "Replaced installed AppImage binary.");

        var updated_app = appimage_manager.AppImageManager.mergeMetadata(app_to_update, new_metadata, appimage_ptr.version);
        updated_app.path = current_path;
        var integration = manager.beginDesktopIntegration(updated_app, current_path, content.source_desktop_path, content.icon_source) catch |err| {
            std.log.warn("Could not refresh desktop entry for {s}: {s}. Rolling back...", .{ appimage_ptr.name, @errorName(err) });
            self.emitStatusFmt(.err, "Could not refresh the desktop entry: {s}. Rolling back...", .{@errorName(err)});
            manager.writeFileAtomically(backup_path, current_path, "restore") catch {};
            return false;
        };
        defer integration.deinit();
        manager.addAppImageToLocalDb(updated_app) catch |err| {
            std.log.warn("Could not persist updated metadata: {s}. Rolling back...", .{@errorName(err)});
            self.emitStatusFmt(.err, "Could not persist the AppImage update: {s}. Rolling back...", .{@errorName(err)});
            integration.rollback() catch |rollback_err| self.emitStatusFmt(.err, "Could not restore desktop integration: {s}.", .{@errorName(rollback_err)});
            manager.writeFileAtomically(backup_path, current_path, "restore") catch |restore_err| self.emitStatusFmt(.err, "Could not restore AppImage binary: {s}.", .{@errorName(restore_err)});
            return false;
        };
        try integration.finish();
        manager.refreshDesktopCachesBestEffort(content.icon_source != null);
        self.emitStatus(.information, "Refreshed desktop integration.");
        std.Io.Dir.cwd().deleteFile(self.io, backup_path) catch |err| {
            self.emitStatusFmt(.warning, "Could not remove the AppImage backup: {s}.", .{@errorName(err)});
        };

        self.emitStatusFmt(.success, "Updated AppImage {s} to {s}.", .{ app_to_update.name, updated_app.version });
        return true;
    }

    pub fn check_static_url_update(self: UpdateManager, url: []const u8, app_name: []const u8, current_version: []const u8) !?appimage.AppImageUpdate {
        var operation_scope = events.OperationScope.init(self.operation_context, self.dispatcher, .search, app_name);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        const uri = std.Uri.parse(url) catch return null;

        var client: HttpClient = .{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        var req = client.request(.HEAD, uri, .{
            .headers = .{},
            .redirect_behavior = .init(10),
        }) catch return null;
        defer req.deinit();

        req.sendBodiless() catch return null;

        var redirect_buffer: [8 * 1024]u8 = undefined;
        const response = req.receiveHead(&redirect_buffer) catch return null;

        if (response.head.status.class() != .success) return null;

        if (response.head.content_type) |content_type| {
            if (contentTypeIsNotAppImage(content_type)) {
                std.log.warn("Static update URL for {s} returned content type '{s}'; it does not point to a downloadable AppImage.", .{ app_name, content_type });
                self.emitStatusFmt(.warning, "The static update URL for {s} does not point to a downloadable AppImage (content type '{s}').", .{ app_name, content_type });
                return null;
            }
        }

        var etag: ?[]const u8 = null;
        var last_modified: ?[]const u8 = null;

        var it = response.head.iterateHeaders();
        while (it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "etag")) {
                etag = header.value;
            } else if (std.ascii.eqlIgnoreCase(header.name, "last-modified")) {
                last_modified = header.value;
            }
        }

        const raw_version = if (etag != null) etag.? else if (last_modified != null) last_modified.? else "";
        return build_static_url(self.allocator, app_name, url, current_version, raw_version);
    }

    fn build_static_url(allocator: std.mem.Allocator, app_name: []const u8, url: []const u8, current_version: []const u8, raw_version: []const u8) !?appimage.AppImageUpdate {
        const version = normalizeStaticVersion(raw_version);
        return @as(?appimage.AppImageUpdate, try makeUpdate(allocator, app_name, version, url, current_version));
    }

    /// Normalizes the version token derived from an HTTP validator header.
    /// Strips the weak-validator prefix (RFC 7232, e.g. `W/"abc"`) and the
    /// surrounding quotes from an ETag. Last-Modified dates pass through
    /// unchanged.
    fn normalizeStaticVersion(raw_version: []const u8) []const u8 {
        var version = raw_version;
        if (version.len >= 2 and (version[0] == 'W' or version[0] == 'w') and version[1] == '/') {
            version = version[2..];
        }
        return std.mem.trim(u8, version, "\"");
    }

    /// Returns true when the Content-Type indicates the response is a document
    /// (web page, JSON feed, etc.) rather than a downloadable AppImage binary.
    /// A missing or unrecognized type is treated as acceptable because many
    /// servers serve binaries with unusual or absent Content-Type values.
    fn contentTypeIsNotAppImage(content_type: []const u8) bool {
        var mime = content_type;
        if (std.mem.indexOfScalar(u8, mime, ';')) |idx| mime = mime[0..idx];
        mime = std.mem.trim(u8, mime, &std.ascii.whitespace);
        if (mime.len == 0) return false;

        const text_prefix = "text/";
        if (mime.len >= text_prefix.len and std.ascii.eqlIgnoreCase(mime[0..text_prefix.len], text_prefix)) return true;

        const document_types = [_][]const u8{
            "application/json",
            "application/xml",
            "application/xhtml+xml",
            "application/rss+xml",
            "application/atom+xml",
        };
        for (document_types) |t| {
            if (std.ascii.eqlIgnoreCase(mime, t)) return true;
        }
        return false;
    }

    fn getSystemArchitecture() []const u8 {
        const arch = builtin.cpu.arch;
        return switch (arch) {
            .x86_64 => "x86_64",
            .aarch64 => "aarch64",
            .x86 => "x86",
            .arm => "arm",
            else => @tagName(arch),
        };
    }

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (haystack.len < needle.len) return false;

        const max_i = haystack.len - needle.len + 1;
        for (0..max_i) |i| {
            var match = true;
            for (0..needle.len) |j| {
                if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                    match = false;
                    break;
                }
            }
            if (match) return true;
        }
        return false;
    }

    fn anyContains(haystack: []const u8, aliases: []const []const u8) bool {
        for (aliases) |alias| {
            if (containsIgnoreCase(haystack, alias)) return true;
        }
        return false;
    }

    fn isCorrectArchitecture(asset_name: []const u8) bool {
        const system_arch = getSystemArchitecture();

        const x8664_aliases = [_][]const u8{ "x86_64", "amd64", "x64" };
        const aarch64_aliases = [_][]const u8{ "aarch64", "arm64", "armv8" };
        const i386_aliases = [_][]const u8{ "i386", "i686", "x86" };
        const armhf_aliases = [_][]const u8{ "armhf", "armv7l", "arm" };

        var target_aliases: []const []const u8 = undefined;

        if (std.mem.eql(u8, system_arch, "x86_64")) {
            target_aliases = x8664_aliases[0..];
        } else if (std.mem.eql(u8, system_arch, "aarch64")) {
            target_aliases = aarch64_aliases[0..];
        } else if (std.mem.eql(u8, system_arch, "i386")) {
            target_aliases = i386_aliases[0..];
        } else if (std.mem.eql(u8, system_arch, "arm")) {
            target_aliases = armhf_aliases[0..];
        } else {
            const single_arch = [_][]const u8{system_arch};
            target_aliases = single_arch[0..];
        }

        if (anyContains(asset_name, target_aliases)) {
            return true;
        }

        const all_alias_groups = [_][]const []const u8{
            x8664_aliases[0..],
            aarch64_aliases[0..],
            i386_aliases[0..],
            armhf_aliases[0..],
        };

        for (all_alias_groups) |group| {
            for (group) |alias| {
                var is_in_target = false;
                for (target_aliases) |ta| {
                    if (std.mem.eql(u8, alias, ta)) {
                        is_in_target = true;
                        break;
                    }
                }
                if (!is_in_target) {
                    if (containsIgnoreCase(asset_name, alias)) {
                        return false;
                    }
                }
            }
        }

        return true;
    }

    fn isAssetNameSeparator(character: u8) bool {
        return character == '-' or character == '_' or std.ascii.isWhitespace(character);
    }

    fn isVersionToken(token: []const u8) bool {
        if (token.len == 0) return false;

        var index: usize = 0;
        if ((token[0] == 'v' or token[0] == 'V') and token.len > 1) index = 1;

        var component_has_digit = false;
        var separator_count: usize = 0;
        while (index < token.len) : (index += 1) {
            const character = token[index];
            if (std.ascii.isDigit(character)) {
                component_has_digit = true;
                continue;
            }
            if (character != '.' or !component_has_digit or index + 1 == token.len) return false;
            separator_count += 1;
            component_has_digit = false;
        }
        return component_has_digit and separator_count > 0;
    }

    fn normalizeAppImageStem(allocator: std.mem.Allocator, stem: []const u8) ![]u8 {
        var normalized: std.ArrayList(u8) = .empty;
        errdefer normalized.deinit(allocator);

        var token_start: usize = 0;
        while (token_start < stem.len) {
            while (token_start < stem.len and isAssetNameSeparator(stem[token_start])) : (token_start += 1) {}
            if (token_start == stem.len) break;

            var token_end = token_start;
            while (token_end < stem.len and !isAssetNameSeparator(stem[token_end])) : (token_end += 1) {}
            const token = stem[token_start..token_end];
            if (!isVersionToken(token)) {
                if (normalized.items.len > 0) try normalized.append(allocator, '-');
                for (token) |character| try normalized.append(allocator, std.ascii.toLower(character));
            }
            token_start = token_end;
        }
        return normalized.toOwnedSlice(allocator);
    }

    fn selectReleaseAssetUrl(
        allocator: std.mem.Allocator,
        assets: []const std.json.Value,
        app_name: []const u8,
        url_field: []const u8,
    ) !?[]const u8 {
        const normalized_app_name = try normalizeAppImageStem(allocator, app_name);
        defer allocator.free(normalized_app_name);

        var compatible_count: usize = 0;
        var compatible_url: ?[]const u8 = null;
        var exact_count: usize = 0;
        var exact_url: ?[]const u8 = null;
        var normalized_count: usize = 0;
        var normalized_url: ?[]const u8 = null;

        for (assets) |asset| {
            if (asset != .object) continue;
            const name_value = asset.object.get("name") orelse continue;
            const url_value = asset.object.get(url_field) orelse continue;
            if (name_value != .string or url_value != .string) continue;
            if (!endsWithIgnoreCase(name_value.string, ".AppImage")) continue;
            if (!isHttpUrl(url_value.string)) continue;
            if (!isCorrectArchitecture(name_value.string)) continue;

            compatible_count += 1;
            compatible_url = url_value.string;

            const asset_stem = std.fs.path.stem(name_value.string);
            if (std.ascii.eqlIgnoreCase(asset_stem, app_name)) {
                exact_count += 1;
                exact_url = url_value.string;
                continue;
            }

            const normalized_asset_name = try normalizeAppImageStem(allocator, asset_stem);
            defer allocator.free(normalized_asset_name);
            if (normalized_app_name.len > 0 and
                std.mem.eql(u8, normalized_asset_name, normalized_app_name))
            {
                normalized_count += 1;
                normalized_url = url_value.string;
            }
        }

        if (exact_count == 1) return exact_url;
        if (exact_count > 1) return null;
        if (normalized_count == 1) return normalized_url;
        if (normalized_count > 1) return null;
        if (compatible_count == 1) return compatible_url;
        return null;
    }

    pub fn gitea_to_releases_api(allocator: std.mem.Allocator, domain: []const u8, owner: []const u8, repo: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "https://{s}/api/v1/repos/{s}/{s}/releases", .{ domain, owner, repo });
    }

    fn forgejo_to_releases_api(allocator: std.mem.Allocator, origin: []const u8, owner: []const u8, repo: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/api/v1/repos/{s}/{s}/releases", .{ origin, owner, repo });
    }

    pub fn check_gitea_update(self: UpdateManager, domain: []const u8, owner: []const u8, repo: []const u8, app_name: []const u8, current_version: []const u8, allow_prerelease: bool) !?appimage.AppImageUpdate {
        var operation_scope = events.OperationScope.init(self.operation_context, self.dispatcher, .search, app_name);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        const url = try gitea_to_releases_api(self.allocator, domain, owner, repo);
        defer self.allocator.free(url);

        const body = (try self.fetchJson(url, "application/json")) orelse return null;
        defer self.allocator.free(body);
        return parse_github_response(self.allocator, body, app_name, current_version, allow_prerelease);
    }

    pub fn check_codeberg_update(self: UpdateManager, owner: []const u8, repo: []const u8, app_name: []const u8, current_version: []const u8, allow_prerelease: bool) !?appimage.AppImageUpdate {
        var operation_scope = events.OperationScope.init(self.operation_context, self.dispatcher, .search, app_name);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        return self.check_gitea_update("codeberg.org", owner, repo, app_name, current_version, allow_prerelease);
    }

    pub fn check_forgejo_update(self: UpdateManager, update_url: []const u8, app_name: []const u8, current_version: []const u8, allow_prerelease: bool) !?appimage.AppImageUpdate {
        var operation_scope = events.OperationScope.init(self.operation_context, self.dispatcher, .search, app_name);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        const repository = parseForgejoRepository(update_url) catch return null;
        const url = try forgejo_to_releases_api(
            self.allocator,
            repository.origin,
            repository.owner,
            repository.repo,
        );
        defer self.allocator.free(url);

        const body = (try self.fetchJson(url, "application/json")) orelse return null;
        defer self.allocator.free(body);
        return parse_github_response(self.allocator, body, app_name, current_version, allow_prerelease);
    }

    pub fn check_github_update(self: UpdateManager, owner: []const u8, repo: []const u8, app_name: []const u8, current_version: []const u8, allow_prerelease: bool) !?appimage.AppImageUpdate {
        var operation_scope = events.OperationScope.init(self.operation_context, self.dispatcher, .search, app_name);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        const url = try github_to_releases_api(self.allocator, owner, repo);
        defer self.allocator.free(url);

        const body = (try self.fetchJson(url, "application/vnd.github+json")) orelse return null;
        defer self.allocator.free(body);
        return parse_github_response(self.allocator, body, app_name, current_version, allow_prerelease);
    }

    fn parse_github_response(allocator: std.mem.Allocator, body: []const u8, app_name: []const u8, current_version: []const u8, allow_prerelease: bool) !?appimage.AppImageUpdate {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .array or root.array.items.len == 0) return null;

        var release: ?std.json.Value = null;
        for (root.array.items) |r| {
            if (!allow_prerelease) {
                const pre = r.object.get("prerelease") orelse continue;
                if (pre == .bool and pre.bool) continue;
            }
            release = r;
            break;
        }
        const rel = release orelse return null;

        const tag_name_val = rel.object.get("tag_name") orelse return null;
        const latest_version = if (tag_name_val == .string) tag_name_val.string else return null;

        const assets_val = rel.object.get("assets") orelse return null;

        if (assets_val != .array) return null;
        const download_url = try selectReleaseAssetUrl(
            allocator,
            assets_val.array.items,
            app_name,
            "browser_download_url",
        ) orelse return null;

        return @as(?appimage.AppImageUpdate, try makeUpdate(allocator, app_name, latest_version, download_url, current_version));
    }

    pub fn check_gitlab_update(self: UpdateManager, owner: []const u8, repo: []const u8, app_name: []const u8, current_version: []const u8, allow_prerelease: bool) !?appimage.AppImageUpdate {
        var operation_scope = events.OperationScope.init(self.operation_context, self.dispatcher, .search, app_name);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        const url = try gitlab_to_releases_api(self.allocator, owner, repo);
        defer self.allocator.free(url);

        const body = (try self.fetchJson(url, "application/json")) orelse return null;
        defer self.allocator.free(body);
        return parse_gitlab_response(self.allocator, body, app_name, current_version, allow_prerelease);
    }

    fn github_to_releases_api(allocator: std.mem.Allocator, owner: []const u8, repo: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/{s}/releases", .{ owner, repo });
    }

    fn gitlab_to_releases_api(allocator: std.mem.Allocator, owner: []const u8, repo: []const u8) ![]u8 {
        const raw = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ owner, repo });
        defer allocator.free(raw);
        const encoded = try std.mem.replaceOwned(u8, allocator, raw, "/", "%2F");
        defer allocator.free(encoded);
        return std.fmt.allocPrint(allocator, "https://gitlab.com/api/v4/projects/{s}/releases", .{encoded});
    }

    fn parse_gitlab_response(allocator: std.mem.Allocator, body: []const u8, app_name: []const u8, current_version: []const u8, allow_prerelease: bool) !?appimage.AppImageUpdate {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .array or root.array.items.len == 0) return null;

        var release: ?std.json.Value = null;
        for (root.array.items) |r| {
            if (!allow_prerelease) {
                if (r.object.get("upcoming_release")) |upcoming| {
                    if (upcoming == .bool and upcoming.bool) continue;
                }
            }
            release = r;
            break;
        }
        const rel = release orelse return null;

        const tag_name_val = rel.object.get("tag_name") orelse return null;
        const latest_version = if (tag_name_val == .string) tag_name_val.string else return null;

        const assets_val = rel.object.get("assets") orelse return null;

        const links_val = if (assets_val == .object) assets_val.object.get("links") else null;
        if (links_val == null) return null;

        const links = links_val.?;
        if (links != .array) return null;
        const download_url = try selectReleaseAssetUrl(
            allocator,
            links.array.items,
            app_name,
            "url",
        ) orelse return null;

        return @as(?appimage.AppImageUpdate, try makeUpdate(allocator, app_name, latest_version, download_url, current_version));
    }

    fn makeUpdate(
        allocator: std.mem.Allocator,
        app_name: []const u8,
        version: []const u8,
        download_url: []const u8,
        current_version: []const u8,
    ) !appimage.AppImageUpdate {
        const is_available = updateIsAvailable(current_version, version);
        const owned_name = try allocator.dupe(u8, app_name);
        errdefer allocator.free(owned_name);
        const owned_version = try allocator.dupe(u8, version);
        errdefer allocator.free(owned_version);
        const owned_url = try allocator.dupe(u8, download_url);
        return .{
            .name = owned_name,
            .version = owned_version,
            .download_url = owned_url,
            .is_update_available = is_available,
        };
    }

    fn fetchJson(self: UpdateManager, url: []const u8, accept: []const u8) !?[]u8 {
        try self.checkCancelled();
        const uri = std.Uri.parse(url) catch {
            self.emitStatus(.err, "The AppImage update provider URL is invalid.");
            return null;
        };

        var client: HttpClient = .{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();
        const headers = [_]std.http.Header{.{ .name = "accept", .value = accept }};
        var request = client.request(.GET, uri, .{
            .headers = .{
                .user_agent = .{ .override = "Shelly-AppImage-Manager/3.0" },
                .accept_encoding = .{ .override = "identity" },
            },
            .extra_headers = &headers,
            .redirect_behavior = .init(10),
        }) catch {
            self.emitStatus(.err, "Could not connect to the AppImage update provider.");
            return null;
        };
        defer request.deinit();
        request.accept_encoding[@intFromEnum(std.http.ContentEncoding.gzip)] = false;
        request.accept_encoding[@intFromEnum(std.http.ContentEncoding.deflate)] = false;
        request.sendBodiless() catch {
            self.emitStatus(.err, "Could not send the AppImage update request.");
            return null;
        };

        var redirect_buffer: [8 * 1024]u8 = undefined;
        var response = request.receiveHead(&redirect_buffer) catch {
            self.emitStatus(.err, "Could not receive the AppImage update response.");
            return null;
        };
        if (response.head.status.class() != .success) {
            self.emitStatusFmt(.warning, "AppImage update provider returned HTTP {d}.", .{@intFromEnum(response.head.status)});
            return null;
        }

        var transfer_buffer: [8 * 1024]u8 = undefined;
        const body_reader = response.reader(&transfer_buffer);
        var body: std.ArrayList(u8) = .empty;
        errdefer body.deinit(self.allocator);
        var read_buffer: [16 * 1024]u8 = undefined;
        while (true) {
            try self.checkCancelled();
            const amount = body_reader.readSliceShort(&read_buffer) catch {
                self.emitStatus(.err, "Could not read the AppImage update response.");
                return null;
            };
            if (amount == 0) break;
            if (body.items.len + amount > 16 * 1024 * 1024) {
                self.emitStatus(.err, "The AppImage update response was too large.");
                return null;
            }
            try body.appendSlice(self.allocator, read_buffer[0..amount]);
        }
        return @as(?[]u8, try body.toOwnedSlice(self.allocator));
    }

    fn endsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len > haystack.len) return false;
        const tail = haystack[haystack.len - needle.len ..];
        return std.ascii.eqlIgnoreCase(tail, needle);
    }

    pub fn isAppImage(file_path: []const u8) bool {
        return appimage_manager.AppImageManager.isAppImage(file_path);
    }

    pub fn is_appimage(file_path: []const u8) bool {
        return isAppImage(file_path);
    }

    fn normalizeVersionToken(raw: []const u8) []const u8 {
        var token = std.mem.trim(u8, raw, &std.ascii.whitespace);
        token = std.mem.trim(u8, token, "\"");
        token = std.mem.trim(u8, token, &std.ascii.whitespace);
        if (token.len > 1 and (token[0] == 'v' or token[0] == 'V') and std.ascii.isDigit(token[1])) {
            token = token[1..];
        }
        return token;
    }

    fn isNumericDottedVersion(version: []const u8) bool {
        if (std.mem.indexOfScalar(u8, version, '.') == null) return false;
        var components = std.mem.splitScalar(u8, version, '.');
        while (components.next()) |component| {
            if (component.len == 0) return false;
            for (component) |character| {
                if (!std.ascii.isDigit(character)) return false;
            }
        }
        return true;
    }

    fn compareNumericVersions(a: []const u8, b: []const u8) std.math.Order {
        var a_components = std.mem.splitScalar(u8, a, '.');
        var b_components = std.mem.splitScalar(u8, b, '.');
        while (true) {
            const a_component = a_components.next();
            const b_component = b_components.next();
            if (a_component == null and b_component == null) return .eq;
            const a_value: u64 = if (a_component) |component|
                std.fmt.parseInt(u64, component, 10) catch std.math.maxInt(u64)
            else
                0;
            const b_value: u64 = if (b_component) |component|
                std.fmt.parseInt(u64, component, 10) catch std.math.maxInt(u64)
            else
                0;
            if (a_value != b_value) return std.math.order(a_value, b_value);
        }
    }

    fn updateIsAvailable(current_version: []const u8, remote_version: []const u8) bool {
        const current = normalizeVersionToken(current_version);
        const remote = normalizeVersionToken(remote_version);
        if (current.len == 0 or std.ascii.eqlIgnoreCase(current, "unknown")) return true;
        if (remote.len == 0) return true;
        if (isNumericDottedVersion(current) and isNumericDottedVersion(remote)) {
            return compareNumericVersions(remote, current) == .gt;
        }
        return !std.ascii.eqlIgnoreCase(current, remote);
    }

    fn releaseTagMatches(installed_tag: ?[]const u8, remote_version: []const u8) bool {
        const tag = installed_tag orelse return false;
        if (tag.len == 0) return false;
        return std.ascii.eqlIgnoreCase(normalizeVersionToken(tag), normalizeVersionToken(remote_version));
    }

    fn applyInstalledReleaseGuard(app: *const appimage.AppImage, result: *appimage.AppImageUpdate) void {
        if (result.is_update_available and releaseTagMatches(app.release_tag, result.version)) {
            std.log.debug("AppImage {s} already has release '{s}' installed; suppressing update.", .{ app.name, result.version });
            result.is_update_available = false;
        }
    }

    fn appImageManager(self: UpdateManager) appimage_manager.AppImageManager {
        return .{
            .allocator = self.allocator,
            .io = self.io,
            .environ = self.environ,
            .install_directory = self.install_directory,
            .local_db_path = self.local_db_path,
            .dispatcher = self.dispatcher,
            .operation_context = self.operation_context,
        };
    }

    fn emitMissingRepository(self: UpdateManager, app_name: []const u8) void {
        self.emitStatusFmt(.warning, "AppImage {s} has incomplete repository update configuration.", .{app_name});
    }

    fn providerUpdateOrWarn(self: UpdateManager, app_name: []const u8, result: ?appimage.AppImageUpdate) ?appimage.AppImageUpdate {
        if (result == null) {
            self.emitStatusFmt(
                .warning,
                "No compatible downloadable AppImage release asset was found for {s}.",
                .{app_name},
            );
        }
        return result;
    }

    fn emitStatus(self: UpdateManager, kind: events.StatusKind, message: []const u8) void {
        if (self.dispatcher) |dispatcher| dispatcher.raiseStatus(.{ .kind = kind, .message = message });
    }

    fn emitStatusFmt(self: UpdateManager, kind: events.StatusKind, comptime format: []const u8, args: anytype) void {
        const message = std.fmt.allocPrint(self.allocator, format, args) catch {
            self.emitStatus(kind, "AppImage update status unavailable.");
            return;
        };
        defer self.allocator.free(message);
        self.emitStatus(kind, message);
    }

    fn emitProgress(self: UpdateManager, stage: []const u8, message: []const u8, completed: usize, total: usize) void {
        if (self.dispatcher) |dispatcher| {
            if (dispatcher.operation) |operation| operation.progress(.{
                .stage = stage,
                .completed = @intCast(completed),
                .total = @intCast(total),
                .percentage = if (total == 0) 100 else @as(f64, @floatFromInt(completed)) * 100.0 / @as(f64, @floatFromInt(total)),
                .message = message,
            });
        }
    }

    fn checkCancelled(self: UpdateManager) error{Cancelled}!void {
        if (self.dispatcher) |dispatcher| {
            if (dispatcher.operation) |operation| try operation.checkCancelled();
        }
        if (self.operation_context) |context| {
            if (context.isCancelled()) return error.Cancelled;
        }
    }

    fn emitDownloadProgress(self: UpdateManager, app_name: []const u8, progress: downloader.DownloadProgress) void {
        const percentage: ?f64 = if (progress.bytes_total) |total|
            if (total == 0)
                100.0
            else
                @as(f64, @floatFromInt(progress.bytes_downloaded)) / @as(f64, @floatFromInt(total)) * 100.0
        else
            null;
        if (self.dispatcher) |dispatcher| dispatcher.raiseDownloadProgress(.{
            .app_name = app_name,
            .total_bytes = progress.bytes_total,
            .downloaded_bytes = progress.bytes_downloaded,
            .percentage = percentage,
        });
    }

    const DownloadContext = struct {
        manager: UpdateManager,
        app_name: []const u8,
    };

    fn onDownloadEvent(raw_context: ?*anyopaque, event: downloader.DownloadEvent) void {
        const context: *DownloadContext = @ptrCast(@alignCast(raw_context orelse return));
        switch (event.event_type) {
            .Start, .Progress, .Complete => if (event.progress) |progress| {
                context.manager.emitDownloadProgress(context.app_name, progress);
            },
            .Error => if (event.download_error) |download_error| {
                context.manager.emitStatusFmt(.err, "AppImage download failed: {s}", .{@errorName(download_error)});
            },
            .Skipped => context.manager.emitStatus(.information, "AppImage download was skipped."),
        }
    }
};

test "test isAppImage" {
    const result = UpdateManager.is_appimage("xxx.appImage");
    const result2 = UpdateManager.is_appimage("xxx.appimage");
    const result3 = UpdateManager.is_appimage("xxx.ApPiMagE");
    try std.testing.expect(result);
    try std.testing.expect(result2);
    try std.testing.expect(result3);
    try std.testing.expect(!UpdateManager.isAppImage("xxx.AppImage.txt"));
}

test "updateIsAvailable: formats and normalize v prefixes and quotes" {
    // v-prefixed provider tag vs plain embedded version — the reported bug.
    try std.testing.expect(UpdateManager.updateIsAvailable("1.7.4", "v1.7.4") == false);
    try std.testing.expect(UpdateManager.updateIsAvailable("1.7.0", "v1.7.4") == true);
    // Quotes and surrounding whitespace are ignored.
    try std.testing.expect(UpdateManager.updateIsAvailable("1.7.4", " \"v1.7.4\" ") == false);
    try std.testing.expect(UpdateManager.updateIsAvailable("\"1.7.4\"", "v1.7.4") == false);
    // Case-insensitive equality.
    try std.testing.expect(UpdateManager.updateIsAvailable("1.7.4", "1.7.4") == false);
}

test "updateIsAvailable: compares dotted numeric versions semantically" {
    try std.testing.expect(UpdateManager.updateIsAvailable("1.7.4", "1.7.5") == true);
    try std.testing.expect(UpdateManager.updateIsAvailable("1.7.4", "1.10.0") == true);
    try std.testing.expect(UpdateManager.updateIsAvailable("1.7.10", "1.7.9") == false);
    try std.testing.expect(UpdateManager.updateIsAvailable("2.0.0", "1.99.99") == false);
    // Component count differences follow semver rules.
    try std.testing.expect(UpdateManager.updateIsAvailable("1.7", "1.7.0") == false);
    try std.testing.expect(UpdateManager.updateIsAvailable("1.7", "1.7.1") == true);
    try std.testing.expect(UpdateManager.updateIsAvailable("1.7.0", "1.8") == true);
}

test "updateIsAvailable: refuses downgrades" {
    try std.testing.expect(UpdateManager.updateIsAvailable("2.0.0", "v1.9.0") == false);
}

test "updateIsAvailable: unknown or empty local versions always update" {
    try std.testing.expect(UpdateManager.updateIsAvailable("Unknown", "v1.7.4") == true);
    try std.testing.expect(UpdateManager.updateIsAvailable("", "v1.7.4") == true);
    try std.testing.expect(UpdateManager.updateIsAvailable("1.7.4", "") == true);
}

test "updateIsAvailable: non-semantic markers keep string comparison" {
    // ETags and dates are not dotted numeric versions; any change counts.
    try std.testing.expect(UpdateManager.updateIsAvailable("abc123", "abc123") == false);
    try std.testing.expect(UpdateManager.updateIsAvailable("abc123", "def456") == true);
    // Calendar tags stay single tokens.
    try std.testing.expect(UpdateManager.updateIsAvailable("20250801", "20250801") == false);
    try std.testing.expect(UpdateManager.updateIsAvailable("20250801", "20250901") == true);
    // Mixed tokens (e.g. 1.7.4-beta) fall back to string equality.
    try std.testing.expect(UpdateManager.updateIsAvailable("1.7.4-beta", "v1.7.4") == true);
}

test "releaseTagMatches: guard suppresses re-offering the installed release" {
    const app = appimage.AppImage{
        .name = "ARDM",
        .version = "1.7.4",
        .release_tag = "v1.7.4",
    };
    var update = appimage.AppImageUpdate{
        .name = "ARDM",
        .version = "v1.7.4",
        .download_url = "https://example.com/ARDM.AppImage",
        .is_update_available = true,
    };
    UpdateManager.applyInstalledReleaseGuard(&app, &update);
    try std.testing.expect(!update.is_update_available);

    // A different release is not suppressed.
    var newer = appimage.AppImageUpdate{
        .name = "ARDM",
        .version = "v1.7.5",
        .download_url = "https://example.com/ARDM.AppImage",
        .is_update_available = true,
    };
    UpdateManager.applyInstalledReleaseGuard(&app, &newer);
    try std.testing.expect(newer.is_update_available);

    // Absent or empty tags never suppress.
    const untagged = appimage.AppImage{ .name = "ARDM", .version = "1.7.4" };
    var untagged_update = appimage.AppImageUpdate{
        .name = "ARDM",
        .version = "v1.7.4",
        .download_url = "https://example.com/ARDM.AppImage",
        .is_update_available = true,
    };
    UpdateManager.applyInstalledReleaseGuard(&untagged, &untagged_update);
    try std.testing.expect(untagged_update.is_update_available);
}

test "test sysarch assume x86_64" {
    const sys_arch = UpdateManager.getSystemArchitecture();
    try std.testing.expectEqualStrings("x86_64", sys_arch);
}

test "test isCorrectArchitecture - x86_64" {
    const result1 = UpdateManager.isCorrectArchitecture("my-app-x86_64.AppImage");
    try std.testing.expect(result1);
}

test "configureUpdates: None resets url and repo fields" {
    var app = appimage.AppImage{
        .name = "Test",
        .update_type = .github,
        .update_url = "stale",
        .repo_owner = "old-owner",
        .repo_name = "old-repo",
    };

    try UpdateManager.configure_update("ignored", .none, &app, true);

    try std.testing.expectEqual(appimage.UpdateType.none, app.update_type);
    try std.testing.expectEqualStrings("", app.update_url);
    try std.testing.expectEqual(@as(?[]const u8, null), app.repo_owner);
    try std.testing.expectEqual(@as(?[]const u8, null), app.repo_name);
    try std.testing.expectEqual(true, app.allow_prerelease);
}

test "configureUpdates: StaticUrl stores the url verbatim" {
    var app = appimage.AppImage{
        .name = "Test",
        .repo_owner = "stale-owner",
        .repo_name = "stale-repo",
    };

    try UpdateManager.configure_update("https://example.com/update.json", .static_url, &app, false);

    try std.testing.expectEqual(appimage.UpdateType.static_url, app.update_type);
    try std.testing.expectEqualStrings("https://example.com/update.json", app.update_url);
    try std.testing.expect(app.repo_owner == null);
    try std.testing.expect(app.repo_name == null);
}

test "configureUpdates: Forgejo accepts a well-formed url" {
    var app = appimage.AppImage{
        .name = "Test",
        .repo_owner = "stale-owner",
        .repo_name = "stale-repo",
    };

    try UpdateManager.configure_update("https://codeberg.org/user/repo", .forgejo, &app, false);

    try std.testing.expectEqual(appimage.UpdateType.forgejo, app.update_type);
    try std.testing.expectEqualStrings("https://codeberg.org/user/repo", app.update_url);
    try std.testing.expect(app.repo_owner == null);
    try std.testing.expect(app.repo_name == null);
}

test "configureUpdates: Forgejo normalizes repository release pages" {
    var app = appimage.AppImage{ .name = "Test" };

    try UpdateManager.configure_update(
        " https://git.eden-emu.dev/eden-ci/nightly/releases/ ",
        .forgejo,
        &app,
        true,
    );

    try std.testing.expectEqual(appimage.UpdateType.forgejo, app.update_type);
    try std.testing.expectEqualStrings("https://git.eden-emu.dev/eden-ci/nightly", app.update_url);
    try std.testing.expect(app.allow_prerelease);
}

test "configureUpdates: Forgejo rejects a url missing the scheme separator" {
    var app = appimage.AppImage{ .name = "Test", .update_type = .none };

    try std.testing.expectError(
        error.InvalidAppImageUpdateConfiguration,
        UpdateManager.configure_update("codeberg.org/user/repo", .forgejo, &app, false),
    );

    try std.testing.expectEqual(appimage.UpdateType.none, app.update_type);
}

test "configureUpdates: Forgejo rejects a url with the wrong path depth" {
    var app = appimage.AppImage{
        .name = "Test",
        .update_url = "https://old.example/owner/repo",
        .update_type = .forgejo,
    };

    try std.testing.expectError(
        error.InvalidAppImageUpdateConfiguration,
        UpdateManager.configure_update("https://codeberg.org/user/repo/extra", .forgejo, &app, false),
    );

    try std.testing.expectEqual(appimage.UpdateType.forgejo, app.update_type);
    try std.testing.expectEqualStrings("https://old.example/owner/repo", app.update_url);
}

test "configureUpdates: GitHub/GitLab/Codeberg split owner and repo" {
    var app = appimage.AppImage{ .name = "Test", .update_url = "https://stale.example/update" };

    try UpdateManager.configure_update("torvalds/linux", .github, &app, false);

    try std.testing.expectEqual(appimage.UpdateType.github, app.update_type);
    try std.testing.expectEqualStrings("", app.update_url);
    try std.testing.expectEqualStrings("torvalds", app.repo_owner.?);
    try std.testing.expectEqualStrings("linux", app.repo_name.?);
}

test "configureUpdates: GitLab works identically to GitHub" {
    var app = appimage.AppImage{ .name = "Test" };

    try UpdateManager.configure_update("gitlab-org/gitlab", .gitlab, &app, false);

    try std.testing.expectEqual(appimage.UpdateType.gitlab, app.update_type);
    try std.testing.expectEqualStrings("gitlab-org", app.repo_owner.?);
    try std.testing.expectEqualStrings("gitlab", app.repo_name.?);
}

test "configureUpdates: Codeberg rejects malformed owner/repo (no slash)" {
    var app = appimage.AppImage{ .name = "Test", .repo_owner = null, .repo_name = null, .update_type = .none };

    try std.testing.expectError(
        error.InvalidAppImageUpdateConfiguration,
        UpdateManager.configure_update("just-a-name", .codeberg, &app, false),
    );

    try std.testing.expectEqual(appimage.UpdateType.none, app.update_type);
    try std.testing.expectEqual(@as(?[]const u8, null), app.repo_owner);
    try std.testing.expectEqual(@as(?[]const u8, null), app.repo_name);
}

test "configureUpdates: GitHub rejects malformed owner/repo (too many slashes)" {
    var app = appimage.AppImage{ .name = "Test", .update_type = .none };

    try std.testing.expectError(
        error.InvalidAppImageUpdateConfiguration,
        UpdateManager.configure_update("owner/repo/extra", .github, &app, false),
    );

    try std.testing.expectEqual(appimage.UpdateType.none, app.update_type);
}

test "configureUpdates: failed validation does not partially apply prerelease" {
    var app = appimage.AppImage{ .name = "Test" };

    try std.testing.expectError(
        error.InvalidAppImageUpdateConfiguration,
        UpdateManager.configure_update("malformed", .github, &app, true),
    );

    try std.testing.expect(!app.allow_prerelease);
}

test "configureUpdates: StaticUrl rejects a non-http url without mutation" {
    var app = appimage.AppImage{
        .name = "Test",
        .update_url = "https://old.example/update",
        .update_type = .static_url,
    };

    try std.testing.expectError(
        error.InvalidAppImageUpdateConfiguration,
        UpdateManager.configure_update("file:///tmp/Test.AppImage", .static_url, &app, true),
    );

    try std.testing.expectEqual(appimage.UpdateType.static_url, app.update_type);
    try std.testing.expectEqualStrings("https://old.example/update", app.update_url);
    try std.testing.expect(!app.allow_prerelease);
}

test "github_to_releases_api builds correct url" {
    const url = try UpdateManager.github_to_releases_api(std.testing.allocator, "ppy", "osu");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://api.github.com/repos/ppy/osu/releases", url);
}

test "gitlab_to_releases_api builds correct url with encoded path" {
    const url = try UpdateManager.gitlab_to_releases_api(std.testing.allocator, "gitlab-org", "gitlab");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://gitlab.com/api/v4/projects/gitlab-org%2Fgitlab/releases", url);
}

test "parse_github_response: returns null for empty array" {
    const body = "[]";
    const result = try UpdateManager.parse_github_response(std.testing.allocator, body, "osu", "0.0.0", false);
    try std.testing.expectEqual(@as(?appimage.AppImageUpdate, null), result);
}

test "parse_github_response: returns null for invalid json" {
    const body = "not json";
    const result = try UpdateManager.parse_github_response(std.testing.allocator, body, "osu", "0.0.0", false);
    try std.testing.expectEqual(@as(?appimage.AppImageUpdate, null), result);
}

test "parse_github_response: skips prerelease when allow_prerelease=false" {
    const body =
        \\[
        \\  {"tag_name":"2025.701.0","prerelease":true,"assets":[{"name":"osu.AppImage","browser_download_url":"https://example.com/prerelease/osu.AppImage"}]},
        \\  {"tag_name":"2025.630.0","prerelease":false,"assets":[{"name":"osu.AppImage","browser_download_url":"https://example.com/stable/osu.AppImage"}]}
        \\]
    ;
    const result = try UpdateManager.parse_github_response(std.testing.allocator, body, "osu", "0.0.0", false);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("2025.630.0", result.?.version);
}

test "parse_github_response: includes prerelease when allow_prerelease=true" {
    const body =
        \\[
        \\  {"tag_name":"2025.701.0","prerelease":true,"assets":[{"name":"osu.AppImage","browser_download_url":"https://example.com/prerelease/osu.AppImage"}]},
        \\  {"tag_name":"2025.630.0","prerelease":false,"assets":[{"name":"osu.AppImage","browser_download_url":"https://example.com/stable/osu.AppImage"}]}
        \\]
    ;
    const result = try UpdateManager.parse_github_response(std.testing.allocator, body, "osu", "0.0.0", true);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("2025.701.0", result.?.version);
}

test "parse_github_response: picks single AppImage asset (ppy/osu style)" {
    const body =
        \\[{
        \\  "tag_name": "2025.630.0",
        \\  "prerelease": false,
        \\  "assets": [
        \\    {"name":"osu.AppImage","browser_download_url":"https://github.com/ppy/osu/releases/download/2025.630.0/osu.AppImage"},
        \\    {"name":"osu.dmg","browser_download_url":"https://github.com/ppy/osu/releases/download/2025.630.0/osu.dmg"}
        \\  ]
        \\}]
    ;
    const result = try UpdateManager.parse_github_response(std.testing.allocator, body, "osu", "0.0.0", false);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("osu", result.?.name);
    try std.testing.expectEqualStrings("2025.630.0", result.?.version);
    try std.testing.expectEqualStrings("https://github.com/ppy/osu/releases/download/2025.630.0/osu.AppImage", result.?.download_url);
    try std.testing.expect(result.?.is_update_available);
}

test "parse_github_response: picks exact installed basename when multiple AppImages present" {
    const body =
        \\[{
        \\  "tag_name": "2025.630.0",
        \\  "prerelease": false,
        \\  "assets": [
        \\    {"name":"DuckStation-arm64.AppImage","browser_download_url":"https://example.com/DuckStation-arm64.AppImage"},
        \\    {"name":"DuckStation-armhf.AppImage","browser_download_url":"https://example.com/DuckStation-armhf.AppImage"},
        \\    {"name":"DuckStation-x64-SSE2.AppImage","browser_download_url":"https://example.com/DuckStation-x64-SSE2.AppImage"},
        \\    {"name":"DuckStation-x64.AppImage","browser_download_url":"https://example.com/DuckStation-x64.AppImage"}
        \\  ]
        \\}]
    ;
    const result = try UpdateManager.parse_github_response(std.testing.allocator, body, "DuckStation-x64", "0.0.0", false);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("https://example.com/DuckStation-x64.AppImage", result.?.download_url);
}

test "parse_github_response: selects versioned assets reported in issue 1525" {
    const Case = struct {
        app_name: []const u8,
        current_version: []const u8,
        body: []const u8,
        expected_url: []const u8,
    };
    const cases = [_]Case{
        .{
            .app_name = "goverlay-1.8.8-x86_64",
            .current_version = "1.8.8",
            .body =
            \\[{"tag_name":"1.8.10","prerelease":false,"assets":[
            \\  {"name":"goverlay-1.8.10-aarch64.AppImage","browser_download_url":"https://example.com/goverlay-1.8.10-aarch64.AppImage"},
            \\  {"name":"goverlay-1.8.10-x86_64.AppImage","browser_download_url":"https://example.com/goverlay-1.8.10-x86_64.AppImage"}
            \\]}]
            ,
            .expected_url = "https://example.com/goverlay-1.8.10-x86_64.AppImage",
        },
        .{
            .app_name = "waywallen-x86_64",
            .current_version = "v0.2.5",
            .body =
            \\[{"tag_name":"v0.2.6","prerelease":false,"assets":[
            \\  {"name":"waywallen-0.2.6-x86_64.AppImage","browser_download_url":"https://example.com/waywallen-0.2.6-x86_64.AppImage"}
            \\]}]
            ,
            .expected_url = "https://example.com/waywallen-0.2.6-x86_64.AppImage",
        },
        .{
            .app_name = "QIDIStudio_Ubuntu24",
            .current_version = "v2.06.00.51",
            .body =
            \\[{"tag_name":"v2.07.02.10","prerelease":false,"assets":[
            \\  {"name":"QIDIStudio_v02.07.02.10_Ubuntu22.AppImage","browser_download_url":"https://example.com/QIDIStudio_v02.07.02.10_Ubuntu22.AppImage"},
            \\  {"name":"QIDIStudio_v02.07.02.10_Ubuntu24.AppImage","browser_download_url":"https://example.com/QIDIStudio_v02.07.02.10_Ubuntu24.AppImage"}
            \\]}]
            ,
            .expected_url = "https://example.com/QIDIStudio_v02.07.02.10_Ubuntu24.AppImage",
        },
    };

    for (cases) |case| {
        const result = try UpdateManager.parse_github_response(
            std.testing.allocator,
            case.body,
            case.app_name,
            case.current_version,
            false,
        );
        defer if (result) |update_result| update_result.deinit(std.testing.allocator);
        try std.testing.expect(result != null);
        try std.testing.expectEqualStrings(case.expected_url, result.?.download_url);
        try std.testing.expect(result.?.is_update_available);
    }
}

test "parse_github_response: refuses ambiguous compatible AppImage assets" {
    const body =
        \\[{"tag_name":"v2.0.0","prerelease":false,"assets":[
        \\  {"name":"editor-standard-x86_64.AppImage","browser_download_url":"https://example.com/editor-standard-x86_64.AppImage"},
        \\  {"name":"editor-portable-x86_64.AppImage","browser_download_url":"https://example.com/editor-portable-x86_64.AppImage"}
        \\]}]
    ;
    const result = try UpdateManager.parse_github_response(std.testing.allocator, body, "editor", "v1.0.0", false);
    try std.testing.expectEqual(@as(?appimage.AppImageUpdate, null), result);
}

test "parse_github_response: ignores AppImage assets without a valid download URL" {
    const body =
        \\[{"tag_name":"v2.0.0","prerelease":false,"assets":[
        \\  {"name":"editor.AppImage","browser_download_url":""},
        \\  {"name":"editor-x86_64.AppImage","browser_download_url":"file:///tmp/editor.AppImage"}
        \\]}]
    ;
    const result = try UpdateManager.parse_github_response(std.testing.allocator, body, "editor", "v1.0.0", false);
    try std.testing.expectEqual(@as(?appimage.AppImageUpdate, null), result);
}

test "parse_github_response: rejects a sole incompatible architecture asset" {
    const body = if (std.mem.eql(u8, UpdateManager.getSystemArchitecture(), "x86_64"))
        \\[{"tag_name":"v2.0.0","prerelease":false,"assets":[
        \\  {"name":"editor-aarch64.AppImage","browser_download_url":"https://example.com/editor-aarch64.AppImage"}
        \\]}]
    else
        \\[{"tag_name":"v2.0.0","prerelease":false,"assets":[
        \\  {"name":"editor-x86_64.AppImage","browser_download_url":"https://example.com/editor-x86_64.AppImage"}
        \\]}]
    ;
    const result = try UpdateManager.parse_github_response(std.testing.allocator, body, "editor", "v1.0.0", false);
    try std.testing.expectEqual(@as(?appimage.AppImageUpdate, null), result);
}

test "parse_github_response: normalized matching is case insensitive" {
    const body =
        \\[{"tag_name":"v2.0.0","prerelease":false,"assets":[
        \\  {"name":"mytool-2.0.AppImage","browser_download_url":"https://example.com/mytool-2.0.AppImage"},
        \\  {"name":"another-tool.AppImage","browser_download_url":"https://example.com/another-tool.AppImage"}
        \\]}]
    ;
    const result = try UpdateManager.parse_github_response(std.testing.allocator, body, "MyTool-1.0", "v1.0.0", false);
    defer if (result) |update_result| update_result.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("https://example.com/mytool-2.0.AppImage", result.?.download_url);
}

test "parse_github_response: skips malformed assets before selecting a valid one" {
    const body =
        \\[{"tag_name":"v2.0.0","prerelease":false,"assets":[
        \\  null,
        \\  "not-an-object",
        \\  {"name":42,"browser_download_url":"https://example.com/wrong-name-type.AppImage"},
        \\  {"name":"missing-url.AppImage"},
        \\  {"name":"wrong-url-type.AppImage","browser_download_url":42},
        \\  {"name":"editor.AppImage","browser_download_url":"https://example.com/editor.AppImage"}
        \\]}]
    ;
    const result = try UpdateManager.parse_github_response(std.testing.allocator, body, "editor", "v1.0.0", false);
    defer if (result) |update_result| update_result.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("https://example.com/editor.AppImage", result.?.download_url);
}

test "parse_github_response: is_update_available false when version matches" {
    const body =
        \\[{"tag_name":"2025.630.0","prerelease":false,"assets":[{"name":"osu.AppImage","browser_download_url":"https://example.com/osu.AppImage"}]}]
    ;
    const result = try UpdateManager.parse_github_response(std.testing.allocator, body, "osu", "2025.630.0", false);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expect(!result.?.is_update_available);
}

test "parse_github_response: no assets key returns null" {
    const body =
        \\[{"tag_name":"2025.630.0","prerelease":false}]
    ;
    const result = try UpdateManager.parse_github_response(std.testing.allocator, body, "osu", "0.0.0", false);
    try std.testing.expectEqual(@as(?appimage.AppImageUpdate, null), result);
}

test "parse_gitlab_response: returns null for empty array" {
    const body = "[]";
    const result = try UpdateManager.parse_gitlab_response(std.testing.allocator, body, "myapp", "0.0.0", false);
    try std.testing.expectEqual(@as(?appimage.AppImageUpdate, null), result);
}

test "parse_gitlab_response: skips upcoming_release when allow_prerelease=false" {
    const body =
        \\[
        \\  {"tag_name":"v2.0.0","upcoming_release":true,"assets":{"links":[{"name":"myapp.AppImage","url":"https://example.com/upcoming/myapp.AppImage"}]}},
        \\  {"tag_name":"v1.9.0","upcoming_release":false,"assets":{"links":[{"name":"myapp.AppImage","url":"https://example.com/stable/myapp.AppImage"}]}}
        \\]
    ;
    const result = try UpdateManager.parse_gitlab_response(std.testing.allocator, body, "myapp", "0.0.0", false);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("v1.9.0", result.?.version);
}

test "parse_gitlab_response: includes upcoming_release when allow_prerelease=true" {
    const body =
        \\[
        \\  {"tag_name":"v2.0.0","upcoming_release":true,"assets":{"links":[{"name":"myapp.AppImage","url":"https://example.com/upcoming/myapp.AppImage"}]}},
        \\  {"tag_name":"v1.9.0","upcoming_release":false,"assets":{"links":[{"name":"myapp.AppImage","url":"https://example.com/stable/myapp.AppImage"}]}}
        \\]
    ;
    const result = try UpdateManager.parse_gitlab_response(std.testing.allocator, body, "myapp", "0.0.0", true);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("v2.0.0", result.?.version);
}

test "parse_gitlab_response: picks single AppImage link" {
    const body =
        \\[{
        \\  "tag_name": "v1.9.0",
        \\  "upcoming_release": false,
        \\  "assets": {
        \\    "links": [
        \\      {"name":"myapp-x86_64.AppImage","url":"https://gitlab.com/mygroup/myapp/-/releases/v1.9.0/downloads/myapp-x86_64.AppImage"},
        \\      {"name":"myapp.tar.gz","url":"https://gitlab.com/mygroup/myapp/-/releases/v1.9.0/downloads/myapp.tar.gz"}
        \\    ]
        \\  }
        \\}]
    ;
    const result = try UpdateManager.parse_gitlab_response(std.testing.allocator, body, "myapp", "0.0.0", false);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("myapp", result.?.name);
    try std.testing.expectEqualStrings("v1.9.0", result.?.version);
    try std.testing.expectEqualStrings("https://gitlab.com/mygroup/myapp/-/releases/v1.9.0/downloads/myapp-x86_64.AppImage", result.?.download_url);
    try std.testing.expect(result.?.is_update_available);
}

test "parse_gitlab_response: selects a case-insensitive versioned match among multiple links" {
    const body =
        \\[{"tag_name":"v2.0.0","upcoming_release":false,"assets":{"links":[
        \\  {"name":"editor-standard-2.0.AppImage","url":"https://example.com/editor-standard-2.0.AppImage"},
        \\  {"name":"editor-pro-2.0.AppImage","url":"https://example.com/editor-pro-2.0.AppImage"}
        \\]}}]
    ;
    const result = try UpdateManager.parse_gitlab_response(std.testing.allocator, body, "Editor_Pro-1.0", "v1.0.0", false);
    defer if (result) |update_result| update_result.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("https://example.com/editor-pro-2.0.AppImage", result.?.download_url);
}

test "parse_gitlab_response: no assets key returns null" {
    const body =
        \\[{"tag_name":"v1.9.0","upcoming_release":false}]
    ;
    const result = try UpdateManager.parse_gitlab_response(std.testing.allocator, body, "myapp", "0.0.0", false);
    try std.testing.expectEqual(@as(?appimage.AppImageUpdate, null), result);
}

test "gitea_to_releases_api builds correct url" {
    const url = try UpdateManager.gitea_to_releases_api(std.testing.allocator, "codeberg.org", "user", "myapp");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://codeberg.org/api/v1/repos/user/myapp/releases", url);
}

test "gitea_to_releases_api builds correct url for custom forgejo domain" {
    const url = try UpdateManager.gitea_to_releases_api(std.testing.allocator, "git.example.com", "alice", "tool");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://git.example.com/api/v1/repos/alice/tool/releases", url);
}

test "parse_github_response: codeberg/forgejo style response (same shape as github)" {
    const body =
        \\[{
        \\  "tag_name": "v1.2.3",
        \\  "prerelease": false,
        \\  "assets": [
        \\    {"name":"myapp-x86_64.AppImage","browser_download_url":"https://codeberg.org/user/myapp/releases/download/v1.2.3/myapp-x86_64.AppImage"}
        \\  ]
        \\}]
    ;
    const result = try UpdateManager.parse_github_response(std.testing.allocator, body, "myapp-x86_64", "0.0.0", false);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("myapp-x86_64", result.?.name);
    try std.testing.expectEqualStrings("v1.2.3", result.?.version);
    try std.testing.expectEqualStrings("https://codeberg.org/user/myapp/releases/download/v1.2.3/myapp-x86_64.AppImage", result.?.download_url);
    try std.testing.expect(result.?.is_update_available);
}

test "parse_github_response: forgejo skips prerelease when allow_prerelease=false" {
    const body =
        \\[
        \\  {"tag_name":"v2.0.0-beta","prerelease":true,"assets":[{"name":"myapp.AppImage","browser_download_url":"https://example.com/prerelease/myapp.AppImage"}]},
        \\  {"tag_name":"v1.9.0","prerelease":false,"assets":[{"name":"myapp.AppImage","browser_download_url":"https://example.com/stable/myapp.AppImage"}]}
        \\]
    ;
    const result = try UpdateManager.parse_github_response(std.testing.allocator, body, "myapp", "0.0.0", false);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("v1.9.0", result.?.version);
}

test "parse_github_response: forgejo includes prerelease when allow_prerelease=true" {
    const body =
        \\[
        \\  {"tag_name":"v2.0.0-beta","prerelease":true,"assets":[{"name":"myapp.AppImage","browser_download_url":"https://example.com/prerelease/myapp.AppImage"}]},
        \\  {"tag_name":"v1.9.0","prerelease":false,"assets":[{"name":"myapp.AppImage","browser_download_url":"https://example.com/stable/myapp.AppImage"}]}
        \\]
    ;
    const result = try UpdateManager.parse_github_response(std.testing.allocator, body, "myapp", "0.0.0", true);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("v2.0.0-beta", result.?.version);
}

test "build_static_url: uses etag as version and strips quotes" {
    const result = try UpdateManager.build_static_url(std.testing.allocator, "myapp", "https://example.com/myapp.AppImage", "0.0.0", "\"abc123\"");
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("myapp", result.?.name);
    try std.testing.expectEqualStrings("abc123", result.?.version);
    try std.testing.expectEqualStrings("https://example.com/myapp.AppImage", result.?.download_url);
    try std.testing.expect(result.?.is_update_available);
}

test "build_static_url: uses last-modified as version when no etag quotes" {
    const result = try UpdateManager.build_static_url(std.testing.allocator, "myapp", "https://example.com/myapp.AppImage", "0.0.0", "Mon, 01 Jan 2025 00:00:00 GMT");
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("Mon, 01 Jan 2025 00:00:00 GMT", result.?.version);
    try std.testing.expectEqualStrings("https://example.com/myapp.AppImage", result.?.download_url);
    try std.testing.expect(result.?.is_update_available);
}

test "build_static_url: is_update_available false when version matches etag" {
    const result = try UpdateManager.build_static_url(std.testing.allocator, "myapp", "https://example.com/myapp.AppImage", "abc123", "\"abc123\"");
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expect(!result.?.is_update_available);
}

test "build_static_url: empty raw_version yields empty version string and update available" {
    const result = try UpdateManager.build_static_url(std.testing.allocator, "myapp", "https://example.com/myapp.AppImage", "1.0.0", "");
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("", result.?.version);
    try std.testing.expect(result.?.is_update_available);
}

test "build_static_url: current version Unknown always reports update available" {
    const result = try UpdateManager.build_static_url(std.testing.allocator, "myapp", "https://example.com/myapp.AppImage", "Unknown", "\"abc123\"");
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.is_update_available);
}

test "parse_gitlab_response: no links key returns null" {
    const body =
        \\[{"tag_name":"v1.9.0","upcoming_release":false,"assets":{}}]
    ;
    const result = try UpdateManager.parse_gitlab_response(std.testing.allocator, body, "myapp", "0.0.0", false);
    try std.testing.expectEqual(@as(?appimage.AppImageUpdate, null), result);
}

test "build_static_url: name is preserved in result" {
    const result = try UpdateManager.build_static_url(std.testing.allocator, "my-special-app", "https://example.com/app.AppImage", "0.0.0", "\"v2.0\"");
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("my-special-app", result.?.name);
    try std.testing.expectEqualStrings("v2.0", result.?.version);
    try std.testing.expect(result.?.is_update_available);
}

test "build_static_url: download_url is preserved verbatim" {
    const url = "https://releases.example.com/path/to/app-x86_64.AppImage";
    const result = try UpdateManager.build_static_url(std.testing.allocator, "app", url, "0.0.0", "etag-val");
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(url, result.?.download_url);
}

test "build_static_url: strips weak etag prefix and quotes" {
    const result = try UpdateManager.build_static_url(std.testing.allocator, "myapp", "https://example.com/myapp.AppImage", "0.0.0", "W/\"03a6517f9aeed6a2de262f80d7857df4\"");
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("03a6517f9aeed6a2de262f80d7857df4", result.?.version);
    try std.testing.expect(result.?.is_update_available);
}

test "build_static_url: weak etag matching current version reports no update" {
    const result = try UpdateManager.build_static_url(std.testing.allocator, "myapp", "https://example.com/myapp.AppImage", "abc123", "W/\"abc123\"");
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expect(!result.?.is_update_available);
}

test "normalizeStaticVersion: strips weak prefix and quotes, passes dates through" {
    try std.testing.expectEqualStrings("abc", UpdateManager.normalizeStaticVersion("W/\"abc\""));
    try std.testing.expectEqualStrings("abc", UpdateManager.normalizeStaticVersion("w/\"abc\""));
    try std.testing.expectEqualStrings("abc", UpdateManager.normalizeStaticVersion("\"abc\""));
    try std.testing.expectEqualStrings("Mon, 01 Jan 2025 00:00:00 GMT", UpdateManager.normalizeStaticVersion("Mon, 01 Jan 2025 00:00:00 GMT"));
    try std.testing.expectEqualStrings("", UpdateManager.normalizeStaticVersion(""));
}

test "contentTypeIsNotAppImage: rejects html text and feed types" {
    try std.testing.expect(UpdateManager.contentTypeIsNotAppImage("text/html"));
    try std.testing.expect(UpdateManager.contentTypeIsNotAppImage("text/html; charset=utf-8"));
    try std.testing.expect(UpdateManager.contentTypeIsNotAppImage("TEXT/HTML"));
    try std.testing.expect(UpdateManager.contentTypeIsNotAppImage("text/plain"));
    try std.testing.expect(UpdateManager.contentTypeIsNotAppImage("application/json"));
    try std.testing.expect(UpdateManager.contentTypeIsNotAppImage("application/json; charset=utf-8"));
    try std.testing.expect(UpdateManager.contentTypeIsNotAppImage("application/xml"));
    try std.testing.expect(UpdateManager.contentTypeIsNotAppImage("application/xhtml+xml"));
}

test "contentTypeIsNotAppImage: accepts binary and unknown types" {
    try std.testing.expect(!UpdateManager.contentTypeIsNotAppImage("application/octet-stream"));
    try std.testing.expect(!UpdateManager.contentTypeIsNotAppImage("application/x-appimage"));
    try std.testing.expect(!UpdateManager.contentTypeIsNotAppImage("application/vnd.appimage"));
    try std.testing.expect(!UpdateManager.contentTypeIsNotAppImage("application/x-executable"));
    try std.testing.expect(!UpdateManager.contentTypeIsNotAppImage("application/x-iso9660-appimage"));
    try std.testing.expect(!UpdateManager.contentTypeIsNotAppImage(""));
}

test "parse_github_response: is_update_available true when current is Unknown" {
    const body =
        \\[{"tag_name":"v1.0.0","prerelease":false,"assets":[{"name":"myapp.AppImage","browser_download_url":"https://example.com/myapp.AppImage"}]}]
    ;
    const result = try UpdateManager.parse_github_response(std.testing.allocator, body, "myapp", "Unknown", false);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.is_update_available);
}

test "parse_github_response: is_update_available false when versions match" {
    const body =
        \\[{"tag_name":"v1.0.0","prerelease":false,"assets":[{"name":"myapp.AppImage","browser_download_url":"https://example.com/myapp.AppImage"}]}]
    ;
    const result = try UpdateManager.parse_github_response(std.testing.allocator, body, "myapp", "v1.0.0", false);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expect(!result.?.is_update_available);
}

test "parse_gitlab_response: is_update_available true when current is Unknown" {
    const body =
        \\[{"tag_name":"v3.0.0","upcoming_release":false,"assets":{"links":[{"name":"myapp.AppImage","url":"https://example.com/myapp.AppImage"}]}}]
    ;
    const result = try UpdateManager.parse_gitlab_response(std.testing.allocator, body, "myapp", "Unknown", false);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.is_update_available);
}

test "parse_gitlab_response: is_update_available false when versions match" {
    const body =
        \\[{"tag_name":"v3.0.0","upcoming_release":false,"assets":{"links":[{"name":"myapp.AppImage","url":"https://example.com/myapp.AppImage"}]}}]
    ;
    const result = try UpdateManager.parse_gitlab_response(std.testing.allocator, body, "myapp", "v3.0.0", false);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expect(!result.?.is_update_available);
}

test "github_to_releases_api: owner and repo are embedded correctly" {
    const url = try UpdateManager.github_to_releases_api(std.testing.allocator, "my-org", "my-repo");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://api.github.com/repos/my-org/my-repo/releases", url);
}

test "gitlab_to_releases_api: slash in owner/repo is percent-encoded" {
    const url = try UpdateManager.gitlab_to_releases_api(std.testing.allocator, "my-group", "my-project");
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "%2F") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "my-group") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "my-project") != null);
}

fn makeUpdateManager(allocator: std.mem.Allocator, install_dir: []const u8, db_path: []const u8) UpdateManager {
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .environ = std.testing.environ,
        .install_directory = install_dir,
        .local_db_path = db_path,
    };
}

fn seedDb(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8, apps: []const appimage.AppImage) !void {
    const json_bytes = try std.json.Stringify.valueAlloc(allocator, apps, .{ .whitespace = .indent_2 });
    defer allocator.free(json_bytes);
    var file = try std.Io.Dir.cwd().createFile(io, db_path, .{});
    defer file.close(io);
    var write_buf: [4096]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    try writer.interface.writeAll(json_bytes);
    try writer.interface.flush();
}

test "configure_updates persists a normalized Forgejo release-page URL" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const root = path_buffer[0..path_length];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root, "appimage-metadata-v2.db" });
    defer std.testing.allocator.free(db_path);

    try seedDb(std.testing.allocator, std.testing.io, db_path, &.{
        .{
            .name = "Eden",
            .update_type = .github,
            .repo_owner = "stale-owner",
            .repo_name = "stale-repo",
        },
    });

    var manager = makeUpdateManager(std.testing.allocator, root, db_path);
    defer manager.deinit();
    try std.testing.expect(try manager.configure_updates(
        "https://git.eden-emu.dev/eden-ci/nightly/releases",
        "Eden",
        .forgejo,
        true,
    ));

    const database = appimage_manager.AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = std.testing.environ,
        .install_directory = root,
        .local_db_path = db_path,
    };
    const apps = try database.getAppImagesFromLocalDb();
    defer database.freeAppImages(apps);
    try std.testing.expectEqual(@as(usize, 1), apps.len);
    try std.testing.expectEqual(appimage.UpdateType.forgejo, apps[0].update_type);
    try std.testing.expectEqualStrings("https://git.eden-emu.dev/eden-ci/nightly", apps[0].update_url);
    try std.testing.expect(apps[0].repo_owner == null);
    try std.testing.expect(apps[0].repo_name == null);
    try std.testing.expect(apps[0].allow_prerelease);
}

test "configure_updates leaves the database unchanged when Forgejo validation fails" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const root = path_buffer[0..path_length];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root, "appimage-metadata-v2.db" });
    defer std.testing.allocator.free(db_path);

    try seedDb(std.testing.allocator, std.testing.io, db_path, &.{
        .{
            .name = "Eden",
            .update_url = "https://old.example/owner/repo",
            .update_type = .forgejo,
        },
    });
    const before = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        db_path,
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(before);

    var manager = makeUpdateManager(std.testing.allocator, root, db_path);
    defer manager.deinit();
    try std.testing.expectError(
        error.InvalidAppImageUpdateConfiguration,
        manager.configure_updates(
            "https://git.eden-emu.dev/eden-ci/nightly/actions",
            "Eden",
            .forgejo,
            false,
        ),
    );

    const after = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        db_path,
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "get_update returns optional owned results for configured providers" {
    const Capture = struct {
        last_status: ?events.StatusKind = null,

        fn status(data: ?*anyopaque, args: events.StatusArgs) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.last_status = args.kind;
        }
    };

    var dispatcher = events.Dispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();
    var capture: Capture = .{};
    _ = try dispatcher.addStatusHandler(.{ .function = Capture.status, .data = &capture });

    var manager = makeUpdateManager(std.testing.allocator, "unused", "unused");
    manager.setEventDispatcher(&dispatcher);

    const disabled = appimage.AppImage{ .name = "Disabled", .update_type = .none };
    try std.testing.expect((try manager.get_update(&disabled)) == null);

    const incomplete = appimage.AppImage{ .name = "Incomplete", .update_type = .github };
    try std.testing.expect((try manager.get_update(&incomplete)) == null);
    try std.testing.expectEqual(events.StatusKind.warning, capture.last_status.?);
}

test "providerUpdateOrWarn warns only when no provider asset is available" {
    const expected_message = "No compatible downloadable AppImage release asset was found for Editor.";
    const Capture = struct {
        count: usize = 0,
        last_status: ?events.StatusKind = null,
        message_matches: bool = false,

        fn status(data: ?*anyopaque, args: events.StatusArgs) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.count += 1;
            self.last_status = args.kind;
            self.message_matches = std.mem.eql(u8, args.message, expected_message);
        }
    };

    var dispatcher = events.Dispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();
    var capture: Capture = .{};
    _ = try dispatcher.addStatusHandler(.{ .function = Capture.status, .data = &capture });

    var manager = makeUpdateManager(std.testing.allocator, "unused", "unused");
    manager.setEventDispatcher(&dispatcher);

    try std.testing.expect(manager.providerUpdateOrWarn("Editor", null) == null);
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqual(events.StatusKind.warning, capture.last_status.?);
    try std.testing.expect(capture.message_matches);

    const available = appimage.AppImageUpdate{
        .name = "Editor",
        .version = "v2.0.0",
        .download_url = "https://example.com/Editor.AppImage",
        .is_update_available = true,
    };
    const returned = manager.providerUpdateOrWarn("Editor", available);
    try std.testing.expect(returned != null);
    try std.testing.expectEqualStrings(available.download_url, returned.?.download_url);
    try std.testing.expectEqual(@as(usize, 1), capture.count);
}

test "get_updates returns an owned update list" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = path_buf[0..len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "apps.db" });
    defer std.testing.allocator.free(db_path);

    try seedDb(std.testing.allocator, std.testing.io, db_path, &.{
        .{ .name = "NoUpdatesConfigured", .update_type = .none },
    });

    const manager = makeUpdateManager(std.testing.allocator, dir_path, db_path);
    var updates = try manager.get_updates();
    defer updates.deinit();
    try std.testing.expectEqual(@as(usize, 0), updates.items.len);
}

test "AppImage update manager forwards downloader progress" {
    const Capture = struct {
        total: ?u64 = null,
        downloaded: u64 = 0,
        percentage: ?f64 = null,

        fn progress(data: ?*anyopaque, args: events.DownloadProgressArgs) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.total = args.total_bytes;
            self.downloaded = args.downloaded_bytes;
            self.percentage = args.percentage;
        }
    };

    var dispatcher = events.Dispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();
    var capture: Capture = .{};
    _ = try dispatcher.addDownloadProgressHandler(.{ .function = Capture.progress, .data = &capture });

    var manager = makeUpdateManager(std.testing.allocator, "unused", "unused");
    manager.setEventDispatcher(&dispatcher);
    var context = UpdateManager.DownloadContext{ .manager = manager, .app_name = "Example" };
    UpdateManager.onDownloadEvent(&context, .{
        .event_type = .Progress,
        .progress = .{
            .bytes_downloaded = 25,
            .bytes_total = 200,
            .percent = 12,
            .speed_bytes_per_sec = null,
        },
    });

    try std.testing.expectEqual(@as(?u64, 200), capture.total);
    try std.testing.expectEqual(@as(u64, 25), capture.downloaded);
    try std.testing.expectEqual(@as(?f64, 12.5), capture.percentage);
}

test "AppImage updates honor shared cancellation" {
    var context = operation_api.OperationContext.init(std.testing.allocator, std.testing.io);
    defer context.deinit();
    var manager = UpdateManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = std.testing.environ,
        .install_directory = "/tmp/shelly-appimage-cancelled",
        .local_db_path = "/tmp/shelly-appimage-cancelled.json",
    };
    defer manager.deinit();
    try manager.setOperationContext(&context);

    context.cancel();
    try std.testing.expectError(error.Cancelled, manager.get_updates());
}

test "update: returns false when app not found in db" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(dir_path);

    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "apps.db" });
    defer std.testing.allocator.free(db_path);

    try seedDb(std.testing.allocator, std.testing.io, db_path, &.{});

    const um = makeUpdateManager(std.testing.allocator, dir_path, db_path);
    var dto = appimage.AppImageUpdate{
        .name = "nonexistent",
        .version = "v2.0",
        .download_url = "https://example.com/app.AppImage",
        .is_update_available = true,
    };
    const result = try um.update(&dto);
    try std.testing.expect(!result);
}

test "update: returns false when download_url is empty" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(dir_path);

    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "apps.db" });
    defer std.testing.allocator.free(db_path);

    try seedDb(std.testing.allocator, std.testing.io, db_path, &.{
        .{ .name = "myapp", .version = "v1.0" },
    });

    const um = makeUpdateManager(std.testing.allocator, dir_path, db_path);
    var dto = appimage.AppImageUpdate{
        .name = "myapp",
        .version = "v2.0",
        .download_url = "",
        .is_update_available = true,
    };
    const result = try um.update(&dto);
    try std.testing.expect(!result);
}

test "update: returns false when current AppImage file does not exist on disk" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(dir_path);

    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "apps.db" });
    defer std.testing.allocator.free(db_path);

    try seedDb(std.testing.allocator, std.testing.io, db_path, &.{
        .{ .name = "myapp", .version = "v1.0" },
    });

    // intentionally do NOT create myapp.AppImage in dir_path
    const um = makeUpdateManager(std.testing.allocator, dir_path, db_path);
    var dto = appimage.AppImageUpdate{
        .name = "myapp",
        .version = "v2.0",
        .download_url = "https://example.com/myapp.AppImage",
        .is_update_available = true,
    };
    const result = try um.update(&dto);
    try std.testing.expect(!result);
}

test "update: downloads real AppImage and returns true" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(dir_path);

    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "apps.db" });
    defer std.testing.allocator.free(db_path);

    const app_name = "appimagetool";
    const download_url = "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage";

    try seedDb(std.testing.allocator, std.testing.io, db_path, &.{
        .{ .name = app_name, .version = "v0.0", .desktop_name = app_name },
    });

    // Create a placeholder current AppImage so the file-exists guard passes
    const current_filename = try std.fmt.allocPrint(std.testing.allocator, "{s}.AppImage", .{app_name});
    defer std.testing.allocator.free(current_filename);
    const current_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, current_filename });
    defer std.testing.allocator.free(current_path);
    {
        var f = try std.Io.Dir.cwd().createFile(std.testing.io, current_path, .{});
        f.close(std.testing.io);
    }

    const um = makeUpdateManager(std.testing.allocator, dir_path, db_path);
    var dto = appimage.AppImageUpdate{
        .name = app_name,
        .version = "continuous",
        .download_url = download_url,
        .is_update_available = true,
    };
    const result = try um.update(&dto);
    try std.testing.expect(result);

    const manager = appimage_manager.AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = std.testing.environ,
        .install_directory = dir_path,
        .local_db_path = db_path,
    };
    const apps = try manager.getAppImagesFromLocalDb();
    defer manager.freeAppImages(apps);
    try std.testing.expectEqual(@as(usize, 1), apps.len);
    try std.testing.expectEqualStrings(app_name, apps[0].name);
    const expected_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/{s}.AppImage",
        .{ dir_path, app_name },
    );
    defer std.testing.allocator.free(expected_path);
    try std.testing.expectEqualStrings(expected_path, apps[0].path);
    const installed_stat = try std.Io.Dir.cwd().statFile(std.testing.io, expected_path, .{});
    try std.testing.expect(installed_stat.permissions.toMode() & 0o111 != 0);
    try std.testing.expect(
        std.mem.eql(u8, apps[0].version, "continuous") or apps[0].version.len > 0,
    );
}

test "update: name lookup is case-insensitive" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(dir_path);

    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "apps.db" });
    defer std.testing.allocator.free(db_path);

    // DB has "MyApp" but dto uses "myapp" — should still find it, then fail on missing file
    try seedDb(std.testing.allocator, std.testing.io, db_path, &.{
        .{ .name = "MyApp", .version = "v1.0" },
    });

    const um = makeUpdateManager(std.testing.allocator, dir_path, db_path);
    var dto = appimage.AppImageUpdate{
        .name = "myapp",
        .version = "v2.0",
        .download_url = "https://example.com/myapp.AppImage",
        .is_update_available = true,
    };
    // Will fail at "file not found" (not "app not found"), proving case-insensitive match worked
    const result = try um.update(&dto);
    try std.testing.expect(!result);
}

const newDesktopNameAppImage =
    \\#!/bin/sh
    \\if [ "$1" = "--appimage-extract" ]; then
    \\  mkdir -p squashfs-root
    \\  printf '%s\n' '[Desktop Entry]' 'Name=New Name' 'X-AppImage-Version=2.0.0' 'Exec=editor %U' 'TryExec=editor' 'Icon=editor' 'Categories=Utility;' > squashfs-root/editor.desktop
    \\  exit 0
    \\fi
    \\exit 0
;

const noEmbeddedDesktopAppImage =
    \\#!/bin/sh
    \\if [ "$1" = "--appimage-extract" ]; then
    \\  mkdir -p squashfs-root
    \\  exit 0
    \\fi
    \\exit 0
;

fn writeUpdateFixture(io: std.Io, path: []const u8, contents: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var write_buf: [4096]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    try writer.interface.writeAll(contents);
    try writer.interface.flush();
}

fn readUpdateFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    return reader.interface.allocRemaining(allocator, .unlimited);
}

fn makeStagedUpdateManager(
    allocator: std.mem.Allocator,
    install_dir: []const u8,
    db_path: []const u8,
    staged_download_path: []const u8,
) UpdateManager {
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .environ = std.testing.environ,
        .install_directory = install_dir,
        .local_db_path = db_path,
        .staged_download_path = staged_download_path,
    };
}

fn failingUpdateCacheCommand(
    allocator: std.mem.Allocator,
    _: std.Io,
    _: std.process.Environ,
    _: []const []const u8,
) !std.process.RunResult {
    const stdout = try allocator.dupe(u8, "");
    errdefer allocator.free(stdout);
    return .{
        .term = .{ .exited = 1 },
        .stdout = stdout,
        .stderr = try allocator.dupe(u8, "update cache rejected broken.desktop\n"),
    };
}

const UpdateCacheWarningCapture = struct {
    saw_cache_warning: bool = false,

    fn handle(data: ?*anyopaque, args: events.StatusArgs) void {
        if (args.kind != .warning) return;
        const self: *@This() = @ptrCast(@alignCast(data.?));
        self.saw_cache_warning = self.saw_cache_warning or
            (std.mem.indexOf(u8, args.message, "update-desktop-database") != null and
                std.mem.indexOf(u8, args.message, "broken.desktop") != null);
    }
};

test "update: automated update commits despite cache refresh failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(dir_path);

    const install_dir = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "install" });
    defer std.testing.allocator.free(install_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, install_dir);

    const data_home = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "data" });
    defer std.testing.allocator.free(data_home);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, data_home);

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("HOME", dir_path);
    try environ.put("XDG_DATA_HOME", data_home);
    try environ.put("XDG_CACHE_HOME", dir_path);
    var environ_block = try environ.createPosixBlock(std.testing.allocator, .{});
    defer environ_block.deinit(std.testing.allocator);
    const test_environ: std.process.Environ = .{ .block = environ_block };

    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "apps.db" });
    defer std.testing.allocator.free(db_path);

    const app_name = "Editor";
    const current_path = try std.fs.path.join(std.testing.allocator, &.{ install_dir, "Editor.AppImage" });
    defer std.testing.allocator.free(current_path);
    try writeUpdateFixture(std.testing.io, current_path, "#!/bin/sh\nexit 0\n");

    const desktop_dir = try std.fs.path.join(std.testing.allocator, &.{ data_home, "applications" });
    defer std.testing.allocator.free(desktop_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, desktop_dir);
    const desktop_path = try std.fs.path.join(std.testing.allocator, &.{ desktop_dir, "editor.desktop" });
    defer std.testing.allocator.free(desktop_path);
    try writeUpdateFixture(std.testing.io, desktop_path, "[Desktop Entry]\nName=Old Name\nExec=old-binary\n");

    try seedDb(std.testing.allocator, std.testing.io, db_path, &.{
        .{ .name = app_name, .version = "1.0.0", .desktop_name = "Old Name", .path = current_path },
    });

    const staged_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "staged.AppImage" });
    defer std.testing.allocator.free(staged_path);
    try writeUpdateFixture(std.testing.io, staged_path, newDesktopNameAppImage);

    var um = makeStagedUpdateManager(std.testing.allocator, install_dir, db_path, staged_path);
    um.environ = test_environ;
    var dispatcher = events.Dispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();
    var capture: UpdateCacheWarningCapture = .{};
    _ = try dispatcher.addStatusHandler(.{ .function = UpdateCacheWarningCapture.handle, .data = &capture });
    um.dispatcher = &dispatcher;
    um.cache_command_run = failingUpdateCacheCommand;
    var dto = appimage.AppImageUpdate{
        .name = app_name,
        .version = "2.0.0",
        .download_url = "https://example.com/Editor.AppImage",
        .is_update_available = true,
    };
    try std.testing.expect(try um.update(&dto));

    const manager = appimage_manager.AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = test_environ,
        .install_directory = install_dir,
        .local_db_path = db_path,
    };
    const apps = try manager.getAppImagesFromLocalDb();
    defer manager.freeAppImages(apps);
    try std.testing.expectEqual(@as(usize, 1), apps.len);
    try std.testing.expectEqualStrings("New Name", apps[0].desktop_name);
    try std.testing.expectEqualStrings("2.0.0", apps[0].version);
    try std.testing.expectEqualStrings(current_path, apps[0].path);

    const desktop = try readUpdateFile(std.testing.allocator, std.testing.io, desktop_path);
    defer std.testing.allocator.free(desktop);
    try std.testing.expect(std.mem.indexOf(u8, desktop, "Name=New Name\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, desktop, "Name=Old Name") == null);
    const expected_exec = try std.fmt.allocPrint(std.testing.allocator, "Exec=\"{s}\" %U\n", .{current_path});
    defer std.testing.allocator.free(expected_exec);
    try std.testing.expect(std.mem.indexOf(u8, desktop, expected_exec) != null);
    try std.testing.expect(capture.saw_cache_warning);
}

test "update follows a symlinked install directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(dir_path);

    const install_target = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "install-target" });
    defer std.testing.allocator.free(install_target);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, install_target);
    const install_dir = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "install-link" });
    defer std.testing.allocator.free(install_dir);
    try std.Io.Dir.cwd().symLink(std.testing.io, install_target, install_dir, .{});

    const data_home = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "data" });
    defer std.testing.allocator.free(data_home);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, data_home);

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("HOME", dir_path);
    try environ.put("XDG_DATA_HOME", data_home);
    try environ.put("XDG_CACHE_HOME", dir_path);
    var environ_block = try environ.createPosixBlock(std.testing.allocator, .{});
    defer environ_block.deinit(std.testing.allocator);
    const test_environ: std.process.Environ = .{ .block = environ_block };

    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "apps.db" });
    defer std.testing.allocator.free(db_path);

    const app_name = "Editor";
    const current_path = try std.fs.path.join(std.testing.allocator, &.{ install_dir, "Editor.AppImage" });
    defer std.testing.allocator.free(current_path);
    try writeUpdateFixture(std.testing.io, current_path, "#!/bin/sh\nexit 0\n");

    try seedDb(std.testing.allocator, std.testing.io, db_path, &.{
        .{ .name = app_name, .version = "1.0.0", .desktop_name = "Old Name", .path = current_path },
    });

    const staged_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "staged.AppImage" });
    defer std.testing.allocator.free(staged_path);
    try writeUpdateFixture(std.testing.io, staged_path, newDesktopNameAppImage);

    var um = makeStagedUpdateManager(std.testing.allocator, install_dir, db_path, staged_path);
    um.environ = test_environ;
    var dto = appimage.AppImageUpdate{
        .name = app_name,
        .version = "2.0.0",
        .download_url = "https://example.com/Editor.AppImage",
        .is_update_available = true,
    };
    try std.testing.expect(try um.update(&dto));

    // The replacement must land in the directory the symlink points to.
    const resolved_path = try std.fs.path.join(std.testing.allocator, &.{ install_target, "Editor.AppImage" });
    defer std.testing.allocator.free(resolved_path);
    const installed = try readUpdateFile(std.testing.allocator, std.testing.io, resolved_path);
    defer std.testing.allocator.free(installed);
    try std.testing.expectEqualStrings(newDesktopNameAppImage, installed);

    const manager = appimage_manager.AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = test_environ,
        .install_directory = install_dir,
        .local_db_path = db_path,
    };
    const apps = try manager.getAppImagesFromLocalDb();
    defer manager.freeAppImages(apps);
    try std.testing.expectEqual(@as(usize, 1), apps.len);
    try std.testing.expectEqualStrings("2.0.0", apps[0].version);
    try std.testing.expectEqualStrings(current_path, apps[0].path);
}

test "update: preserves GitHub provider configuration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(dir_path);

    const install_dir = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "install" });
    defer std.testing.allocator.free(install_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, install_dir);

    const data_home = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "data" });
    defer std.testing.allocator.free(data_home);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, data_home);

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("HOME", dir_path);
    try environ.put("XDG_DATA_HOME", data_home);
    try environ.put("XDG_CACHE_HOME", dir_path);
    var environ_block = try environ.createPosixBlock(std.testing.allocator, .{});
    defer environ_block.deinit(std.testing.allocator);
    const test_environ: std.process.Environ = .{ .block = environ_block };

    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "apps.db" });
    defer std.testing.allocator.free(db_path);

    const app_name = "Editor";
    const current_path = try std.fs.path.join(std.testing.allocator, &.{ install_dir, "Editor.AppImage" });
    defer std.testing.allocator.free(current_path);
    try writeUpdateFixture(std.testing.io, current_path, "#!/bin/sh\nexit 0\n");

    try seedDb(std.testing.allocator, std.testing.io, db_path, &.{
        .{
            .name = app_name,
            .version = "1.0.0",
            .desktop_name = "Old Name",
            .path = current_path,
            .update_type = .github,
            .repo_owner = "shelly",
            .repo_name = "editor",
            .allow_prerelease = true,
            .update_url = "https://updates.example.com/editor",
        },
    });

    const staged_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "staged.AppImage" });
    defer std.testing.allocator.free(staged_path);
    try writeUpdateFixture(std.testing.io, staged_path, newDesktopNameAppImage);

    var um = makeStagedUpdateManager(std.testing.allocator, install_dir, db_path, staged_path);
    um.environ = test_environ;
    var dto = appimage.AppImageUpdate{
        .name = app_name,
        .version = "2.0.0",
        .download_url = "https://example.com/Editor.AppImage",
        .is_update_available = true,
    };
    try std.testing.expect(try um.update(&dto));

    const manager = appimage_manager.AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = test_environ,
        .install_directory = install_dir,
        .local_db_path = db_path,
    };
    const apps = try manager.getAppImagesFromLocalDb();
    defer manager.freeAppImages(apps);
    try std.testing.expectEqual(@as(usize, 1), apps.len);
    try std.testing.expectEqual(appimage.UpdateType.github, apps[0].update_type);
    try std.testing.expectEqualStrings("shelly", apps[0].repo_owner.?);
    try std.testing.expectEqualStrings("editor", apps[0].repo_name.?);
    try std.testing.expect(apps[0].allow_prerelease);
    try std.testing.expectEqualStrings("https://updates.example.com/editor", apps[0].update_url);
    try std.testing.expectEqualStrings("New Name", apps[0].desktop_name);
    // The provider version of the applied update is remembered so the same release is never offered again.
    try std.testing.expectEqualStrings("2.0.0", apps[0].release_tag.?);
}

test "update: preserves stable desktop filename when display name changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(dir_path);

    const install_dir = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "install" });
    defer std.testing.allocator.free(install_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, install_dir);

    const data_home = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "data" });
    defer std.testing.allocator.free(data_home);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, data_home);

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("HOME", dir_path);
    try environ.put("XDG_DATA_HOME", data_home);
    try environ.put("XDG_CACHE_HOME", dir_path);
    var environ_block = try environ.createPosixBlock(std.testing.allocator, .{});
    defer environ_block.deinit(std.testing.allocator);
    const test_environ: std.process.Environ = .{ .block = environ_block };

    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "apps.db" });
    defer std.testing.allocator.free(db_path);

    const app_name = "Editor";
    const current_path = try std.fs.path.join(std.testing.allocator, &.{ install_dir, "Editor.AppImage" });
    defer std.testing.allocator.free(current_path);
    try writeUpdateFixture(std.testing.io, current_path, "#!/bin/sh\nexit 0\n");

    const desktop_dir = try std.fs.path.join(std.testing.allocator, &.{ data_home, "applications" });
    defer std.testing.allocator.free(desktop_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, desktop_dir);
    const desktop_path = try std.fs.path.join(std.testing.allocator, &.{ desktop_dir, "editor.desktop" });
    defer std.testing.allocator.free(desktop_path);
    try writeUpdateFixture(std.testing.io, desktop_path, "[Desktop Entry]\nName=Old Name\nExec=old-binary\n");

    try seedDb(std.testing.allocator, std.testing.io, db_path, &.{
        .{ .name = app_name, .version = "1.0.0", .desktop_name = "Old Name", .path = current_path },
    });

    const staged_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "staged.AppImage" });
    defer std.testing.allocator.free(staged_path);
    try writeUpdateFixture(std.testing.io, staged_path, newDesktopNameAppImage);

    var um = makeStagedUpdateManager(std.testing.allocator, install_dir, db_path, staged_path);
    um.environ = test_environ;
    var dto = appimage.AppImageUpdate{
        .name = app_name,
        .version = "2.0.0",
        .download_url = "https://example.com/Editor.AppImage",
        .is_update_available = true,
    };
    try std.testing.expect(try um.update(&dto));

    // Only the stable <clean_name>.desktop file should exist (ignore cache files).
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, desktop_dir, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".desktop")) continue;
        try std.testing.expectEqualStrings("editor.desktop", entry.name);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "update: preserves Exec= field codes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(dir_path);

    const install_dir = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "install" });
    defer std.testing.allocator.free(install_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, install_dir);

    const data_home = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "data" });
    defer std.testing.allocator.free(data_home);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, data_home);

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("HOME", dir_path);
    try environ.put("XDG_DATA_HOME", data_home);
    try environ.put("XDG_CACHE_HOME", dir_path);
    var environ_block = try environ.createPosixBlock(std.testing.allocator, .{});
    defer environ_block.deinit(std.testing.allocator);
    const test_environ: std.process.Environ = .{ .block = environ_block };

    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "apps.db" });
    defer std.testing.allocator.free(db_path);

    const app_name = "Editor";
    const current_path = try std.fs.path.join(std.testing.allocator, &.{ install_dir, "Editor.AppImage" });
    defer std.testing.allocator.free(current_path);
    try writeUpdateFixture(std.testing.io, current_path, "#!/bin/sh\nexit 0\n");

    try seedDb(std.testing.allocator, std.testing.io, db_path, &.{
        .{ .name = app_name, .version = "1.0.0", .desktop_name = "Editor", .path = current_path },
    });

    const staged_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "staged.AppImage" });
    defer std.testing.allocator.free(staged_path);
    try writeUpdateFixture(std.testing.io, staged_path, newDesktopNameAppImage);

    var um = makeStagedUpdateManager(std.testing.allocator, install_dir, db_path, staged_path);
    um.environ = test_environ;
    var dto = appimage.AppImageUpdate{
        .name = app_name,
        .version = "2.0.0",
        .download_url = "https://example.com/Editor.AppImage",
        .is_update_available = true,
    };
    try std.testing.expect(try um.update(&dto));

    const desktop_dir = try std.fs.path.join(std.testing.allocator, &.{ data_home, "applications" });
    defer std.testing.allocator.free(desktop_dir);
    const desktop_path = try std.fs.path.join(std.testing.allocator, &.{ desktop_dir, "editor.desktop" });
    defer std.testing.allocator.free(desktop_path);
    const desktop = try readUpdateFile(std.testing.allocator, std.testing.io, desktop_path);
    defer std.testing.allocator.free(desktop);
    const expected_exec = try std.fmt.allocPrint(std.testing.allocator, "Exec=\"{s}\" %U\n", .{current_path});
    defer std.testing.allocator.free(expected_exec);
    try std.testing.expect(std.mem.indexOf(u8, desktop, expected_exec) != null);
}

test "update: failed database commit rolls back binary and desktop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(dir_path);

    const install_dir = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "install" });
    defer std.testing.allocator.free(install_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, install_dir);

    const data_home = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "data" });
    defer std.testing.allocator.free(data_home);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, data_home);

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("HOME", dir_path);
    try environ.put("XDG_DATA_HOME", data_home);
    try environ.put("XDG_CACHE_HOME", dir_path);
    var environ_block = try environ.createPosixBlock(std.testing.allocator, .{});
    defer environ_block.deinit(std.testing.allocator);
    const test_environ: std.process.Environ = .{ .block = environ_block };

    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "apps.db" });
    defer std.testing.allocator.free(db_path);

    const app_name = "Editor";
    const current_path = try std.fs.path.join(std.testing.allocator, &.{ install_dir, "Editor.AppImage" });
    defer std.testing.allocator.free(current_path);
    const old_binary = "#!/bin/sh\nold-binary\nexit 0\n";
    try writeUpdateFixture(std.testing.io, current_path, old_binary);

    const desktop_dir = try std.fs.path.join(std.testing.allocator, &.{ data_home, "applications" });
    defer std.testing.allocator.free(desktop_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, desktop_dir);
    const desktop_path = try std.fs.path.join(std.testing.allocator, &.{ desktop_dir, "editor.desktop" });
    defer std.testing.allocator.free(desktop_path);
    const old_desktop = "[Desktop Entry]\nName=Old Name\nExec=old-binary\n";
    try writeUpdateFixture(std.testing.io, desktop_path, old_desktop);

    try seedDb(std.testing.allocator, std.testing.io, db_path, &.{
        .{ .name = app_name, .version = "1.0.0", .desktop_name = "Old Name", .path = current_path },
    });

    const staged_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "staged.AppImage" });
    defer std.testing.allocator.free(staged_path);
    try writeUpdateFixture(std.testing.io, staged_path, newDesktopNameAppImage);

    var um = makeStagedUpdateManager(std.testing.allocator, install_dir, db_path, staged_path);
    um.environ = test_environ;
    um.database_commit = appimage_manager.failDatabaseCommit;
    var dto = appimage.AppImageUpdate{
        .name = app_name,
        .version = "2.0.0",
        .download_url = "https://example.com/Editor.AppImage",
        .is_update_available = true,
    };
    try std.testing.expect(!try um.update(&dto));

    // Binary content should be the original.
    const installed_binary = try readUpdateFile(std.testing.allocator, std.testing.io, current_path);
    defer std.testing.allocator.free(installed_binary);
    try std.testing.expectEqualStrings(old_binary, installed_binary);

    // Desktop file should be the original.
    const installed_desktop = try readUpdateFile(std.testing.allocator, std.testing.io, desktop_path);
    defer std.testing.allocator.free(installed_desktop);
    try std.testing.expectEqualStrings(old_desktop, installed_desktop);

    // DB record should still be the old one.
    const manager = appimage_manager.AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = test_environ,
        .install_directory = install_dir,
        .local_db_path = db_path,
    };
    const apps = try manager.getAppImagesFromLocalDb();
    defer manager.freeAppImages(apps);
    try std.testing.expectEqual(@as(usize, 1), apps.len);
    try std.testing.expectEqualStrings("1.0.0", apps[0].version);
    try std.testing.expectEqualStrings("Old Name", apps[0].desktop_name);
}

test "update: no embedded desktop file uses fallback entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(dir_path);

    const install_dir = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "install" });
    defer std.testing.allocator.free(install_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, install_dir);

    const data_home = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "data" });
    defer std.testing.allocator.free(data_home);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, data_home);

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("HOME", dir_path);
    try environ.put("XDG_DATA_HOME", data_home);
    try environ.put("XDG_CACHE_HOME", dir_path);
    var environ_block = try environ.createPosixBlock(std.testing.allocator, .{});
    defer environ_block.deinit(std.testing.allocator);
    const test_environ: std.process.Environ = .{ .block = environ_block };

    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "apps.db" });
    defer std.testing.allocator.free(db_path);

    const app_name = "Editor";
    const current_path = try std.fs.path.join(std.testing.allocator, &.{ install_dir, "Editor.AppImage" });
    defer std.testing.allocator.free(current_path);
    try writeUpdateFixture(std.testing.io, current_path, "#!/bin/sh\nexit 0\n");

    try seedDb(std.testing.allocator, std.testing.io, db_path, &.{
        .{ .name = app_name, .version = "1.0.0", .desktop_name = "Editor", .path = current_path },
    });

    const staged_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "staged.AppImage" });
    defer std.testing.allocator.free(staged_path);
    try writeUpdateFixture(std.testing.io, staged_path, noEmbeddedDesktopAppImage);

    var um = makeStagedUpdateManager(std.testing.allocator, install_dir, db_path, staged_path);
    um.environ = test_environ;
    var dto = appimage.AppImageUpdate{
        .name = app_name,
        .version = "2.0.0",
        .download_url = "https://example.com/Editor.AppImage",
        .is_update_available = true,
    };
    try std.testing.expect(try um.update(&dto));

    const desktop_dir = try std.fs.path.join(std.testing.allocator, &.{ data_home, "applications" });
    defer std.testing.allocator.free(desktop_dir);
    const desktop_path = try std.fs.path.join(std.testing.allocator, &.{ desktop_dir, "editor.desktop" });
    defer std.testing.allocator.free(desktop_path);
    const desktop = try readUpdateFile(std.testing.allocator, std.testing.io, desktop_path);
    defer std.testing.allocator.free(desktop);
    // Fallback entry should use the logical app name and final installed path.
    try std.testing.expect(std.mem.indexOf(u8, desktop, "Name=Editor\n") != null);
    const expected_exec = try std.fmt.allocPrint(std.testing.allocator, "Exec=\"{s}\"\n", .{current_path});
    defer std.testing.allocator.free(expected_exec);
    try std.testing.expect(std.mem.indexOf(u8, desktop, expected_exec) != null);
}

// Test F: sync and automated update produce equivalent metadata and desktop
// integration for the same old/new AppImage pair. This guards against the two
// code paths drifting in desktop name, description, icon, size, or desktop
// file contents.
const ParityEnv = struct {
    dir_path: []const u8,
    install_dir: []const u8,
    data_home: []const u8,
    db_path: []const u8,
    desktop_path: []const u8,
    current_path: []const u8,
    environ: std.process.Environ,
    environ_block: std.process.Environ.PosixBlock,

    fn deinit(self: *ParityEnv, allocator: std.mem.Allocator) void {
        self.environ_block.deinit(allocator);
        allocator.free(self.desktop_path);
        allocator.free(self.current_path);
        allocator.free(self.db_path);
        allocator.free(self.data_home);
        allocator.free(self.install_dir);
        allocator.free(self.dir_path);
    }
};

fn makeParityEnv(
    allocator: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
) !ParityEnv {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try allocator.dupe(u8, path_buf[0..len]);
    errdefer allocator.free(dir_path);

    const install_dir = try std.fs.path.join(allocator, &.{ dir_path, "install" });
    errdefer allocator.free(install_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, install_dir);

    const data_home = try std.fs.path.join(allocator, &.{ dir_path, "data" });
    errdefer allocator.free(data_home);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, data_home);

    const db_path = try std.fs.path.join(allocator, &.{ dir_path, "apps.db" });
    errdefer allocator.free(db_path);

    const current_path = try std.fs.path.join(allocator, &.{ install_dir, "Editor.AppImage" });
    errdefer allocator.free(current_path);
    try writeUpdateFixture(std.testing.io, current_path, "#!/bin/sh\nexit 0\n");

    const desktop_dir = try std.fs.path.join(allocator, &.{ data_home, "applications" });
    defer allocator.free(desktop_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, desktop_dir);
    const desktop_path = try std.fs.path.join(allocator, &.{ desktop_dir, "editor.desktop" });
    errdefer allocator.free(desktop_path);
    try writeUpdateFixture(std.testing.io, desktop_path, "[Desktop Entry]\nName=Old Name\nExec=old-binary\n");

    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", dir_path);
    try environ.put("XDG_DATA_HOME", data_home);
    try environ.put("XDG_CACHE_HOME", dir_path);
    const environ_block = try environ.createPosixBlock(allocator, .{});

    return .{
        .dir_path = dir_path,
        .install_dir = install_dir,
        .data_home = data_home,
        .db_path = db_path,
        .desktop_path = desktop_path,
        .current_path = current_path,
        .environ = .{ .block = environ_block },
        .environ_block = environ_block,
    };
}

test "update: sync and automated update produce equivalent metadata" {
    var sync_tmp = std.testing.tmpDir(.{});
    defer sync_tmp.cleanup();
    var update_tmp = std.testing.tmpDir(.{});
    defer update_tmp.cleanup();

    var sync_env = try makeParityEnv(std.testing.allocator, &sync_tmp);
    defer sync_env.deinit(std.testing.allocator);
    var update_env = try makeParityEnv(std.testing.allocator, &update_tmp);
    defer update_env.deinit(std.testing.allocator);

    const app_name = "Editor";

    // Seed both databases with the same old record.
    try seedDb(std.testing.allocator, std.testing.io, sync_env.db_path, &.{
        .{ .name = app_name, .version = "1.0.0", .desktop_name = "Old Name", .path = sync_env.current_path },
    });
    try seedDb(std.testing.allocator, std.testing.io, update_env.db_path, &.{
        .{ .name = app_name, .version = "1.0.0", .desktop_name = "Old Name", .path = update_env.current_path },
    });

    // For sync: place the new AppImage at the install path (sync inspects the
    // installed binary). For update: stage the new AppImage for download. Both
    // fixtures must be executable so `extractMetadataPure` can spawn them.
    try writeUpdateFixture(std.testing.io, sync_env.current_path, newDesktopNameAppImage);
    const sync_manager_for_chmod = appimage_manager.AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = sync_env.environ,
        .install_directory = sync_env.install_dir,
        .local_db_path = sync_env.db_path,
    };
    try sync_manager_for_chmod.setExecutable(sync_env.current_path);
    const staged_path = try std.fs.path.join(std.testing.allocator, &.{ update_env.dir_path, "staged.AppImage" });
    defer std.testing.allocator.free(staged_path);
    try writeUpdateFixture(std.testing.io, staged_path, newDesktopNameAppImage);

    // Run sync against the sync environment.
    const sync_manager = appimage_manager.AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = sync_env.environ,
        .install_directory = sync_env.install_dir,
        .local_db_path = sync_env.db_path,
    };
    try std.testing.expect(try sync_manager.syncAppImageMeta(&.{app_name}));

    // Run update against the update environment.
    var um = makeStagedUpdateManager(std.testing.allocator, update_env.install_dir, update_env.db_path, staged_path);
    um.environ = update_env.environ;
    var dto = appimage.AppImageUpdate{
        .name = app_name,
        .version = "2.0.0",
        .download_url = "https://example.com/Editor.AppImage",
        .is_update_available = true,
    };
    try std.testing.expect(try um.update(&dto));

    // Compare database records.
    const sync_db = appimage_manager.AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = sync_env.environ,
        .install_directory = sync_env.install_dir,
        .local_db_path = sync_env.db_path,
    };
    const sync_apps = try sync_db.getAppImagesFromLocalDb();
    defer sync_db.freeAppImages(sync_apps);
    const update_db = appimage_manager.AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = update_env.environ,
        .install_directory = update_env.install_dir,
        .local_db_path = update_env.db_path,
    };
    const update_apps = try update_db.getAppImagesFromLocalDb();
    defer update_db.freeAppImages(update_apps);
    try std.testing.expectEqual(@as(usize, 1), sync_apps.len);
    try std.testing.expectEqual(@as(usize, 1), update_apps.len);
    try std.testing.expectEqualStrings(sync_apps[0].desktop_name, update_apps[0].desktop_name);
    try std.testing.expectEqualStrings(sync_apps[0].description, update_apps[0].description);
    try std.testing.expectEqualStrings(sync_apps[0].icon_name, update_apps[0].icon_name);
    try std.testing.expectEqual(sync_apps[0].size_on_disk, update_apps[0].size_on_disk);

    // Compare desktop entries.
    const sync_desktop = try readUpdateFile(std.testing.allocator, std.testing.io, sync_env.desktop_path);
    defer std.testing.allocator.free(sync_desktop);
    const update_desktop = try readUpdateFile(std.testing.allocator, std.testing.io, update_env.desktop_path);
    defer std.testing.allocator.free(update_desktop);

    // Both should use the new embedded desktop name.
    try std.testing.expect(std.mem.indexOf(u8, sync_desktop, "Name=New Name\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, update_desktop, "Name=New Name\n") != null);

    // Both should preserve the %U field code.
    try std.testing.expect(std.mem.indexOf(u8, sync_desktop, "%U") != null);
    try std.testing.expect(std.mem.indexOf(u8, update_desktop, "%U") != null);

    // Both should reference their respective installed paths via Exec=.
    const sync_exec = try std.fmt.allocPrint(std.testing.allocator, "Exec=\"{s}\" %U\n", .{sync_env.current_path});
    defer std.testing.allocator.free(sync_exec);
    const update_exec = try std.fmt.allocPrint(std.testing.allocator, "Exec=\"{s}\" %U\n", .{update_env.current_path});
    defer std.testing.allocator.free(update_exec);
    try std.testing.expect(std.mem.indexOf(u8, sync_desktop, sync_exec) != null);
    try std.testing.expect(std.mem.indexOf(u8, update_desktop, update_exec) != null);

    const sync_try_exec = try std.fmt.allocPrint(std.testing.allocator, "TryExec={s}\n", .{sync_env.current_path});
    defer std.testing.allocator.free(sync_try_exec);
    const update_try_exec = try std.fmt.allocPrint(std.testing.allocator, "TryExec={s}\n", .{update_env.current_path});
    defer std.testing.allocator.free(update_try_exec);
    try std.testing.expect(std.mem.indexOf(u8, sync_desktop, sync_try_exec) != null);
    try std.testing.expect(std.mem.indexOf(u8, update_desktop, update_try_exec) != null);

    // Both should use the same icon (the fallback, since the fixture has no
    // actual icon file, only a desktop-file Icon= line that is not installed).
    try std.testing.expect(std.mem.indexOf(u8, sync_desktop, "Icon=application-x-executable\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, update_desktop, "Icon=application-x-executable\n") != null);
}
