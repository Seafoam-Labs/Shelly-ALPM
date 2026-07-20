const std = @import("std");
const file_inspector = @import("file_inspector.zig");

pub const Error = error{
    InvalidDesktopName,
    InvalidDesktopValue,
    InvalidIcon,
    CacheUpdateFailed,
};

pub const Options = struct {
    desktop_directory: []const u8 = "/usr/share/applications",
    icon_root: []const u8 = "/usr/share/icons/hicolor",
    run_cache_updates: bool = true,
};

pub const DesktopEntry = struct {
    app_name: []const u8,
    file_name: []const u8,
    executable: []const u8,
    comment: ?[]const u8 = null,
    icon: []const u8 = "application-x-executable",
    terminal: bool = false,
    categories: []const u8 = "Utility;",
};

pub const Integration = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options = .{},

    pub fn createDesktopEntry(self: Integration, entry: DesktopEntry) !void {
        try validateFileName(entry.file_name);
        try validateValue(entry.app_name);
        try validateValue(entry.executable);
        try validateValue(entry.comment orelse entry.app_name);
        try validateValue(entry.icon);
        try validateValue(entry.categories);

        try std.Io.Dir.cwd().createDirPath(self.io, self.options.desktop_directory);
        const file_name = try std.fmt.allocPrint(self.allocator, "{s}.desktop", .{entry.file_name});
        defer self.allocator.free(file_name);
        const path = try std.fs.path.join(self.allocator, &.{ self.options.desktop_directory, file_name });
        defer self.allocator.free(path);

        var output = std.Io.Writer.Allocating.init(self.allocator);
        defer output.deinit();
        try output.writer.print(
            "[Desktop Entry]\n" ++
                "Version=1.0\n" ++
                "Type=Application\n" ++
                "Name={s}\n" ++
                "Comment={s}\n" ++
                "Exec={s}\n" ++
                "Icon={s}\n" ++
                "Terminal={s}\n" ++
                "Categories={s}\n" ++
                "StartupNotify=true\n",
            .{
                entry.app_name,
                entry.comment orelse entry.app_name,
                entry.executable,
                entry.icon,
                if (entry.terminal) "true" else "false",
                entry.categories,
            },
        );
        try std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = path,
            .data = output.written(),
            .flags = .{ .permissions = std.Io.File.Permissions.fromMode(0o644) },
        });
        if (self.options.run_cache_updates)
            try runCommand(self.io, &.{ "update-desktop-database", self.options.desktop_directory });
    }

    pub fn removeDesktopEntry(self: Integration, binary_name: []const u8) !bool {
        const stem = std.fs.path.stem(binary_name);
        try validateFileName(stem);
        const cleaned_stem = try cleanName(self.allocator, stem);
        defer self.allocator.free(cleaned_stem);
        const file_name = try std.fmt.allocPrint(self.allocator, "{s}.desktop", .{cleaned_stem});
        defer self.allocator.free(file_name);
        const path = try std.fs.path.join(self.allocator, &.{ self.options.desktop_directory, file_name });
        defer self.allocator.free(path);
        std.Io.Dir.cwd().deleteFile(self.io, path) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }

    /// Installs an icon and returns an owned icon name.
    pub fn installIcon(self: Integration, icon_path: []const u8, app_name: []const u8) ![]u8 {
        if (!file_inspector.isIcon(icon_path)) return Error.InvalidIcon;
        const icon_name = try cleanName(self.allocator, app_name);
        errdefer self.allocator.free(icon_name);
        const extension = extensionOf(icon_path) orelse return Error.InvalidIcon;
        const destination_directory = try self.iconDirectory(icon_path);
        defer self.allocator.free(destination_directory);
        try std.Io.Dir.cwd().createDirPath(self.io, destination_directory);
        const destination_name = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ icon_name, extension });
        defer self.allocator.free(destination_name);
        const destination_path = try std.fs.path.join(self.allocator, &.{ destination_directory, destination_name });
        defer self.allocator.free(destination_path);
        _ = try std.Io.Dir.updateFile(.cwd(), self.io, icon_path, .cwd(), destination_path, .{});

        if (self.options.run_cache_updates)
            try runCommand(self.io, &.{ "gtk-update-icon-cache", "-f", "-t", self.options.icon_root });
        return icon_name;
    }

    pub fn removeIcon(self: Integration, binary_name: []const u8, source_icon_path: []const u8) !bool {
        if (!file_inspector.isIcon(source_icon_path)) return false;
        const clean_binary = try cleanName(self.allocator, binary_name);
        defer self.allocator.free(clean_binary);
        const extension = extensionOf(source_icon_path) orelse return false;
        const destination_directory = try self.iconDirectory(source_icon_path);
        defer self.allocator.free(destination_directory);
        const destination_name = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ clean_binary, extension });
        defer self.allocator.free(destination_name);
        const destination_path = try std.fs.path.join(self.allocator, &.{ destination_directory, destination_name });
        defer self.allocator.free(destination_path);
        std.Io.Dir.cwd().deleteFile(self.io, destination_path) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }

    /// Removes every installed PNG/SVG icon whose stem matches `binary_name`.
    pub fn removeInstalledIcons(self: Integration, binary_name: []const u8) !usize {
        const clean_binary = try cleanName(self.allocator, binary_name);
        defer self.allocator.free(clean_binary);
        var root = std.Io.Dir.cwd().openDir(self.io, self.options.icon_root, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => return err,
        };
        defer root.close(self.io);
        var walker = try root.walk(self.allocator);
        defer walker.deinit();
        var removed: usize = 0;
        while (try walker.next(self.io)) |entry| {
            if (entry.kind != .file or !file_inspector.isIcon(entry.basename)) continue;
            if (!std.ascii.eqlIgnoreCase(std.fs.path.stem(entry.basename), clean_binary)) continue;
            root.deleteFile(self.io, entry.path) catch continue;
            removed += 1;
        }
        return removed;
    }

    fn iconDirectory(self: Integration, source_icon_path: []const u8) ![]u8 {
        const extension = extensionOf(source_icon_path) orelse return Error.InvalidIcon;
        if (std.ascii.eqlIgnoreCase(extension, ".svg"))
            return std.fs.path.join(self.allocator, &.{ self.options.icon_root, "scalable", "apps" });
        const size = parseImageSize(std.fs.path.basename(source_icon_path)) orelse 256;
        const size_directory = try std.fmt.allocPrint(self.allocator, "{d}x{d}", .{ size, size });
        defer self.allocator.free(size_directory);
        return std.fs.path.join(self.allocator, &.{ self.options.icon_root, size_directory, "apps" });
    }
};

pub fn cleanName(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (value.len == 0) return Error.InvalidDesktopName;
    const result = try allocator.alloc(u8, value.len);
    for (value, result) |char, *out| {
        out.* = switch (char) {
            'A'...'Z' => std.ascii.toLower(char),
            ' ', '/', '\\' => '-',
            else => char,
        };
    }
    return result;
}

fn validateFileName(value: []const u8) !void {
    if (value.len == 0 or std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..") or
        std.mem.indexOfAny(u8, value, "/\\\r\n") != null) return Error.InvalidDesktopName;
}

fn validateValue(value: []const u8) !void {
    if (std.mem.indexOfAny(u8, value, "\r\n") != null) return Error.InvalidDesktopValue;
}

fn extensionOf(path: []const u8) ?[]const u8 {
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return null;
    return base[dot..];
}

fn parseImageSize(file_name: []const u8) ?u32 {
    var start: ?usize = null;
    for (file_name, 0..) |char, index| {
        if (std.ascii.isDigit(char)) {
            if (start == null) start = index;
        } else if (start) |begin| {
            return std.fmt.parseInt(u32, file_name[begin..index], 10) catch null;
        }
    }
    if (start) |begin| return std.fmt.parseInt(u32, file_name[begin..], 10) catch null;
    return null;
}

fn runCommand(io: std.Io, argv: []const []const u8) !void {
    var process = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try process.wait(io);
    if (term != .exited or term.exited != 0) return Error.CacheUpdateFailed;
}

test "desktop entries and icons are confined to configured directories" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(root);
    const desktop = try std.fs.path.join(testing.allocator, &.{ root, "applications" });
    defer testing.allocator.free(desktop);
    const icons = try std.fs.path.join(testing.allocator, &.{ root, "icons", "hicolor" });
    defer testing.allocator.free(icons);
    const source_icon = try std.fs.path.join(testing.allocator, &.{ root, "demo-64x64.png" });
    defer testing.allocator.free(source_icon);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = source_icon, .data = "png" });

    const integration: Integration = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .options = .{ .desktop_directory = desktop, .icon_root = icons, .run_cache_updates = false },
    };
    try integration.createDesktopEntry(.{
        .app_name = "Demo",
        .file_name = "demo",
        .executable = "demo",
    });
    const icon_name = try integration.installIcon(source_icon, "Demo");
    defer testing.allocator.free(icon_name);
    try testing.expectEqualStrings("demo", icon_name);

    const desktop_path = try std.fs.path.join(testing.allocator, &.{ desktop, "demo.desktop" });
    defer testing.allocator.free(desktop_path);
    try std.Io.Dir.cwd().access(testing.io, desktop_path, .{});
    const icon_path = try std.fs.path.join(testing.allocator, &.{ icons, "64x64", "apps", "demo.png" });
    defer testing.allocator.free(icon_path);
    try std.Io.Dir.cwd().access(testing.io, icon_path, .{});

    try testing.expect(try integration.removeDesktopEntry("demo"));
    try testing.expectEqual(@as(usize, 1), try integration.removeInstalledIcons("demo"));
}
