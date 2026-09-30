//! libalpm path lists: last matching rule wins; fnmatch uses flags=0.
const std = @import("std");

const c = @cImport({
    @cInclude("fnmatch.h");
});

pub const Match = enum(i8) { unmatched = -1, matched = 0, excluded = 1 };

pub fn match(allocator: std.mem.Allocator, patterns: []const []const u8, path: []const u8) !Match {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    const name = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(name);
    var index = patterns.len;
    while (index != 0) {
        index -= 1;
        var pattern = patterns[index];
        const inverted = pattern.len != 0 and pattern[0] == '!';
        if (pattern.len != 0 and (inverted or pattern[0] == '\\')) pattern = pattern[1..];
        const rule = try allocator.dupeSentinel(u8, pattern, 0);
        defer allocator.free(rule);
        if (c.fnmatch(rule, name, 0) == 0) return if (inverted) .excluded else .matched;
    }
    return .unmatched;
}
