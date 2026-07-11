const std = @import("std");

pub const InitError = error{};

pub fn init(init_path: []const u8) InitError!void {
    _ = init_path;

    return;
}
