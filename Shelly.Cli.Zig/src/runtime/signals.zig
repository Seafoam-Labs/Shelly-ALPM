const std = @import("std");
const builtin = @import("builtin");

pub fn installInterruptHandler() void {
    if (builtin.os.tag != .linux) return;
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = handleInterrupt },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &action, null);
}

fn handleInterrupt(_: std.posix.SIG) callconv(.c) void {
    const message = "\nOperation Cancelled...Exiting\n";
    _ = std.os.linux.write(std.posix.STDOUT_FILENO, message.ptr, message.len);
    std.os.linux.exit_group(130);
}
