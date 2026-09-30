//! Duplex native Zig action transport. No changes to the parent's credentials,
//! cwd, umask, environment, signals, or network. Cancellation kills/reaps the
//! process group, including children still holding the output pipe open.
const std = @import("std");
const protocol = @import("action_protocol");
const Root = @import("RootPath.zig");
const Owner = @import("Owner.zig");
const Workers = @import("workers");

const c = protocol.c;
pub const Result = protocol.Result;
pub const Network = protocol.Network;
pub const Failure = protocol.Failure;

pub const Request = struct {
    root: *const Root,
    argv: []const []const u8,
    command: ?[]const u8 = null,
    stdin: []const u8 = "",
    network: Network = .required,
};

fn nonblock(fd: c_int) !void {
    const flags = c.fcntl(fd, c.F_GETFL);
    if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) < 0)
        return error.ActionTransportFailed;
}

const Lines = struct {
    bytes: [2048]u8 = undefined,
    len: usize = 0,

    fn flush(self: *Lines, owner: *Owner) void {
        if (self.len == 0) return;
        if (self.bytes[self.len - 1] != '\n') {
            self.bytes[self.len] = '\n';
            self.len += 1;
        }
        owner.transactionEvent(.{ .scriptlet_output = self.bytes[0..self.len] });
        self.len = 0;
    }

    fn append(self: *Lines, owner: *Owner, input: []const u8) void {
        for (input) |byte| {
            self.bytes[self.len] = byte;
            self.len += 1;
            if (byte == '\n' or self.len == 2046) self.flush(owner);
        }
    }
};

pub fn run(owner: *Owner, io: std.Io, request: Request) !Result {
    try owner.checkCancelled();
    if (request.argv.len == 0) return error.InvalidHookCommand;
    var configured = try Root.init(owner.configuration.root);
    defer configured.deinit();
    const held_state = try Root.state(request.root.fd);
    const configured_state = try Root.state(configured.fd);
    if (held_state.device != configured_state.device or held_state.inode != configured_state.inode or
        held_state.mount_id != configured_state.mount_id)
        return error.StaleFilesystemState;
    var arena = std.heap.ArenaAllocator.init(owner.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const payload = try std.json.Stringify.valueAlloc(
        a,
        protocol.Request{
            .root_descriptor = try std.fmt.allocPrint(a, "/proc/{d}/fd/{d}", .{ c.getpid(), request.root.fd }),
            .chroot = !std.mem.eql(u8, owner.configuration.root, "/"),
            .command = request.command orelse request.argv[0],
            .argv = request.argv,
            .network = if (owner.configuration.sandbox.disable_network) .allowed else request.network,
        },
        .{},
    );
    if (payload.len > protocol.maximum_request) return error.ActionRequestTooLarge;
    const input = try a.alloc(u8, 4 + payload.len + request.stdin.len);
    std.mem.writeInt(u32, input[0..4], @intCast(payload.len), .little);
    @memcpy(input[4..][0..payload.len], payload);
    @memcpy(input[4 + payload.len ..], request.stdin);
    var sockets: [2]c_int = undefined;
    if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0, &sockets) != 0)
        return error.ActionTransportFailed;
    defer _ = c.close(sockets[0]);
    var child_socket_open = true;
    defer if (child_socket_open) {
        _ = c.close(sockets[1]);
    };
    var child = try std.process.spawn(io, .{
        .argv = &.{ owner.configuration.worker_executable orelse Workers.self_executable, Workers.action_argument },
        .stdin = .{ .file = .{ .handle = sockets[1], .flags = .{ .nonblocking = false } } },
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    });
    const pid = child.id.?;
    defer if (child.id != null) {
        _ = c.kill(-pid, c.SIGKILL);
        child.kill(io);
    };
    _ = c.close(sockets[1]);
    child_socket_open = false;
    const pidfd: c_int = @intCast(c.syscall(c.SYS_pidfd_open, pid, @as(c_uint, 0)));
    if (pidfd < 0) return error.ActionTransportFailed;
    defer _ = c.close(pidfd);
    try nonblock(sockets[0]);
    try nonblock(child.stdout.?.handle);
    try nonblock(child.stderr.?.handle);
    var fds = [_]c.struct_pollfd{
        .{
            .fd = sockets[0],
            .events = c.POLLOUT,
            .revents = 0,
        },
        .{
            .fd = child.stdout.?.handle,
            .events = c.POLLIN,
            .revents = 0,
        },
        .{
            .fd = child.stderr.?.handle,
            .events = c.POLLIN,
            .revents = 0,
        },
        .{
            .fd = pidfd,
            .events = c.POLLIN,
            .revents = 0,
        },
    };
    var offset: usize = 0;
    var reports: [8]u8 = undefined;
    var report_len: usize = 0;
    var result: Result = .{ .term = .{ .unknown = 0 } };
    var lines: Lines = .{};
    var exited = false;
    while (!exited or fds[1].fd >= 0 or fds[2].fd >= 0) {
        try owner.checkCancelled();
        const ready = c.poll(&fds, fds.len, 100);
        if (ready < 0) {
            if (std.c._errno().* == c.EINTR) continue;
            return error.ActionTransportFailed;
        }
        if (fds[3].revents != 0) {
            exited = true;
            fds[3].fd = -1;
        }
        if (fds[0].fd >= 0 and fds[0].revents != 0) {
            const count = c.send(sockets[0], input[offset..].ptr, input.len - offset, c.MSG_NOSIGNAL);
            if (count > 0)
                offset += @intCast(count)
            else if (count < 0 and std.c._errno().* != c.EAGAIN and
                std.c._errno().* != c.EINTR)
                offset = input.len;
            if (offset == input.len) {
                _ = c.shutdown(sockets[0], c.SHUT_WR);
                fds[0].fd = -1;
            }
        }
        for (1..3) |index| {
            if (fds[index].fd < 0 or fds[index].revents == 0) continue;
            var buffer: [4096]u8 = undefined;
            const count = c.read(fds[index].fd, &buffer, buffer.len);
            if (count < 0) {
                if (std.c._errno().* == c.EAGAIN or std.c._errno().* == c.EINTR) continue;
                return error.ActionTransportFailed;
            }
            if (count == 0) {
                fds[index].fd = -1;
                continue;
            }
            if (index == 1)
                lines.append(owner, buffer[0..@intCast(count)])
            else for (buffer[0..@intCast(count)]) |byte| {
                reports[report_len] = byte;
                report_len += 1;
                if (report_len == 8) {
                    const stage = std.enums.fromInt(protocol.Stage, reports[0]) orelse
                        return error.ActionProtocolFailed;
                    const errno = std.mem.readInt(i32, reports[4..8], .little);
                    if (reports[1] == 1)
                        result.setup_failure = .{ .stage = stage, .errno = errno }
                    else if (stage == .network and reports[1] == 0)
                        result.network_warning = errno
                    else
                        return error.ActionProtocolFailed;
                    report_len = 0;
                }
            }
        }
    }
    lines.flush(owner);
    try owner.checkCancelled();
    if (report_len != 0) return error.ActionProtocolFailed;
    result.term = try child.wait(io);
    return result;
}
