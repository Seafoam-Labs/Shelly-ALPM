const std = @import("std");

pub const InitError = error{};

pub fn init(allocator: std.mem.Allocator, io: std.Io, init_path: []const u8) InitError!void {
    _ = allocator;
    _ = io;
    _ = init_path;

    return;
}
