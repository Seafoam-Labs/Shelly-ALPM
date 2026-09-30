//! Exclusive pacman lock. Only the acquiring instance may unlink it.
const std = @import("std");

const Lock = @This();
extern "c" fn rlpm_lock_acquire([*:0]const u8, *c_int) c_int;
extern "c" fn rlpm_lock_check([*:0]const u8, c_int) c_int;
extern "c" fn rlpm_lock_release([*:0]const u8, c_int) c_int;

path: [:0]u8,
fd: c_int,

pub fn acquire(allocator: std.mem.Allocator, path: []const u8) !Lock {
    const owned = try allocator.dupeZ(u8, path);
    errdefer allocator.free(owned);
    var fd: c_int = undefined;
    try check(rlpm_lock_acquire(owned, &fd));
    return .{ .path = owned, .fd = fd };
}

pub fn validate(self: *const Lock) !void {
    try check(rlpm_lock_check(self.path, self.fd));
}

/// Always closes the descriptor and frees the path, including on failure.
pub fn release(self: *Lock, allocator: std.mem.Allocator) !void {
    const result = rlpm_lock_release(self.path, self.fd);
    allocator.free(self.path);
    self.* = undefined;
    try check(result);
}

fn check(result: c_int) !void {
    if (result == 0) return;
    return switch (@as(std.c.E, @enumFromInt(result))) {
        .EXIST => error.DatabaseLocked,
        .ACCES, .PERM, .ROFS => error.LockPermissionDenied,
        .STALE => error.LockOwnershipLost,
        .NOENT => error.LockNotHeld,
        .NOMEM => error.OutOfMemory,
        else => error.DatabaseLockFailed,
    };
}
