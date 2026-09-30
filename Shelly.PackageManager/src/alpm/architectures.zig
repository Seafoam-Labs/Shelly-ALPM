const std = @import("std");
const PhysicalArchitectures = @import("Shelly_Rlpm").PhysicalArchitectures;

/// Arena-owned names in configured order. CachyOS expands each `auto` token
/// using runtime CPU and OS capabilities; mirror substitution uses the first.
pub fn expand(arena: std.mem.Allocator, configured: []const [:0]const u8, fallback: [:0]const u8) !std.ArrayList([]const u8) {
    var result: std.ArrayList([]const u8) = .empty;
    const values = if (configured.len == 0) &.{fallback} else configured;
    for (values) |value| {
        if (std.mem.eql(u8, value, "auto")) {
            var physical = try PhysicalArchitectures.init(arena);
            defer physical.deinit();
            for (physical.names) |name| try result.append(arena, try arena.dupe(u8, name));
        } else try result.append(arena, value);
    }
    if (result.items.len == 0) return error.MissingArchitecture;
    try result.append(arena, "any");
    return result;
}
