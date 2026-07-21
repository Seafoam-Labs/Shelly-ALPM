const std = @import("std");
const ConfigResolver = @import("config_resolver.zig").ConfigResolver;
const xdg_paths = @import("xdg_paths.zig");

// src/shellpers/runtime.zig
pub var io: std.Io = undefined;
pub var environ_map: *std.process.Environ.Map = undefined;
pub var data_home: []const u8 = "";

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

    config = svc;
    return svc;
}

pub fn teardownConfig(allocator: std.mem.Allocator) void {
    if (config) |svc| {
        svc.deinit();
        allocator.destroy(svc);
        config = null;
    }
}
