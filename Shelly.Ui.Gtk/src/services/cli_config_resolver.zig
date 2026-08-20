const std = @import("std");
const Io = std.Io;
const xdg_paths = @import("xdg_paths.zig").xdg_paths;

const cli_config_path = "shelly/config.json";

const settings_path = @import("ui_config_resolver.zig").settings_path;

const max_config_size: Io.Limit = .limited(1 << 20);

const install_path_key = "AppImageInstallPath";

pub const CliConfigResolver = struct {
    allocator: std.mem.Allocator,
    io: Io,
    config_dir: Io.Dir,
    owns_config_dir: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: Io,
        env_map: *const std.process.Environ.Map,
    ) !CliConfigResolver {
        const home_path = try xdg_paths.xdgConfigHome(allocator, env_map);
        defer allocator.free(home_path);

        const cwd = Io.Dir.cwd();
        const config_dir = cwd.createDirPathOpen(io, home_path, .{}) catch |err| switch (err) {
            error.PathAlreadyExists => try cwd.openDir(io, home_path, .{}),
            else => return err,
        };

        return .{
            .allocator = allocator,
            .io = io,
            .config_dir = config_dir,
            .owns_config_dir = true,
        };
    }

    pub fn initDir(allocator: std.mem.Allocator, io: Io, config_dir: Io.Dir) CliConfigResolver {
        return .{
            .allocator = allocator,
            .io = io,
            .config_dir = config_dir,
            .owns_config_dir = false,
        };
    }

    pub fn deinit(self: *CliConfigResolver) void {
        if (self.owns_config_dir) self.config_dir.close(self.io);
    }

    pub fn readAppImageInstallPath(self: CliConfigResolver) !?[]const u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const data = self.readConfigFile(arena.allocator(), cli_config_path) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        const root = try parseObject(arena.allocator(), data);

        const value = root.object.get(install_path_key) orelse return null;
        if (value == .null) return null;
        if (value != .string) return error.InvalidCliConfig;
        return try self.allocator.dupe(u8, value.string);
    }

    pub fn writeAppImageInstallPath(self: CliConfigResolver, path: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var root: std.json.Value = .{ .object = .empty };
        if (self.readConfigFile(allocator, cli_config_path) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        }) |data| {
            root = try parseObject(allocator, data);
        }

        try root.object.put(allocator, install_path_key, .{ .string = path });

        const serialized = try std.json.Stringify.valueAlloc(
            allocator,
            root,
            .{ .whitespace = .indent_2, .escape_unicode = true },
        );

        const dir_name = std.fs.path.dirname(cli_config_path).?;
        var sub_dir = try self.config_dir.createDirPathOpen(self.io, dir_name, .{});
        defer sub_dir.close(self.io);
        const file = try sub_dir.createFile(self.io, std.fs.path.basename(cli_config_path), .{});
        defer file.close(self.io);
        var buf: [4096]u8 = undefined;
        var fw = file.writer(self.io, &buf);
        try fw.interface.writeAll(serialized);
        try fw.flush();
    }

    /// One-time migration from the legacy UI setting: earlier releases stored
    /// `AppImageInstallPath` in settings.json. When that legacy value is set
    /// and config.json has none, copy it over so the CLI configuration stays
    /// the single source of truth. Never fatal. TODO: Remove after few releases.
    pub fn migrateLegacyInstallPath(self: CliConfigResolver) void {
        const legacy = self.readLegacyInstallPath() catch |err| {
            std.log.warn("appimage: could not read legacy install path: {t}", .{err});
            return;
        };
        const legacy_path = legacy orelse return;
        defer self.allocator.free(legacy_path);
        if (legacy_path.len == 0) return;

        const existing = self.readAppImageInstallPath() catch |err| {
            std.log.warn("appimage: could not read CLI config during migration: {t}", .{err});
            return;
        };
        if (existing) |value| {
            self.allocator.free(value);
            return;
        }

        self.writeAppImageInstallPath(legacy_path) catch |err| {
            std.log.warn("appimage: could not migrate legacy install path: {t}", .{err});
            return;
        };
        std.log.info("appimage: migrated install path from settings.json to config.json", .{});
    }

    fn readLegacyInstallPath(self: CliConfigResolver) !?[]const u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const data = self.readConfigFile(arena.allocator(), settings_path) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        const root = try parseObject(arena.allocator(), data);

        const value = root.object.get(install_path_key) orelse return null;
        if (value != .string) return null;
        return try self.allocator.dupe(u8, value.string);
    }

    fn readConfigFile(self: CliConfigResolver, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return self.config_dir.readFileAlloc(self.io, path, allocator, max_config_size);
    }

    fn parseObject(allocator: std.mem.Allocator, data: []const u8) !std.json.Value {
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, data, .{});
        if (parsed != .object) return error.InvalidCliConfig;
        return parsed;
    }
};

const testing = std.testing;

fn makeService(tmp: *std.testing.TmpDir) CliConfigResolver {
    return CliConfigResolver.initDir(testing.allocator, testing.io, tmp.dir);
}

fn seedFile(tmp: *std.testing.TmpDir, name: []const u8, contents: []const u8) !void {
    var sub_dir = try tmp.dir.createDirPathOpen(testing.io, "shelly", .{});
    defer sub_dir.close(testing.io);
    const file = try sub_dir.createFile(testing.io, name, .{});
    defer file.close(testing.io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(testing.io, &buf);
    try fw.interface.writeAll(contents);
    try fw.flush();
}

fn readTmpFile(tmp: *std.testing.TmpDir, name: []const u8) ![]u8 {
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "shelly/{s}", .{name});
    return tmp.dir.readFileAlloc(testing.io, path, testing.allocator, max_config_size);
}

test "read returns null when the CLI config is missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var svc = makeService(&tmp);
    defer svc.deinit();

    try testing.expect((try svc.readAppImageInstallPath()) == null);
}

test "write then read round-trips the install path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var svc = makeService(&tmp);
    defer svc.deinit();

    try svc.writeAppImageInstallPath("/opt/appimages");

    const path = (try svc.readAppImageInstallPath()).?;
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/opt/appimages", path);
}

test "write preserves unrelated CLI settings" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try seedFile(&tmp, "config.json",
        \\{
        \\  "FileSizeDisplay": "Megabytes",
        \\  "ParallelDownloadCount": 22,
        \\  "AppImageInstallPath": null
        \\}
    );

    var svc = makeService(&tmp);
    defer svc.deinit();
    try svc.writeAppImageInstallPath("/custom/bin");

    const data = try readTmpFile(&tmp, "config.json");
    defer testing.allocator.free(data);
    try testing.expect(std.mem.indexOf(u8, data, "\"ParallelDownloadCount\": 22") != null);
    try testing.expect(std.mem.indexOf(u8, data, "\"FileSizeDisplay\": \"Megabytes\"") != null);
    try testing.expect(std.mem.indexOf(u8, data, "\"AppImageInstallPath\": \"/custom/bin\"") != null);
}

test "read rejects a config that is not a JSON object" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try seedFile(&tmp, "config.json", "\"just a string\"");

    var svc = makeService(&tmp);
    defer svc.deinit();

    try testing.expectError(error.InvalidCliConfig, svc.readAppImageInstallPath());
}

test "migration copies a legacy settings value into the CLI config" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try seedFile(&tmp, "settings.json",
        \\{
        \\  "AppImageInstallPath": "/legacy/bin",
        \\  "TrayEnabled": true
        \\}
    );

    var svc = makeService(&tmp);
    defer svc.deinit();
    svc.migrateLegacyInstallPath();

    const path = (try svc.readAppImageInstallPath()).?;
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/legacy/bin", path);
}

test "migration keeps an existing CLI value" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try seedFile(&tmp, "settings.json", "{\"AppImageInstallPath\": \"/legacy/bin\"}");
    try seedFile(&tmp, "config.json", "{\"AppImageInstallPath\": \"/cli/bin\"}");

    var svc = makeService(&tmp);
    defer svc.deinit();
    svc.migrateLegacyInstallPath();

    const path = (try svc.readAppImageInstallPath()).?;
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/cli/bin", path);
}

test "migration ignores unset or empty legacy values" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try seedFile(&tmp, "settings.json", "{\"TrayEnabled\": true}");

    var svc = makeService(&tmp);
    defer svc.deinit();
    svc.migrateLegacyInstallPath();
    try testing.expect((try svc.readAppImageInstallPath()) == null);

    try seedFile(&tmp, "settings.json", "{\"AppImageInstallPath\": \"\"}");
    svc.migrateLegacyInstallPath();
    try testing.expect((try svc.readAppImageInstallPath()) == null);

    // settings.json is left untouched by the migration.
    const data = try readTmpFile(&tmp, "settings.json");
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("{\"AppImageInstallPath\": \"\"}", data);
}
