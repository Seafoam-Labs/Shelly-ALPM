const std = @import("std");
const Io = std.Io;
const shelly_config = @import("../models/shelly_config.zig");
const ShellyConfig = shelly_config.ShellyConfig;
const ShellyTabs = shelly_config.ShellyTabs;
const ViewType = shelly_config.ViewType;
const xdg_paths = @import("xdg_paths.zig").xdg_paths;

const log = std.log.scoped(.config);

const settings_path = "shelly/settings.json";

const corrupt_settings_path = settings_path ++ ".corrupt";

const kept_corrupt_note: []const u8 = " A copy was kept as " ++ corrupt_settings_path ++ ".";

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

        self.parsed = self.parseJsonIntoConfig(data) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                self.recoverFromUnreadableSettings(err);
                self.parsed = try self.parseJsonIntoConfig("{}");
                return;
            },
        };
    }

    /// An unreadable file is replaced by the defaults, and kept aside first when
    /// possible, so a truncated or hand-edited file cannot leave the tray
    /// unable to start. Without this the reconnect loop retries the same
    /// failure forever. A repair that cannot be written is only reported,
    /// because the defaults already in memory are enough to run on.
    fn recoverFromUnreadableSettings(self: *ConfigResolver, json_error: anyerror) void {
        var kept_copy = true;
        self.config_dir.rename(
            settings_path,
            self.config_dir,
            corrupt_settings_path,
            self.io,
        ) catch |err| {
            kept_copy = false;
            log.warn("Could not keep a copy of the unreadable settings file. {0s}\n\nTechnical details: {1s}", .{ @import("diagnostics").cause(err), @errorName(err) });
        };

        var repaired = true;
        self.saveDefault(settings_path) catch |err| {
            repaired = false;
            log.warn("Could not write the default settings file. {0s}\n\nTechnical details: {1s}", .{ @import("diagnostics").cause(err), @errorName(err) });
        };

        const outcome: []const u8 = if (repaired)
            "the settings were reset to their defaults"
        else
            "the defaults apply to this session only";
        log.warn(
            "The settings file was not readable as JSON, so {0s}.{1s}\n\nTechnical details: {2s}",
            .{
                outcome,
                if (kept_copy) kept_corrupt_note else "",
                @errorName(json_error),
            },
        );
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
        try self.writeJson(settings_path, self.parsed.?.value);
    }

    /// Stages the payload in a sibling file and renames it into place, so an
    /// interrupted write can never leave the settings file empty or half
    /// written. The sync is what keeps a power loss from committing an empty
    /// rename over the previous contents.
    fn writeJson(self: *ConfigResolver, path: []const u8, value: anytype) !void {
        var staged = try self.config_dir.createFileAtomic(self.io, path, .{
            .make_path = true,
            .replace = true,
        });
        defer staged.deinit(self.io);

        var buf: [4096]u8 = undefined;
        var fw = staged.file.writer(self.io, &buf);
        try fw.interface.print("{f}", .{
            std.json.fmt(value, .{ .whitespace = .indent_2 }),
        });
        try fw.flush();
        try staged.file.sync(self.io);
        try staged.replace(self.io);
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
        try self.writeJson(path, ShellyConfig{});
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

const testing = std.testing;

fn makeService(tmp: *std.testing.TmpDir) ConfigResolver {
    return ConfigResolver.initDir(testing.allocator, testing.io, tmp.dir);
}

fn seedSettings(tmp: *std.testing.TmpDir, contents: []const u8) !void {
    var sub_dir = tmp.dir.createDirPathOpen(testing.io, "shelly", .{}) catch |err| switch (err) {
        error.PathAlreadyExists => try tmp.dir.openDir(testing.io, "shelly", .{}),
        else => return err,
    };
    defer sub_dir.close(testing.io);

    const file = try sub_dir.createFile(testing.io, "settings.json", .{ .truncate = true });
    defer file.close(testing.io);

    var buf: [256]u8 = undefined;
    var fw = file.writer(testing.io, &buf);
    try fw.interface.writeAll(contents);
    try fw.flush();
}

fn readSeedFile(tmp: *std.testing.TmpDir, path: []const u8) ![]u8 {
    return tmp.dir.readFileAlloc(testing.io, path, testing.allocator, max_settings_size);
}

test "load falls back to defaults for an empty settings file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try seedSettings(&tmp, "");

    var svc = makeService(&tmp);
    defer svc.deinit();
    try svc.load();

    const cfg = try svc.get();
    try testing.expectEqual(@as(u32, 72), cfg.TrayCheckIntervalHours);
    try testing.expectEqual(false, cfg.TrayEnabled);

    // The empty file is kept aside and replaced, so the next start reads defaults.
    const kept = try readSeedFile(&tmp, corrupt_settings_path);
    defer testing.allocator.free(kept);
    try testing.expectEqual(@as(usize, 0), kept.len);

    const rewritten = try readSeedFile(&tmp, settings_path);
    defer testing.allocator.free(rewritten);
    try testing.expect(std.mem.indexOf(u8, rewritten, "\"TrayCheckIntervalHours\"") != null);
}

test "load falls back to defaults for unreadable JSON" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try seedSettings(&tmp, "{\"TrayEnabled\":tru");

    var svc = makeService(&tmp);
    defer svc.deinit();
    try svc.load();

    const cfg = try svc.get();
    try testing.expectEqual(@as(u32, 72), cfg.TrayCheckIntervalHours);

    const kept = try readSeedFile(&tmp, corrupt_settings_path);
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings("{\"TrayEnabled\":tru", kept);
}

test "load leaves a readable settings file alone" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try seedSettings(&tmp, "{\"TrayEnabled\":true,\"TrayCheckIntervalHours\":6}");

    var svc = makeService(&tmp);
    defer svc.deinit();
    try svc.load();

    const cfg = try svc.get();
    try testing.expectEqual(true, cfg.TrayEnabled);
    try testing.expectEqual(@as(u32, 6), cfg.TrayCheckIntervalHours);

    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access(testing.io, corrupt_settings_path, .{}),
    );
}

test "reload recovers from a file emptied since startup" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try seedSettings(&tmp, "{\"TrayCheckIntervalHours\":6}");

    var svc = makeService(&tmp);
    defer svc.deinit();
    try svc.load();

    try seedSettings(&tmp, "");
    try svc.reload();

    const cfg = try svc.get();
    try testing.expectEqual(@as(u32, 72), cfg.TrayCheckIntervalHours);
    try testing.expect(svc.dirty.load(.seq_cst));
}

test "save leaves no staging files beside the settings file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var svc = makeService(&tmp);
    defer svc.deinit();
    try svc.load();

    try svc.updateField(.TrayCheckIntervalHours, @as(u32, 12));

    var sub_dir = try tmp.dir.openDir(testing.io, "shelly", .{ .iterate = true });
    defer sub_dir.close(testing.io);

    var saw_settings = false;
    var others: usize = 0;
    var it = sub_dir.iterate();
    while (try it.next(testing.io)) |entry| {
        if (std.mem.eql(u8, entry.name, "settings.json")) {
            saw_settings = true;
        } else {
            others += 1;
        }
    }
    try testing.expect(saw_settings);
    try testing.expectEqual(@as(usize, 0), others);
}
