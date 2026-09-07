const std = @import("std");

pub const StringHelper = struct {
    pub fn countCharacter(str: []const u8, char: u8) usize {
        var count: usize = 0;
        for (str) |c| {
            if (c == char) count += 1;
        }
        return count;
    }

    pub fn stripSuffix(str: []const u8, suffix: []const u8) []const u8 {
        if (std.mem.endsWith(u8, str, suffix)) {
            return str[0 .. str.len - suffix.len];
        }
        return str;
    }
};

test "StringHelper.countCharacter" {
    const count = StringHelper.countCharacter("hello", 'l');
    std.testing.expectEqual(count, 2);
}

test "StringHelper.stripSuffix" {
    const result = StringHelper.stripSuffix("hello.desktop", ".desktop");
    std.testing.expectEqualStrings(result, "hello");
}
