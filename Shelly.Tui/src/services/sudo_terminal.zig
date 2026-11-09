//! Private controlling terminal. Standard streams remain protocol pipes.
const std = @import("std");
const c = std.c;
const linux = std.os.linux;

// These libc entry points are not currently declared by std.c.
const pty = struct {
    extern "c" fn posix_openpt(flags: c.O) c_int;
    extern "c" fn grantpt(fd: c_int) c_int;
    extern "c" fn unlockpt(fd: c_int) c_int;
    extern "c" fn ptsname_r(fd: c_int, path: [*]u8, capacity: usize) c_int;
};

pub const Terminal = struct {
    master: c_int,
    slave: c_int,
    path: [128]u8 = undefined,
    modes: linux.termios = std.mem.zeroes(linux.termios),

    pub fn open() !Terminal {
        const master = pty.posix_openpt(.{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true, .NONBLOCK = true });
        if (master < 0) return error.OpenPrivateTerminal;
        errdefer _ = c.close(master);
        if (pty.grantpt(master) != 0 or pty.unlockpt(master) != 0) return error.OpenPrivateTerminal;
        var result: Terminal = .{ .master = master, .slave = -1 };
        if (pty.ptsname_r(master, &result.path, result.path.len) != 0) return error.OpenPrivateTerminal;
        result.slave = c.open(@ptrCast(&result.path), .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true });
        if (result.slave < 0) return error.OpenPrivateTerminal;
        errdefer _ = c.close(result.slave);

        var modes: linux.termios = std.mem.zeroes(linux.termios);
        if (linux.tcgetattr(result.slave, &modes) != 0) return error.OpenPrivateTerminal;
        modes.lflag.ECHO = false;
        modes.lflag.ECHONL = false;
        if (linux.tcsetattr(result.slave, .NOW, &modes) != 0) return error.OpenPrivateTerminal;
        result.modes = modes;

        var size: std.posix.winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
        var actual: std.posix.winsize = undefined;
        if (linux.ioctl(std.posix.STDIN_FILENO, linux.T.IOCGWINSZ, @intFromPtr(&actual)) == 0 and actual.row != 0 and actual.col != 0) size = actual;
        if (linux.ioctl(result.slave, linux.T.IOCSWINSZ, @intFromPtr(&size)) != 0) return error.OpenPrivateTerminal;
        return result;
    }

    pub fn close(self: Terminal) void {
        _ = c.close(self.slave);
        _ = c.close(self.master);
    }

    pub fn prepare(self: Terminal) !void {
        // Each operation starts with hidden, canonical input and no credentials
        // or output left queued by the preceding operation.
        if (linux.tcsetattr(self.slave, .NOW, &self.modes) != 0) return error.PreparePrivateTerminal;
        // Linux TCFLSH/TCIOFLUSH also clears pending line-discipline buffers;
        // TCSETSF alone can leave recently submitted PTY input in flight.
        if (linux.ioctl(self.slave, linux.T.CFLSH, 2) != 0) return error.PreparePrivateTerminal;
        var buffer: [512]u8 = undefined;
        defer std.crypto.secureZero(u8, &buffer);
        var drained: usize = 0;
        while (drained < 64 * 1024) {
            const len = c.read(self.master, &buffer, buffer.len);
            if (c.errno(len) == .INTR) continue;
            if (len <= 0) return;
            drained += @intCast(len);
        }
        return error.PrivateTerminalStillProducingOutput;
    }

    pub fn name(self: *const Terminal) []const u8 {
        return std.mem.sliceTo(&self.path, 0);
    }

    pub fn write(self: Terminal, bytes: []const u8) !void {
        // Never submit credentials if another program has enabled echo.
        var modes: linux.termios = std.mem.zeroes(linux.termios);
        if (linux.tcgetattr(self.master, &modes) != 0 or modes.lflag.ECHO or modes.lflag.ECHONL) return error.TerminalInputFailed;
        while (true) {
            const len = c.write(self.master, bytes.ptr, bytes.len);
            if (c.errno(len) == .INTR) continue;
            if (len < 0 or @as(usize, @intCast(len)) != bytes.len) return error.TerminalInputFailed;
            return;
        }
    }

    pub fn read(self: Terminal, buffer: []u8) usize {
        var fd: c.pollfd = .{ .fd = self.master, .events = c.POLL.IN, .revents = 0 };
        while (true) {
            const result = c.poll(@ptrCast(&fd), 1, 50);
            if (c.errno(result) == .INTR) continue;
            if (result <= 0) return 0;
            break;
        }
        while (true) {
            const len = c.read(self.master, buffer.ptr, buffer.len);
            if (c.errno(len) == .INTR) continue;
            return if (len > 0) @intCast(len) else 0;
        }
    }
};

/// Called only by the fresh, unprivileged session supervisor.
pub fn claim(path: [:0]const u8) !c_int {
    if (!std.mem.startsWith(u8, path, "/dev/pts/")) return error.InvalidTerminalArguments;
    if (c.getuid() != c.geteuid() or c.getgid() != c.getegid()) return error.SetPrivateTerminal;
    if (c.setsid() < 0) return error.SetPrivateTerminal;
    const slave = c.open(path, .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true });
    if (slave < 0) return error.SetPrivateTerminal;
    errdefer _ = c.close(slave);
    if (linux.ioctl(slave, linux.T.IOCSCTTY, 0) != 0) return error.SetPrivateTerminal;
    return slave;
}

test "private terminal disables echo and accepts input independently" {
    const terminal = try Terminal.open();
    defer terminal.close();
    try std.testing.expect(std.mem.startsWith(u8, terminal.name(), "/dev/pts/"));
    try terminal.write("secret\n");
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), terminal.read(&buffer));
    const len = c.read(terminal.slave, &buffer, buffer.len);
    defer std.crypto.secureZero(u8, &buffer);
    try std.testing.expectEqualStrings("secret\n", buffer[0..@intCast(len)]);
}

test "private terminal refuses input when echo is enabled" {
    const terminal = try Terminal.open();
    defer terminal.close();
    var modes: linux.termios = std.mem.zeroes(linux.termios);
    try std.testing.expectEqual(@as(usize, 0), linux.tcgetattr(terminal.slave, &modes));
    try std.testing.expect(!modes.lflag.ECHO and !modes.lflag.ECHONL);
    modes.lflag.ECHO = true;
    try std.testing.expectEqual(@as(usize, 0), linux.tcsetattr(terminal.slave, .NOW, &modes));
    try std.testing.expectError(error.TerminalInputFailed, terminal.write("secret\n"));
    modes.lflag.ECHO = false;
    modes.lflag.ECHONL = true;
    try std.testing.expectEqual(@as(usize, 0), linux.tcsetattr(terminal.slave, .NOW, &modes));
    try std.testing.expectError(error.TerminalInputFailed, terminal.write("secret\n"));
}

test "reused terminal restores hidden input and discards queued credentials" {
    const terminal = try Terminal.open();
    defer terminal.close();
    try terminal.write("stale\n");
    var modes = terminal.modes;
    modes.lflag.ECHO = true;
    try std.testing.expectEqual(@as(usize, 0), linux.tcsetattr(terminal.slave, .NOW, &modes));
    try terminal.prepare();
    try terminal.write("fresh\n");
    var buffer: [64]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    const len = c.read(terminal.slave, &buffer, buffer.len);
    try std.testing.expect(len > 0);
    try std.testing.expectEqualStrings("fresh\n", buffer[0..@intCast(len)]);
    try std.testing.expectEqual(@as(usize, 0), terminal.read(&buffer));
}
