const std = @import("std");

pub inline fn convertInteger(comptime T: type, x: T, endianess: std.builtin.Endian) [@sizeOf(@TypeOf(x))]u8 {
    comptime switch (@typeInfo(T)) {
        .int => {},
        else => @compileError("convertInteger expects an integer type"),
    };
    return std.mem.toBytes(std.mem.nativeTo(T, x, endianess));
}

pub inline fn readInteger(comptime T: type, data: *const [4]u8, endianess: std.builtin.Endian) T {
    std.debug.print("data = {any}\n", .{data});
    return switch (endianess) {
        .little => std.mem.littleToNative(T, std.mem.bytesToValue(T, data)),
        .big => std.mem.bigToNative(T, std.mem.bytesToValue(T, data)),
    };
}
