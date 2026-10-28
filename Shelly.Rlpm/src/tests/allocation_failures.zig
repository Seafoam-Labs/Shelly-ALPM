const std = @import("std");

/// Force reallocations to take the allocate/copy/free path. Zig 0.17's backing
/// allocator can grow a block in place depending on address reuse, which makes
/// the number of allocation points vary between failure-injection iterations.
/// The standard checker still verifies every allocation failure and all frees.
pub fn checkAllAllocationFailures(allocator: std.mem.Allocator, comptime test_fn: anytype, args: anytype) !void {
    var fixed_growth = std.testing.FailingAllocator.init(allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(fixed_growth.allocator(), test_fn, args);
}
