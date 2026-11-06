//! One unprivileged session leader per TUI; each operation gets fresh pipes.
//! Descriptor passing keeps authentication, command output and answers separate.
const std = @import("std");
const c = std.c;
const linux = std.os.linux;
const Terminal = @import("sudo_terminal.zig").Terminal;

pub const flag = "--internal-sudo-session";
const max_request = 128 * 1024;
const Rights = extern struct {
    header: c.cmsghdr,
    descriptors: [4]c_int,
};
const Request = struct {
    argv: []const []const u8,
    keys: []const []const u8,
    values: []const []const u8,
};

fn file(fd: c_int) std.Io.File {
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

fn pipe() ![2]c_int {
    var fds: [2]c_int = undefined;
    if (c.pipe2(&fds, .{ .CLOEXEC = true }) != 0) return error.CreateOperationPipe;
    return fds;
}

fn writeNumber(fd: c_int, value: c_int) !void {
    const bytes = std.mem.asBytes(&value);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const len = c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (c.errno(len) == .INTR) continue;
        if (len <= 0) return error.SessionDisconnected;
        offset += @intCast(len);
    }
}

fn readNumber(fd: c_int, cancelled: ?*const std.atomic.Value(bool)) !c_int {
    var value: c_int = undefined;
    const bytes = std.mem.asBytes(&value);
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (cancelled) |state| if (state.load(.acquire)) return error.Cancelled;
        var pollfd: c.pollfd = .{ .fd = fd, .events = c.POLL.IN, .revents = 0 };
        const ready = c.poll(@ptrCast(&pollfd), 1, 50);
        if (c.errno(ready) == .INTR or ready == 0) continue;
        if (ready < 0) return error.SessionDisconnected;
        const len = c.read(fd, bytes.ptr + offset, bytes.len - offset);
        if (c.errno(len) == .INTR) continue;
        if (len <= 0) return error.SessionDisconnected;
        offset += @intCast(len);
    }
    return value;
}

pub const Process = struct {
    id: ?c.pid_t,
    stdin: ?std.Io.File,
    stdout: ?std.Io.File,
    stderr: ?std.Io.File,
    status: ?std.Io.File = null,
    local: ?std.process.Child = null,

    pub fn spawn(io: std.Io, options: std.process.SpawnOptions) !Process {
        var child = try std.process.spawn(io, options);
        var result: Process = .{ .id = child.id, .stdin = child.stdin, .stdout = child.stdout, .stderr = child.stderr };
        child.stdin = null;
        child.stdout = null;
        child.stderr = null;
        result.local = child;
        return result;
    }

    pub fn wait(self: *Process, io: std.Io) !std.process.Child.Term {
        if (self.stdout) |output| output.close(io);
        self.stdout = null;
        if (self.stderr) |output| output.close(io);
        self.stderr = null;
        const term = if (self.local) |*child| try child.wait(io) else blk: {
            const result = try readNumber(self.status.?.handle, null);
            break :blk if (result >= 0 and result <= 255) std.process.Child.Term{ .exited = @intCast(result) } else std.process.Child.Term{ .unknown = 0 };
        };
        self.id = null;
        return term;
    }

    pub fn kill(self: *Process, io: std.Io) void {
        if (self.id) |pid| {
            _ = c.kill(-pid, .KILL);
            _ = self.wait(io) catch {};
        }
        if (self.stdin) |input| input.close(io);
        self.stdin = null;
        if (self.stdout) |output| output.close(io);
        self.stdout = null;
        if (self.stderr) |output| output.close(io);
        self.stderr = null;
        if (self.status) |status| status.close(io);
        self.status = null;
    }
};

pub const Session = struct {
    terminal: ?Terminal = null,
    child: ?std.process.Child = null,
    control: ?c_int = null,
    busy: std.atomic.Value(bool) = .init(false),

    pub fn acquire(self: *Session) !void {
        if (self.busy.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return error.AuthorizationSessionBusy;
    }

    pub fn release(self: *Session) void {
        self.busy.store(false, .release);
    }

    pub fn deinit(self: *Session, io: std.Io) void {
        if (self.control) |fd| _ = c.close(fd);
        self.control = null;
        if (self.child) |*child| child.kill(io);
        self.child = null;
        if (self.terminal) |terminal| terminal.close();
        self.terminal = null;
    }

    pub fn ensure(self: *Session, io: std.Io, executable: []const u8, env: *const std.process.Environ.Map, cancelled: *const std.atomic.Value(bool)) !void {
        if (cancelled.load(.acquire)) return error.Cancelled;
        if (self.child != null) return;
        errdefer self.deinit(io);
        self.terminal = try Terminal.open();
        var sockets: [2]c_int = undefined;
        if (c.socketpair(c.AF.UNIX, c.SOCK.SEQPACKET | c.SOCK.CLOEXEC, 0, &sockets) != 0) return error.CreateSessionChannel;
        self.control = sockets[0];
        defer _ = c.close(sockets[1]);
        var fd_buffer: [32]u8 = undefined;
        const fd_text = try std.fmt.bufPrint(&fd_buffer, "{d}", .{sockets[1]});
        self.child = try std.process.spawn(io, .{
            .argv = &.{ executable, flag, self.terminal.?.name(), fd_text },
            .environ_map = env,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .inherit_files = &.{file(sockets[1])},
        });
        if (try readNumber(self.control.?, cancelled) != 0) return error.StartAuthorizationSession;
    }

    pub fn spawn(self: *Session, io: std.Io, alloc: std.mem.Allocator, argv: []const []const u8, env: *const std.process.Environ.Map, cancelled: *const std.atomic.Value(bool)) !Process {
        if (cancelled.load(.acquire)) return error.Cancelled;
        try self.terminal.?.prepare();
        const input = try pipe();
        defer _ = c.close(input[0]);
        errdefer _ = c.close(input[1]);
        const output = try pipe();
        defer _ = c.close(output[1]);
        errdefer _ = c.close(output[0]);
        const errors = try pipe();
        defer _ = c.close(errors[1]);
        errdefer _ = c.close(errors[0]);
        const status = try pipe();
        defer _ = c.close(status[1]);
        errdefer _ = c.close(status[0]);
        const json = try std.json.Stringify.valueAlloc(alloc, Request{ .argv = argv, .keys = env.keys(), .values = env.values() }, .{});
        defer alloc.free(json);
        if (json.len > max_request) return error.AuthorizationRequestTooLarge;
        var rights: Rights = .{ .header = .{ .len = @sizeOf(Rights), .level = c.SOL.SOCKET, .type = c.SCM.RIGHTS }, .descriptors = .{ input[0], output[1], errors[1], status[1] } };
        const iov: c.iovec_const = .{ .base = json.ptr, .len = json.len };
        const message: c.msghdr_const = .{ .name = null, .namelen = 0, .iov = @ptrCast(&iov), .iovlen = 1, .control = &rights, .controllen = @sizeOf(Rights), .flags = 0 };
        errdefer self.deinit(io);
        while (true) {
            const sent = c.sendmsg(self.control.?, &message, c.MSG.NOSIGNAL);
            if (c.errno(sent) == .INTR) continue;
            if (sent != json.len) return error.SendAuthorizationRequest;
            break;
        }
        // Once submitted, collect the PID even if cancelled, so the caller can
        // kill/reap this exact operation rather than abandoning a running sudo.
        const pid = try readNumber(self.control.?, null);
        if (pid <= 0) return error.StartAuthorizedOperation;
        return .{ .id = pid, .stdin = file(input[1]), .stdout = file(output[0]), .stderr = file(errors[0]), .status = file(status[0]) };
    }
};

fn ignoreSignal(signal: c.SIG) !void {
    var action: c.Sigaction = std.mem.zeroes(c.Sigaction);
    action.handler.handler = c.SIG.IGN;
    if (c.sigaction(signal, &action, null) != 0) return error.SessionSignalSetup;
}

test "authorization session rejects overlapping operations" {
    var session: Session = .{};
    try session.acquire();
    try std.testing.expectError(error.AuthorizationSessionBusy, session.acquire());
    session.release();
    try session.acquire();
    session.release();
}

/// Fresh unprivileged process. It owns the controlling terminal until TUI exit.
pub fn launch(init: std.process.Init, args: []const []const u8) !void {
    if (args.len != 4) return error.InvalidSessionArguments;
    const control = try std.fmt.parseInt(c_int, args[3], 10);
    if (control < 3) return error.InvalidSessionArguments;
    defer _ = c.close(control);
    if (c.fcntl(control, c.F.SETFD, @as(c_int, linux.FD_CLOEXEC)) < 0) return error.SessionChannelFlags;
    const path = try init.arena.allocator().allocSentinel(u8, args[2].len, 0);
    @memcpy(path, args[2]);
    const terminal = try @import("sudo_terminal.zig").claim(path);
    defer _ = c.close(terminal);
    try ignoreSignal(.TTOU);
    try ignoreSignal(.PIPE);
    try writeNumber(control, 0);
    while (true) {
        var arena: std.heap.ArenaAllocator = .init(init.gpa);
        defer arena.deinit();
        const alloc = arena.allocator();
        const buffer = try alloc.alloc(u8, max_request);
        var rights: Rights = .{ .header = std.mem.zeroes(c.cmsghdr), .descriptors = @splat(-1) };
        var iov: c.iovec = .{ .base = buffer.ptr, .len = buffer.len };
        var message: c.msghdr = .{ .name = null, .namelen = 0, .iov = @ptrCast(&iov), .iovlen = 1, .control = &rights, .controllen = @sizeOf(Rights), .flags = 0 };
        const len = while (true) {
            const received = c.recvmsg(control, &message, c.MSG.CMSG_CLOEXEC);
            if (c.errno(received) == .INTR) continue;
            break received;
        };
        defer for (rights.descriptors) |fd| {
            if (fd >= 0) _ = c.close(fd);
        };
        if (len == 0) return;
        if (len < 0 or message.flags & (c.MSG.TRUNC | c.MSG.CTRUNC) != 0 or rights.header.level != c.SOL.SOCKET or rights.header.type != c.SCM.RIGHTS or rights.header.len != @sizeOf(Rights)) return error.InvalidSessionRequest;
        for (rights.descriptors) |fd| if (fd < 0) return error.InvalidSessionRequest;
        const request = try std.json.parseFromSlice(Request, alloc, buffer[0..@intCast(len)], .{});
        if (request.value.argv.len == 0 or request.value.keys.len != request.value.values.len) return error.InvalidSessionRequest;
        var env: std.process.Environ.Map = .init(alloc);
        defer env.deinit();
        for (request.value.keys, request.value.values) |key, value| try env.put(key, value);
        _ = env.swapRemove("SUDO_ASKPASS");
        _ = env.swapRemove("SHELLY_TUI_ASKPASS_SOCKET");
        var child = std.process.spawn(init.io, .{
            .argv = request.value.argv,
            .environ_map = &env,
            .stdin = .{ .file = file(rights.descriptors[0]) },
            .stdout = .{ .file = file(rights.descriptors[1]) },
            .stderr = .{ .file = file(rights.descriptors[2]) },
            .pgid = 0,
        }) catch {
            try writeNumber(control, -1);
            continue;
        };
        defer child.kill(init.io);
        var pid = child.id.?;
        if (linux.tcsetpgrp(terminal, &pid) != 0) return error.SessionForegroundProcess;
        _ = c.kill(pid, .CONT);
        try writeNumber(control, pid);
        const term = try child.wait(init.io);
        var supervisor = linux.getpid();
        if (linux.tcsetpgrp(terminal, &supervisor) != 0) return error.SessionForegroundProcess;
        try writeNumber(rights.descriptors[3], if (term == .exited) @as(c_int, term.exited) else -1);
    }
}
