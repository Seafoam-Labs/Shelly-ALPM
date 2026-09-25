const std = @import("std");
const ConfigResolver = @import("ui_config_resolver.zig").ConfigResolver;
const cli_config_resolver = @import("cli_config_resolver.zig");
const xdg_paths = @import("xdg_paths.zig");
const deep_link = @import("../helpers/deep_link.zig");

// src/shellpers/runtime.zig
pub var io: std.Io = undefined;
pub var environ_map: *std.process.Environ.Map = undefined;
pub var data_home: []const u8 = "";

pub const PendingLocalFile = struct {
    buffer: [deep_link.max_file_path_len + 1]u8,
    len: usize,

    pub fn path(self: *const PendingLocalFile) [:0]const u8 {
        return self.buffer[0..self.len :0];
    }
};

pub const PendingApp = struct {
    buffer: [deep_link.max_app_id_len + 1]u8,
    len: usize,

    pub fn id(self: *const PendingApp) [:0]const u8 {
        return self.buffer[0..self.len :0];
    }
};

pub const PendingNavigation = union(enum) {
    page: deep_link.PageTarget,
    flatpak_app: PendingApp,
    local_flatpak_file: PendingLocalFile,
};

pub var pending_navigation: ?PendingNavigation = null;

pub fn queuePage(target: deep_link.PageTarget) void {
    pending_navigation = .{ .page = target };
}

pub fn queueFlatpakApp(app_id: []const u8) void {
    var pending: PendingApp = undefined;
    if (app_id.len > deep_link.max_app_id_len) return;
    @memcpy(pending.buffer[0..app_id.len], app_id);
    pending.buffer[app_id.len] = 0;
    pending.len = app_id.len;

    pending_navigation = .{ .flatpak_app = pending };
}

pub fn queueLocalFlatpakPath(path: []const u8) void {
    if (path.len == 0 or path.len > deep_link.max_file_path_len) return;
    var pending: PendingLocalFile = undefined;
    @memcpy(pending.buffer[0..path.len], path);
    pending.buffer[path.len] = 0;
    pending.len = path.len;
    pending_navigation = .{ .local_flatpak_file = pending };
}

pub fn takePendingNavigation() ?PendingNavigation {
    const pending = pending_navigation;
    pending_navigation = null;
    return pending;
}

pub var config: ?*ConfigResolver = null;

pub fn setup(init: std.process.Init) void {
    io = init.io;
    environ_map = init.environ_map;
    data_home = xdg_paths.xdgDataHome(init.arena.allocator(), init.environ_map) catch "";
}

pub fn setupConfig(allocator: std.mem.Allocator) !*ConfigResolver {
    if (config) |existing| return existing;

    const svc = try allocator.create(ConfigResolver);
    errdefer allocator.destroy(svc);

    svc.* = try ConfigResolver.init(allocator, io, environ_map);
    try svc.load();

    migrateLegacyAppImageInstallPath(allocator);

    config = svc;
    return svc;
}

fn migrateLegacyAppImageInstallPath(allocator: std.mem.Allocator) void {
    var resolver = cli_config_resolver.CliConfigResolver.init(allocator, io, environ_map) catch |err| {
        std.log.warn("Could not read the CLI settings during AppImage settings migration. {0s}\n\nTechnical details: {1s}", .{ @import("diagnostics").cause(err), @errorName(err) });
        return;
    };
    defer resolver.deinit();
    resolver.migrateLegacyInstallPath();
}

pub fn teardownConfig(allocator: std.mem.Allocator) void {
    if (config) |svc| {
        svc.deinit();
        allocator.destroy(svc);
        config = null;
    }
}
