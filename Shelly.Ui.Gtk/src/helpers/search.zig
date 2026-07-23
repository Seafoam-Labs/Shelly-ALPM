const std = @import("std");

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;

    var index: usize = 0;
    outer: while (index + needle.len <= haystack.len) : (index += 1) {
        for (needle, 0..) |character, offset| {
            if (std.ascii.toLower(haystack[index + offset]) != std.ascii.toLower(character)) continue :outer;
        }
        return true;
    }

    return false;
}

pub fn matchesAnyIgnoreCase(needle: []const u8, fields: []const []const u8) bool {
    if (needle.len == 0) return true;

    for (fields) |field| {
        if (containsIgnoreCase(field, needle)) return true;
    }

    return false;
}

test "search matches fields without case sensitivity" {
    try std.testing.expect(matchesAnyIgnoreCase("paint", &.{ "Drawing", "Org.Example.Paint", "Create artwork" }));
    try std.testing.expect(matchesAnyIgnoreCase("ARTWORK", &.{ "Drawing", "Org.Example.Paint", "Create artwork" }));
}

test "search rejects missing text and accepts an empty query" {
    try std.testing.expect(!matchesAnyIgnoreCase("video", &.{ "Drawing", "Org.Example.Paint", "Create artwork" }));
    try std.testing.expect(matchesAnyIgnoreCase("", &.{"Drawing"}));
    try std.testing.expect(!matchesAnyIgnoreCase("drawing application", &.{"Drawing"}));
}
