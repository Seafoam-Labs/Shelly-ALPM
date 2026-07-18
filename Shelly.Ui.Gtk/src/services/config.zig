const std = @import("std");
const Io = std.Io;
const ShellyConfig = @import("../models/shelly_config.zig").ShellyConfig;
const xdg_paths = @import("xdg_paths.zig").xdg_paths;

const settings_relative_path = "shelly/settings.json";

/// Maximum size accepted when reading the settings file (1 MiB).
const max_settings_size: Io.Limit = .limited(1 << 20);

pub const ConfigError = error{
    NotLoaded,
};

pub const ConfigService = struct {
    allocator: std.mem.Allocator,
    io: Io,
    config_dir: Io.Dir,
    parsed: ?std.json.Parsed(ShellyConfig),

    pub fn init(
        allocator: std.mem.Allocator,
        io: Io,
        env_map: *const std.process.Environ.Map,
    ) !ConfigService {
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
            .parsed = null,
        };
    }

    pub fn initDir(allocator: std.mem.Allocator, io: Io, config_dir: Io.Dir) ConfigService {
        return .{
            .allocator = allocator,
            .io = io,
            .config_dir = config_dir,
            .parsed = null,
        };
    }

    pub fn deinit(self: *ConfigService) void {
        if (self.parsed) |*p| {
            p.deinit();
            self.parsed = null;
        }
    }

    pub fn configPath(self: ConfigService) ![]u8 {
        return try self.allocator.dupe(u8, settings_relative_path);
    }

    pub fn load(self: *ConfigService) !void {
        if (self.parsed) |*p| {
            p.deinit();
            self.parsed = null;
        }

        const path = try self.configPath();
        defer self.allocator.free(path);

        const data = self.config_dir.readFileAlloc(
            self.io,
            path,
            self.allocator,
            max_settings_size,
        ) catch |err| switch (err) {
            error.FileNotFound => {
                try self.saveDefault(path);
                const default_json = try std.json.Stringify.valueAlloc(
                    self.allocator,
                    ShellyConfig{},
                    .{ .whitespace = .indent_2 },
                );
                defer self.allocator.free(default_json);
                self.parsed = try std.json.parseFromSlice(
                    ShellyConfig,
                    self.allocator,
                    default_json,
                    .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
                );
                return;
            },
            else => return err,
        };
        defer self.allocator.free(data);

        self.parsed = try std.json.parseFromSlice(
            ShellyConfig,
            self.allocator,
            data,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
    }

    pub fn save(self: *ConfigService) !void {
        if (self.parsed == null) return ConfigError.NotLoaded;

        const path = try self.configPath();
        defer self.allocator.free(path);

        const dir_name = std.fs.path.dirname(path).?;
        var sub_dir = try self.config_dir.createDirPathOpen(self.io, dir_name, .{});
        defer sub_dir.close(self.io);

        const file = try sub_dir.createFile(self.io, std.fs.path.basename(path), .{});
        defer file.close(self.io);

        var buf: [4096]u8 = undefined;
        var fw = file.writer(self.io, &buf);
        try fw.interface.print("{f}", .{
            std.json.fmt(self.parsed.?.value, .{ .whitespace = .indent_2 }),
        });
        try fw.flush();
    }

    pub fn get(self: *ConfigService) !*ShellyConfig {
        if (self.parsed) |*p| {
            return &p.value;
        }
        return ConfigError.NotLoaded;
    }

    pub fn set(self: *ConfigService, new_config: ShellyConfig) !void {
        if (self.parsed) |*p| {
            p.deinit();
        }
        const json = try std.json.Stringify.valueAlloc(self.allocator, new_config, .{});
        defer self.allocator.free(json);
        self.parsed = try std.json.parseFromSlice(
            ShellyConfig,
            self.allocator,
            json,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
    }

    fn saveDefault(self: *ConfigService, path: []const u8) !void {
        const dir_name = std.fs.path.dirname(path).?;
        var sub_dir = try self.config_dir.createDirPathOpen(self.io, dir_name, .{});
        defer sub_dir.close(self.io);

        const file = try sub_dir.createFile(self.io, std.fs.path.basename(path), .{});
        defer file.close(self.io);

        var buf: [4096]u8 = undefined;
        var fw = file.writer(self.io, &buf);
        try std.json.Stringify.value(
            ShellyConfig{},
            .{ .whitespace = .indent_2 },
            &fw.interface,
        );
        try fw.flush();
    }
};

const testing = std.testing;

fn makeService(tmp: *std.testing.TmpDir) ConfigService {
    return ConfigService.initDir(testing.allocator, testing.io, tmp.dir);
}

test "get before load returns NotLoaded" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var svc = makeService(&tmp);
    defer svc.deinit();

    try testing.expectError(ConfigError.NotLoaded, svc.get());
}

test "save before load returns NotLoaded" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var svc = makeService(&tmp);
    defer svc.deinit();

    try testing.expectError(ConfigError.NotLoaded, svc.save());
}

test "configPath is relative to config dir" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var svc = makeService(&tmp);
    defer svc.deinit();

    const path = try svc.configPath();
    defer svc.allocator.free(path);

    try testing.expectEqualStrings("shelly/settings.json", path);
}

test "load creates a default file when none exists" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var svc = makeService(&tmp);
    defer svc.deinit();

    try svc.load();

    // The defaults should match `ShellyConfig{}`.
    const defaults: ShellyConfig = .{};
    const cfg = try svc.get();
    try testing.expectEqual(defaults.NewInstall, cfg.NewInstall);
    try testing.expectEqual(defaults.AurEnabled, cfg.AurEnabled);
    try testing.expectEqual(defaults.DefaultPageDropDown, cfg.DefaultPageDropDown);

    // The file should now exist on disk.
    const data = try tmp.dir.readFileAlloc(
        testing.io,
        "shelly/settings.json",
        testing.allocator,
        max_settings_size,
    );
    defer testing.allocator.free(data);

    // It must be valid JSON and contain at least one expected field.
    try testing.expect(std.mem.indexOf(u8, data, "\"NewInstall\"") != null);
}

test "load reads an existing file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Pre-seed the config file.
    {
        var sub_dir = try tmp.dir.createDirPathOpen(testing.io, "shelly", .{});
        defer sub_dir.close(testing.io);
        const file = try sub_dir.createFile(testing.io, "settings.json", .{});
        defer file.close(testing.io);
        var buf: [1024]u8 = undefined;
        var fw = file.writer(testing.io, &buf);
        try fw.interface.print("{f}", .{
            std.json.fmt(
                ShellyConfig{ .AurEnabled = true, .NewInstall = false },
                .{ .whitespace = .indent_2 },
            ),
        });
        try fw.flush();
    }

    var svc = makeService(&tmp);
    defer svc.deinit();
    try svc.load();

    const cfg = try svc.get();
    try testing.expectEqual(true, cfg.AurEnabled);
    try testing.expectEqual(false, cfg.NewInstall);
}

test "set replaces in-memory config" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var svc = makeService(&tmp);
    defer svc.deinit();

    try svc.set(.{ .AurEnabled = true, .WindowWidth = 1024 });

    const cfg = try svc.get();
    try testing.expectEqual(true, cfg.AurEnabled);
    try testing.expectEqual(@as(f64, 1024), cfg.WindowWidth);
}

test "save persists modifications and survives reload" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var svc = makeService(&tmp);
        defer svc.deinit();
        try svc.load();

        const cfg = try svc.get();
        cfg.AurEnabled = true;
        cfg.WindowWidth = 1280;

        try svc.save();
    }

    // A fresh service should observe the saved values.
    var svc = makeService(&tmp);
    defer svc.deinit();
    try svc.load();

    const cfg = try svc.get();
    try testing.expectEqual(true, cfg.AurEnabled);
    try testing.expectEqual(@as(f64, 1280), cfg.WindowWidth);
}

test "load can be called repeatedly without leaking" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var svc = makeService(&tmp);
    defer svc.deinit();

    for (0..3) |_| {
        try svc.load();
        const cfg = try svc.get();
        cfg.WindowWidth = 999;
    }

    // Final reload should reflect whatever is on disk (defaults here).
    try svc.load();
    const cfg = try svc.get();
    try testing.expectEqual(@as(f64, 800), cfg.WindowWidth);
}

test "set then save round-trips nested enum fields" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var svc = makeService(&tmp);
    defer svc.deinit();

    const new_config = ShellyConfig{
        .DefaultPageDropDown = .flatpak,
        .PackageInstallView = .grid,
    };
    try svc.set(new_config);
    try svc.save();

    // Reload and verify the enums survived serialization.
    var other = makeService(&tmp);
    defer other.deinit();
    try other.load();

    const cfg = try other.get();
    try testing.expectEqual(@as(u8, 2), @intFromEnum(cfg.DefaultPageDropDown));
    try testing.expectEqual(@as(u8, 0), @intFromEnum(cfg.PackageInstallView));
}

test "ignores unknown fields when loading" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var sub_dir = try tmp.dir.createDirPathOpen(testing.io, "shelly", .{});
        defer sub_dir.close(testing.io);
        const file = try sub_dir.createFile(testing.io, "settings.json", .{});
        defer file.close(testing.io);
        var buf: [512]u8 = undefined;
        var fw = file.writer(testing.io, &buf);
        try fw.interface.writeAll(
            \\{"NewInstall":false,"SomeFutureField":"ignored"}
        );
        try fw.flush();
    }

    var svc = makeService(&tmp);
    defer svc.deinit();
    try svc.load();

    const cfg = try svc.get();
    try testing.expectEqual(false, cfg.NewInstall);
}

test "load propagates errors for malformed JSON" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var sub_dir = try tmp.dir.createDirPathOpen(testing.io, "shelly", .{});
        defer sub_dir.close(testing.io);
        const file = try sub_dir.createFile(testing.io, "settings.json", .{});
        defer file.close(testing.io);
        var buf: [128]u8 = undefined;
        var fw = file.writer(testing.io, &buf);
        try fw.interface.writeAll("{not valid json}");
        try fw.flush();
    }

    var svc = makeService(&tmp);
    defer svc.deinit();

    try testing.expectError(error.SyntaxError, svc.load());
}
