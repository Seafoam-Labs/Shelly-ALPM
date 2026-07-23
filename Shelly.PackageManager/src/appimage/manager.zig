const std = @import("std");
const appimage = @import("bindings.zig").appimage;
const events = @import("events.zig");
const xdg_paths = @import("../shared/xdg_paths.zig").xdg_paths;
const operation_api = @import("operation_context");

const LegacyAppImage = struct {
    Name: []const u8 = "",
    DesktopName: []const u8 = "",
    Version: []const u8 = "",
    IconName: []const u8 = "",
    Description: []const u8 = "",
    SizeOnDisk: i64 = 0,
    UpdateURl: []const u8 = "",
    RawUpdateInfo: []const u8 = "",
    RepoOwner: ?[]const u8 = null,
    RepoName: ?[]const u8 = null,
    UpdateType: i64 = 0,
    AllowPrerelease: bool = false,
    CommandLineArgs: ?[]const u8 = null,
    Path: ?[]const u8 = null,
};

pub const AppImageManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    install_directory: []const u8,
    local_db_path: []const u8,
    dispatcher: ?*events.Dispatcher = null,
    operation_context: ?*operation_api.OperationContext = null,
    owned_dispatcher: ?*events.Dispatcher = null,

    pub fn setEventDispatcher(self: *AppImageManager, dispatcher: ?*events.Dispatcher) void {
        self.dispatcher = dispatcher orelse self.owned_dispatcher;
    }

    /// Borrows a shared context and creates an internal legacy adapter when
    /// needed. The context must outlive this manager and all active calls.
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

    /// Classifies paths by the AppImage extension, matching the established
    /// C# behavior without opening or executing the file.
    pub fn isAppImage(file_path: []const u8) bool {
        return std.ascii.eqlIgnoreCase(std.fs.path.extension(file_path), ".AppImage");
    }

    pub fn is_app_image(file_path: []const u8) bool {
        return isAppImage(file_path);
    }

    pub fn installAppImage(self: AppImageManager, location: []const u8) !bool {
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

        try std.Io.Dir.cwd().createDirPath(self.io, self.install_directory);
        try self.copyFile(location, staging_path);
        try self.setExecutable(staging_path);

        const metadata = (try self.extractMetadataForInstall(staging_path, app_name, dest_path)) orelse {
            std.log.warn("Failed to extract metadata during installation.", .{});
            self.emitStatus(.err, "Failed to extract metadata during installation.");
            operation_scope.finish(.failed);
            return false;
        };
        defer self.freeAppImage(metadata);

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
                replaced = existing;
                break;
            }
        }

        const had_existing = (std.Io.Dir.cwd().statFile(self.io, dest_path, .{}) catch null) != null;
        if (had_existing) {
            std.Io.Dir.hardLink(.cwd(), dest_path, .cwd(), backup_path, self.io, .{}) catch
                try self.copyFile(dest_path, backup_path);
        }
        std.Io.Dir.rename(.cwd(), staging_path, .cwd(), dest_path, self.io) catch |err| {
            return err;
        };

        self.addAppImageToLocalDb(metadata) catch |err| {
            if (had_existing) {
                std.Io.Dir.rename(.cwd(), backup_path, .cwd(), dest_path, self.io) catch |rollback_err| {
                    self.emitStatusFmt(.err, "Could not restore the previous AppImage: {s}.", .{@errorName(rollback_err)});
                    return rollback_err;
                };
            } else std.Io.Dir.cwd().deleteFile(self.io, dest_path) catch {};
            self.emitStatusFmt(.err, "Could not install {s}: {s}.", .{ app_name, @errorName(err) });
            operation_scope.finish(.failed);
            return false;
        };

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

        self.emitStatusFmt(.success, "Installed AppImage {s}.", .{app_name});
        operation_scope.finish(.success);
        return true;
    }

    pub fn copyFile(self: AppImageManager, src_path: []const u8, dest_path: []const u8) !void {
        var operation_scope = events.OperationScope.init(self.operation_context, self.dispatcher, .install, src_path);
        operation_scope.attach();
        errdefer operation_scope.fail();
        try self.checkCancelled();
        var src = try std.Io.Dir.cwd().openFile(self.io, src_path, .{});
        defer src.close(self.io);
        var dst = try std.Io.Dir.cwd().createFile(self.io, dest_path, .{});
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
        return self.extractMetadataWithIdentity(path, null, null);
    }

    fn extractMetadataForInstall(
        self: AppImageManager,
        path: []const u8,
        app_name: []const u8,
        exec_path: []const u8,
    ) !?appimage.AppImage {
        return self.extractMetadataWithIdentity(path, app_name, exec_path);
    }

    fn extractMetadataWithIdentity(
        self: AppImageManager,
        path: []const u8,
        app_name_override: ?[]const u8,
        exec_path_override: ?[]const u8,
    ) !?appimage.AppImage {
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

        cleanup: {
            const dh = xdg_paths.xdgDataHome(self.allocator, self.environ) catch break :cleanup;
            defer self.allocator.free(dh);
            const dd = std.fs.path.join(self.allocator, &.{ dh, "applications" }) catch break :cleanup;
            defer self.allocator.free(dd);
            var dir = std.Io.Dir.cwd().openDir(self.io, dd, .{ .iterate = true }) catch break :cleanup;
            defer dir.close(self.io);
            var dir_it = dir.iterate();
            while (dir_it.next(self.io) catch null) |entry| {
                if (entry.kind != .file) continue;
                const bad_suffix = ".AppImage.desktop";
                if (entry.name.len < bad_suffix.len) continue;
                if (!std.ascii.eqlIgnoreCase(entry.name[entry.name.len - bad_suffix.len ..], bad_suffix)) continue;
                const bad_path = std.fs.path.join(self.allocator, &.{ dd, entry.name }) catch continue;
                defer self.allocator.free(bad_path);
                std.Io.Dir.cwd().deleteFile(self.io, bad_path) catch {};
            }
        }

        var random_suffix: [8]u8 = undefined;
        self.io.random(&random_suffix);
        const suffix_hex = std.fmt.bytesToHex(random_suffix, .lower);

        const working_dir = try std.fmt.allocPrint(
            self.allocator,
            "/tmp/shelly-appimage-sync-{s}-{s}",
            .{ app_name, suffix_hex[0..8] },
        );
        defer self.allocator.free(working_dir);
        defer std.Io.Dir.cwd().deleteTree(self.io, working_dir) catch {};

        try std.Io.Dir.cwd().createDirPath(self.io, working_dir);

        var extract_proc = try std.process.spawn(self.io, .{
            .argv = &.{ path, "--appimage-extract" },
            .cwd = .{ .path = working_dir },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });

        const term = try extract_proc.wait(self.io);
        if (term != .exited or term.exited != 0) {
            std.log.warn("Could not extract AppImage {s}", .{path});
            operation_scope.finish(.failed);
            return null;
        }

        const squashfs_root = try std.fs.path.join(self.allocator, &.{ working_dir, "squashfs-root" });
        defer self.allocator.free(squashfs_root);

        const desktop_file_path = try self.findDesktopFile(squashfs_root);
        defer if (desktop_file_path) |p| self.allocator.free(p);

        var version: []const u8 = "Unknown";
        var version_owned = false;
        var desktop_name: []const u8 = "";
        var desktop_name_owned = false;
        var description: []const u8 = "";
        var description_owned = false;
        var icon_line_value: ?[]const u8 = null;

        if (desktop_file_path) |dfp| {
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

        const icon_name: []const u8 = if (icon_line_value) |icon_val| blk: {
            defer self.allocator.free(icon_val);
            break :blk try self.installIcon(squashfs_root, clean_name, icon_val);
        } else try self.allocator.dupe(u8, "");

        try self.writeDesktopEntry(clean_name, exec_path, desktop_file_path, squashfs_root, icon_name, desktop_name, description);

        const update_info = try self.getAppImageUpdateInfo(path);

        const owned_version = if (version_owned) version else try self.allocator.dupe(u8, "Unknown");
        const owned_description = if (description_owned) description else try self.allocator.dupe(u8, "");
        const owned_desktop_name = if (desktop_name.len > 0)
            desktop_name
        else blk: {
            if (desktop_name_owned) self.allocator.free(desktop_name);
            break :blk try self.allocator.dupe(u8, app_name);
        };

        const metadata = appimage.AppImage{
            .name = try self.allocator.dupe(u8, app_name),
            .version = owned_version,
            .raw_update_info = update_info,
            .icon_name = icon_name,
            .description = owned_description,
            .desktop_name = owned_desktop_name,
            .size_on_disk = (try std.Io.Dir.cwd().statFile(self.io, path, .{})).size,
            .path = try self.allocator.dupe(u8, exec_path),
        };
        operation_scope.finish(.success);
        return metadata;
    }

    fn findDesktopFile(self: AppImageManager, dir: []const u8) !?[]const u8 {
        var d = std.Io.Dir.cwd().openDir(self.io, dir, .{ .iterate = true }) catch return null;
        defer d.close(self.io);

        var it = d.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.endsWith(u8, entry.name, ".desktop")) {
                return try std.fs.path.join(self.allocator, &.{ dir, entry.name });
            }
        }
        return null;
    }

    fn readFileAllocOwned(self: AppImageManager, path: []const u8) ![]u8 {
        var file = try std.Io.Dir.cwd().openFile(self.io, path, .{});
        defer file.close(self.io);
        var buf: [4096]u8 = undefined;
        var reader = file.reader(self.io, &buf);
        return reader.interface.allocRemaining(self.allocator, .unlimited);
    }

    fn installIcon(self: AppImageManager, squashfs_root: []const u8, clean_name: []const u8, icon_value: []const u8) ![]const u8 {
        var d = std.Io.Dir.cwd().openDir(self.io, squashfs_root, .{ .iterate = true }) catch return try self.allocator.dupe(u8, "");
        defer d.close(self.io);

        var found_path: ?[]const u8 = null;
        var found_ext: []const u8 = ".png";

        var it = d.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            const stem = std.fs.path.stem(entry.name);
            if (std.mem.eql(u8, stem, icon_value)) {
                found_path = try std.fs.path.join(self.allocator, &.{ squashfs_root, entry.name });
                found_ext = std.fs.path.extension(entry.name);
                break;
            }
        }
        defer if (found_path) |p| self.allocator.free(p);

        const src_icon_path = found_path orelse blk: {
            const diricon = try std.fs.path.join(self.allocator, &.{ squashfs_root, ".DirIcon" });
            if (std.Io.Dir.cwd().statFile(self.io, diricon, .{})) |_| {
                found_ext = ".png";
                break :blk diricon;
            } else |_| {
                self.allocator.free(diricon);
                return try self.allocator.dupe(u8, "");
            }
        };

        const icon_sub_dir = if (std.mem.eql(u8, found_ext, ".svg"))
            "icons/hicolor/scalable/apps"
        else
            "icons/hicolor/256x256/apps";

        const data_home = try xdg_paths.xdgDataHome(self.allocator, self.environ);
        defer self.allocator.free(data_home);
        const icon_dir = try std.fs.path.join(self.allocator, &.{ data_home, icon_sub_dir });
        defer self.allocator.free(icon_dir);
        try std.Io.Dir.cwd().createDirPath(self.io, icon_dir);

        const lower_clean = try std.ascii.allocLowerString(self.allocator, clean_name);
        defer self.allocator.free(lower_clean);

        const dest_icon_name = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ lower_clean, found_ext });
        defer self.allocator.free(dest_icon_name);
        const dest_icon_path = try std.fs.path.join(self.allocator, &.{ icon_dir, dest_icon_name });
        defer self.allocator.free(dest_icon_path);

        self.copyFile(src_icon_path, dest_icon_path) catch |err| {
            std.log.warn("Could not copy icon: {s}", .{@errorName(err)});
            return try self.allocator.dupe(u8, "");
        };

        self.updateIconCache(data_home);

        return try self.allocator.dupe(u8, lower_clean);
    }

    fn updateIconCache(self: AppImageManager, data_home: []const u8) void {
        const theme_dir = std.fs.path.join(self.allocator, &.{ data_home, "icons/hicolor" }) catch return;
        defer self.allocator.free(theme_dir);

        var proc = std.process.spawn(self.io, .{
            .argv = &.{ "gtk-update-icon-cache", "-f", "-t", theme_dir },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return;
        _ = proc.wait(self.io) catch {};
    }

    fn writeDesktopEntry(
        self: AppImageManager,
        clean_name: []const u8,
        exec_path: []const u8,
        source_desktop_file: ?[]const u8,
        squashfs_root: []const u8,
        icon_name: []const u8,
        desktop_name: []const u8,
        description: []const u8,
    ) !void {
        _ = squashfs_root;
        const data_home = try xdg_paths.xdgDataHome(self.allocator, self.environ);
        defer self.allocator.free(data_home);
        const desktop_dir = try std.fs.path.join(self.allocator, &.{ data_home, "applications" });
        defer self.allocator.free(desktop_dir);
        try std.Io.Dir.cwd().createDirPath(self.io, desktop_dir);

        const desktop_file_name = try std.fmt.allocPrint(self.allocator, "{s}.desktop", .{clean_name});
        defer self.allocator.free(desktop_file_name);
        const desktop_file_path = try std.fs.path.join(self.allocator, &.{ desktop_dir, desktop_file_name });
        defer self.allocator.free(desktop_file_path);

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();

        if (source_desktop_file) |src| {
            const contents = try self.readFileAllocOwned(src);
            defer self.allocator.free(contents);
            var lines = std.mem.splitScalar(u8, contents, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "Exec=")) {
                    const exec_value = line["Exec=".len..];
                    const trimmed = std.mem.trim(u8, exec_value, " \t");
                    var tokens = std.mem.splitScalar(u8, trimmed, ' ');
                    _ = tokens.next(); // skip original executable token
                    var field_code: ?[]const u8 = null;
                    while (tokens.next()) |token| {
                        if (std.mem.startsWith(u8, token, "%")) {
                            field_code = token;
                            break;
                        }
                    }
                    if (field_code) |fc| {
                        try out.writer.print("Exec=\"{s}\" {s}\n", .{ exec_path, fc });
                    } else {
                        try out.writer.print("Exec=\"{s}\"\n", .{exec_path});
                    }
                } else if (std.mem.startsWith(u8, line, "TryExec=")) {
                    continue;
                } else if (std.mem.startsWith(u8, line, "Icon=")) {
                    try out.writer.print("Icon={s}\n", .{icon_name});
                } else {
                    try out.writer.print("{s}\n", .{line});
                }
            }
        } else {
            try out.writer.print(
                "[Desktop Entry]\nVersion=1.0\nType=Application\nName={s}\nComment={s}\nExec=\"{s}\"\nIcon={s}\nTerminal=false\nCategories=Utility;\nStartupNotify=true\n",
                .{ desktop_name, if (description.len > 0) description else "application", exec_path, icon_name },
            );
        }

        var file = try std.Io.Dir.cwd().createFile(self.io, desktop_file_path, .{});
        defer file.close(self.io);
        var write_buf: [4096]u8 = undefined;
        var writer = file.writer(self.io, &write_buf);
        try writer.interface.writeAll(out.written());
        try writer.interface.flush();

        self.updateDesktopDatabase(desktop_dir);
    }

    fn updateDesktopDatabase(self: AppImageManager, desktop_dir: []const u8) void {
        var proc = std.process.spawn(self.io, .{
            .argv = &.{ "update-desktop-database", desktop_dir },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return;
        _ = proc.wait(self.io) catch {};
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

        if (std.json.parseFromSlice([]appimage.AppImage, self.allocator, contents, .{})) |parsed| {
            defer parsed.deinit();
            return try self.cloneAppImages(parsed.value);
        } else |_| {}

        const parsed = std.json.parseFromSlice([]LegacyAppImage, self.allocator, contents, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            std.log.warn("Error reading AppImage local DB: {s}", .{@errorName(err)});
            return &.{};
        };
        defer parsed.deinit();

        const result = self.convertLegacyAppImages(parsed.value) catch |err| switch (err) {
            error.InvalidLegacySizeOnDisk, error.UnsupportedLegacyUpdateType => {
                std.log.warn("Error reading AppImage local DB: {s}", .{@errorName(err)});
                return &.{};
            },
            else => return err,
        };
        errdefer self.freeAppImages(result);
        try self.persistAppImages(result);
        return result;
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
        const raw_update_info = try self.allocator.dupe(u8, source.raw_update_info);
        errdefer self.allocator.free(raw_update_info);
        const icon_name = try self.allocator.dupe(u8, source.icon_name);
        errdefer self.allocator.free(icon_name);
        const description = try self.allocator.dupe(u8, source.description);
        errdefer self.allocator.free(description);
        const desktop_name = try self.allocator.dupe(u8, source.desktop_name);
        errdefer self.allocator.free(desktop_name);
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
            .raw_update_info = raw_update_info,
            .icon_name = icon_name,
            .description = description,
            .desktop_name = desktop_name,
            .size_on_disk = source.size_on_disk,
            .command_line_args = command_line_args,
            .path = path,
            .update_url = update_url,
            .update_type = source.update_type,
            .repo_owner = repo_owner,
            .repo_name = repo_name,
            .allow_prerelease = source.allow_prerelease,
        };
    }

    fn convertLegacyAppImages(self: AppImageManager, source: []const LegacyAppImage) ![]appimage.AppImage {
        const result = try self.allocator.alloc(appimage.AppImage, source.len);
        errdefer self.allocator.free(result);

        var initialized: usize = 0;
        errdefer for (result[0..initialized]) |item| self.freeAppImage(item);

        for (source) |item| {
            const size_on_disk = std.math.cast(u64, item.SizeOnDisk) orelse return error.InvalidLegacySizeOnDisk;
            const update_type = try legacyUpdateType(item.UpdateType);
            result[initialized] = try self.cloneAppImage(.{
                .name = item.Name,
                .version = item.Version,
                .raw_update_info = item.RawUpdateInfo,
                .icon_name = item.IconName,
                .description = item.Description,
                .desktop_name = item.DesktopName,
                .size_on_disk = size_on_disk,
                .command_line_args = item.CommandLineArgs orelse "",
                .path = item.Path orelse "",
                .update_url = item.UpdateURl,
                .update_type = update_type,
                .repo_owner = item.RepoOwner,
                .repo_name = item.RepoName,
                .allow_prerelease = item.AllowPrerelease,
            });
            initialized += 1;
        }
        return result;
    }

    fn legacyUpdateType(value: i64) !appimage.UpdateType {
        return switch (value) {
            0 => .none,
            1 => .static_url,
            2 => .github,
            3 => .gitlab,
            4 => .codeberg,
            5 => .forgejo,
            else => error.UnsupportedLegacyUpdateType,
        };
    }

    fn persistAppImages(self: AppImageManager, items: []const appimage.AppImage) !void {
        const json_bytes = try std.json.Stringify.valueAlloc(self.allocator, items, .{ .whitespace = .indent_2 });
        defer self.allocator.free(json_bytes);

        if (std.fs.path.dirname(self.local_db_path)) |dir| {
            try std.Io.Dir.cwd().createDirPath(self.io, dir);
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

        try std.Io.Dir.rename(.cwd(), staging_path, .cwd(), self.local_db_path, self.io);
    }

    fn uniqueSiblingPath(self: AppImageManager, target_path: []const u8, label: []const u8) ![]u8 {
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

        const data_home = try xdg_paths.xdgDataHome(self.allocator, self.environ);
        defer self.allocator.free(data_home);
        for ([_][]const u8{ "icons/hicolor/scalable/apps", "icons/hicolor/256x256/apps" }) |icon_sub_dir| {
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

        if (remove_config_files) {
            self.removeAppConfigDirectories(desktop_app_name);
        }

        self.emitStatusFmt(.success, "Removed AppImage {s}.", .{app_name});
        return true;
    }

    pub fn syncAppImageMeta(self: AppImageManager, app_image_names: []const []const u8) !bool {
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
                        std.Io.Dir.cwd().createDirPath(self.io, self.install_directory) catch {};
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
                    std.log.warn("AppImage not found at {s}", .{appimage_path});
                    success = false;
                    continue;
                }
            }

            const new_meta = (try self.extractMetadata(appimage_path)) orelse {
                std.log.err("Failed to extract metadata for {s}", .{app_name});
                success = false;
                continue;
            };
            defer self.freeAppImage(new_meta);

            var updated = new_meta;
            if (existing) |ex| {
                if (ex.update_url.len > 0) {
                    updated.update_url = ex.update_url;
                    updated.update_type = ex.update_type;
                }
                if (ex.raw_update_info.len > 0 and new_meta.raw_update_info.len == 0) {
                    updated.raw_update_info = ex.raw_update_info;
                }
                updated.repo_owner = ex.repo_owner;
                updated.repo_name = ex.repo_name;
                updated.update_type = ex.update_type;
                updated.allow_prerelease = ex.allow_prerelease;
            } else {
                if (new_meta.raw_update_info.len > 0 and new_meta.update_url.len == 0) {
                    updated.update_type = .static_url;
                }
            }

            try self.addAppImageToLocalDb(updated);
            self.migrateDesktopEntry(updated) catch |err| {
                std.log.warn("Could not migrate desktop entry for {s}: {s}", .{ app_name, @errorName(err) });
            };
        }

        self.emitStatus(
            if (success) .success else .warning,
            if (success) "AppImage metadata synchronized." else "Some AppImage metadata could not be synchronized.",
        );
        operation_scope.finish(if (success) .success else .failed);
        return success;
    }

    fn migrateDesktopEntry(self: AppImageManager, ai: appimage.AppImage) !void {
        const clean_name = try self.cleanInvalidNames(ai.name);
        defer self.allocator.free(clean_name);

        const new_exec_filename = try std.fmt.allocPrint(self.allocator, "{s}.AppImage", .{ai.name});
        defer self.allocator.free(new_exec_filename);
        const new_exec_path = try std.fs.path.join(self.allocator, &.{ self.install_directory, new_exec_filename });
        defer self.allocator.free(new_exec_path);

        const data_home = try xdg_paths.xdgDataHome(self.allocator, self.environ);
        defer self.allocator.free(data_home);
        const desktop_dir = try std.fs.path.join(self.allocator, &.{ data_home, "applications" });
        defer self.allocator.free(desktop_dir);

        const desktop_file_name = try std.fmt.allocPrint(self.allocator, "{s}.desktop", .{clean_name});
        defer self.allocator.free(desktop_file_name);
        const desktop_file_path = try std.fs.path.join(self.allocator, &.{ desktop_dir, desktop_file_name });
        defer self.allocator.free(desktop_file_path);

        _ = std.Io.Dir.cwd().statFile(self.io, desktop_file_path, .{}) catch return;

        const contents = try self.readFileAllocOwned(desktop_file_path);
        defer self.allocator.free(contents);

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();

        var updated = false;
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "Exec=")) {
                const current_exec = std.mem.trim(u8, line["Exec=".len..], " \t");
                if (std.mem.indexOf(u8, current_exec, new_exec_path) != null) {
                    try out.writer.print("{s}\n", .{line});
                    continue;
                }
                var tokens = std.mem.splitScalar(u8, current_exec, ' ');
                _ = tokens.next(); // skip existing executable
                var field_code: ?[]const u8 = null;
                while (tokens.next()) |token| {
                    if (std.mem.startsWith(u8, token, "%")) {
                        field_code = token;
                        break;
                    }
                }
                if (field_code) |fc| {
                    try out.writer.print("Exec=\"{s}\" {s}\n", .{ new_exec_path, fc });
                } else {
                    try out.writer.print("Exec=\"{s}\"\n", .{new_exec_path});
                }
                updated = true;
            } else {
                try out.writer.print("{s}\n", .{line});
            }
        }

        if (updated) {
            var file = try std.Io.Dir.cwd().createFile(self.io, desktop_file_path, .{});
            defer file.close(self.io);
            var write_buf: [4096]u8 = undefined;
            var writer = file.writer(self.io, &write_buf);
            try writer.interface.writeAll(out.written());
            try writer.interface.flush();
        }

        self.updateDesktopDatabase(desktop_dir);

        if (ai.icon_name.len > 0) {
            self.updateIconCache(data_home);
        }
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
            self.updateDesktopDatabase(desktop_dir);
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

    fn cleanInvalidNames(self: AppImageManager, name: []const u8) ![]u8 {
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
        self.allocator.free(appimage_struct.raw_update_info);
        self.allocator.free(appimage_struct.icon_name);
        self.allocator.free(appimage_struct.description);
        self.allocator.free(appimage_struct.desktop_name);
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

fn setTestPathMode(path: []const u8, mode: []const u8) !void {
    var process = try std.process.spawn(std.testing.io, .{
        .argv = &.{ "chmod", mode, path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try process.wait(std.testing.io);
    if (term != .exited or term.exited != 0) return error.ChmodFailed;
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

    try setTestPathMode(db_dir_path, "0555");
    defer setTestPathMode(db_dir_path, "0755") catch {};

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

test "AppImage classification is case insensitive and extension based" {
    try std.testing.expect(AppImageManager.isAppImage("Example.AppImage"));
    try std.testing.expect(AppImageManager.is_app_image("/tmp/Example.appimage"));
    try std.testing.expect(!AppImageManager.isAppImage("Example.AppImage.zsync"));
    try std.testing.expect(!AppImageManager.isAppImage("AppImage"));
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

test "getAppImagesFromLocalDb maps C# AppImage V2 fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(dir_path);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "appimages.db" });
    defer std.testing.allocator.free(db_path);

    try writeTestAppImageDb(db_path,
        \\[
        \\  {
        \\    "Name": "LegacyApp",
        \\    "DesktopName": "Legacy App",
        \\    "Version": "2.3.4",
        \\    "IconName": "legacy-icon",
        \\    "Description": "Legacy description",
        \\    "SizeOnDisk": 123456,
        \\    "UpdateURl": "https://example.test/LegacyApp.AppImage",
        \\    "RawUpdateInfo": "zsync|https://example.test/LegacyApp.zsync",
        \\    "RepoOwner": "shelly",
        \\    "RepoName": "legacy-app",
        \\    "UpdateType": 4,
        \\    "AllowPrerelease": true,
        \\    "CommandLineArgs": "--safe-mode",
        \\    "Path": "/opt/appimages/LegacyApp.AppImage"
        \\  }
        \\]
    );

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
    const item = result[0];
    try std.testing.expectEqualStrings("LegacyApp", item.name);
    try std.testing.expectEqualStrings("Legacy App", item.desktop_name);
    try std.testing.expectEqualStrings("2.3.4", item.version);
    try std.testing.expectEqualStrings("legacy-icon", item.icon_name);
    try std.testing.expectEqualStrings("Legacy description", item.description);
    try std.testing.expectEqual(@as(u64, 123456), item.size_on_disk);
    try std.testing.expectEqualStrings("https://example.test/LegacyApp.AppImage", item.update_url);
    try std.testing.expectEqualStrings("zsync|https://example.test/LegacyApp.zsync", item.raw_update_info);
    try std.testing.expectEqualStrings("shelly", item.repo_owner.?);
    try std.testing.expectEqualStrings("legacy-app", item.repo_name.?);
    try std.testing.expectEqual(appimage.UpdateType.codeberg, item.update_type);
    try std.testing.expect(item.allow_prerelease);
    try std.testing.expectEqualStrings("--safe-mode", item.command_line_args);
    try std.testing.expectEqualStrings("/opt/appimages/LegacyApp.AppImage", item.path);
}

test "getAppImagesFromLocalDb normalizes nullable C# strings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(dir_path);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "appimages.db" });
    defer std.testing.allocator.free(db_path);

    try writeTestAppImageDb(db_path,
        \\[
        \\  {
        \\    "Name": "NullableApp",
        \\    "RepoOwner": null,
        \\    "RepoName": null,
        \\    "CommandLineArgs": null,
        \\    "Path": null
        \\  }
        \\]
    );

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
    try std.testing.expectEqualStrings("", result[0].command_line_args);
    try std.testing.expectEqualStrings("", result[0].path);
    try std.testing.expect(result[0].repo_owner == null);
    try std.testing.expect(result[0].repo_name == null);
}

test "getAppImagesFromLocalDb maps every C# update type" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(dir_path);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "appimages.db" });
    defer std.testing.allocator.free(db_path);

    try writeTestAppImageDb(db_path,
        \\[
        \\  { "Name": "None", "UpdateType": 0 },
        \\  { "Name": "Static", "UpdateType": 1 },
        \\  { "Name": "GitHub", "UpdateType": 2 },
        \\  { "Name": "GitLab", "UpdateType": 3 },
        \\  { "Name": "Codeberg", "UpdateType": 4 },
        \\  { "Name": "Forgejo", "UpdateType": 5 }
        \\]
    );

    const manager = AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = std.testing.environ,
        .install_directory = dir_path,
        .local_db_path = db_path,
    };
    const result = try manager.getAppImagesFromLocalDb();
    defer manager.freeAppImages(result);

    const expected = [_]appimage.UpdateType{ .none, .static_url, .github, .gitlab, .codeberg, .forgejo };
    try std.testing.expectEqual(expected.len, result.len);
    for (result, expected) |item, update_type| {
        try std.testing.expectEqual(update_type, item.update_type);
    }
}

test "getAppImagesFromLocalDb rejects unsupported C# update type" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(dir_path);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "appimages.db" });
    defer std.testing.allocator.free(db_path);

    const source = "[{\"Name\":\"FutureApp\",\"UpdateType\":6}]";
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

test "getAppImagesFromLocalDb migrates C# database and second load is native" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(dir_path);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "appimages.db" });
    defer std.testing.allocator.free(db_path);

    try writeTestAppImageDb(db_path,
        \\[
        \\  {
        \\    "Name": "MigratedApp",
        \\    "DesktopName": "Migrated App",
        \\    "Version": "1.0.0",
        \\    "UpdateType": 2,
        \\    "UpdateVersion": "ignored legacy field",
        \\    "CommandLineArgs": null,
        \\    "Path": null
        \\  }
        \\]
    );

    const manager = AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = std.testing.environ,
        .install_directory = dir_path,
        .local_db_path = db_path,
    };
    const first = try manager.getAppImagesFromLocalDb();
    defer manager.freeAppImages(first);
    try std.testing.expectEqual(@as(usize, 1), first.len);
    try std.testing.expectEqual(appimage.UpdateType.github, first[0].update_type);

    const canonical = try readTestAppImageDb(std.testing.allocator, db_path);
    defer std.testing.allocator.free(canonical);
    try std.testing.expect(std.mem.indexOf(u8, canonical, "\"name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, canonical, "\"update_type\": \"github\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, canonical, "\"Name\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, canonical, "UpdateVersion") == null);

    const parsed = try std.json.parseFromSlice([]appimage.AppImage, std.testing.allocator, canonical, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.len);

    const second = try manager.getAppImagesFromLocalDb();
    defer manager.freeAppImages(second);
    try std.testing.expectEqualStrings(first[0].name, second[0].name);
    try std.testing.expectEqual(first[0].update_type, second[0].update_type);
    try std.testing.expectEqualStrings(first[0].command_line_args, second[0].command_line_args);
    try std.testing.expectEqualStrings(first[0].path, second[0].path);

    const after_second_load = try readTestAppImageDb(std.testing.allocator, db_path);
    defer std.testing.allocator.free(after_second_load);
    try std.testing.expectEqualStrings(canonical, after_second_load);
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

test "getAppImagesFromLocalDb leaves malformed C# database unchanged" {
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
        .desktop_name = "TestApp",
        .path = "/fake/path/TestApp.AppImage",
    };

    try manager.addAppImageToLocalDb(appimage_struct);

    const result = try manager.getAppImagesFromLocalDb();
    defer manager.freeAppImages(result);

    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings("TestApp", result[0].name);
    try std.testing.expectEqualStrings("1.2.3", result[0].version);
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
