//! Fresh executable; no Owner, libcurl, or resolver cleanup after spawning.
const std = @import("std");
const protocol = @import("action_protocol");

const c = protocol.c;
var control: c_int = 2;

fn report(stage: protocol.Stage, fatal: bool, errno: i32) void {
    var bytes: [8]u8 = @splat(0);
    bytes[0] = @intFromEnum(stage);
    bytes[1] = @intFromBool(fatal);
    std.mem.writeInt(i32, bytes[4..8], errno, .little);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = c.write(control, bytes[offset..].ptr, bytes.len - offset);
        if (count < 0 and std.c._errno().* == c.EINTR) continue;
        if (count <= 0) break;
        offset += @intCast(count);
    }
}

fn fail(stage: protocol.Stage) noreturn {
    report(stage, true, std.c._errno().*);
    std.process.exit(125);
}

fn readExact(bytes: []u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = c.read(0, bytes[offset..].ptr, bytes.len - offset);
        if (count < 0 and std.c._errno().* == c.EINTR) continue;
        if (count <= 0) fail(.protocol);
        offset += @intCast(count);
    }
}

fn string(a: std.mem.Allocator, value: []const u8) [:0]const u8 {
    if (std.mem.indexOfScalar(u8, value, 0) != null) fail(.protocol);
    return a.dupeZ(u8, value) catch fail(.protocol);
}

pub fn run(init: std.process.Init) noreturn {
    control = c.fcntl(2, c.F_DUPFD_CLOEXEC, @as(c_int, 3));
    if (control < 0) {
        control = 2;
        fail(.descriptors);
    }
    if (c.dup2(1, 2) < 0) fail(.descriptors);
    const a = init.arena.allocator();
    var size: [4]u8 = undefined;
    readExact(&size);
    const length = std.mem.readInt(u32, &size, .little);
    if (length > protocol.maximum_request) fail(.protocol);
    const bytes = a.alloc(u8, length) catch fail(.protocol);
    readExact(bytes);
    const request = std.json.parseFromSliceLeaky(protocol.Request, a, bytes, .{}) catch fail(.protocol);
    if (request.version != 1 or request.argv.len == 0) fail(.protocol);
    const root = c.open(string(a, request.root_descriptor), c.O_PATH | c.O_DIRECTORY | c.O_CLOEXEC);
    if (root < 0) fail(.root);
    const command = string(a, request.command);
    const argv = a.allocSentinel(?[*:0]const u8, request.argv.len, null) catch fail(.protocol);
    for (request.argv, argv) |arg, *dest|
        dest.* = string(a, arg).ptr;
    // Network isolation precedes chroot. The two download-only restrictions do
    // not apply to package actions. Loopback setup is best effort, as in CachyOS.
    if (request.network != .allowed) {
        if (c.unshare(c.CLONE_NEWNET) != 0) {
            if (request.network == .required) fail(.network);
            report(.network, false, std.c._errno().*);
        } else {
            const socket = c.socket(c.AF_INET, c.SOCK_DGRAM | c.SOCK_CLOEXEC, 0);
            if (socket >= 0) {
                var iface: c.struct_ifreq = std.mem.zeroes(c.struct_ifreq);
                @memcpy(iface.ifr_ifrn.ifrn_name[0..3], "lo\x00");
                if (c.ioctl(socket, c.SIOCGIFFLAGS, &iface) == 0) {
                    iface.ifr_ifru.ifru_flags |= c.IFF_UP;
                    _ = c.ioctl(socket, c.SIOCSIFFLAGS, &iface);
                }
                _ = c.close(socket);
            }
        }
    }
    if (c.fchdir(root) != 0) fail(.root);
    if (request.chroot and c.chroot(".") != 0) fail(.root);
    if (c.chdir("/") != 0) fail(.root);
    _ = c.close(root);
    if (c.unsetenv("BASH_ENV") != 0 or c.setenv("SHLVL", "1", 0) != 0) fail(.environment);
    _ = c.umask(0o022);
    // No inherited signal dispositions, blocked signals, or parent descriptors
    // may leak into the script. The private control pipe also closes on exec.
    var signals: c.sigset_t = undefined;
    _ = c.sigemptyset(&signals);
    if (c.sigprocmask(c.SIG_SETMASK, &signals, null) != 0) fail(.environment);
    var signal: c_int = 1;
    while (signal < c.NSIG) : (signal += 1) {
        _ = c.signal(signal, c.SIG_DFL);
    }
    if (c.syscall(c.SYS_close_range, @as(c_uint, 3), @as(c_uint, std.math.maxInt(c_uint)), @as(c_uint, 4)) != 0)
        fail(.descriptors); // CLOSE_RANGE_CLOEXEC
    _ = c.execv(command, @ptrCast(argv.ptr));
    fail(.execute);
}
