//! Runs in a disposable child; never confines the calling test runner.
const std = @import("std");
const sandbox = @import("Sandbox");
const linux = std.os.linux;
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) return error.InvalidArguments;
    const directory = args[1];
    const outside = args[2];
    const flags = try std.fmt.parseInt(u8, args[3], 10);
    const filesystem = flags & 1 != 0;
    const syscalls = flags & 2 != 0;
    const inside = try std.fmt.allocPrintSentinel(init.arena.allocator(), "{s}/allowed", .{directory}, 0);
    const uid = std.c.getuid();
    try sandbox.noNewPrivileges();
    if (filesystem) try sandbox.restrictFilesystem(directory);
    if (syscalls) try sandbox.restrictSyscalls();
    const created = std.c.open(inside, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    if (created < 0) return error.StagingWriteDenied;
    if (std.c.write(created, "ok", 2) != 2) return error.StagingWriteFailed;
    _ = std.c.close(created);
    const null_fd = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY, .CLOEXEC = true });
    if (null_fd < 0) return error.NullDeviceDenied;
    _ = std.c.close(null_fd);
    const outside_fd = std.c.open(outside, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    if (outside_fd >= 0) _ = std.c.close(outside_fd);
    if (filesystem) {
        if (outside_fd >= 0 or std.c._errno().* != @intFromEnum(std.c.E.ACCES)) return error.WriteConfinementFailed;
    } else if (outside_fd < 0) return error.UnexpectedWriteRestriction;
    const personality = linux.syscall1(.personality, 0xffffffff); // Query only.
    if (syscalls) {
        if (linux.errno(personality) != .PERM) return error.SyscallFilterFailed;
    } else if (linux.errno(personality) != .SUCCESS) return error.UnexpectedSyscallRestriction;
    if (linux.getpid() <= 0 or std.c.getuid() != uid) return error.ParentIdentityChanged;
}
