const std = @import("std");
const xdg_paths = @import("xdg_paths.zig").xdg_paths;

/// Shared by read-only queries and transaction workers. Debug builds use the
/// checkout CLI; release builds resolve Shelly through PATH.
pub fn shellyBin() []const u8 {
    return @import("cli_options").binary;
}
pub var terminal: ?*@import("vaxis").vxfw.App = null;

pub fn supportsImages() bool {
    return if (terminal) |app| app.vx.caps.kitty_graphics else false;
}

pub var io: std.Io = undefined;
pub var environ_map: *std.process.Environ.Map = undefined;
pub var data_home: []const u8 = "";

pub fn setup(init: std.process.Init) void {
    @import("ShellyHttp").setDefaultProxyEnvironment(init.environ_map);
    io = init.io;
    environ_map = init.environ_map;
    data_home = xdg_paths.xdgDataHome(init.arena.allocator(), init.environ_map) catch "";
}
