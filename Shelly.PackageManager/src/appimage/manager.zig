const std = @import("std");
const builtin = @import("builtin");
const appimage = @import("bindings.zig").appimage;
const launch_environment = @import("environment.zig");
const events = @import("events.zig");
const xdg_paths = @import("../shared/xdg_paths.zig").xdg_paths;
const operation_api = @import("operation_context");

pub const DatabaseCommitFn = *const fn (
    io: std.Io,
    staging_path: []const u8,
    destination_path: []const u8,
) anyerror!void;

pub const CacheCommandRunFn = *const fn (
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    argv: []const []const u8,
) anyerror!std.process.RunResult;

const max_cache_command_output = 16 * 1024;

pub const AppImageManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    install_directory: []const u8,
    local_db_path: []const u8,
    dispatcher: ?*events.Dispatcher = null,
    operation_context: ?*operation_api.OperationContext = null,
    owned_dispatcher: ?*events.Dispatcher = null,
    database_commit: DatabaseCommitFn = commitDatabase,
    cache_command_run: CacheCommandRunFn = runCacheCommand,

    pub fn setEventDispatcher(self: *AppImageManager, dispatcher: ?*events.Dispatcher) void {
        self.dispatcher = dispatcher orelse self.owned_dispatcher;
    }

    pub fn setOperationContext(self: *AppImageManager, context: ?*operation_api.OperationContext) !void {
        self.operation_context = context;
        if (context != null and self.dispatcher == null) {
            const dispatcher = try self.allocator.create(events.Dispatcher);
            dispatcher.* = events.Dispatcher.init(self.allocator);
            self.owned_dispatcher = dispatcher;
            self.dispatcher = dispatcher;
        }
    }

    pub fn deinit(self: *AppImageManager) void {
        if (self.owned_dispatcher) |dispatcher| {
            if (self.dispatcher == dispatcher) self.dispatcher = null;
            dispatcher.deinit();
            self.allocator.destroy(dispatcher);
            self.owned_dispatcher = null;
        }
        self.operation_context = null;
    }

    pub fn isAppImage(file_path: []const u8) bool {
        return std.ascii.eqlIgnoreCase(std.fs.path.extension(file_path), ".AppImage");
    }

    pub fn is_app_image(file_path: []const u8) bool {
        return isAppImage(file_path);
    }

    pub fn installAppImage(self: AppImageManager, location: []const u8) !bool {
        try ensureNonRootMutation();
        var operation_scope = events.OperationScope.init(self.operation_context, self.dispatcher, .install, location);
        operation_scope.attach();
        errdefer operation_scope.fail();
        try self.checkCancelled();
        const app_name = std.fs.path.stem(location);
        self.emitStatusFmt(.information, "Installing AppImage {s}...", .{app_name});
        const dest_name = try std.fmt.allocPrint(self.allocator, "{s}.AppImage", .{app_name});
        defer self.allocator.free(dest_name);
        const dest_path = try std.fs.path.join(self.allocator, &.{ self.install_directory, dest_name });
        defer self.allocator.free(dest_path);

        const staging_path = try self.uniqueSiblingPath(dest_path, "install");
        defer self.allocator.free(staging_path);
        defer std.Io.Dir.cwd().deleteFile(self.io, staging_path) catch {};
        const backup_path = try self.uniqueSiblingPath(dest_path, "backup");
        defer self.allocator.free(backup_path);
        defer std.Io.Dir.cwd().deleteFile(self.io, backup_path) catch {};

        var install_dir = try std.Io.Dir.cwd().createDirPathOpen(
            self.io,
            self.install_directory,
            .{},
        );
        defer install_dir.close(self.io);
        try self.copyFile(location, staging_path);
        try self.setExecutable(staging_path);

        var content = (try self.extractMetadataPure(staging_path, app_name, dest_path)) orelse {
            std.log.warn("Failed to extract metadata during installation.", .{});
            self.emitStatus(.err, "Failed to extract metadata during installation.");
            operation_scope.finish(.failed);
            return false;
        };
        defer content.deinit();
        var metadata = content.metadata;

        const existing_images = try self.getAppImagesFromLocalDb();
        defer self.freeAppImages(existing_images);
        var replaced: ?appimage.AppImage = null;
        for (existing_images) |existing| {
            const name_match = std.ascii.eqlIgnoreCase(existing.name, metadata.name);
            const desktop_match = existing.desktop_name.len > 0 and metadata.desktop_name.len > 0 and
                std.ascii.eqlIgnoreCase(existing.desktop_name, metadata.desktop_name);
            if (name_match or desktop_match) {
                std.log.warn("AppImage {s} already exists. Overwriting...", .{existing.name});
                self.emitStatusFmt(.warning, "AppImage {s} already exists. Overwriting...", .{existing.name});
                metadata.environment_variables = existing.environment_variables;
                replaced = existing;
                break;
            }
        }

        // Back up the current binary so the install can be rolled back if desktop integration or database commit fails.
        const had_existing = (std.Io.Dir.cwd().statFile(self.io, dest_path, .{}) catch null) != null;
        if (had_existing) {
            std.Io.Dir.hardLink(.cwd(), dest_path, .cwd(), backup_path, self.io, .{}) catch
                try self.copyFile(dest_path, backup_path);
        }

        std.Io.Dir.rename(.cwd(), staging_path, .cwd(), dest_path, self.io) catch |err| return err;

        var integration = self.beginDesktopIntegration(metadata, dest_path, content.source_desktop_path, content.icon_source) catch |err| {
            self.emitStatusFmt(.err, "Could not write desktop integration for {s}: {s}.", .{ app_name, @errorName(err) });
            self.rollbackInstalledBinary(dest_path, backup_path, had_existing);
            operation_scope.finish(.failed);
            return false;
        };
        defer integration.deinit();

        self.addAppImageToLocalDb(metadata) catch |err| {
            self.emitStatusFmt(.err, "Could not install {s}: {s}.", .{ app_name, @errorName(err) });
            integration.rollback() catch |rollback_err| self.emitStatusFmt(.err, "Could not restore desktop integration: {s}.", .{@errorName(rollback_err)});
            self.rollbackInstalledBinary(dest_path, backup_path, had_existing);
            operation_scope.finish(.failed);
            return false;
        };
        try integration.finish();

        if (replaced) |existing| {
            const old_path = if (existing.path.len > 0) existing.path else dest_path;
            if (!std.ascii.eqlIgnoreCase(existing.name, metadata.name)) {
                const removed_name = self.cleanDesktopEntries(existing.name, old_path) catch null;
                if (removed_name) |name| self.allocator.free(name);
            }
            if (existing.path.len > 0 and !std.mem.eql(u8, existing.path, dest_path))
                std.Io.Dir.cwd().deleteFile(self.io, existing.path) catch {};
        }
        if (had_existing) std.Io.Dir.cwd().deleteFile(self.io, backup_path) catch |err| {
            self.emitStatusFmt(.warning, "Could not remove the AppImage backup: {s}.", .{@errorName(err)});
        };
        self.refreshDesktopCachesBestEffort(content.icon_source != null);

        self.emitStatusFmt(.success, "Installed AppImage {s}.", .{app_name});
        operation_scope.finish(.success);
        return true;
    }

    fn rollbackInstalledBinary(self: AppImageManager, dest_path: []const u8, backup_path: []const u8, had_existing: bool) void {
        if (had_existing) {
            std.Io.Dir.rename(.cwd(), backup_path, .cwd(), dest_path, self.io) catch |err| {
                self.emitStatusFmt(.err, "Could not restore the previous AppImage: {s}.", .{@errorName(err)});
            };
        } else {
            std.Io.Dir.cwd().deleteFile(self.io, dest_path) catch {};
        }
    }

    pub fn installedDesktopPath(self: AppImageManager, clean_name: []const u8) ![]u8 {
        const data_home = try xdg_paths.xdgDataHome(self.allocator, self.environ);
        defer self.allocator.free(data_home);
        const desktop_file_name = try std.fmt.allocPrint(self.allocator, "{s}.desktop", .{clean_name});
        defer self.allocator.free(desktop_file_name);
        return try std.fs.path.join(self.allocator, &.{ data_home, "applications", desktop_file_name });
    }

    pub fn copyFile(self: AppImageManager, src_path: []const u8, dest_path: []const u8) !void {
        var operation_scope = events.OperationScope.init(self.operation_context, self.dispatcher, .install, src_path);
        operation_scope.attach();
        errdefer operation_scope.fail();
        try self.checkCancelled();
        var src = try std.Io.Dir.cwd().openFile(self.io, src_path, .{});
        defer src.close(self.io);
        var dst = try std.Io.Dir.cwd().createFile(self.io, dest_path, .{ .exclusive = true });
        defer dst.close(self.io);

        var read_buf: [1024 * 64]u8 = undefined;
        var write_buf: [1024 * 64]u8 = undefined;
        var reader = src.reader(self.io, &.{});
        var writer = dst.writer(self.io, &write_buf);

        while (true) {
            try self.checkCancelled();
            const n = try reader.interface.readSliceShort(&read_buf);
            if (n == 0) break;
            try writer.interface.writeAll(read_buf[0..n]);
        }
        try writer.interface.flush();
        try dst.sync(self.io);
        operation_scope.finish(.success);
    }

    pub fn setExecutable(self: AppImageManager, path: []const u8) !void {
        var operation_scope = events.OperationScope.init(self.operation_context, self.dispatcher, .configure, path);
        operation_scope.attach();
        errdefer operation_scope.fail();
        try self.checkCancelled();
        var proc = try std.process.spawn(self.io, .{
            .argv = &.{ "chmod", "a+x", path },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        const term = try proc.wait(self.io);
        if (term != .exited or term.exited != 0) return error.ChmodFailed;
        operation_scope.finish(.success);
    }

    pub fn extractMetadata(self: AppImageManager, path: []const u8) !?appimage.AppImage {
        var content = (try self.extractMetadataPure(path, null, null)) orelse return null;
        const metadata = content.stealMetadata();
        content.deinit();
        return metadata;
    }

    pub fn extractMetadataPure(
        self: AppImageManager,
        path: []const u8,
        app_name_override: ?[]const u8,
        exec_path_override: ?[]const u8,
    ) !?ExtractedContent {
        var operation_scope = events.OperationScope.init(self.operation_context, self.dispatcher, .inspect, path);
        operation_scope.attach();
        errdefer operation_scope.fail();
        try self.checkCancelled();
        const is_rep = path.len >= 4 and std.ascii.eqlIgnoreCase(path[path.len - 4 ..], ".rep");
        const inferred_app_name = if (is_rep)
            std.fs.path.stem(std.fs.path.stem(path))
        else
            std.fs.path.stem(path);
        const app_name = app_name_override orelse inferred_app_name;
        const exec_path = exec_path_override orelse if (is_rep) path[0 .. path.len - 4] else path;

        const clean_name = try self.cleanInvalidNames(app_name);
        defer self.allocator.free(clean_name);

        var working_dir: ?[]u8 = try self.createExtractionWorkingDir(clean_name);
        errdefer freeWorkingDir(self.allocator, self.io, &working_dir);

        try std.Io.Dir.cwd().createDirPath(self.io, working_dir.?);

        var extract_proc = try std.process.spawn(self.io, .{
            .argv = &.{ path, "--appimage-extract" },
            .cwd = .{ .path = working_dir.? },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });

        const term = try extract_proc.wait(self.io);
        if (term != .exited or term.exited != 0) {
            std.log.warn("Could not extract AppImage {s}", .{path});
            operation_scope.finish(.failed);
            freeWorkingDir(self.allocator, self.io, &working_dir);
            return null;
        }

        var squashfs_root: ?[]u8 = try std.fs.path.join(self.allocator, &.{ working_dir.?, "squashfs-root" });
        errdefer if (squashfs_root) |s| self.allocator.free(s);

        var source_desktop_path: ?[]const u8 = try self.findDesktopFile(squashfs_root.?);
        errdefer if (source_desktop_path) |p| self.allocator.free(p);

        var version: []const u8 = "Unknown";
        var version_owned = false;
        var desktop_name: []const u8 = "";
        var desktop_name_owned = false;
        var description: []const u8 = "";
        var description_owned = false;
        var icon_line_value: ?[]const u8 = null;
        errdefer if (icon_line_value) |v| self.allocator.free(v);

        if (source_desktop_path) |dfp| {
            const contents = try self.readFileAllocOwned(dfp);
            defer self.allocator.free(contents);

            var lines = std.mem.splitScalar(u8, contents, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "X-AppImage-Version=") and !version_owned) {
                    version = try self.allocator.dupe(u8, line["X-AppImage-Version=".len..]);
                    version_owned = true;
                } else if (std.mem.startsWith(u8, line, "Name=") and desktop_name.len == 0) {
                    desktop_name = try self.allocator.dupe(u8, line["Name=".len..]);
                    desktop_name_owned = true;
                } else if (std.mem.startsWith(u8, line, "Comment=") and description.len == 0) {
                    description = try self.allocator.dupe(u8, line["Comment=".len..]);
                    description_owned = true;
                } else if (std.mem.startsWith(u8, line, "Icon=") and icon_line_value == null) {
                    icon_line_value = try self.allocator.dupe(u8, line["Icon=".len..]);
                }
            }
        }

        var icon_source: ?IconSource = try self.findIconSource(squashfs_root.?, icon_line_value orelse "");
        errdefer if (icon_source) |src| self.allocator.free(src.path);
        if (icon_line_value) |v| {
            self.allocator.free(v);
            icon_line_value = null;
        }

        const icon_name: []const u8 = if (icon_source != null)
            try std.ascii.allocLowerString(self.allocator, clean_name)
        else
            try self.allocator.dupe(u8, "application-x-executable");
        errdefer self.allocator.free(icon_name);

        const update_info = try self.getAppImageUpdateInfo(path);
        errdefer self.allocator.free(update_info);

        const owned_version = if (version_owned) version else try self.allocator.dupe(u8, "Unknown");
        errdefer if (!version_owned) self.allocator.free(owned_version);

        const owned_description = if (description_owned) description else try self.allocator.dupe(u8, "");
        errdefer if (!description_owned) self.allocator.free(owned_description);

        const owned_desktop_name = if (desktop_name.len > 0)
            desktop_name
        else blk: {
            if (desktop_name_owned) self.allocator.free(desktop_name);
            break :blk try self.allocator.dupe(u8, app_name);
        };
        errdefer if (desktop_name.len == 0) self.allocator.free(owned_desktop_name);

        const owned_name = try self.allocator.dupe(u8, app_name);
        errdefer self.allocator.free(owned_name);
        const owned_path = try self.allocator.dupe(u8, exec_path);
        errdefer self.allocator.free(owned_path);

        const stat = try std.Io.Dir.cwd().statFile(self.io, path, .{});

        const metadata = appimage.AppImage{
            .name = owned_name,
            .version = owned_version,
            .raw_update_info = update_info,
            .icon_name = icon_name,
            .description = owned_description,
            .desktop_name = owned_desktop_name,
            .size_on_disk = stat.size,
            .path = owned_path,
        };

        operation_scope.finish(.success);

        const result = ExtractedContent{
            .allocator = self.allocator,
            .io = self.io,
            .metadata = metadata,
            .source_desktop_path = source_desktop_path,
            .icon_source = icon_source,
            .working_dir = working_dir.?,
            .squashfs_root = squashfs_root.?,
        };

        working_dir = null;
        squashfs_root = null;
        source_desktop_path = null;
        icon_source = null;
        icon_line_value = null;
        version_owned = false;
        description_owned = false;

        return result;
    }

    fn createExtractionWorkingDir(self: AppImageManager, clean_name: []const u8) ![]u8 {
        const cache_home = try xdg_paths.xdgCacheHome(self.allocator, self.environ);
        defer self.allocator.free(cache_home);
        const root = try std.fs.path.join(self.allocator, &.{ cache_home, "Shelly", "extractions" });
        defer self.allocator.free(root);

        var root_handle = try std.Io.Dir.cwd().createDirPathOpen(self.io, root, .{});
        root_handle.close(self.io);

        var random_suffix: [16]u8 = undefined;
        self.io.random(&random_suffix);
        const suffix_hex = std.fmt.bytesToHex(random_suffix, .lower);
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}-{s}", .{ root, clean_name, suffix_hex[0..] });
        errdefer self.allocator.free(path);
        try std.Io.Dir.createDirAbsolute(self.io, path, .default_dir);
        return path;
    }

    fn findDesktopFile(self: AppImageManager, dir: []const u8) !?[]const u8 {
        var d = std.Io.Dir.cwd().openDir(self.io, dir, .{ .iterate = true }) catch return null;
        defer d.close(self.io);

        var it = d.iterate();
        while (try it.next(self.io)) |entry| {
            if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(entry.name), ".desktop")) continue;
            const path = try std.fs.path.join(self.allocator, &.{ dir, entry.name });
            if (entry.kind == .file) return path;
            if (entry.kind == .sym_link) {
                const resolved = try self.resolveConfinedFile(dir, path);
                self.allocator.free(path);
                if (resolved) |resolved_path| return resolved_path;
            } else self.allocator.free(path);
        }

        var walker = try d.walk(self.allocator);
        defer walker.deinit();
        while (try walker.next(self.io)) |entry| {
            if (entry.kind != .file or
                !std.ascii.eqlIgnoreCase(std.fs.path.extension(entry.basename), ".desktop")) continue;
            return try std.fs.path.join(self.allocator, &.{ dir, entry.path });
        }
        return null;
    }

    fn resolveConfinedFile(
        self: AppImageManager,
        root: []const u8,
        candidate: []const u8,
    ) !?[]u8 {
        const canonical_root = try std.Io.Dir.cwd().realPathFileAlloc(self.io, root, self.allocator);
        defer self.allocator.free(canonical_root);
        const canonical_candidate = std.Io.Dir.cwd().realPathFileAlloc(
            self.io,
            candidate,
            self.allocator,
        ) catch return null;
        errdefer self.allocator.free(canonical_candidate);
        if (!pathIsInside(canonical_root, canonical_candidate)) {
            self.allocator.free(canonical_candidate);
            return null;
        }
        const status = std.Io.Dir.cwd().statFile(
            self.io,
            canonical_candidate,
            .{ .follow_symlinks = false },
        ) catch {
            self.allocator.free(canonical_candidate);
            return null;
        };
        if (status.kind != .file) {
            self.allocator.free(canonical_candidate);
            return null;
        }
        const result = try self.allocator.dupe(u8, canonical_candidate);
        self.allocator.free(canonical_candidate);
        return result;
    }

    fn readFileAllocOwned(self: AppImageManager, path: []const u8) ![]u8 {
        var file = try std.Io.Dir.cwd().openFile(self.io, path, .{});
        defer file.close(self.io);
        var buf: [4096]u8 = undefined;
        var reader = file.reader(self.io, &buf);
        return reader.interface.allocRemaining(self.allocator, .unlimited);
    }

    const IconSource = struct { path: []const u8, ext: []const u8 };

    pub const ExtractedContent = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        metadata: appimage.AppImage,
        source_desktop_path: ?[]const u8 = null,
        icon_source: ?IconSource = null,
        working_dir: []const u8,
        squashfs_root: []const u8,
        owns_metadata: bool = true,

        pub fn deinit(self: *ExtractedContent) void {
            const allocator = self.allocator;
            if (self.owns_metadata) freeAppImageStatic(allocator, self.metadata);
            if (self.source_desktop_path) |p| allocator.free(p);
            if (self.icon_source) |src| allocator.free(src.path);
            allocator.free(self.squashfs_root);
            std.Io.Dir.cwd().deleteTree(self.io, self.working_dir) catch {};
            allocator.free(self.working_dir);
            self.* = undefined;
        }

        pub fn stealMetadata(self: *ExtractedContent) appimage.AppImage {
            self.owns_metadata = false;
            return self.metadata;
        }
    };

    fn findIconSource(self: AppImageManager, squashfs_root: []const u8, icon_value: []const u8) !?IconSource {
        var d = std.Io.Dir.cwd().openDir(self.io, squashfs_root, .{ .iterate = true }) catch return null;
        defer d.close(self.io);

        const requested_stem = std.fs.path.stem(std.fs.path.basename(icon_value));
        var best_path: ?[]u8 = null;
        errdefer if (best_path) |path| self.allocator.free(path);
        var best_score: u8 = 0;

        if (requested_stem.len > 0) {
            var walker = try d.walk(self.allocator);
            defer walker.deinit();
            while (try walker.next(self.io)) |entry| {
                if (entry.kind != .file) continue;
                const ext = std.fs.path.extension(entry.basename);
                if (!isSupportedIconExtension(ext) or
                    !std.ascii.eqlIgnoreCase(std.fs.path.stem(entry.basename), requested_stem)) continue;
                const score = iconSourceScore(entry.path, ext);
                if (best_path != null and score <= best_score) continue;
                const candidate = try std.fs.path.join(self.allocator, &.{ squashfs_root, entry.path });
                if (best_path) |path| self.allocator.free(path);
                best_path = candidate;
                best_score = score;
            }
        }
        if (best_path) |path| {
            const ext = std.fs.path.extension(path);
            return IconSource{ .path = path, .ext = ext };
        }

        const diricon = try std.fs.path.join(self.allocator, &.{ squashfs_root, ".DirIcon" });
        defer self.allocator.free(diricon);
        const resolved = (try self.resolveConfinedFile(squashfs_root, diricon)) orelse return null;
        const resolved_ext = std.fs.path.extension(resolved);
        if (isSupportedIconExtension(resolved_ext)) {
            return IconSource{ .path = resolved, .ext = resolved[resolved.len - resolved_ext.len ..] };
        }
        return IconSource{ .path = resolved, .ext = ".png" };
    }

    fn iconSubDir(ext: []const u8) []const u8 {
        return if (std.mem.eql(u8, ext, ".svg"))
            "icons/hicolor/scalable/apps"
        else
            "icons/hicolor/256x256/apps";
    }

    fn iconDestinationPath(self: AppImageManager, source: IconSource, icon_name: []const u8) ![]u8 {
        const data_home = try xdg_paths.xdgDataHome(self.allocator, self.environ);
        defer self.allocator.free(data_home);
        const icon_dir = try std.fs.path.join(self.allocator, &.{ data_home, iconSubDir(source.ext) });
        defer self.allocator.free(icon_dir);
        const dest_icon_name = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ icon_name, source.ext });
        defer self.allocator.free(dest_icon_name);
        return std.fs.path.join(self.allocator, &.{ icon_dir, dest_icon_name });
    }

    fn updateIconCache(self: AppImageManager, data_home: []const u8) void {
        const theme_dir = std.fs.path.join(self.allocator, &.{ data_home, "icons/hicolor" }) catch |err| {
            self.emitCacheWarningFmt(
                "Could not prepare the icon cache refresh: {s}. Installed icons may not appear in menus until the icon cache is rebuilt.",
                .{@errorName(err)},
            );
            return;
        };
        defer self.allocator.free(theme_dir);
        self.runCacheRefresh(
            "gtk-update-icon-cache",
            theme_dir,
            &.{ "gtk-update-icon-cache", "-f", "-t", theme_dir },
            "Installed icons may not appear in menus until the icon cache is rebuilt.",
        );
    }

    pub fn refreshDesktopCachesBestEffort(self: AppImageManager, refresh_icons: bool) void {
        const data_home = xdg_paths.xdgDataHome(self.allocator, self.environ) catch |err| {
            self.emitCacheWarningFmt("Could not resolve the user data directory for cache refreshes: {s}.", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(data_home);

        const desktop_dir = std.fs.path.join(self.allocator, &.{ data_home, "applications" }) catch |err| {
            self.emitCacheWarningFmt(
                "Could not prepare the desktop database refresh: {s}. Application menu entries may not update until the desktop database is rebuilt.",
                .{@errorName(err)},
            );
            if (refresh_icons) self.updateIconCache(data_home);
            return;
        };
        defer self.allocator.free(desktop_dir);
        self.updateDesktopDatabase(desktop_dir);
        if (refresh_icons) self.updateIconCache(data_home);
    }

    fn runCacheRefresh(
        self: AppImageManager,
        tool_name: []const u8,
        target_path: []const u8,
        argv: []const []const u8,
        consequence: []const u8,
    ) void {
        const result = self.cache_command_run(self.allocator, self.io, self.environ, argv) catch |err| {
            if (err == error.StreamTooLong) {
                self.emitCacheWarningFmt(
                    "{s} produced more than {d} bytes of output while refreshing {s}. {s}",
                    .{ tool_name, max_cache_command_output, target_path, consequence },
                );
            } else if (err == error.FileNotFound) {
                self.emitCacheWarningFmt(
                    "Cache utility {s} is unavailable; {s} was not refreshed. {s}",
                    .{ tool_name, target_path, consequence },
                );
            } else {
                self.emitCacheWarningFmt(
                    "Could not run {s} for {s}: {s}. {s}",
                    .{ tool_name, target_path, @errorName(err), consequence },
                );
            }
            return;
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term == .exited and result.term.exited == 0) return;

        const diagnostic_output = if (std.mem.trim(u8, result.stderr, " \t\r\n").len > 0)
            result.stderr
        else
            result.stdout;
        sanitizeCacheDiagnostic(diagnostic_output);
        const diagnostic = std.mem.trim(u8, diagnostic_output, " \t\r\n");

        var term_buffer: [96]u8 = undefined;
        const term_description = switch (result.term) {
            .exited => |code| std.fmt.bufPrint(&term_buffer, "exited with status {d}", .{code}) catch "failed",
            .signal => |signal| std.fmt.bufPrint(&term_buffer, "terminated by signal {d}", .{@intFromEnum(signal)}) catch "failed",
            .stopped => |signal| std.fmt.bufPrint(&term_buffer, "stopped by signal {d}", .{@intFromEnum(signal)}) catch "failed",
            .unknown => |status| std.fmt.bufPrint(&term_buffer, "returned unknown status {d}", .{status}) catch "failed",
        };

        if (diagnostic.len > 0) {
            self.emitCacheWarningFmt(
                "{s} {s} while refreshing {s}: {s}. {s}",
                .{ tool_name, term_description, target_path, diagnostic, consequence },
            );
        } else {
            self.emitCacheWarningFmt(
                "{s} {s} while refreshing {s}. {s}",
                .{ tool_name, term_description, target_path, consequence },
            );
        }
    }

    fn emitCacheWarningFmt(self: AppImageManager, comptime format: []const u8, args: anytype) void {
        const message = std.fmt.allocPrint(self.allocator, format, args) catch {
            std.log.warn("A desktop integration cache refresh failed, but the AppImage operation completed.", .{});
            self.emitStatus(.warning, "A desktop integration cache refresh failed, but the AppImage operation completed.");
            return;
        };
        defer self.allocator.free(message);
        std.log.warn("{s}", .{message});
        self.emitStatus(.warning, message);
    }

    pub fn applyDesktopIntegration(
        self: AppImageManager,
        metadata: appimage.AppImage,
        final_exec_path: []const u8,
        source_desktop_path: ?[]const u8,
        icon_source: ?IconSource,
    ) !void {
        var integration = try self.beginDesktopIntegration(metadata, final_exec_path, source_desktop_path, icon_source);
        defer integration.deinit();
        try integration.finish();
        self.refreshDesktopCachesBestEffort(icon_source != null);
    }

    pub const DesktopIntegration = struct {
        manager: AppImageManager,
        desktop_path: []u8,
        desktop_backup: ?[]u8 = null,
        icon_path: ?[]u8 = null,
        icon_backup: ?[]u8 = null,
        active: bool = true,

        pub fn deinit(self: *DesktopIntegration) void {
            if (self.active) self.rollback() catch {};
            if (self.desktop_backup) |path| self.manager.allocator.free(path);
            if (self.icon_backup) |path| self.manager.allocator.free(path);
            self.manager.allocator.free(self.desktop_path);
            if (self.icon_path) |path| self.manager.allocator.free(path);
            self.* = undefined;
        }

        fn snapshot(self: *DesktopIntegration, path: []const u8, label: []const u8) !?[]u8 {
            _ = std.Io.Dir.cwd().statFile(self.manager.io, path, .{}) catch return null;
            const backup = try self.manager.uniqueSiblingPath(path, label);
            errdefer self.manager.allocator.free(backup);
            std.Io.Dir.hardLink(.cwd(), path, .cwd(), backup, self.manager.io, .{}) catch
                try self.manager.copyFile(path, backup);
            return backup;
        }

        pub fn rollback(self: *DesktopIntegration) !void {
            if (!self.active) return;
            try restoreArtifact(self.manager.io, self.desktop_path, self.desktop_backup);
            if (self.icon_path) |icon_path| try restoreArtifact(self.manager.io, icon_path, self.icon_backup);
            self.active = false;
        }

        pub fn finish(self: *DesktopIntegration) !void {
            if (!self.active) return;
            if (self.desktop_backup) |backup| std.Io.Dir.cwd().deleteFile(self.manager.io, backup) catch |err| {
                std.log.warn("Could not remove desktop backup {s}: {s}", .{ backup, @errorName(err) });
            };
            if (self.icon_backup) |backup| std.Io.Dir.cwd().deleteFile(self.manager.io, backup) catch |err| {
                std.log.warn("Could not remove icon backup {s}: {s}", .{ backup, @errorName(err) });
            };
            self.active = false;
        }
    };

    pub fn beginDesktopIntegration(
        self: AppImageManager,
        metadata: appimage.AppImage,
        final_exec_path: []const u8,
        source_desktop_path: ?[]const u8,
        icon_source: ?IconSource,
    ) !DesktopIntegration {
        const clean_name = try self.cleanInvalidNames(metadata.name);
        defer self.allocator.free(clean_name);
        const desktop_path = try self.installedDesktopPath(clean_name);
        var integration = DesktopIntegration{ .manager = self, .desktop_path = desktop_path };
        errdefer integration.deinit();
        integration.desktop_backup = try integration.snapshot(desktop_path, "desktop-backup");

        if (icon_source) |source| {
            const icon_path = try self.iconDestinationPath(source, metadata.icon_name);
            integration.icon_path = icon_path;
            integration.icon_backup = try integration.snapshot(icon_path, "icon-backup");
            try self.writeFileAtomically(source.path, icon_path, "icon-stage");
        }
        try self.writeDesktopEntry(clean_name, final_exec_path, source_desktop_path, metadata);

        return integration;
    }

    fn writeDesktopEntry(
        self: AppImageManager,
        clean_name: []const u8,
        exec_path: []const u8,
        source_desktop_file: ?[]const u8,
        metadata: appimage.AppImage,
    ) !void {
        const data_home = try xdg_paths.xdgDataHome(self.allocator, self.environ);
        defer self.allocator.free(data_home);
        const desktop_dir = try std.fs.path.join(self.allocator, &.{ data_home, "applications" });
        defer self.allocator.free(desktop_dir);
        {
            var desktop_dir_handle = try std.Io.Dir.cwd().createDirPathOpen(self.io, desktop_dir, .{});
            desktop_dir_handle.close(self.io);
        }

        const desktop_file_name = try std.fmt.allocPrint(self.allocator, "{s}.desktop", .{clean_name});
        defer self.allocator.free(desktop_file_name);
        const desktop_file_path = try std.fs.path.join(self.allocator, &.{ desktop_dir, desktop_file_name });
        defer self.allocator.free(desktop_file_path);

        const desktop_name: []const u8 = if (metadata.desktop_name.len > 0) metadata.desktop_name else metadata.name;
        const comment: []const u8 = if (metadata.description.len > 0) metadata.description else "application";
        const escaped_exec_path = try launch_environment.composeExec(self.allocator, exec_path, null, metadata.environment_variables);
        defer self.allocator.free(escaped_exec_path);
        const escaped_try_exec_path = try escapeDesktopStringValue(self.allocator, exec_path);
        defer self.allocator.free(escaped_try_exec_path);

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var in_desktop_entry = source_desktop_file == null;
        var saw_desktop_entry = source_desktop_file == null;
        var wrote_name = false;
        var wrote_comment = false;
        var wrote_exec = false;
        var wrote_try_exec = false;
        var wrote_icon = false;

        const append_authoritative = struct {
            fn call(writer: *std.Io.Writer.Allocating, name: []const u8, description: []const u8, escaped_exec: []const u8, escaped_try_exec: []const u8, icon: []const u8, name_written: *bool, comment_written: *bool, exec_written: *bool, try_exec_written: *bool, icon_written: *bool) !void {
                if (!name_written.*) {
                    try writer.writer.print("Name={s}\n", .{name});
                    name_written.* = true;
                }
                if (!comment_written.*) {
                    try writer.writer.print("Comment={s}\n", .{description});
                    comment_written.* = true;
                }
                if (!exec_written.*) {
                    try writer.writer.print("Exec={s}\n", .{escaped_exec});
                    exec_written.* = true;
                }
                if (!try_exec_written.*) {
                    try writer.writer.print("TryExec={s}\n", .{escaped_try_exec});
                    try_exec_written.* = true;
                }
                if (!icon_written.*) {
                    try writer.writer.print("Icon={s}\n", .{icon});
                    icon_written.* = true;
                }
            }
        }.call;

        if (source_desktop_file) |src| {
            const contents = try self.readFileAllocOwned(src);
            defer self.allocator.free(contents);
            var main_exec: ?[]const u8 = null;
            var source_lines = std.mem.splitScalar(u8, contents, '\n');
            var main_section = false;
            while (source_lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "[")) main_section = std.mem.eql(u8, line, "[Desktop Entry]");
                if (main_section and std.mem.startsWith(u8, line, "Exec=")) main_exec = line[5..];
            }
            var in_action = false;
            var lines = std.mem.splitScalar(u8, contents, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "[")) in_action = std.mem.startsWith(u8, line, "[Desktop Action ");
                if (std.mem.startsWith(u8, line, "[") and !std.mem.eql(u8, line, "[Desktop Entry]")) {
                    if (in_desktop_entry) try append_authoritative(&out, desktop_name, comment, escaped_exec_path, escaped_try_exec_path, metadata.icon_name, &wrote_name, &wrote_comment, &wrote_exec, &wrote_try_exec, &wrote_icon);
                    in_desktop_entry = false;
                }
                if (std.mem.eql(u8, line, "[Desktop Entry]")) {
                    saw_desktop_entry = true;
                    in_desktop_entry = true;
                    try out.writer.writeAll("[Desktop Entry]\n");
                } else if (in_desktop_entry and std.mem.startsWith(u8, line, "Exec=")) {
                    const command = try launch_environment.composeExec(self.allocator, exec_path, line["Exec=".len..], metadata.environment_variables);
                    defer self.allocator.free(command);
                    try out.writer.print("Exec={s}\n", .{command});
                    wrote_exec = true;
                } else if (in_action and main_exec != null and
                    std.mem.startsWith(u8, line, "Exec=") and launch_environment.sameExecutable(main_exec.?, line[5..]))
                {
                    const command = try launch_environment.composeExec(self.allocator, exec_path, line[5..], metadata.environment_variables);
                    defer self.allocator.free(command);
                    try out.writer.print("Exec={s}\n", .{command});
                } else if (in_desktop_entry and std.mem.startsWith(u8, line, "TryExec=")) {
                    try out.writer.print("TryExec={s}\n", .{escaped_try_exec_path});
                    wrote_try_exec = true;
                } else if (in_desktop_entry and std.mem.startsWith(u8, line, "Icon=")) {
                    try out.writer.print("Icon={s}\n", .{metadata.icon_name});
                    wrote_icon = true;
                } else if (in_desktop_entry and std.mem.startsWith(u8, line, "Name=")) {
                    try out.writer.print("Name={s}\n", .{desktop_name});
                    wrote_name = true;
                } else if (in_desktop_entry and std.mem.startsWith(u8, line, "Comment=")) {
                    try out.writer.print("Comment={s}\n", .{comment});
                    wrote_comment = true;
                } else {
                    try out.writer.print("{s}\n", .{line});
                }
            }
        }
        if (!saw_desktop_entry) try out.writer.writeAll("[Desktop Entry]\nVersion=1.0\nType=Application\n");
        try append_authoritative(&out, desktop_name, comment, escaped_exec_path, escaped_try_exec_path, metadata.icon_name, &wrote_name, &wrote_comment, &wrote_exec, &wrote_try_exec, &wrote_icon);
        if (!saw_desktop_entry) try out.writer.writeAll("Terminal=false\nCategories=Utility;\nStartupNotify=true\n");
        try self.writeBytesAtomically(out.written(), desktop_file_path, "desktop-stage");
    }

    pub fn writeFileAtomically(self: AppImageManager, source_path: []const u8, destination_path: []const u8, label: []const u8) !void {
        const staging_path = try self.uniqueSiblingPath(destination_path, label);
        defer self.allocator.free(staging_path);
        defer std.Io.Dir.cwd().deleteFile(self.io, staging_path) catch {};
        if (std.fs.path.dirname(destination_path)) |directory| {
            var directory_handle = try std.Io.Dir.cwd().createDirPathOpen(self.io, directory, .{});
            directory_handle.close(self.io);
        }
        try self.copyFile(source_path, staging_path);
        try std.Io.Dir.rename(.cwd(), staging_path, .cwd(), destination_path, self.io);
    }

    fn writeBytesAtomically(self: AppImageManager, bytes: []const u8, destination_path: []const u8, label: []const u8) !void {
        const staging_path = try self.uniqueSiblingPath(destination_path, label);
        defer self.allocator.free(staging_path);
        defer std.Io.Dir.cwd().deleteFile(self.io, staging_path) catch {};
        {
            var file = try std.Io.Dir.cwd().createFile(self.io, staging_path, .{ .exclusive = true });
            defer file.close(self.io);
            var write_buf: [4096]u8 = undefined;
            var writer = file.writer(self.io, &write_buf);
            try writer.interface.writeAll(bytes);
            try writer.interface.flush();
            try file.sync(self.io);
        }
        try std.Io.Dir.rename(.cwd(), staging_path, .cwd(), destination_path, self.io);
    }

    fn updateDesktopDatabase(self: AppImageManager, desktop_dir: []const u8) void {
        self.runCacheRefresh(
            "update-desktop-database",
            desktop_dir,
            &.{ "update-desktop-database", desktop_dir },
            "Application menu entries may not update until the desktop database is rebuilt.",
        );
    }

    pub fn getAppImageUpdateInfo(self: AppImageManager, appimage_path: []const u8) ![]const u8 {
        var operation_scope = events.OperationScope.init(self.operation_context, self.dispatcher, .inspect, appimage_path);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        var proc = std.process.spawn(self.io, .{
            .argv = &.{ appimage_path, "--appimage-updateinfo" },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch return try self.allocator.dupe(u8, "");

        const stdout_file = proc.stdout orelse {
            _ = proc.wait(self.io) catch {};
            return try self.allocator.dupe(u8, "");
        };
        var buf: [4096]u8 = undefined;
        var reader = stdout_file.reader(self.io, &buf);
        const output = reader.interface.allocRemaining(self.allocator, .unlimited) catch {
            _ = proc.wait(self.io) catch {};
            return try self.allocator.dupe(u8, "");
        };
        defer self.allocator.free(output);
        _ = proc.wait(self.io) catch {};
        return try self.allocator.dupe(u8, std.mem.trim(u8, output, " \t\r\n"));
    }

    pub fn getAppImagesFromLocalDb(self: AppImageManager) ![]appimage.AppImage {
        var operation_scope = events.OperationScope.init(self.operation_context, self.dispatcher, .search, self.local_db_path);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        var file = std.Io.Dir.cwd().openFile(self.io, self.local_db_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return &.{},
            else => return err,
        };
        defer file.close(self.io);

        var buf: [4096]u8 = undefined;
        var reader = file.reader(self.io, &buf);
        const contents = try reader.interface.allocRemaining(self.allocator, .unlimited);
        defer self.allocator.free(contents);

        const parsed = std.json.parseFromSlice([]appimage.AppImage, self.allocator, contents, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            std.log.warn("Error reading AppImage local DB: {s}", .{@errorName(err)});
            return &.{};
        };
        defer parsed.deinit();
        return try self.cloneAppImages(parsed.value);
    }

    pub fn configureEnvironment(self: AppImageManager, name: []const u8, mutation: launch_environment.Mutation) !void {
        try ensureNonRootMutation();
        try self.checkCancelled();
        const apps = try self.getAppImagesFromLocalDb();
        defer self.freeAppImages(apps);
        var selected: ?appimage.AppImage = null;
        for (apps) |app| {
            if (std.ascii.eqlIgnoreCase(app.name, name)) {
                if (selected != null) return error.AmbiguousAppImage;
                selected = app;
            }
        }
        var candidate = selected orelse return error.AppImageNotFound;
        const variables = try launch_environment.mutate(self.allocator, candidate.environment_variables, mutation);
        defer launch_environment.free(self.allocator, variables);
        candidate.environment_variables = variables;
        var content = (try self.extractMetadataPure(candidate.path, null, null)) orelse return error.AppImageExtractionFailed;
        defer content.deinit();
        var integration = try self.beginDesktopIntegration(candidate, candidate.path, content.source_desktop_path, content.icon_source);
        defer integration.deinit();
        self.addAppImageToLocalDb(candidate) catch |err| {
            try integration.rollback();
            return err;
        };
        try integration.finish();
        self.refreshDesktopCachesBestEffort(content.icon_source != null);
    }

    pub fn mergeMetadata(existing: appimage.AppImage, extracted: appimage.AppImage, provider_version: ?[]const u8) appimage.AppImage {
        return .{
            .name = existing.name,
            .version = if (extracted.version.len > 0 and !std.mem.eql(u8, extracted.version, "Unknown")) extracted.version else provider_version orelse existing.version,
            .release_tag = provider_version orelse existing.release_tag,
            .raw_update_info = if (extracted.raw_update_info.len > 0) extracted.raw_update_info else existing.raw_update_info,
            .icon_name = extracted.icon_name,
            .description = extracted.description,
            .desktop_name = extracted.desktop_name,
            .size_on_disk = extracted.size_on_disk,
            .environment_variables = existing.environment_variables,
            .command_line_args = existing.command_line_args,
            .path = existing.path,
            .update_url = existing.update_url,
            .update_type = existing.update_type,
            .repo_owner = existing.repo_owner,
            .repo_name = existing.repo_name,
            .allow_prerelease = existing.allow_prerelease,
        };
    }

    fn cloneAppImages(self: AppImageManager, source: []const appimage.AppImage) ![]appimage.AppImage {
        const result = try self.allocator.alloc(appimage.AppImage, source.len);
        errdefer self.allocator.free(result);

        var initialized: usize = 0;
        errdefer for (result[0..initialized]) |item| self.freeAppImage(item);

        for (source) |item| {
            result[initialized] = try self.cloneAppImage(item);
            initialized += 1;
        }
        return result;
    }

    fn cloneAppImage(self: AppImageManager, source: appimage.AppImage) !appimage.AppImage {
        const name = try self.allocator.dupe(u8, source.name);
        errdefer self.allocator.free(name);
        const version = try self.allocator.dupe(u8, source.version);
        errdefer self.allocator.free(version);
        const release_tag: ?[]const u8 = if (source.release_tag) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (release_tag) |value| self.allocator.free(value);
        const raw_update_info = try self.allocator.dupe(u8, source.raw_update_info);
        errdefer self.allocator.free(raw_update_info);
        const icon_name = try self.allocator.dupe(u8, source.icon_name);
        errdefer self.allocator.free(icon_name);
        const description = try self.allocator.dupe(u8, source.description);
        errdefer self.allocator.free(description);
        const desktop_name = try self.allocator.dupe(u8, source.desktop_name);
        errdefer self.allocator.free(desktop_name);
        const environment_variables = try launch_environment.clone(self.allocator, source.environment_variables);
        errdefer launch_environment.free(self.allocator, environment_variables);
        const command_line_args = try self.allocator.dupe(u8, source.command_line_args);
        errdefer self.allocator.free(command_line_args);
        const path = try self.allocator.dupe(u8, source.path);
        errdefer self.allocator.free(path);
        const update_url = try self.allocator.dupe(u8, source.update_url);
        errdefer self.allocator.free(update_url);
        const repo_owner: ?[]const u8 = if (source.repo_owner) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (repo_owner) |value| self.allocator.free(value);
        const repo_name: ?[]const u8 = if (source.repo_name) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (repo_name) |value| self.allocator.free(value);

        return .{
            .name = name,
            .version = version,
            .release_tag = release_tag,
            .raw_update_info = raw_update_info,
            .icon_name = icon_name,
            .description = description,
            .desktop_name = desktop_name,
            .size_on_disk = source.size_on_disk,
            .environment_variables = environment_variables,
            .command_line_args = command_line_args,
            .path = path,
            .update_url = update_url,
            .update_type = source.update_type,
            .repo_owner = repo_owner,
            .repo_name = repo_name,
            .allow_prerelease = source.allow_prerelease,
        };
    }

    fn persistAppImages(self: AppImageManager, items: []const appimage.AppImage) !void {
        const json_bytes = try std.json.Stringify.valueAlloc(self.allocator, items, .{ .whitespace = .indent_2 });
        defer self.allocator.free(json_bytes);

        if (std.fs.path.dirname(self.local_db_path)) |dir| {
            var dir_handle = try std.Io.Dir.cwd().createDirPathOpen(self.io, dir, .{});
            dir_handle.close(self.io);
        }

        const staging_path = try self.uniqueSiblingPath(self.local_db_path, "database");
        defer self.allocator.free(staging_path);
        defer std.Io.Dir.cwd().deleteFile(self.io, staging_path) catch {};

        {
            var file = try std.Io.Dir.cwd().createFile(self.io, staging_path, .{ .exclusive = true });
            defer file.close(self.io);
            var write_buf: [4096]u8 = undefined;
            var writer = file.writer(self.io, &write_buf);
            try writer.interface.writeAll(json_bytes);
            try writer.interface.flush();
            try file.sync(self.io);
        }

        try self.database_commit(self.io, staging_path, self.local_db_path);
    }

    pub fn uniqueSiblingPath(self: AppImageManager, target_path: []const u8, label: []const u8) ![]u8 {
        var random_suffix: [8]u8 = undefined;
        self.io.random(&random_suffix);
        const suffix_hex = std.fmt.bytesToHex(random_suffix, .lower);
        return std.fmt.allocPrint(
            self.allocator,
            "{s}.shelly-{s}-{s}.tmp",
            .{ target_path, label, suffix_hex[0..] },
        );
    }

    pub fn addAppImageToLocalDb(self: AppImageManager, appimage_struct: appimage.AppImage) !void {
        var operation_scope = events.OperationScope.init(self.operation_context, self.dispatcher, .configure, appimage_struct.name);
        operation_scope.attach();
        errdefer operation_scope.fail();
        try self.checkCancelled();
        const existing = try self.getAppImagesFromLocalDb();
        defer self.freeAppImages(existing);

        var list: std.ArrayList(appimage.AppImage) = .empty;
        defer list.deinit(self.allocator);

        for (existing) |item| {
            const same_name = std.ascii.eqlIgnoreCase(item.name, appimage_struct.name);
            const same_desktop_name = appimage_struct.desktop_name.len > 0 and
                std.ascii.eqlIgnoreCase(item.desktop_name, appimage_struct.desktop_name);
            if (same_name or same_desktop_name) continue;
            try list.append(self.allocator, item);
        }
        try list.append(self.allocator, appimage_struct);

        try self.persistAppImages(list.items);
        operation_scope.finish(.success);
    }

    pub fn removeAppImageFromLocalDb(self: AppImageManager, app_name: []const u8) !void {
        var operation_scope = events.OperationScope.init(self.operation_context, self.dispatcher, .configure, app_name);
        operation_scope.attach();
        errdefer operation_scope.fail();
        try self.checkCancelled();

        const existing = try self.getAppImagesFromLocalDb();
        defer self.freeAppImages(existing);

        var list: std.ArrayList(appimage.AppImage) = .empty;
        defer list.deinit(self.allocator);

        var removed = false;
        for (existing) |item| {
            if (std.ascii.eqlIgnoreCase(item.name, app_name)) {
                removed = true;
                continue;
            }
            try list.append(self.allocator, item);
        }

        if (removed) try self.persistAppImages(list.items);
        operation_scope.finish(.success);
    }

    pub fn removeAppImage(self: AppImageManager, appimage_path: []const u8, remove_config_files: bool) !bool {
        try ensureNonRootMutation();
        var operation_scope = events.OperationScope.init(self.operation_context, self.dispatcher, .remove, appimage_path);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        const app_name = std.fs.path.stem(appimage_path);
        self.emitStatusFmt(.information, "Removing AppImage {s}...", .{app_name});
        const clean_name = try self.cleanInvalidNames(app_name);
        defer self.allocator.free(clean_name);

        try self.removeAppImageFromLocalDb(app_name);

        std.Io.Dir.cwd().deleteFile(self.io, appimage_path) catch {};

        const desktop_app_name = self.cleanDesktopEntries(app_name, appimage_path) catch null;
        defer if (desktop_app_name) |n| self.allocator.free(n);

        try self.removeAppImageIcons(clean_name);

        if (remove_config_files) {
            self.removeAppConfigDirectories(desktop_app_name);
        }

        self.refreshDesktopCachesBestEffort(true);

        self.emitStatusFmt(.success, "Removed AppImage {s}.", .{app_name});
        return true;
    }

    fn removeAppImageIcons(self: AppImageManager, clean_name: []const u8) !void {
        const data_home = try xdg_paths.xdgDataHome(self.allocator, self.environ);
        defer self.allocator.free(data_home);
        for ([_][]const u8{ iconSubDir(".svg"), iconSubDir(".png") }) |icon_sub_dir| {
            const icon_dir = std.fs.path.join(self.allocator, &.{ data_home, icon_sub_dir }) catch continue;
            defer self.allocator.free(icon_dir);
            var d = std.Io.Dir.cwd().openDir(self.io, icon_dir, .{ .iterate = true }) catch continue;
            defer d.close(self.io);
            var it = d.iterate();
            while (it.next(self.io) catch null) |entry| {
                try self.checkCancelled();
                if (entry.kind != .file) continue;
                if (!std.ascii.eqlIgnoreCase(std.fs.path.stem(entry.name), clean_name)) continue;
                const icon_path = std.fs.path.join(self.allocator, &.{ icon_dir, entry.name }) catch continue;
                defer self.allocator.free(icon_path);
                std.Io.Dir.cwd().deleteFile(self.io, icon_path) catch {};
            }
        }
    }

    fn removeStaleAppImageEntry(self: AppImageManager, app_name: []const u8, appimage_path: []const u8) void {
        self.removeAppImageFromLocalDb(app_name) catch |err| {
            std.log.warn("Could not remove stale AppImage metadata for {s}: {s}", .{ app_name, @errorName(err) });
            return;
        };
        self.emitStatusFmt(.warning, "AppImage file for {s} not found; removed stale metadata entry.", .{app_name});

        const desktop_app_name = self.cleanDesktopEntries(app_name, appimage_path) catch null;
        if (desktop_app_name) |n| self.allocator.free(n);

        const clean_name = self.cleanInvalidNames(app_name) catch return;
        defer self.allocator.free(clean_name);
        self.removeAppImageIcons(clean_name) catch {};

        self.refreshDesktopCachesBestEffort(true);
    }

    pub fn syncAppImageMeta(self: AppImageManager, app_image_names: []const []const u8) !bool {
        try ensureNonRootMutation();
        var operation_scope = events.OperationScope.init(self.operation_context, self.dispatcher, .sync, null);
        operation_scope.attach();
        errdefer operation_scope.fail();
        try self.checkCancelled();
        self.emitStatus(.information, "Synchronizing AppImage metadata...");
        const db_images = try self.getAppImagesFromLocalDb();
        defer self.freeAppImages(db_images);
        var success = true;

        for (app_image_names, 0..) |app_name, app_index| {
            try self.checkCancelled();
            if (self.dispatcher) |dispatcher| {
                if (dispatcher.operation) |operation| operation.progress(.{
                    .stage = "metadata",
                    .completed = app_index,
                    .total = app_image_names.len,
                    .percentage = if (app_image_names.len == 0) 100 else @as(f64, @floatFromInt(app_index)) * 100.0 / @as(f64, @floatFromInt(app_image_names.len)),
                    .message = app_name,
                });
            }
            const existing: ?appimage.AppImage = blk: {
                for (db_images) |img| {
                    if (std.ascii.eqlIgnoreCase(img.name, app_name)) break :blk img;
                }
                break :blk null;
            };

            const dest_name = std.fmt.allocPrint(self.allocator, "{s}.AppImage", .{app_name}) catch {
                success = false;
                continue;
            };
            defer self.allocator.free(dest_name);
            const appimage_path = std.fs.path.join(self.allocator, &.{ self.install_directory, dest_name }) catch {
                success = false;
                continue;
            };
            defer self.allocator.free(appimage_path);

            const file_at_install = (std.Io.Dir.cwd().statFile(self.io, appimage_path, .{}) catch null) != null;

            if (!file_at_install) {
                const moved = blk: {
                    if (existing) |ex| {
                        if (ex.path.len == 0) break :blk false;
                        const old_exists = (std.Io.Dir.cwd().statFile(self.io, ex.path, .{}) catch null) != null;
                        if (!old_exists) break :blk false;
                        std.log.info("Moving AppImage from {s} to {s}", .{ ex.path, appimage_path });
                        if (std.Io.Dir.cwd().createDirPathOpen(self.io, self.install_directory, .{})) |dir_handle| {
                            dir_handle.close(self.io);
                        } else |_| {}
                        self.copyFile(ex.path, appimage_path) catch |err| {
                            std.log.err("Failed to move AppImage: {s}", .{@errorName(err)});
                            break :blk false;
                        };
                        std.Io.Dir.cwd().deleteFile(self.io, ex.path) catch {};
                        break :blk true;
                    }
                    break :blk false;
                };
                if (!moved) {
                    if (existing != null) {
                        self.removeStaleAppImageEntry(app_name, appimage_path);
                        continue;
                    }
                    std.log.warn("AppImage not found at {s}", .{appimage_path});
                    success = false;
                    continue;
                }
            }

            var content = (try self.extractMetadataPure(appimage_path, null, null)) orelse {
                std.log.err("Failed to extract metadata for {s}", .{app_name});
                success = false;
                continue;
            };
            defer content.deinit();

            var updated = content.metadata;
            if (existing) |ex| {
                updated = mergeMetadata(ex, content.metadata, null);
            } else if (updated.raw_update_info.len > 0 and updated.update_url.len == 0) {
                updated.update_type = .static_url;
            }

            var integration = self.beginDesktopIntegration(updated, appimage_path, content.source_desktop_path, content.icon_source) catch |err| {
                std.log.warn("Could not apply desktop integration for {s}: {s}", .{ app_name, @errorName(err) });
                success = false;
                continue;
            };
            defer integration.deinit();

            self.addAppImageToLocalDb(updated) catch |err| {
                std.log.warn("Could not persist metadata for {s}: {s}", .{ app_name, @errorName(err) });
                integration.rollback() catch |rollback_err| std.log.err("Could not restore desktop integration: {s}", .{@errorName(rollback_err)});
                success = false;
                continue;
            };
            integration.finish() catch |err| {
                std.log.warn("Could not finalize desktop integration for {s}: {s}", .{ app_name, @errorName(err) });
                success = false;
                continue;
            };
            self.refreshDesktopCachesBestEffort(content.icon_source != null);
        }

        self.emitStatus(
            if (success) .success else .warning,
            if (success) "AppImage metadata synchronized." else "Some AppImage metadata could not be synchronized.",
        );
        operation_scope.finish(if (success) .success else .failed);
        return success;
    }

    fn cleanDesktopEntries(self: AppImageManager, app_name: []const u8, app_path: []const u8) !?[]u8 {
        const clean_name = try self.cleanInvalidNames(app_name);
        defer self.allocator.free(clean_name);

        const data_home = try xdg_paths.xdgDataHome(self.allocator, self.environ);
        defer self.allocator.free(data_home);
        const desktop_dir = try std.fs.path.join(self.allocator, &.{ data_home, "applications" });
        defer self.allocator.free(desktop_dir);

        var d = std.Io.Dir.cwd().openDir(self.io, desktop_dir, .{ .iterate = true }) catch return null;
        defer d.close(self.io);

        var desktop_app_name: ?[]u8 = null;

        var it = d.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".desktop")) continue;

            const df_path = try std.fs.path.join(self.allocator, &.{ desktop_dir, entry.name });
            defer self.allocator.free(df_path);

            const expected_name = try std.fmt.allocPrint(self.allocator, "{s}.desktop", .{clean_name});
            defer self.allocator.free(expected_name);
            const is_name_match = std.ascii.eqlIgnoreCase(entry.name, expected_name);

            const contents: ?[]u8 = blk: {
                const c = self.readFileAllocOwned(df_path) catch break :blk null;
                break :blk c;
            };
            defer if (contents) |c| self.allocator.free(c);

            var is_exec_match = false;
            if (contents) |c| {
                var file_lines = std.mem.splitScalar(u8, c, '\n');
                find_exec: while (file_lines.next()) |fl| {
                    if (!std.mem.startsWith(u8, fl, "Exec=")) continue;
                    if (std.mem.indexOf(u8, fl, app_path) != null) {
                        is_exec_match = true;
                        break :find_exec;
                    }
                    const quoted = std.fmt.allocPrint(self.allocator, "\"{s}\"", .{app_path}) catch continue;
                    defer self.allocator.free(quoted);
                    if (std.mem.indexOf(u8, fl, quoted) != null) {
                        is_exec_match = true;
                        break :find_exec;
                    }
                }
            }

            if (!is_name_match and !is_exec_match) continue;

            if (desktop_app_name == null) {
                if (contents) |c| {
                    var name_lines = std.mem.splitScalar(u8, c, '\n');
                    while (name_lines.next()) |nl| {
                        if (std.mem.startsWith(u8, nl, "Name=")) {
                            const val = std.mem.trim(u8, nl["Name=".len..], " \t\r\n");
                            desktop_app_name = try self.allocator.dupe(u8, val);
                            break;
                        }
                    }
                }
            }

            std.Io.Dir.cwd().deleteFile(self.io, df_path) catch |err| {
                std.log.warn("Failed to remove desktop entry {s}: {s}", .{ df_path, @errorName(err) });
            };
        }

        return desktop_app_name;
    }

    fn removeAppConfigDirectories(self: AppImageManager, desktop_app_name: ?[]const u8) void {
        const name = desktop_app_name orelse return;
        if (name.len == 0) return;

        const normalized_key = self.normalizeForConfig(name) catch return;
        defer self.allocator.free(normalized_key);

        const config_home = xdg_paths.xdgConfigHome(self.allocator, self.environ) catch return;
        defer self.allocator.free(config_home);
        const data_home = xdg_paths.xdgDataHome(self.allocator, self.environ) catch return;
        defer self.allocator.free(data_home);
        const cache_home = xdg_paths.xdgCacheHome(self.allocator, self.environ) catch return;
        defer self.allocator.free(cache_home);
        const state_home = xdg_paths.xdgStateHome(self.allocator, self.environ) catch return;
        defer self.allocator.free(state_home);

        for ([_][]const u8{ config_home, data_home, cache_home, state_home }) |root| {
            var dir = std.Io.Dir.cwd().openDir(self.io, root, .{ .iterate = true }) catch continue;
            defer dir.close(self.io);
            var dir_it = dir.iterate();
            while (dir_it.next(self.io) catch null) |entry| {
                if (entry.kind != .directory) continue;
                const norm = self.normalizeForConfig(entry.name) catch continue;
                defer self.allocator.free(norm);
                if (!std.mem.eql(u8, norm, normalized_key)) continue;
                const dir_path = std.fs.path.join(self.allocator, &.{ root, entry.name }) catch continue;
                defer self.allocator.free(dir_path);
                std.Io.Dir.cwd().deleteTree(self.io, dir_path) catch |err| {
                    std.log.warn("Could not remove config directory {s}: {s}", .{ dir_path, @errorName(err) });
                };
            }
        }
    }

    fn normalizeForConfig(self: AppImageManager, name: []const u8) ![]u8 {
        var buf = try self.allocator.alloc(u8, name.len);
        errdefer self.allocator.free(buf);
        var len: usize = 0;
        for (name) |c| {
            if (c == '-' or c == '_' or c == ' ') continue;
            buf[len] = std.ascii.toLower(c);
            len += 1;
        }
        return self.allocator.realloc(buf, len);
    }

    pub fn cleanInvalidNames(self: AppImageManager, name: []const u8) ![]u8 {
        const lower = try std.ascii.allocLowerString(self.allocator, name);
        defer self.allocator.free(lower);
        const buf = try self.allocator.dupe(u8, lower);
        for (buf) |*c| {
            if (c.* == ' ' or c.* == '/' or c.* == '\\') c.* = '-';
        }
        return buf;
    }

    fn emitStatus(self: AppImageManager, kind: events.StatusKind, message: []const u8) void {
        if (self.dispatcher) |dispatcher| dispatcher.raiseStatus(.{ .kind = kind, .message = message });
    }

    fn checkCancelled(self: AppImageManager) error{Cancelled}!void {
        if (self.dispatcher) |dispatcher| {
            if (dispatcher.operation) |operation| try operation.checkCancelled();
        }
        if (self.operation_context) |context| {
            if (context.isCancelled()) return error.Cancelled;
        }
    }

    fn emitStatusFmt(self: AppImageManager, kind: events.StatusKind, comptime format: []const u8, args: anytype) void {
        const message = std.fmt.allocPrint(self.allocator, format, args) catch {
            self.emitStatus(kind, "AppImage operation status unavailable.");
            return;
        };
        defer self.allocator.free(message);
        self.emitStatus(kind, message);
    }

    pub fn freeAppImage(self: AppImageManager, appimage_struct: appimage.AppImage) void {
        self.allocator.free(appimage_struct.name);
        self.allocator.free(appimage_struct.version);
        if (appimage_struct.release_tag) |v| self.allocator.free(v);
        self.allocator.free(appimage_struct.raw_update_info);
        self.allocator.free(appimage_struct.icon_name);
        self.allocator.free(appimage_struct.description);
        self.allocator.free(appimage_struct.desktop_name);
        launch_environment.free(self.allocator, appimage_struct.environment_variables);
        self.allocator.free(appimage_struct.command_line_args);
        self.allocator.free(appimage_struct.path);
        self.allocator.free(appimage_struct.update_url);
        if (appimage_struct.repo_owner) |v| self.allocator.free(v);
        if (appimage_struct.repo_name) |v| self.allocator.free(v);
    }

    pub fn freeAppImages(self: AppImageManager, appimage_structs: []appimage.AppImage) void {
        for (appimage_structs) |appimage_struct| self.freeAppImage(appimage_struct);
        self.allocator.free(appimage_structs);
    }
};

fn ensureNonRootMutation() !void {
    if (!builtin.is_test and builtin.os.tag == .linux and std.os.linux.geteuid() == 0) {
        return error.RootAppImageMutationDenied;
    }
}

fn restoreArtifact(io: std.Io, destination: []const u8, backup: ?[]const u8) !void {
    if (backup) |path| {
        std.Io.Dir.cwd().deleteFile(io, destination) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        try std.Io.Dir.rename(.cwd(), path, .cwd(), destination, io);
    } else {
        std.Io.Dir.cwd().deleteFile(io, destination) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

fn escapeDesktopStringValue(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var escaped: std.ArrayList(u8) = .empty;
    errdefer escaped.deinit(allocator);
    for (value) |character| {
        const sequence: ?[]const u8 = switch (character) {
            '\\' => "\\\\",
            '\n' => "\\n",
            '\t' => "\\t",
            '\r' => "\\r",
            else => null,
        };
        if (sequence) |bytes| {
            try escaped.appendSlice(allocator, bytes);
        } else {
            try escaped.append(allocator, character);
        }
    }
    return escaped.toOwnedSlice(allocator);
}

fn pathIsInside(root: []const u8, candidate: []const u8) bool {
    return candidate.len > root.len and
        std.mem.startsWith(u8, candidate, root) and
        std.fs.path.isSep(candidate[root.len]);
}

fn freeAppImageStatic(allocator: std.mem.Allocator, value: appimage.AppImage) void {
    allocator.free(value.name);
    allocator.free(value.version);
    if (value.release_tag) |v| allocator.free(v);
    allocator.free(value.raw_update_info);
    allocator.free(value.icon_name);
    allocator.free(value.description);
    allocator.free(value.desktop_name);
    launch_environment.free(allocator, value.environment_variables);
    allocator.free(value.command_line_args);
    allocator.free(value.path);
    allocator.free(value.update_url);
    if (value.repo_owner) |v| allocator.free(v);
    if (value.repo_name) |v| allocator.free(v);
}

fn freeWorkingDir(allocator: std.mem.Allocator, io: std.Io, dir: *?[]u8) void {
    if (dir.*) |w| {
        std.Io.Dir.cwd().deleteTree(io, w) catch |err| {
            std.log.warn("Could not remove AppImage extraction directory {s}: {s}", .{ w, @errorName(err) });
        };
        allocator.free(w);
        dir.* = null;
    }
}

fn isSupportedIconExtension(extension: []const u8) bool {
    return std.ascii.eqlIgnoreCase(extension, ".png") or
        std.ascii.eqlIgnoreCase(extension, ".svg");
}

fn iconSourceScore(path: []const u8, extension: []const u8) u8 {
    if (std.mem.indexOf(u8, path, "icons/hicolor/scalable/apps/") != null) return 7;
    if (std.mem.indexOf(u8, path, "icons/hicolor/256x256/apps/") != null) return 6;
    if (std.mem.indexOf(u8, path, "icons/hicolor/512x512/apps/") != null) return 5;
    if (std.ascii.eqlIgnoreCase(extension, ".svg")) return 4;
    return 1;
}

fn writeTestAppImageDb(path: []const u8, contents: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    var write_buf: [4096]u8 = undefined;
    var writer = file.writer(std.testing.io, &write_buf);
    try writer.interface.writeAll(contents);
    try writer.interface.flush();
}

fn readTestAppImageDb(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(std.testing.io, &read_buf);
    return reader.interface.allocRemaining(allocator, .unlimited);
}

fn createTestAppImageEnviron(allocator: std.mem.Allocator, root: []const u8) !std.process.Environ {
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    const data_home = try std.fs.path.join(allocator, &.{ root, "data" });
    defer allocator.free(data_home);
    try environment.put("HOME", root);
    try environment.put("XDG_DATA_HOME", data_home);
    return .{ .block = try environment.createPosixBlock(allocator, .{}) };
}

fn expectOnlyInstalledAppImage(directory: []const u8, expected_name: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, directory, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |entry| {
        try std.testing.expectEqualStrings(expected_name, entry.name);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

pub fn commitDatabase(
    io: std.Io,
    staging_path: []const u8,
    destination_path: []const u8,
) !void {
    try std.Io.Dir.rename(.cwd(), staging_path, .cwd(), destination_path, io);
}

pub fn runCacheCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    argv: []const []const u8,
) !std.process.RunResult {
    var environment = try environ.createMap(allocator);
    defer environment.deinit();
    return std.process.run(allocator, io, .{
        .argv = argv,
        .environ_map = &environment,
        .stdout_limit = .limited(max_cache_command_output),
        .stderr_limit = .limited(max_cache_command_output),
    });
}

pub fn failDatabaseCommit(
    _: std.Io,
    _: []const u8,
    _: []const u8,
) anyerror!void {
    return error.InjectedDatabaseCommitFailure;
}

fn sanitizeCacheDiagnostic(output: []u8) void {
    for (output) |*character| {
        if ((character.* < ' ' and character.* != '\n' and character.* != '\t') or character.* == 0x7f)
            character.* = ' ';
    }
}

const validTestAppImage =
    \\#!/bin/sh
    \\if [ "$1" = "--appimage-extract" ]; then
    \\  mkdir -p squashfs-root
    \\  printf '%s\n' '[Desktop Entry]' 'Name=Editor' 'X-AppImage-Version=2.0.0' 'Exec=editor' > squashfs-root/editor.desktop
    \\  exit 0
    \\fi
    \\exit 0
;

test "configureEnvironment survives sync and replacement and rolls back failed writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = path_buffer[0..try tmp.dir.realPath(std.testing.io, &path_buffer)];
    const source = try std.fs.path.join(allocator, &.{ root, "Editor.AppImage" });
    const replacement = try std.fs.path.join(allocator, &.{ root, "Editor-2.AppImage" });
    const install_dir = try std.fs.path.join(allocator, &.{ root, "install" });
    const database = try std.fs.path.join(allocator, &.{ root, "appimages.db" });
    const fixture = try std.mem.replaceOwned(u8, allocator, validTestAppImage, "'Exec=editor'", "'Exec=editor' 'Actions=New;Helper;' '[Desktop Action New]' 'Name=New' 'Exec=editor --new' '[Desktop Action Helper]' 'Name=Helper' 'Exec=/usr/bin/true'");
    try writeTestAppImageDb(source, fixture);
    try writeTestAppImageDb(replacement, fixture);
    var environ = try createTestAppImageEnviron(std.testing.allocator, root);
    defer environ.block.deinit(std.testing.allocator);
    var manager = AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = environ,
        .install_directory = install_dir,
        .local_db_path = database,
        .cache_command_run = successfulCacheCommand,
    };
    try std.testing.expect(try manager.installAppImage(source));
    try manager.configureEnvironment("editor", .{ .set = .{ .key = "WEBKIT_DISABLE_DMABUF_RENDERER", .value = "1" } });
    const desktop_path = try manager.installedDesktopPath("editor");
    defer std.testing.allocator.free(desktop_path);
    const desktop_before = try readTestAppImageDb(allocator, desktop_path);
    const database_before = try readTestAppImageDb(allocator, database);
    try std.testing.expect(std.mem.indexOf(u8, desktop_before, "Exec=env \"WEBKIT_DISABLE_DMABUF_RENDERER=1\"") != null);
    try std.testing.expectError(error.InvalidEnvironmentName, manager.configureEnvironment("Editor", .{ .set = .{ .key = "BAD KEY", .value = "2" } }));
    manager.database_commit = failDatabaseCommit;
    try std.testing.expectError(error.InjectedDatabaseCommitFailure, manager.configureEnvironment("Editor", .clear));
    try std.testing.expectEqualStrings(desktop_before, try readTestAppImageDb(allocator, desktop_path));
    try std.testing.expectEqualStrings(database_before, try readTestAppImageDb(allocator, database));
    manager.database_commit = commitDatabase;
    try std.testing.expect(try manager.syncAppImageMeta(&.{"Editor"}));
    try std.testing.expect(try manager.installAppImage(replacement));
    const apps = try manager.getAppImagesFromLocalDb();
    defer manager.freeAppImages(apps);
    try std.testing.expectEqual(@as(usize, 1), apps.len);
    try std.testing.expectEqualStrings("Editor-2", apps[0].name);
    try std.testing.expect(std.mem.endsWith(u8, apps[0].path, "Editor-2.AppImage"));
    try std.testing.expectEqualStrings("1", apps[0].environment_variables[0].value);
    try manager.configureEnvironment("Editor-2", .{ .unset = "WEBKIT_DISABLE_DMABUF_RENDERER" });
    const cleared = try manager.getAppImagesFromLocalDb();
    defer manager.freeAppImages(cleared);
    try std.testing.expectEqual(@as(usize, 0), cleared[0].environment_variables.len);
    const cleared_desktop_path = try manager.installedDesktopPath("editor-2");
    defer std.testing.allocator.free(cleared_desktop_path);
    const cleared_desktop = try readTestAppImageDb(allocator, cleared_desktop_path);
    const action_exec = try std.fmt.allocPrint(allocator, "Exec=\"{s}\" --new", .{cleared[0].path});
    try std.testing.expect(std.mem.indexOf(u8, cleared_desktop, action_exec) != null);
    try std.testing.expect(std.mem.indexOf(u8, cleared_desktop, "Exec=/usr/bin/true") != null);
    try std.testing.expect(std.mem.indexOf(u8, cleared_desktop, "WEBKIT_DISABLE_DMABUF_RENDERER=1") == null);
}

const symlinkLayoutTestAppImage =
    \\#!/bin/sh
    \\if [ "$1" = "--appimage-extract" ]; then
    \\  mkdir -p squashfs-root/usr/share/applications
    \\  mkdir -p squashfs-root/usr/share/icons/hicolor/256x256/apps
    \\  printf '%s\n' '[Desktop Entry]' 'Name=Symlink Editor' 'X-AppImage-Version=3.1.0' 'Exec=editor %u' 'Icon=editor' 'Categories=Game;Emulator;' > squashfs-root/usr/share/applications/editor.desktop
    \\  printf '%s\n' 'icon-data' > squashfs-root/usr/share/icons/hicolor/256x256/apps/editor.png
    \\  ln -s usr/share/applications/editor.desktop squashfs-root/editor.desktop
    \\  ln -s usr/share/icons/hicolor/256x256/apps/editor.png squashfs-root/editor.png
    \\  ln -s usr/share/icons/hicolor/256x256/apps/editor.png squashfs-root/.DirIcon
    \\  exit 0
    \\fi
    \\exit 0
;

const spacedIconTestAppImage =
    \\#!/bin/sh
    \\if [ "$1" = "--appimage-extract" ]; then
    \\  mkdir -p squashfs-root/usr/share/icons/hicolor/256x256/apps
    \\  printf '%s\n' '[Desktop Entry]' 'Name=Weather App' 'Exec=weather' 'Icon=Weather Icon' > squashfs-root/weather.desktop
    \\  printf '%s\n' 'icon-data' > 'squashfs-root/usr/share/icons/hicolor/256x256/apps/Weather Icon.png'
    \\  exit 0
    \\fi
    \\exit 0
;

fn successfulCacheCommand(
    allocator: std.mem.Allocator,
    _: std.Io,
    _: std.process.Environ,
    _: []const []const u8,
) !std.process.RunResult {
    const stdout = try allocator.dupe(u8, "");
    errdefer allocator.free(stdout);
    return .{
        .term = .{ .exited = 0 },
        .stdout = stdout,
        .stderr = try allocator.dupe(u8, ""),
    };
}

fn failingCacheCommand(
    allocator: std.mem.Allocator,
    _: std.Io,
    _: std.process.Environ,
    argv: []const []const u8,
) !std.process.RunResult {
    const stdout = try allocator.dupe(u8, "");
    errdefer allocator.free(stdout);
    const stderr_message = if (std.mem.eql(u8, argv[0], "gtk-update-icon-cache"))
        "Invalid icon filename\x1b: Weather Icon.png\n"
    else
        "Invalid desktop entry: broken.desktop\n";
    return .{
        .term = .{ .exited = 1 },
        .stdout = stdout,
        .stderr = try allocator.dupe(u8, stderr_message),
    };
}

fn missingCacheCommand(
    _: std.mem.Allocator,
    _: std.Io,
    _: std.process.Environ,
    _: []const []const u8,
) !std.process.RunResult {
    return error.FileNotFound;
}

const CacheWarningCapture = struct {
    warning_count: usize = 0,
    saw_icon_diagnostic: bool = false,
    saw_desktop_diagnostic: bool = false,
    saw_missing_utility: bool = false,
    saw_unsafe_control_character: bool = false,

    fn handle(data: ?*anyopaque, args: events.StatusArgs) void {
        if (args.kind != .warning) return;
        const self: *@This() = @ptrCast(@alignCast(data.?));
        self.warning_count += 1;
        self.saw_icon_diagnostic = self.saw_icon_diagnostic or
            (std.mem.indexOf(u8, args.message, "gtk-update-icon-cache") != null and
                std.mem.indexOf(u8, args.message, "Weather Icon.png") != null);
        self.saw_desktop_diagnostic = self.saw_desktop_diagnostic or
            (std.mem.indexOf(u8, args.message, "update-desktop-database") != null and
                std.mem.indexOf(u8, args.message, "broken.desktop") != null);
        self.saw_missing_utility = self.saw_missing_utility or
            std.mem.indexOf(u8, args.message, "is unavailable") != null;
        self.saw_unsafe_control_character = self.saw_unsafe_control_character or
            std.mem.indexOfScalar(u8, args.message, 0x1b) != null;
    }
};

test "installAppImage preserves an existing install when staged validation fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(root);
    const source_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "source" });
    defer std.testing.allocator.free(source_dir);
    const install_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "install" });
    defer std.testing.allocator.free(install_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, source_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, install_dir);

    const source_path = try std.fs.path.join(std.testing.allocator, &.{ source_dir, "Editor.AppImage" });
    defer std.testing.allocator.free(source_path);
    const installed_path = try std.fs.path.join(std.testing.allocator, &.{ install_dir, "Editor.AppImage" });
    defer std.testing.allocator.free(installed_path);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root, "config", "appimages.db" });
    defer std.testing.allocator.free(db_path);

    try writeTestAppImageDb(source_path, "#!/bin/sh\nexit 1\n");
    try writeTestAppImageDb(installed_path, "existing-binary\n");
    var environ = try createTestAppImageEnviron(std.testing.allocator, root);
    defer environ.block.deinit(std.testing.allocator);
    const manager = AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = environ,
        .install_directory = install_dir,
        .local_db_path = db_path,
    };
    try manager.addAppImageToLocalDb(.{
        .name = "Editor",
        .version = "1.0.0",
        .desktop_name = "Editor",
        .path = installed_path,
    });

    try std.testing.expect(!try manager.installAppImage(source_path));

    const installed = try readTestAppImageDb(std.testing.allocator, installed_path);
    defer std.testing.allocator.free(installed);
    try std.testing.expectEqualStrings("existing-binary\n", installed);
    const app_images = try manager.getAppImagesFromLocalDb();
    defer manager.freeAppImages(app_images);
    try std.testing.expectEqual(@as(usize, 1), app_images.len);
    try std.testing.expectEqualStrings("1.0.0", app_images[0].version);
    try std.testing.expectEqualStrings(installed_path, app_images[0].path);
    try expectOnlyInstalledAppImage(install_dir, "Editor.AppImage");
}

test "installAppImage atomically replaces a validated AppImage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(root);
    const source_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "source" });
    defer std.testing.allocator.free(source_dir);
    const install_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "install" });
    defer std.testing.allocator.free(install_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, source_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, install_dir);

    const source_path = try std.fs.path.join(std.testing.allocator, &.{ source_dir, "Editor.AppImage" });
    defer std.testing.allocator.free(source_path);
    const installed_path = try std.fs.path.join(std.testing.allocator, &.{ install_dir, "Editor.AppImage" });
    defer std.testing.allocator.free(installed_path);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root, "config", "appimages.db" });
    defer std.testing.allocator.free(db_path);
    try writeTestAppImageDb(source_path, validTestAppImage);
    try writeTestAppImageDb(installed_path, "existing-binary\n");
    var environ = try createTestAppImageEnviron(std.testing.allocator, root);
    defer environ.block.deinit(std.testing.allocator);
    const manager = AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = environ,
        .install_directory = install_dir,
        .local_db_path = db_path,
    };
    try manager.addAppImageToLocalDb(.{
        .name = "Editor",
        .version = "1.0.0",
        .desktop_name = "Editor",
        .path = installed_path,
    });

    try std.testing.expect(try manager.installAppImage(source_path));

    const installed = try readTestAppImageDb(std.testing.allocator, installed_path);
    defer std.testing.allocator.free(installed);
    try std.testing.expectEqualStrings(validTestAppImage, installed);
    const app_images = try manager.getAppImagesFromLocalDb();
    defer manager.freeAppImages(app_images);
    try std.testing.expectEqual(@as(usize, 1), app_images.len);
    try std.testing.expectEqualStrings("2.0.0", app_images[0].version);
    try std.testing.expectEqualStrings(installed_path, app_images[0].path);
    try expectOnlyInstalledAppImage(install_dir, "Editor.AppImage");

    const desktop_path = try std.fs.path.join(std.testing.allocator, &.{ root, "data", "applications", "editor.desktop" });
    defer std.testing.allocator.free(desktop_path);
    const desktop = try readTestAppImageDb(std.testing.allocator, desktop_path);
    defer std.testing.allocator.free(desktop);
    try std.testing.expect(std.mem.indexOf(u8, desktop, installed_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, desktop, ".shelly-install-") == null);
}

test "installAppImage follows a symlinked install directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(root);
    const source_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "source" });
    defer std.testing.allocator.free(source_dir);
    const install_target = try std.fs.path.join(std.testing.allocator, &.{ root, "install-target" });
    defer std.testing.allocator.free(install_target);
    const install_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "install-link" });
    defer std.testing.allocator.free(install_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, source_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, install_target);
    try std.Io.Dir.cwd().symLink(std.testing.io, install_target, install_dir, .{});

    const source_path = try std.fs.path.join(std.testing.allocator, &.{ source_dir, "Editor.AppImage" });
    defer std.testing.allocator.free(source_path);
    const installed_path = try std.fs.path.join(std.testing.allocator, &.{ install_dir, "Editor.AppImage" });
    defer std.testing.allocator.free(installed_path);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root, "config", "appimages.db" });
    defer std.testing.allocator.free(db_path);
    try writeTestAppImageDb(source_path, validTestAppImage);

    var environ = try createTestAppImageEnviron(std.testing.allocator, root);
    defer environ.block.deinit(std.testing.allocator);
    const manager = AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = environ,
        .install_directory = install_dir,
        .local_db_path = db_path,
    };

    try std.testing.expect(try manager.installAppImage(source_path));

    const installed = try readTestAppImageDb(std.testing.allocator, installed_path);
    defer std.testing.allocator.free(installed);
    try std.testing.expectEqualStrings(validTestAppImage, installed);
    try expectOnlyInstalledAppImage(install_target, "Editor.AppImage");
}

test "installAppImage creates a missing directory beneath a symlinked parent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(root);
    const source_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "source" });
    defer std.testing.allocator.free(source_dir);
    const parent_target = try std.fs.path.join(std.testing.allocator, &.{ root, "parent-target" });
    defer std.testing.allocator.free(parent_target);
    const parent_link = try std.fs.path.join(std.testing.allocator, &.{ root, "parent-link" });
    defer std.testing.allocator.free(parent_link);
    const install_dir = try std.fs.path.join(std.testing.allocator, &.{ parent_link, "install" });
    defer std.testing.allocator.free(install_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, source_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, parent_target);
    try std.Io.Dir.cwd().symLink(std.testing.io, parent_target, parent_link, .{});

    const source_path = try std.fs.path.join(std.testing.allocator, &.{ source_dir, "Editor.AppImage" });
    defer std.testing.allocator.free(source_path);
    const installed_path = try std.fs.path.join(std.testing.allocator, &.{ install_dir, "Editor.AppImage" });
    defer std.testing.allocator.free(installed_path);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root, "config", "appimages.db" });
    defer std.testing.allocator.free(db_path);
    try writeTestAppImageDb(source_path, validTestAppImage);

    var environ = try createTestAppImageEnviron(std.testing.allocator, root);
    defer environ.block.deinit(std.testing.allocator);
    const manager = AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = environ,
        .install_directory = install_dir,
        .local_db_path = db_path,
    };

    try std.testing.expect(try manager.installAppImage(source_path));

    const installed = try readTestAppImageDb(std.testing.allocator, installed_path);
    defer std.testing.allocator.free(installed);
    try std.testing.expectEqualStrings(validTestAppImage, installed);
    try expectOnlyInstalledAppImage(install_dir, "Editor.AppImage");
}

test "installAppImage reads desktop metadata and icons through standard AppImage symlinks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(root);
    const source_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "source" });
    defer std.testing.allocator.free(source_dir);
    const install_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "install" });
    defer std.testing.allocator.free(install_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, source_dir);

    const source_path = try std.fs.path.join(std.testing.allocator, &.{ source_dir, "Editor.AppImage" });
    defer std.testing.allocator.free(source_path);
    const installed_path = try std.fs.path.join(std.testing.allocator, &.{ install_dir, "Editor.AppImage" });
    defer std.testing.allocator.free(installed_path);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root, "config", "appimages.db" });
    defer std.testing.allocator.free(db_path);
    try writeTestAppImageDb(source_path, symlinkLayoutTestAppImage);

    var environ = try createTestAppImageEnviron(std.testing.allocator, root);
    defer environ.block.deinit(std.testing.allocator);
    const manager = AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = environ,
        .install_directory = install_dir,
        .local_db_path = db_path,
    };

    try std.testing.expect(try manager.installAppImage(source_path));

    const app_images = try manager.getAppImagesFromLocalDb();
    defer manager.freeAppImages(app_images);
    try std.testing.expectEqual(@as(usize, 1), app_images.len);
    try std.testing.expectEqualStrings("Symlink Editor", app_images[0].desktop_name);
    try std.testing.expectEqualStrings("editor", app_images[0].icon_name);
    try std.testing.expectEqualStrings("3.1.0", app_images[0].version);
    try std.testing.expectEqualStrings(installed_path, app_images[0].path);

    const desktop_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "data", "applications", "editor.desktop" },
    );
    defer std.testing.allocator.free(desktop_path);
    const desktop = try readTestAppImageDb(std.testing.allocator, desktop_path);
    defer std.testing.allocator.free(desktop);
    try std.testing.expect(std.mem.indexOf(u8, desktop, "Name=Symlink Editor\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, desktop, "Icon=editor\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, desktop, "Categories=Game;Emulator;\n") != null);
    const expected_exec = try std.fmt.allocPrint(
        std.testing.allocator,
        "Exec=\"{s}\" %u\n",
        .{installed_path},
    );
    defer std.testing.allocator.free(expected_exec);
    try std.testing.expect(std.mem.indexOf(u8, desktop, expected_exec) != null);

    const icon_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "data", "icons", "hicolor", "256x256", "apps", "editor.png" },
    );
    defer std.testing.allocator.free(icon_path);
    const icon = try readTestAppImageDb(std.testing.allocator, icon_path);
    defer std.testing.allocator.free(icon);
    try std.testing.expectEqualStrings("icon-data\n", icon);
}

test "installAppImage commits and reports diagnostics when cache refreshes fail" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(root);
    const source_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "source" });
    defer std.testing.allocator.free(source_dir);
    const install_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "install" });
    defer std.testing.allocator.free(install_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, source_dir);

    const source_path = try std.fs.path.join(std.testing.allocator, &.{ source_dir, "Editor.AppImage" });
    defer std.testing.allocator.free(source_path);
    const installed_path = try std.fs.path.join(std.testing.allocator, &.{ install_dir, "Editor.AppImage" });
    defer std.testing.allocator.free(installed_path);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root, "config", "appimages.db" });
    defer std.testing.allocator.free(db_path);
    try writeTestAppImageDb(source_path, symlinkLayoutTestAppImage);

    var environ = try createTestAppImageEnviron(std.testing.allocator, root);
    defer environ.block.deinit(std.testing.allocator);
    var dispatcher = events.Dispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();
    var capture: CacheWarningCapture = .{};
    _ = try dispatcher.addStatusHandler(.{ .function = CacheWarningCapture.handle, .data = &capture });

    const manager = AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = environ,
        .install_directory = install_dir,
        .local_db_path = db_path,
        .dispatcher = &dispatcher,
        .cache_command_run = failingCacheCommand,
    };

    try std.testing.expect(try manager.installAppImage(source_path));
    try std.Io.Dir.cwd().access(std.testing.io, installed_path, .{});

    const desktop_path = try std.fs.path.join(std.testing.allocator, &.{ root, "data", "applications", "editor.desktop" });
    defer std.testing.allocator.free(desktop_path);
    try std.Io.Dir.cwd().access(std.testing.io, desktop_path, .{});
    const icon_path = try std.fs.path.join(std.testing.allocator, &.{ root, "data", "icons", "hicolor", "256x256", "apps", "editor.png" });
    defer std.testing.allocator.free(icon_path);
    try std.Io.Dir.cwd().access(std.testing.io, icon_path, .{});

    const apps = try manager.getAppImagesFromLocalDb();
    defer manager.freeAppImages(apps);
    try std.testing.expectEqual(@as(usize, 1), apps.len);
    try std.testing.expectEqual(@as(usize, 2), capture.warning_count);
    try std.testing.expect(capture.saw_desktop_diagnostic);
    try std.testing.expect(capture.saw_icon_diagnostic);
    try std.testing.expect(!capture.saw_unsafe_control_character);
}

test "installAppImage sanitizes a bundled icon filename containing spaces" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(root);
    const source_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "source" });
    defer std.testing.allocator.free(source_dir);
    const install_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "install" });
    defer std.testing.allocator.free(install_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, source_dir);

    const source_path = try std.fs.path.join(std.testing.allocator, &.{ source_dir, "Weather App.AppImage" });
    defer std.testing.allocator.free(source_path);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root, "config", "appimages.db" });
    defer std.testing.allocator.free(db_path);
    try writeTestAppImageDb(source_path, spacedIconTestAppImage);

    var environ = try createTestAppImageEnviron(std.testing.allocator, root);
    defer environ.block.deinit(std.testing.allocator);
    const manager = AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = environ,
        .install_directory = install_dir,
        .local_db_path = db_path,
        .cache_command_run = successfulCacheCommand,
    };

    try std.testing.expect(try manager.installAppImage(source_path));
    const icon_path = try std.fs.path.join(std.testing.allocator, &.{ root, "data", "icons", "hicolor", "256x256", "apps", "weather-app.png" });
    defer std.testing.allocator.free(icon_path);
    try std.Io.Dir.cwd().access(std.testing.io, icon_path, .{});
}

test "cache refresh reports a missing optional utility without failing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(root);
    var environ = try createTestAppImageEnviron(std.testing.allocator, root);
    defer environ.block.deinit(std.testing.allocator);
    var dispatcher = events.Dispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();
    var capture: CacheWarningCapture = .{};
    _ = try dispatcher.addStatusHandler(.{ .function = CacheWarningCapture.handle, .data = &capture });
    const manager = AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = environ,
        .install_directory = root,
        .local_db_path = root,
        .dispatcher = &dispatcher,
        .cache_command_run = missingCacheCommand,
    };

    manager.refreshDesktopCachesBestEffort(false);
    try std.testing.expectEqual(@as(usize, 1), capture.warning_count);
    try std.testing.expect(capture.saw_missing_utility);
}

test "installAppImage restores the previous binary when database commit fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(root);
    const source_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "source" });
    defer std.testing.allocator.free(source_dir);
    const install_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "install" });
    defer std.testing.allocator.free(install_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, source_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, install_dir);

    const source_path = try std.fs.path.join(std.testing.allocator, &.{ source_dir, "Editor.AppImage" });
    defer std.testing.allocator.free(source_path);
    const installed_path = try std.fs.path.join(std.testing.allocator, &.{ install_dir, "Editor.AppImage" });
    defer std.testing.allocator.free(installed_path);
    const db_dir_path = try std.fs.path.join(std.testing.allocator, &.{ root, "config" });
    defer std.testing.allocator.free(db_dir_path);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ db_dir_path, "appimages.db" });
    defer std.testing.allocator.free(db_path);

    try writeTestAppImageDb(source_path, validTestAppImage);
    try writeTestAppImageDb(installed_path, "existing-binary\n");
    var environ = try createTestAppImageEnviron(std.testing.allocator, root);
    defer environ.block.deinit(std.testing.allocator);
    var manager = AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = environ,
        .install_directory = install_dir,
        .local_db_path = db_path,
    };
    try manager.addAppImageToLocalDb(.{
        .name = "Editor",
        .version = "1.0.0",
        .desktop_name = "Editor",
        .path = installed_path,
    });

    manager.database_commit = failDatabaseCommit;

    try std.testing.expect(!try manager.installAppImage(source_path));

    const installed = try readTestAppImageDb(std.testing.allocator, installed_path);
    defer std.testing.allocator.free(installed);
    try std.testing.expectEqualStrings("existing-binary\n", installed);
    const app_images = try manager.getAppImagesFromLocalDb();
    defer manager.freeAppImages(app_images);
    try std.testing.expectEqual(@as(usize, 1), app_images.len);
    try std.testing.expectEqualStrings("1.0.0", app_images[0].version);
    try expectOnlyInstalledAppImage(install_dir, "Editor.AppImage");
}

test "writeDesktopEntry repairs omitted authoritative keys and escapes executable paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(root);
    const source = try std.fs.path.join(std.testing.allocator, &.{ root, "source.desktop" });
    defer std.testing.allocator.free(source);
    try writeTestAppImageDb(source, "[Desktop Entry]\nType=Application\nCategories=Utility;\n");
    var environ = try createTestAppImageEnviron(std.testing.allocator, root);
    defer environ.block.deinit(std.testing.allocator);
    const manager = AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = environ,
        .install_directory = root,
        .local_db_path = source,
    };
    const executable = try std.fs.path.join(std.testing.allocator, &.{ root, "a \\\"quoted\\\"\\path.AppImage" });
    defer std.testing.allocator.free(executable);
    try manager.writeDesktopEntry("editor", executable, source, .{
        .name = "Editor",
        .desktop_name = "Editor Display",
        .description = "An editor",
        .icon_name = "editor",
    });
    const desktop_path = try manager.installedDesktopPath("editor");
    defer std.testing.allocator.free(desktop_path);
    const desktop = try readTestAppImageDb(std.testing.allocator, desktop_path);
    defer std.testing.allocator.free(desktop);
    try std.testing.expect(std.mem.indexOf(u8, desktop, "Name=Editor Display\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, desktop, "Comment=An editor\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, desktop, "Icon=editor\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, desktop, "Exec=\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, desktop, "TryExec=\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, desktop, "TryExec=") != null);
    try std.testing.expect(std.mem.indexOf(u8, desktop, "\\\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, desktop, "\\\\path.AppImage") != null);
}

test "writeDesktopEntry emits unquoted TryExec for existing and omitted source keys" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(root);
    var environ = try createTestAppImageEnviron(std.testing.allocator, root);
    defer environ.block.deinit(std.testing.allocator);

    const executable = try std.fs.path.join(std.testing.allocator, &.{ root, "App Images", "Editor.AppImage" });
    defer std.testing.allocator.free(executable);
    const expected_try_exec = try std.fmt.allocPrint(std.testing.allocator, "TryExec={s}\n", .{executable});
    defer std.testing.allocator.free(expected_try_exec);
    const quoted_try_exec = try std.fmt.allocPrint(std.testing.allocator, "TryExec=\"{s}\"\n", .{executable});
    defer std.testing.allocator.free(quoted_try_exec);

    const cases = [_]struct {
        clean_name: []const u8,
        source_name: []const u8,
        contents: []const u8,
    }{
        .{
            .clean_name = "editor-existing-tryexec",
            .source_name = "existing.desktop",
            .contents = "[Desktop Entry]\nType=Application\nExec=editor %U\nTryExec=editor\n",
        },
        .{
            .clean_name = "editor-omitted-tryexec",
            .source_name = "omitted.desktop",
            .contents = "[Desktop Entry]\nType=Application\nExec=editor %U\n",
        },
    };

    for (cases) |case| {
        const source = try std.fs.path.join(std.testing.allocator, &.{ root, case.source_name });
        defer std.testing.allocator.free(source);
        try writeTestAppImageDb(source, case.contents);
        const manager = AppImageManager{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
            .environ = environ,
            .install_directory = root,
            .local_db_path = source,
        };
        try manager.writeDesktopEntry(case.clean_name, executable, source, .{
            .name = "Editor",
            .desktop_name = "Editor",
            .icon_name = "editor",
        });
        const desktop_path = try manager.installedDesktopPath(case.clean_name);
        defer std.testing.allocator.free(desktop_path);
        const desktop = try readTestAppImageDb(std.testing.allocator, desktop_path);
        defer std.testing.allocator.free(desktop);
        try std.testing.expect(std.mem.indexOf(u8, desktop, expected_try_exec) != null);
        try std.testing.expect(std.mem.indexOf(u8, desktop, quoted_try_exec) == null);
    }
}

test "AppImage classification is case insensitive and extension based" {
    try std.testing.expect(AppImageManager.isAppImage("Example.AppImage"));
    try std.testing.expect(AppImageManager.is_app_image("/tmp/Example.appimage"));
    try std.testing.expect(!AppImageManager.isAppImage("Example.AppImage.zsync"));
    try std.testing.expect(!AppImageManager.isAppImage("AppImage"));
}

test "AppImage metadata discovery rejects symlinks outside the extraction root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(root);
    const extraction_root = try std.fs.path.join(std.testing.allocator, &.{ root, "squashfs-root" });
    defer std.testing.allocator.free(extraction_root);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, extraction_root);

    const outside_desktop = try std.fs.path.join(std.testing.allocator, &.{ root, "outside.desktop" });
    defer std.testing.allocator.free(outside_desktop);
    const outside_icon = try std.fs.path.join(std.testing.allocator, &.{ root, "outside.png" });
    defer std.testing.allocator.free(outside_icon);
    try writeTestAppImageDb(outside_desktop, "[Desktop Entry]\nName=Outside\n");
    try writeTestAppImageDb(outside_icon, "outside-icon\n");

    const desktop_link = try std.fs.path.join(std.testing.allocator, &.{ extraction_root, "outside.desktop" });
    defer std.testing.allocator.free(desktop_link);
    const icon_link = try std.fs.path.join(std.testing.allocator, &.{ extraction_root, ".DirIcon" });
    defer std.testing.allocator.free(icon_link);
    try std.Io.Dir.cwd().symLink(std.testing.io, outside_desktop, desktop_link, .{});
    try std.Io.Dir.cwd().symLink(std.testing.io, outside_icon, icon_link, .{});

    var environ = try createTestAppImageEnviron(std.testing.allocator, root);
    defer environ.block.deinit(std.testing.allocator);
    const manager = AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = environ,
        .install_directory = root,
        .local_db_path = root,
    };

    try std.testing.expect((try manager.findDesktopFile(extraction_root)) == null);
    try std.testing.expect((try manager.findIconSource(extraction_root, "")) == null);
}

test "cleanInvalidNames lowercases and replaces separators" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(db_path);

    const full_db_path = try std.fs.path.join(std.testing.allocator, &.{ db_path, "nonexistent.db" });
    defer std.testing.allocator.free(full_db_path);

    const manager = AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = std.testing.environ,
        .install_directory = db_path,
        .local_db_path = full_db_path,
    };
    const allocator = std.testing.allocator;

    const result1 = try manager.cleanInvalidNames("My Cool App");
    defer allocator.free(result1);
    try std.testing.expectEqualStrings("my-cool-app", result1);

    const result2 = try manager.cleanInvalidNames("Some/Weird\\Name");
    defer allocator.free(result2);
    try std.testing.expectEqualStrings("some-weird-name", result2);

    const result3 = try manager.cleanInvalidNames("AlreadyClean");
    defer allocator.free(result3);
    try std.testing.expectEqualStrings("alreadyclean", result3);
}

test "cleanInvalidNames handles empty string" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(db_path);

    const full_db_path = try std.fs.path.join(std.testing.allocator, &.{ db_path, "nonexistent.db" });
    defer std.testing.allocator.free(full_db_path);

    const manager = AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = std.testing.environ,
        .install_directory = db_path,
        .local_db_path = full_db_path,
    };

    const allocator = std.testing.allocator;
    const result = try manager.cleanInvalidNames("");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "getAppImagesFromLocalDb returns empty when db file does not exist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(db_path);

    const full_db_path = try std.fs.path.join(std.testing.allocator, &.{ db_path, "nonexistent.db" });
    defer std.testing.allocator.free(full_db_path);

    const manager = AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = std.testing.environ,
        .install_directory = db_path,
        .local_db_path = full_db_path,
    };

    const result = try manager.getAppImagesFromLocalDb();
    defer manager.freeAppImages(result);
    try std.testing.expectEqual(0, result.len);
}

test "getAppImagesFromLocalDb leaves native database unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(dir_path);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "appimages.db" });
    defer std.testing.allocator.free(db_path);

    const source = "[{\"name\":\"NativeApp\",\"version\":\"4.0.0\",\"update_type\":\"forgejo\"}]";
    try writeTestAppImageDb(db_path, source);

    const manager = AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = std.testing.environ,
        .install_directory = dir_path,
        .local_db_path = db_path,
    };
    const result = try manager.getAppImagesFromLocalDb();
    defer manager.freeAppImages(result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(appimage.UpdateType.forgejo, result[0].update_type);

    const contents = try readTestAppImageDb(std.testing.allocator, db_path);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings(source, contents);
}

test "getAppImagesFromLocalDb leaves a malformed database unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(dir_path);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "appimages.db" });
    defer std.testing.allocator.free(db_path);

    const source = "[{\"Name\":\"BrokenApp\",\"UpdateType\":\"GitHub\"}]";
    try writeTestAppImageDb(db_path, source);

    const manager = AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = std.testing.environ,
        .install_directory = dir_path,
        .local_db_path = db_path,
    };
    const result = try manager.getAppImagesFromLocalDb();
    defer manager.freeAppImages(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);

    const contents = try readTestAppImageDb(std.testing.allocator, db_path);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings(source, contents);
}

test "addAppImageToLocalDb then getAppImagesFromLocalDb round-trips a single entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(dir_path);

    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "appimages.db" });
    defer std.testing.allocator.free(db_path);

    const manager = AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = std.testing.environ,
        .install_directory = dir_path,
        .local_db_path = db_path,
    };

    const appimage_struct = appimage.AppImage{
        .name = "TestApp",
        .version = "1.2.3",
        .release_tag = "v1.2.3",
        .desktop_name = "TestApp",
        .path = "/fake/path/TestApp.AppImage",
    };

    try manager.addAppImageToLocalDb(appimage_struct);

    const result = try manager.getAppImagesFromLocalDb();
    defer manager.freeAppImages(result);

    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("TestApp", result[0].name);
    try std.testing.expectEqualStrings("1.2.3", result[0].version);
    try std.testing.expectEqualStrings("v1.2.3", result[0].release_tag.?);
}

test "getAppImagesFromLocalDb ignores unknown fields from a newer database" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(dir_path);

    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "appimage-metadata-v2.db" });
    defer std.testing.allocator.free(db_path);

    const future_db =
        \\[{"name":"TestApp","version":"1.2.3","release_tag":"v1.2.3","future_field":42}]
    ;
    {
        var file = try std.Io.Dir.cwd().createFile(std.testing.io, db_path, .{});
        defer file.close(std.testing.io);
        var write_buf: [4096]u8 = undefined;
        var writer = file.writer(std.testing.io, &write_buf);
        try writer.interface.writeAll(future_db);
        try writer.interface.flush();
    }

    const manager = AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = std.testing.environ,
        .install_directory = dir_path,
        .local_db_path = db_path,
    };

    const result = try manager.getAppImagesFromLocalDb();
    defer manager.freeAppImages(result);

    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("TestApp", result[0].name);
    try std.testing.expectEqualStrings("1.2.3", result[0].version);
    try std.testing.expectEqualStrings("v1.2.3", result[0].release_tag.?);
}

test "addAppImageToLocalDb overwrites entry with matching desktop_name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(dir_path);

    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "appimages.db" });
    defer std.testing.allocator.free(db_path);

    const manager = AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = std.testing.environ,
        .install_directory = dir_path,
        .local_db_path = db_path,
    };

    try manager.addAppImageToLocalDb(.{
        .name = "TestApp",
        .version = "1.0.0",
        .desktop_name = "TestApp",
        .path = "/fake/TestApp.AppImage",
    });

    try manager.addAppImageToLocalDb(.{
        .name = "TestApp",
        .version = "2.0.0",
        .desktop_name = "TestApp",
        .path = "/fake/TestApp.AppImage",
    });

    const result = try manager.getAppImagesFromLocalDb();
    defer manager.freeAppImages(result);

    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("2.0.0", result[0].version);
}

test "addAppImageToLocalDb keeps distinct desktop_name entries separate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(dir_path);

    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "appimages.db" });
    defer std.testing.allocator.free(db_path);

    const manager = AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = std.testing.environ,
        .install_directory = dir_path,
        .local_db_path = db_path,
    };

    try manager.addAppImageToLocalDb(.{ .name = "AppOne", .desktop_name = "AppOne", .path = "/fake/one" });
    try manager.addAppImageToLocalDb(.{ .name = "AppTwo", .desktop_name = "AppTwo", .path = "/fake/two" });

    const result = try manager.getAppImagesFromLocalDb();
    defer manager.freeAppImages(result);

    try std.testing.expectEqual(2, result.len);
}

test "removeAppImageFromLocalDb removes an orphaned entry by name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(dir_path);

    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "appimages.db" });
    defer std.testing.allocator.free(db_path);

    const manager = AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = std.testing.environ,
        .install_directory = dir_path,
        .local_db_path = db_path,
    };

    try manager.addAppImageToLocalDb(.{
        .name = "RemoveMe",
        .desktop_name = "Remove Me",
        .path = "/missing/RemoveMe.AppImage",
    });
    try manager.addAppImageToLocalDb(.{
        .name = "KeepMe",
        .desktop_name = "Keep Me",
        .path = "/missing/KeepMe.AppImage",
    });

    try manager.removeAppImageFromLocalDb("removeme");
    try manager.removeAppImageFromLocalDb("not-in-db");

    const result = try manager.getAppImagesFromLocalDb();
    defer manager.freeAppImages(result);

    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("KeepMe", result[0].name);
}

test "removeAppImage removes matching entry from db by name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(dir_path);

    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "appimages.db" });
    defer std.testing.allocator.free(db_path);

    const manager = AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = std.testing.environ,
        .install_directory = dir_path,
        .local_db_path = db_path,
    };

    // Create a fake installed AppImage file so removeAppImage's deleteFile succeeds.
    const fake_appimage_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "RemoveMe.AppImage" });
    defer std.testing.allocator.free(fake_appimage_path);
    {
        var f = try std.Io.Dir.cwd().createFile(std.testing.io, fake_appimage_path, .{});
        f.close(std.testing.io);
    }

    try manager.addAppImageToLocalDb(.{ .name = "RemoveMe", .desktop_name = "RemoveMe", .path = fake_appimage_path });
    try manager.addAppImageToLocalDb(.{ .name = "KeepMe", .desktop_name = "KeepMe", .path = "/fake/keep" });

    const removed = try manager.removeAppImage(fake_appimage_path, false);
    try std.testing.expect(removed);

    const result = try manager.getAppImagesFromLocalDb();
    defer manager.freeAppImages(result);

    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("KeepMe", result[0].name);
}

test "syncAppImageMeta removes a stale entry when the AppImage file is missing" {
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

    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "appimages.db" });
    defer std.testing.allocator.free(db_path);

    const manager = AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = test_environ,
        .install_directory = install_dir,
        .local_db_path = db_path,
    };

    // Seed the database with an entry whose AppImage file no longer exists at
    // either the install location or the recorded path.
    try manager.addAppImageToLocalDb(.{
        .name = "GhostApp",
        .desktop_name = "Ghost App",
        .path = "/nonexistent/GhostApp.AppImage",
    });

    // Syncing a stale entry must succeed and drop the orphaned record instead
    // of failing the whole operation.
    const ok = try manager.syncAppImageMeta(&.{"GhostApp"});
    try std.testing.expect(ok);

    const result = try manager.getAppImagesFromLocalDb();
    defer manager.freeAppImages(result);
    try std.testing.expectEqual(0, result.len);
}

test "copyFile duplicates file contents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(dir_path);

    const src_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "source.txt" });
    defer std.testing.allocator.free(src_path);
    const dst_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "dest.txt" });
    defer std.testing.allocator.free(dst_path);

    {
        var f = try std.Io.Dir.cwd().createFile(std.testing.io, src_path, .{});
        defer f.close(std.testing.io);
        var buf: [64]u8 = undefined;
        var writer = f.writer(std.testing.io, &buf);
        try writer.interface.writeAll("hello from the test file");
        try writer.interface.flush();
    }

    const manager = AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = std.testing.environ,
        .install_directory = dir_path,
        .local_db_path = "unused",
    };

    try manager.copyFile(src_path, dst_path);

    var f = try std.Io.Dir.cwd().openFile(std.testing.io, dst_path, .{});
    defer f.close(std.testing.io);
    var read_buf: [64]u8 = undefined;
    var reader = f.reader(std.testing.io, &read_buf);
    const contents = try reader.interface.allocRemaining(std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(contents);

    try std.testing.expectEqualStrings("hello from the test file", contents);
}
