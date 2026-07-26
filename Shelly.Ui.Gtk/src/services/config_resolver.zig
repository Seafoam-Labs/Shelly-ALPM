const std = @import("std");
const Io = std.Io;
const shelly_config = @import("../models/shelly_config.zig");
const ShellyConfig = shelly_config.ShellyConfig;
const ShellyTabs = shelly_config.ShellyTabs;
const ViewType = shelly_config.ViewType;
const xdg_paths = @import("xdg_paths.zig").xdg_paths;

// TODO: Change me to config.json
const settings_path = "shelly/settings.json";

/// Maximum size accepted when reading the settings file (1 MiB).
const max_settings_size: Io.Limit = .limited(1 << 20);

pub const ConfigError = error{
    NotLoaded,
};

pub const ConfigResolver = struct {
    allocator: std.mem.Allocator,
    io: Io,
    config_dir: Io.Dir,
    parsed: ?std.json.Parsed(ShellyConfig),

    pub fn init(
        allocator: std.mem.Allocator,
        io: Io,
        env_map: *const std.process.Environ.Map,
    ) !ConfigResolver {
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

    pub fn initDir(allocator: std.mem.Allocator, io: Io, config_dir: Io.Dir) ConfigResolver {
        return .{
            .allocator = allocator,
            .io = io,
            .config_dir = config_dir,
            .parsed = null,
        };
    }

    pub fn deinit(self: *ConfigResolver) void {
        if (self.parsed) |*p| {
            p.deinit();
            self.parsed = null;
        }
    }

    pub fn load(self: *ConfigResolver) !void {
        if (self.parsed) |*p| {
            p.deinit();
            self.parsed = null;
        }

        const data = self.config_dir.readFileAlloc(
            self.io,
            settings_path,
            self.allocator,
            max_settings_size,
        ) catch |err| switch (err) {
            error.FileNotFound => {
                try self.saveDefault(settings_path);
                self.parsed = try self.parseJsonIntoConfig("{}");
                return;
            },
            else => return err,
        };
        defer self.allocator.free(data);

        self.parsed = try self.parseJsonIntoConfig(data);
    }

    fn parseJsonIntoConfig(self: *ConfigResolver, json: []const u8) !std.json.Parsed(ShellyConfig) {
        const opts: std.json.ParseOptions = .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        };

        var value_parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            json,
            opts,
        );
        defer value_parsed.deinit();

        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();

        const config = parseTolerant(scratch.allocator(), value_parsed.value);

        const normalized = try std.json.Stringify.valueAlloc(self.allocator, config, .{});
        defer self.allocator.free(normalized);

        return std.json.parseFromSlice(ShellyConfig, self.allocator, normalized, opts);
    }

    pub fn save(self: *ConfigResolver) !void {
        if (self.parsed == null) return ConfigError.NotLoaded;

        const dir_name = std.fs.path.dirname(settings_path).?;
        var sub_dir = try self.config_dir.createDirPathOpen(self.io, dir_name, .{});
        defer sub_dir.close(self.io);

        const file = try sub_dir.createFile(self.io, std.fs.path.basename(settings_path), .{});
        defer file.close(self.io);

        var buf: [4096]u8 = undefined;
        var fw = file.writer(self.io, &buf);
        try fw.interface.print("{f}", .{
            std.json.fmt(self.parsed.?.value, .{ .whitespace = .indent_2 }),
        });
        try fw.flush();
    }

    pub fn get(self: *ConfigResolver) !*ShellyConfig {
        if (self.parsed) |*p| {
            return &p.value;
        }
        return ConfigError.NotLoaded;
    }

    pub fn set(self: *ConfigResolver, new_config: ShellyConfig) !void {
        const json = try std.json.Stringify.valueAlloc(self.allocator, new_config, .{});
        defer self.allocator.free(json);
        if (self.parsed) |*p| {
            p.deinit();
        }
        self.parsed = try std.json.parseFromSlice(
            ShellyConfig,
            self.allocator,
            json,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
    }

    pub fn updateField(
        self: *ConfigResolver,
        comptime field: std.meta.FieldEnum(ShellyConfig),
        value: std.meta.fieldInfo(ShellyConfig, field).type,
    ) !void {
        const cfg = try self.get();
        var updated = cfg.*;
        @field(updated, @tagName(field)) = value;
        try self.set(updated);
        try self.save();
    }

    fn saveDefault(self: *ConfigResolver, path: []const u8) !void {
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

fn parseTolerant(allocator: std.mem.Allocator, source: std.json.Value) ShellyConfig {
    var config: ShellyConfig = .{};

    const obj = switch (source) {
        .object => |o| o,
        else => {
            std.log.warn(
                "shelly config: top-level JSON value is not an object; using defaults",
                .{},
            );
            return config;
        },
    };

    inline for (@typeInfo(ShellyConfig).@"struct".fields) |field| {
        if (obj.get(field.name)) |v| {
            if (coerceValue(field.type, allocator, v)) |value| {
                @field(config, field.name) = value;
            } else {
                std.log.warn(
                    "shelly config: ignoring invalid value for '{s}', using default",
                    .{field.name},
                );
            }
        }
    }

    return config;
}

fn coerceValue(
    comptime T: type,
    allocator: std.mem.Allocator,
    v: std.json.Value,
) ?T {
    return switch (@typeInfo(T)) {
        .bool => switch (v) {
            .bool => |b| b,
            else => null,
        },
        .int => switch (v) {
            .integer => |i| std.math.cast(T, i),
            else => null,
        },
        .float => switch (v) {
            .float => |f| @as(T, f),
            .integer => |i| @as(T, @floatFromInt(i)),
            else => null,
        },
        .@"enum" => switch (v) {
            .string => |s| std.meta.stringToEnum(T, s),
            .integer => |i| blk: {
                const tag_count = @typeInfo(T).@"enum".fields.len;
                if (i >= 0 and i < tag_count) {
                    break :blk @enumFromInt(@as(std.meta.Tag(T), @intCast(i)));
                }
                break :blk null;
            },
            else => null,
        },
        .pointer => |p| switch (p.size) {
            .slice => coerceSlice(T, p.child, allocator, v),
            else => null,
        },
        else => null,
    };
}

fn coerceSlice(
    comptime T: type,
    comptime Child: type,
    allocator: std.mem.Allocator,
    v: std.json.Value,
) ?T {
    if (Child == u8) {
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }

    const arr = switch (v) {
        .array => |a| a,
        else => return null,
    };

    const items = allocator.alloc(Child, arr.items.len) catch return null;
    for (arr.items, 0..) |elem, i| {
        items[i] = coerceValue(Child, allocator, elem) orelse return null;
    }
    return items;
}

const testing = std.testing;

fn makeService(tmp: *std.testing.TmpDir) ConfigResolver {
    return ConfigResolver.initDir(testing.allocator, testing.io, tmp.dir);
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

test "load uses defaults for fields with wrong types" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var sub_dir = try tmp.dir.createDirPathOpen(testing.io, "shelly", .{});
        defer sub_dir.close(testing.io);
        const file = try sub_dir.createFile(testing.io, "settings.json", .{});
        defer file.close(testing.io);
        var buf: [256]u8 = undefined;
        var fw = file.writer(testing.io, &buf);
        // `NewInstall` expects a bool but gets a string; `WindowWidth` expects
        // an f64 but gets a bool. Both should fall back to their defaults while
        // the `AurEnabled` is preserved.
        try fw.interface.writeAll(
            \\{"NewInstall":"oops","WindowWidth":true,"AurEnabled":true}
        );
        try fw.flush();
    }

    var svc = makeService(&tmp);
    defer svc.deinit();
    try svc.load();

    const defaults: ShellyConfig = .{};
    const cfg = try svc.get();
    try testing.expectEqual(defaults.NewInstall, cfg.NewInstall);
    try testing.expectEqual(defaults.WindowWidth, cfg.WindowWidth);
    try testing.expectEqual(true, cfg.AurEnabled);
}

test "load uses default for unknown enum tag" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var sub_dir = try tmp.dir.createDirPathOpen(testing.io, "shelly", .{});
        defer sub_dir.close(testing.io);
        const file = try sub_dir.createFile(testing.io, "settings.json", .{});
        defer file.close(testing.io);
        var buf: [256]u8 = undefined;
        var fw = file.writer(testing.io, &buf);
        try fw.interface.writeAll(
            \\{"DefaultPageDropDown":"not_a_real_tab","PackageInstallView":"grid"}
        );
        try fw.flush();
    }

    var svc = makeService(&tmp);
    defer svc.deinit();
    try svc.load();

    const cfg = try svc.get();
    // Unknown tag -> default (.packages); valid tag still resolves.
    try testing.expectEqual(ShellyTabs.packages, cfg.DefaultPageDropDown);
    try testing.expectEqual(ViewType.grid, cfg.PackageInstallView);
}

test "load defaults when top-level JSON is not an object" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var sub_dir = try tmp.dir.createDirPathOpen(testing.io, "shelly", .{});
        defer sub_dir.close(testing.io);
        const file = try sub_dir.createFile(testing.io, "settings.json", .{});
        defer file.close(testing.io);
        var buf: [64]u8 = undefined;
        var fw = file.writer(testing.io, &buf);
        try fw.interface.writeAll(
            \\"just a string"
        );
        try fw.flush();
    }

    var svc = makeService(&tmp);
    defer svc.deinit();
    try svc.load();

    const defaults: ShellyConfig = .{};
    const cfg = try svc.get();
    try testing.expectEqual(defaults.AurEnabled, cfg.AurEnabled);
    try testing.expectEqual(defaults.WindowWidth, cfg.WindowWidth);
}

test "load accepts integer values for f64 fields" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var sub_dir = try tmp.dir.createDirPathOpen(testing.io, "shelly", .{});
        defer sub_dir.close(testing.io);
        const file = try sub_dir.createFile(testing.io, "settings.json", .{});
        defer file.close(testing.io);
        var buf: [128]u8 = undefined;
        var fw = file.writer(testing.io, &buf);
        try fw.interface.writeAll(
            \\{"WindowWidth":1280,"WindowHeight":720}
        );
        try fw.flush();
    }

    var svc = makeService(&tmp);
    defer svc.deinit();
    try svc.load();

    const cfg = try svc.get();
    try testing.expectEqual(@as(f64, 1280), cfg.WindowWidth);
    try testing.expectEqual(@as(f64, 720), cfg.WindowHeight);
}
