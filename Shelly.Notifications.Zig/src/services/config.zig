const std = @import("std");
const Io = std.Io;
const shelly_config = @import("../models/shelly_config.zig");
const ShellyConfig = shelly_config.ShellyConfig;
const ShellyTabs = shelly_config.ShellyTabs;
const ViewType = shelly_config.ViewType;
const xdg_paths = @import("xdg_paths.zig").xdg_paths;

const log = std.log.scoped(.config);

const settings_path = "shelly/settings.json";

const max_settings_size: Io.Limit = .limited(1 << 20);

pub const ConfigError = error{
    NotLoaded,
};

pub const ConfigResolver = struct {
    allocator: std.mem.Allocator,
    io: Io,
    config_dir: Io.Dir,
    parsed: ?std.json.Parsed(ShellyConfig),
    mutex: std.Io.Mutex = .init,
    dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    settings_dir_abs: ?[]const u8 = null,

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

        const rel_dir = std.fs.path.dirname(settings_path).?;
        const abs_dir = try std.fs.path.join(allocator, &.{ home_path, rel_dir });

        return .{
            .allocator = allocator,
            .io = io,
            .config_dir = config_dir,
            .parsed = null,
            .settings_dir_abs = abs_dir,
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
        if (self.settings_dir_abs) |d| {
            self.allocator.free(d);
            self.settings_dir_abs = null;
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

    pub fn reload(self: *ConfigResolver) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.load();
        self.dirty.store(true, .seq_cst);
    }

    pub fn fileHash(self: *const ConfigResolver) ?u64 {
        const data = self.config_dir.readFileAlloc(
            self.io,
            settings_path,
            self.allocator,
            max_settings_size,
        ) catch return null;
        defer self.allocator.free(data);
        return std.hash.Wyhash.hash(0, data);
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

    pub fn get(self: *const ConfigResolver) !*const ShellyConfig {
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
            // TODO: Change to warn after https://codeberg.org/ziglang/zig/issues/35189
            log.info(
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
                // TODO: Change to warn after https://codeberg.org/ziglang/zig/issues/35189
                log.info(
                    "Ignored invalid value for setting '{0f}' in the selected path; using the default. Expected the documented values.",
                    .{@import("diagnostics").safe(field.name)},
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
