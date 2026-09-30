//! libalpm flag values. Execution-only flags are retained in the reviewed plan;
//! their filesystem/download effects belong to the transaction executor.
const std = @import("std");

const Flags = @This();
no_dependencies: bool = false,
no_save: bool = false,
no_dependency_versions: bool = false,
cascade: bool = false,
recurse: bool = false,
database_only: bool = false,
no_hooks: bool = false,
all_dependencies: bool = false,
download_only: bool = false,
no_scriptlets: bool = false,
no_conflicts: bool = false,
needed: bool = false,
all_explicit: bool = false,
unneeded: bool = false,
recurse_all: bool = false,
no_lock: bool = false,

const bits = [_]u5{ 0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 14, 15, 16, 17 };

pub fn toBits(self: Flags) u32 {
    var result: u32 = 0;
    inline for (std.meta.fields(Flags), bits) |field, bit| {
        if (@field(self, field.name)) result |= @as(u32, 1) << bit;
    }
    return result;
}

pub fn fromBits(value: u32) !Flags {
    var result: Flags = .{};
    var known: u32 = 0;
    inline for (std.meta.fields(Flags), bits) |field, bit| {
        const mask = @as(u32, 1) << bit;
        known |= mask;
        @field(result, field.name) = value & mask != 0;
    }
    if (value & ~known != 0) return error.InvalidTransactionFlags;
    return result;
}
