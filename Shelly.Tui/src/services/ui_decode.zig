const std = @import("std");

pub const JsonPackFrame = struct {
    pub const prefix = "[JSON]";
    pub const suffix = "[/JSON]";

    pub fn decodeBase64(alloc: std.mem.Allocator, base64: []const u8) ![]u8 {
        const decoder = std.base64.standard.Decoder;
        const len = try decoder.calcSizeForSlice(base64);
        const out = try alloc.alloc(u8, len);
        errdefer alloc.free(out);
        try decoder.decode(out, base64);
        return out;
    }

    pub const FrameIterator = struct {
        buf: []const u8,
        pos: usize = 0,

        pub fn next(self: *FrameIterator) ?[]const u8 {
            const rel = std.mem.indexOfPos(u8, self.buf, self.pos, prefix) orelse return null;
            const start = rel + prefix.len;
            const suff = std.mem.indexOfPos(u8, self.buf, start, suffix) orelse return null;
            self.pos = suff + suffix.len;
            return self.buf[start..suff];
        }
    };

    pub fn frames(buf: []const u8) FrameIterator {
        return .{ .buf = buf };
    }
};

const testing = std.testing;

test "frame iterator finds content between markers" {
    const out = "noise[JSON]cGF5bG9hZA==[/JSON]more noise";
    const payload = firstPayload(out).?;
    try testing.expectEqualStrings("cGF5bG9hZA==", payload);
}

test "frame iterator returns null when no prefix" {
    try testing.expect(firstPayload("just some output") == null);
}

test "frame iterator returns null when no suffix" {
    try testing.expect(firstPayload("[JSON]cGF5bG9hZA==") == null);
}

test "frame iterator returns null on empty input" {
    try testing.expect(firstPayload("") == null);
}

test "frame iterator handles empty payload" {
    const payload = firstPayload("[JSON][/JSON]").?;
    try testing.expectEqualStrings("", payload);
}

test "frame iterator ignores a stray suffix before the prefix" {
    // a [/JSON] appearing before [JSON] must not be matched
    const out = "[/JSON][JSON]dGVzdA==[/JSON]";
    const payload = firstPayload(out).?;
    try testing.expectEqualStrings("dGVzdA==", payload);
}

test "frame iterator takes the first frame" {
    const out = "[JSON]Zmlyc3Q=[/JSON][JSON]bGFzdA==[/JSON]";
    const payload = firstPayload(out).?;
    try testing.expectEqualStrings("Zmlyc3Q=", payload);
}

test "decodeBase64 round-trips" {
    // "hello" base64 = "aGVsbG8="
    const bytes = try JsonPackFrame.decodeBase64(testing.allocator, "aGVsbG8=");
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("hello", bytes);
}

test "decodeBase64 fails on invalid input" {
    if (JsonPackFrame.decodeBase64(testing.allocator, "not!base64!")) |bytes| {
        defer testing.allocator.free(bytes);
        return error.TestExpectedError;
    } else |_| {}
}

fn firstPayload(output: []const u8) ?[]const u8 {
    var iterator = JsonPackFrame.frames(output);
    return iterator.next();
}

test "frame iterator consumes multiple frames and stops at incomplete output" {
    var iterator = JsonPackFrame.frames("log [JSON]first[/JSON] text [JSON]second[/JSON][JSON]unfinished");
    try testing.expectEqualStrings("first", iterator.next().?);
    try testing.expectEqualStrings("second", iterator.next().?);
    try testing.expect(iterator.next() == null);
}
