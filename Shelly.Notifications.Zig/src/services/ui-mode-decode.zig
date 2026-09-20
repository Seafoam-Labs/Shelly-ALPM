const std = @import("std");

pub const JsonPackFrame = struct {
    pub const prefix = "[JSON]";
    pub const suffix = "[/JSON]";

    pub fn extractPayload(output: []const u8) ?[]const u8 {
        const pref = std.mem.indexOf(u8, output, prefix) orelse return null;
        const start = pref + prefix.len;
        const suff = std.mem.indexOfPos(u8, output, start, suffix) orelse return null;
        return output[start..suff];
    }

    pub fn extractLastPayload(output: []const u8) ?[]const u8 {
        const pref = std.mem.lastIndexOf(u8, output, prefix) orelse return null;
        const start = pref + prefix.len;
        const suff = std.mem.indexOfPos(u8, output, start, suffix) orelse return null;
        return output[start..suff];
    }

    /// Returns an owned explanation from a failed command, skipping progress,
    /// warnings, and malformed frames. Retain distinct failures in emission order.
    pub fn failureMessage(alloc: std.mem.Allocator, output: []const u8) !?[]u8 {
        const Failure = struct {
            @"$kind": []const u8 = "",
            ErrorMessage: []const u8 = "",
            Level: []const u8 = "Error",
            Recoverable: bool = false,
        };
        var messages: std.StringHashMap(void) = .init(alloc);
        defer {
            var keys = messages.keyIterator();
            while (keys.next()) |key| alloc.free(key.*);
            messages.deinit();
        }
        var text: std.Io.Writer.Allocating = .init(alloc);
        defer text.deinit();
        var iterator = frames(output);
        while (iterator.next()) |payload| {
            const json = decodeBase64(alloc, payload) catch continue;
            defer alloc.free(json);
            const parsed = std.json.parseFromSlice(Failure, alloc, json, .{ .ignore_unknown_fields = true }) catch continue;
            defer parsed.deinit();
            if (std.mem.eql(u8, parsed.value.@"$kind", "alpm.error") and
                std.mem.eql(u8, parsed.value.Level, "Error") and !parsed.value.Recoverable and parsed.value.ErrorMessage.len > 0)
            {
                const message = parsed.value.ErrorMessage;
                if (messages.contains(message)) continue;
                const key = try alloc.dupe(u8, message);
                messages.put(key, {}) catch |err| {
                    alloc.free(key);
                    return err;
                };
                if (text.written().len > 0) try text.writer.writeAll("\n\n");
                try text.writer.writeAll(message);
            }
        }
        return if (text.written().len > 0) try alloc.dupe(u8, text.written()) else null;
    }

    pub fn decodeBase64(alloc: std.mem.Allocator, base64: []const u8) ![]u8 {
        const decoder = std.base64.standard.Decoder;
        const len = try decoder.calcSizeForSlice(base64);
        const out = try alloc.alloc(u8, len);
        errdefer alloc.free(out);
        try decoder.decode(out, base64);
        return out;
    }

    pub fn decode(comptime T: type, alloc: std.mem.Allocator, output: []const u8) !std.json.Parsed(T) {
        const payload = extractPayload(output) orelse return error.NoFrame;
        const json_bytes = try decodeBase64(alloc, payload);
        defer alloc.free(json_bytes);

        return std.json.parseFromSlice(T, alloc, json_bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }

    pub fn decodeLast(comptime T: type, alloc: std.mem.Allocator, output: []const u8) !std.json.Parsed(T) {
        const payload = extractLastPayload(output) orelse return error.NoFrame;
        const json_bytes = try decodeBase64(alloc, payload);
        defer alloc.free(json_bytes);

        return std.json.parseFromSlice(T, alloc, json_bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }

    pub fn nextFrame(buf: []const u8) ?struct { payload: []const u8, consumed: usize } {
        const pref = std.mem.indexOf(u8, buf, prefix) orelse return null;
        const start = pref + prefix.len;
        const suff = std.mem.indexOfPos(u8, buf, start, suffix) orelse return null;
        return .{
            .payload = buf[start..suff],
            .consumed = suff + suffix.len,
        };
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

test "extractPayload finds content between markers" {
    const out = "noise[JSON]cGF5bG9hZA==[/JSON]more noise";
    const payload = JsonPackFrame.extractPayload(out).?;
    try testing.expectEqualStrings("cGF5bG9hZA==", payload);
}

test "extractPayload returns null when no prefix" {
    try testing.expect(JsonPackFrame.extractPayload("just some output") == null);
}

test "extractPayload returns null when no suffix" {
    try testing.expect(JsonPackFrame.extractPayload("[JSON]cGF5bG9hZA==") == null);
}

test "extractPayload returns null on empty input" {
    try testing.expect(JsonPackFrame.extractPayload("") == null);
}

test "extractPayload handles empty payload" {
    const payload = JsonPackFrame.extractPayload("[JSON][/JSON]").?;
    try testing.expectEqualStrings("", payload);
}

test "extractPayload ignores a stray suffix before the prefix" {
    // a [/JSON] appearing before [JSON] must not be matched
    const out = "[/JSON][JSON]dGVzdA==[/JSON]";
    const payload = JsonPackFrame.extractPayload(out).?;
    try testing.expectEqualStrings("dGVzdA==", payload);
}

test "extractLastPayload takes the final frame" {
    const out = "[JSON]Zmlyc3Q=[/JSON] progress [JSON]bGFzdA==[/JSON]";
    const payload = JsonPackFrame.extractLastPayload(out).?;
    try testing.expectEqualStrings("bGFzdA==", payload);
}

test "extractPayload takes the first frame" {
    const out = "[JSON]Zmlyc3Q=[/JSON][JSON]bGFzdA==[/JSON]";
    const payload = JsonPackFrame.extractPayload(out).?;
    try testing.expectEqualStrings("Zmlyc3Q=", payload);
}

test "decodeBase64 round-trips" {
    // "hello" base64 = "aGVsbG8="
    const bytes = try JsonPackFrame.decodeBase64(testing.allocator, "aGVsbG8=");
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("hello", bytes);
}

test "decodeBase64 fails on invalid input" {
    try testing.expect(std.meta.isError(JsonPackFrame.decodeBase64(testing.allocator, "not!base64!")));
}

const TestPayload = struct {
    name: []const u8 = "",
    count: i64 = 0,
};

test "decode parses a framed base64 JSON payload" {
    // {"name":"firefox","count":3} base64-encoded
    const json = "{\"name\":\"firefox\",\"count\":3}";
    var b64_buf: [128]u8 = undefined;
    const encoder = std.base64.standard.Encoder;
    const b64 = encoder.encode(&b64_buf, json);

    var out_buf: [256]u8 = undefined;
    const out = try std.fmt.bufPrint(&out_buf, "log line\n[JSON]{s}[/JSON]\ntrailing", .{b64});

    const parsed = try JsonPackFrame.decode(TestPayload, testing.allocator, out);
    defer parsed.deinit();

    try testing.expectEqualStrings("firefox", parsed.value.name);
    try testing.expectEqual(@as(i64, 3), parsed.value.count);
}

test "decode returns NoFrame when markers are absent" {
    try testing.expectError(
        error.NoFrame,
        JsonPackFrame.decode(TestPayload, testing.allocator, "no markers here"),
    );
}

test "decodeLast picks the final frame among several" {
    const json1 = "{\"name\":\"first\",\"count\":1}";
    const json2 = "{\"name\":\"second\",\"count\":2}";

    var buf1: [128]u8 = undefined;
    var buf2: [128]u8 = undefined;
    const encoder = std.base64.standard.Encoder;
    const b1 = encoder.encode(&buf1, json1);
    const b2 = encoder.encode(&buf2, json2);

    var out_buf: [512]u8 = undefined;
    const out = try std.fmt.bufPrint(&out_buf, "[JSON]{s}[/JSON]\nprogress\n[JSON]{s}[/JSON]", .{ b1, b2 });

    const parsed = try JsonPackFrame.decodeLast(TestPayload, testing.allocator, out);
    defer parsed.deinit();

    try testing.expectEqualStrings("second", parsed.value.name);
    try testing.expectEqual(@as(i64, 2), parsed.value.count);
}

test "decode parses an array payload" {
    const json = "[{\"name\":\"a\",\"count\":1},{\"name\":\"b\",\"count\":2}]";
    var b64_buf: [256]u8 = undefined;
    const encoder = std.base64.standard.Encoder;
    const b64 = encoder.encode(&b64_buf, json);

    var out_buf: [512]u8 = undefined;
    const out = try std.fmt.bufPrint(&out_buf, "[JSON]{s}[/JSON]", .{b64});

    const parsed = try JsonPackFrame.decode([]TestPayload, testing.allocator, out);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 2), parsed.value.len);
    try testing.expectEqualStrings("a", parsed.value[0].name);
    try testing.expectEqualStrings("b", parsed.value[1].name);
}

test "failureMessage retains independent failures and excludes duplicate and recoverable errors" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const messages = [_]struct { text: []const u8, level: []const u8 = "Error", recoverable: bool = false }{
        .{ .text = "cleanup warning", .level = "Warning" },
        .{ .text = "optional failure", .recoverable = true },
        .{ .text = "Could not install foo.\n\nTechnical details: FooFailed" },
        .{ .text = "Could not install bar.\n\nTechnical details: BarFailed" },
        .{ .text = "Could not install foo.\n\nTechnical details: FooFailed" },
    };
    for (messages) |entry| {
        const json = try std.json.Stringify.valueAlloc(allocator, .{
            .@"$kind" = "alpm.error",
            .ErrorMessage = entry.text,
            .Level = entry.level,
            .Recoverable = entry.recoverable,
        }, .{});
        defer allocator.free(json);
        const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(json.len));
        defer allocator.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, json);
        try output.writer.print("[JSON]{s}[/JSON]", .{encoded});
    }
    const message = (try JsonPackFrame.failureMessage(allocator, output.written())).?;
    defer allocator.free(message);
    try std.testing.expectEqualStrings("Could not install foo.\n\nTechnical details: FooFailed\n\nCould not install bar.\n\nTechnical details: BarFailed", message);
}
