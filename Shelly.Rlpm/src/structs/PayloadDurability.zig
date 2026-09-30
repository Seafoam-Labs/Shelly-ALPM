//! Package payload writeback. Hold a readable directory before any mutation so
//! syncfs observes writeback errors throughout the operation. Database journals
//! deliberately retain their separate, immediate fsync ordering.
const std = @import("std");
const builtin = @import("builtin");
const Root = @import("RootPath.zig");

const Self = @This();
const c = Root.c;

pub const Target = struct {
    fd: c_int,
    identity: Root.State,
    path: []const u8,
};
allocator: std.mem.Allocator,
targets: std.ArrayList(Target) = .empty,
system_error: ?c_int = null,

/// Deterministic failure/cancellation injection; absent from production builds.
pub const TestHooks = struct {
    registration_error: ?c_int = null,
    fail_flush_at: ?usize = null,
    flush_error: c_int = c.EIO,
    flush_calls: usize = 0,
    opened: usize = 0,
    closed: usize = 0,
    before_flush: ?*const fn (c_int) anyerror!void = null,
    after_flush: ?*const fn () void = null,
};
pub var test_hooks: if (builtin.is_test) TestHooks else void = if (builtin.is_test) .{} else {};

pub fn init(allocator: std.mem.Allocator) Self {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    for (self.targets.items) |target| {
        close(target.fd);
        self.allocator.free(target.path);
    }
    self.targets.deinit(self.allocator);
    self.* = undefined;
}

pub fn registerBeforeMutation(self: *Self, parent: c_int) !void {
    if (comptime builtin.is_test)
        if (test_hooks.registration_error) |code| return self.failure(code);
    const identity = try Root.state(parent);
    for (self.targets.items) |target| {
        if (target.identity.device != identity.device) continue;
        if (identity.mount_id) |mount| {
            if (target.identity.mount_id == mount) return;
        } else if (target.identity.mount_id == null and target.identity.inode == identity.inode) return;
    }
    // Allocation/open failures occur before the caller changes anything.
    try self.targets.ensureUnusedCapacity(self.allocator, 1);
    const fd = c.openat(parent, ".", c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
    if (fd < 0) return self.failure(std.c._errno().*);
    if (comptime builtin.is_test) test_hooks.opened += 1;
    errdefer close(fd);
    const held = try Root.state(fd);
    if (held.device != identity.device or held.inode != identity.inode or held.mount_id != identity.mount_id)
        return error.StaleFilesystemState;
    var proc_buffer: [64]u8 = undefined;
    const proc_path = try std.fmt.bufPrintZ(&proc_buffer, "/proc/self/fd/{d}", .{fd});
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = c.readlink(proc_path, &path_buffer, path_buffer.len);
    if (length < 0) return self.failure(std.c._errno().*);
    if (length == path_buffer.len) return error.NameTooLong;
    const path = try self.allocator.dupe(u8, path_buffer[0..@intCast(length)]);
    self.targets.appendAssumeCapacity(.{
        .fd = fd,
        .identity = held,
        .path = path,
    });
}

/// Flush one target at a time so the executor can check cancellation and retain
/// the exact failing mount between syscalls. Registration order is deterministic.
pub fn flushTarget(self: *Self, index: usize) !void {
    const target = self.targets.items[index];
    if (comptime builtin.is_test) {
        const call = test_hooks.flush_calls;
        test_hooks.flush_calls += 1;
        if (test_hooks.before_flush) |callback| try callback(target.fd);
        if (test_hooks.fail_flush_at == call) return self.failure(test_hooks.flush_error);
    }
    if (c.syncfs(target.fd) != 0) return self.failure(std.c._errno().*);
    if (comptime builtin.is_test)
        if (test_hooks.after_flush) |callback| callback();
}

fn close(fd: c_int) void {
    _ = c.close(fd);
    if (comptime builtin.is_test) test_hooks.closed += 1;
}

fn failure(self: *Self, code: c_int) anyerror {
    self.system_error = code;
    return switch (code) {
        c.ENOMEM => error.OutOfMemory,
        c.ENOSPC, c.EDQUOT => error.NoSpaceLeft,
        c.EACCES, c.EPERM => error.PathPermissionDenied,
        c.EROFS => error.ReadOnlyFilesystem,
        c.EMFILE, c.ENFILE => error.FileDescriptorLimit,
        else => error.FilesystemWriteFailed,
    };
}
