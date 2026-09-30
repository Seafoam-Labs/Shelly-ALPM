//! Serializes a caller-supplied allocator while transfer workers are active.
const Self = @This();
const std = @import("std");
child_allocator: std.mem.Allocator,
io: std.Io,
mutex: std.Io.Mutex = .init,
pub fn allocator(self: *Self) std.mem.Allocator {
    return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
}
fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.child_allocator.rawAlloc(len, alignment, ret);
}
fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) bool {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.child_allocator.rawResize(memory, alignment, len, ret);
}
fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.child_allocator.rawRemap(memory, alignment, len, ret);
}
fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.child_allocator.rawFree(memory, alignment, ret);
}
