const std = @import("std");
const appimage = @import("bindings.zig").appimage;
const xdg_paths = @import("../helpers/xdg_paths.zig").xdg_paths;

pub const AppImageManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    install_directory: []const u8,
    local_db_path: []const u8,

    pub fn installAppImage(self: AppImageManager, location: []const u8) !bool {
        const app_name = std.fs.path.stem(location);
        const dest_name = try std.fmt.allocPrint(self.allocator, "{s}.AppImage", .{app_name});
        defer self.allocator.free(dest_name);
        const dest_path = try std.fs.path.join(self.allocator, &.{ self.install_directory, dest_name });
        defer self.allocator.free(dest_path);

        try std.Io.Dir.cwd().createDirPath(self.io, self.install_directory);
        try self.copyFile(location, dest_path);
        try self.setExecutable(dest_path);

        const metadata = (try self.extractMetadata(dest_path)) orelse {
            std.log.err("Failed to extract metadata during installation.", .{});
            std.Io.Dir.cwd().deleteFile(self.io, dest_path) catch {};
            return false;
        };
        defer self.freeAppImage(metadata);

        const existing_images = try self.getAppImagesFromLocalDb();
        defer self.freeAppImages(existing_images);
        for (existing_images) |existing| {
            const name_match = std.ascii.eqlIgnoreCase(existing.name, metadata.name);
            const desktop_match = existing.desktop_name.len > 0 and metadata.desktop_name.len > 0 and
                std.ascii.eqlIgnoreCase(existing.desktop_name, metadata.desktop_name);
            if (name_match or desktop_match) {
                std.log.warn("AppImage {s} already exists. Overwriting...", .{existing.name});
                const old_path = if (existing.path.len > 0) existing.path else dest_path;
                const removed_name = self.cleanDesktopEntries(existing.name, old_path) catch null;
                if (removed_name) |n| self.allocator.free(n);
                if (existing.path.len > 0 and !std.mem.eql(u8, existing.path, dest_path)) {
                    std.Io.Dir.cwd().deleteFile(self.io, existing.path) catch {};
                }
                break;
            }
        }

        try self.addAppImageToLocalDb(metadata);
        return true;
    }

    fn copyFile(self: AppImageManager, src_path: []const u8, dest_path: []const u8) !void {
        var src = try std.Io.Dir.cwd().openFile(self.io, src_path, .{});
        defer src.close(self.io);
        var dst = try std.Io.Dir.cwd().createFile(self.io, dest_path, .{});
        defer dst.close(self.io);

        var read_buf: [1024 * 64]u8 = undefined;
        var write_buf: [1024 * 64]u8 = undefined;
        var reader = src.reader(self.io, &.{});
        var writer = dst.writer(self.io, &write_buf);

        while (true) {
            const n = try reader.interface.readSliceShort(&read_buf);
            if (n == 0) break;
            try writer.interface.writeAll(read_buf[0..n]);
        }
        try writer.interface.flush();
    }

    fn setExecutable(self: AppImageManager, path: []const u8) !void {
        var proc = try std.process.spawn(self.io, .{
            .argv = &.{ "chmod", "a+x", path },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        _ = try proc.wait(self.io);
    }

    fn extractMetadata(self: AppImageManager, path: []const u8) !?appimage.AppImage {
        const is_rep = path.len >= 4 and std.ascii.eqlIgnoreCase(path[path.len - 4 ..], ".rep");
        const app_name = if (is_rep)
            std.fs.path.stem(std.fs.path.stem(path))
        else
            std.fs.path.stem(path);
        const exec_path = if (is_rep) path[0 .. path.len - 4] else path;

        const clean_name = try self.cleanInvalidNames(app_name);
        defer self.allocator.free(clean_name);

        cleanup: {
            const dh = self.xdgDataHome() catch break :cleanup;
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

        return appimage.AppImage{
            .name = try self.allocator.dupe(u8, app_name),
            .version = owned_version,
            .raw_update_info = update_info,
            .icon_name = icon_name,
            .description = owned_description,
            .desktop_name = owned_desktop_name,
            .size_on_disk = (try std.Io.Dir.cwd().statFile(self.io, path, .{})).size,
            .path = try self.allocator.dupe(u8, exec_path),
        };
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

        const data_home = try self.xdgDataHome();
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
        const data_home = try self.xdgDataHome();
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
        var file = std.Io.Dir.cwd().openFile(self.io, self.local_db_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return &.{},
            else => return err,
        };
        defer file.close(self.io);

        var buf: [4096]u8 = undefined;
        var reader = file.reader(self.io, &buf);
        const contents = try reader.interface.allocRemaining(self.allocator, .unlimited);
        defer self.allocator.free(contents);

        const parsed = std.json.parseFromSlice([]appimage.AppImage, self.allocator, contents, .{}) catch |err| {
            std.log.err("Error reading AppImage local DB: {s}", .{@errorName(err)});
            return &.{};
        };
        defer parsed.deinit();

        const result = try self.allocator.alloc(appimage.AppImage, parsed.value.len);
        for (parsed.value, result) |src, *dst| {
            dst.* = .{
                .name = try self.allocator.dupe(u8, src.name),
                .version = try self.allocator.dupe(u8, src.version),
                .raw_update_info = try self.allocator.dupe(u8, src.raw_update_info),
                .icon_name = try self.allocator.dupe(u8, src.icon_name),
                .description = try self.allocator.dupe(u8, src.description),
                .desktop_name = try self.allocator.dupe(u8, src.desktop_name),
                .size_on_disk = src.size_on_disk,
                .command_line_args = try self.allocator.dupe(u8, src.command_line_args),
                .path = try self.allocator.dupe(u8, src.path),
                .update_url = try self.allocator.dupe(u8, src.update_url),
                .update_type = src.update_type,
                .repo_owner = if (src.repo_owner) |v| try self.allocator.dupe(u8, v) else null,
                .repo_name = if (src.repo_name) |v| try self.allocator.dupe(u8, v) else null,
                .allow_prerelease = src.allow_prerelease,
            };
        }
        return result;
    }

    fn addAppImageToLocalDb(self: AppImageManager, appimage_struct: appimage.AppImage) !void {
        const existing = try self.getAppImagesFromLocalDb();
        defer self.freeAppImages(existing);

        var list: std.ArrayList(appimage.AppImage) = .empty;
        defer list.deinit(self.allocator);

        for (existing) |item| {
            if (appimage_struct.desktop_name.len > 0 and std.ascii.eqlIgnoreCase(item.desktop_name, appimage_struct.desktop_name)) continue;
            try list.append(self.allocator, item);
        }
        try list.append(self.allocator, appimage_struct);

        const json_bytes = try std.json.Stringify.valueAlloc(self.allocator, list.items, .{ .whitespace = .indent_2 });
        defer self.allocator.free(json_bytes);

        if (std.fs.path.dirname(self.local_db_path)) |dir| {
            try std.Io.Dir.cwd().createDirPath(self.io, dir);
        }

        var file = try std.Io.Dir.cwd().createFile(self.io, self.local_db_path, .{});
        defer file.close(self.io);
        var write_buf: [4096]u8 = undefined;
        var writer = file.writer(self.io, &write_buf);
        try writer.interface.writeAll(json_bytes);
        try writer.interface.flush();
    }

    pub fn removeAppImage(self: AppImageManager, appimage_path: []const u8, remove_config_files: bool) !bool {
        const app_name = std.fs.path.stem(appimage_path);
        const clean_name = try self.cleanInvalidNames(app_name);
        defer self.allocator.free(clean_name);

        const existing = try self.getAppImagesFromLocalDb();
        var list: std.ArrayList(appimage.AppImage) = .empty;
        defer list.deinit(self.allocator);
        defer self.freeAppImages(existing);

        for (existing) |item| {
            if (!std.ascii.eqlIgnoreCase(item.name, app_name)) try list.append(self.allocator, item);
        }
        const json_bytes = try std.json.Stringify.valueAlloc(self.allocator, list.items, .{ .whitespace = .indent_2 });
        defer self.allocator.free(json_bytes);
        var db_file = try std.Io.Dir.cwd().createFile(self.io, self.local_db_path, .{});
        defer db_file.close(self.io);
        var write_buf: [4096]u8 = undefined;
        var writer = db_file.writer(self.io, &write_buf);
        try writer.interface.writeAll(json_bytes);
        try writer.interface.flush();

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

        return true;
    }

    pub fn syncAppImageMeta(self: AppImageManager, app_image_names: []const []const u8) !bool {
        const db_images = try self.getAppImagesFromLocalDb();
        defer self.freeAppImages(db_images);
        var success = true;

        for (app_image_names) |app_name| {
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

        return success;
    }

    fn migrateDesktopEntry(self: AppImageManager, ai: appimage.AppImage) !void {
        const clean_name = try self.cleanInvalidNames(ai.name);
        defer self.allocator.free(clean_name);

        const new_exec_filename = try std.fmt.allocPrint(self.allocator, "{s}.AppImage", .{ai.name});
        defer self.allocator.free(new_exec_filename);
        const new_exec_path = try std.fs.path.join(self.allocator, &.{ self.install_directory, new_exec_filename });
        defer self.allocator.free(new_exec_path);

        const data_home = try self.xdgDataHome();
        defer self.allocator.free(data_home);
        const desktop_dir = try std.fs.path.join(self.allocator, &.{ data_home, "applications" });
        defer self.allocator.free(desktop_dir);

        const desktop_file_name = try std.fmt.allocPrint(self.allocator, "{s}.desktop", .{clean_name});
        defer self.allocator.free(desktop_file_name);
        const desktop_file_path = try std.fs.path.join(self.allocator, &.{ desktop_dir, desktop_file_name });
        defer self.allocator.free(desktop_file_path);

        std.Io.Dir.cwd().statFile(self.io, desktop_file_path, .{}) catch return;

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

    fn freeAppImage(self: AppImageManager, appimage_struct: appimage.AppImage) void {
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
