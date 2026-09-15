const std = @import("std");
const xdg_paths = @import("services/xdg_paths.zig");

// src/shellpers/runtime.zig
pub var io: std.Io = undefined;
pub var environ_map: *std.process.Environ.Map = undefined;
pub var data_home: []const u8 = "";
pub var allocator: std.mem.Allocator = undefined;

pub var wake_gen: std.atomic.Value(u32) = .init(0);

pub fn setup(init: std.process.Init) void {
    io = init.io;
    environ_map = init.environ_map;
    allocator = init.arena.allocator();
    data_home = xdg_paths.xdgDataHome(init.arena.allocator(), init.environ_map) catch "";
}

pub fn wakeWorker() void {
    _ = wake_gen.fetchAdd(1, .release);

    io.futexWake(u32, &wake_gen.raw, 1);
}
