const std = @import("std");
const appimage = @import("bindings.zig").appimage;

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
        const app_name = std.fs.path.stem(path);
        const clean_name = try self.cleanInvalidNames(app_name);
        defer self.allocator.free(clean_name);

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

        try self.writeDesktopEntry(clean_name, path, desktop_file_path, squashfs_root, icon_name, desktop_name, description);

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
            .path = try self.allocator.dupe(u8, path),
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
                    try out.writer.print("Exec=\"{s}\"\n", .{exec_path});
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

    pub fn removeAppImage(self: AppImageManager, appimage_path: []const u8) !bool {
        const app_name = std.fs.path.stem(appimage_path);

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

        const clean_name = try self.cleanInvalidNames(app_name);
        defer self.allocator.free(clean_name);

        const data_home = try self.xdgDataHome();
        defer self.allocator.free(data_home);
        const desktop_dir = try std.fs.path.join(self.allocator, &.{ data_home, "applications" });
        defer self.allocator.free(desktop_dir);

        const desktop_file_name = try std.fmt.allocPrint(self.allocator, "{s}.desktop", .{clean_name});
        defer self.allocator.free(desktop_file_name);
        const desktop_file_path = try std.fs.path.join(self.allocator, &.{ desktop_dir, desktop_file_name });
        defer self.allocator.free(desktop_file_path);
        std.Io.Dir.cwd().deleteFile(self.io, desktop_file_path) catch {};
        self.updateDesktopDatabase(desktop_dir);

        return true;
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

    fn xdgDataHome(self: AppImageManager) ![]u8 {
        if (self.environ.getPosix("XDG_DATA_HOME")) |v| return try self.allocator.dupe(u8, v);
        const home: []const u8 = self.environ.getPosix("HOME") orelse return error.HomeNotSet;
        return std.fs.path.join(self.allocator, &.{ home, ".local", "share" });
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

test "xdgDataHome falls back to HOME/.local/share when XDG_DATA_HOME unset" {
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
    const path = try manager.xdgDataHome();
    defer allocator.free(path);
    try std.testing.expect(path.len > 0);
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

    const removed = try manager.removeAppImage(fake_appimage_path);
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

// test "manual: installAppImage with a real AppImage file" {
//     var tmp = std.testing.tmpDir(.{});
//     defer tmp.cleanup();

//     var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
//     const len = try tmp.dir.realPath(std.testing.io, &path_buf);

//     const dir_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
//     defer std.testing.allocator.free(dir_path);

//     const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "appimages.db" });
//     defer std.testing.allocator.free(db_path);

//     const manager = AppImageManager{
//         .allocator = std.testing.allocator,
//         .io = std.testing.io,
//         .environ = std.testing.environ,
//         .install_directory = dir_path,
//         .local_db_path = db_path,
//     };

//     const result = try manager.installAppImage("/home/caro/Downloads/osu.AppImage");
//     try std.testing.expect(result);

//     const db = try manager.getAppImagesFromLocalDb();
//     defer manager.freeAppImages(db);
//     try std.testing.expect(db.len == 1);
// }
