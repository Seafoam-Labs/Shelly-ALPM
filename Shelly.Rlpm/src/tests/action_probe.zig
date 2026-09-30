//! Fixture executable copied into a disposable root. No package services.
const std = @import("std");

const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("fcntl.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("signal.h");
});

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "environment")) {
        var cwd: [4096]u8 = undefined;
        if (c.getcwd(&cwd, cwd.len) == null or !std.mem.eql(u8, std.mem.sliceTo(&cwd, 0), "/"))
            return error.WrongCwd;
        if (c.getenv("BASH_ENV") != null) return error.UnsafeEnvironment;
        const level = c.getenv("SHLVL") orelse return error.MissingShellLevel;
        if (!std.mem.eql(u8, std.mem.span(level), "7")) return error.WrongShellLevel;
        // The parent holds a deliberately non-CLOEXEC descriptor at 200.
        if (c.fcntl(200, c.F_GETFD) >= 0) return error.InheritedDescriptor;
        if (c.umask(0o022) != 0o022) return error.WrongUmask;
        _ = c.write(1, "environment-ok\n", 15);
        _ = c.write(2, "stderr-ok", 9);
    } else if (args.len == 3 and std.mem.eql(u8, args[1], "network")) {
        const socket = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
        if (socket < 0) return error.SocketFailed;
        defer _ = c.close(socket);
        var address: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
        address.sin_family = c.AF_INET;
        address.sin_port = std.mem.nativeToBig(u16, try std.fmt.parseInt(u16, args[2], 10));
        address.sin_addr.s_addr = std.mem.nativeToBig(u32, 0x7f000001);
        const connected = c.connect(socket, @ptrCast(&address), @sizeOf(@TypeOf(address))) == 0;
        const output: []const u8 = if (connected) "connected\n" else "isolated\n";
        _ = c.write(1, output.ptr, output.len);
    } else return error.InvalidArguments;
}
