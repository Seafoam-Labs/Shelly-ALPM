const std = @import("std");

pub const marker = "--proxy-environment-stdin";
const frame_prefix = "[JSON]";
const frame_suffix = "[/JSON]";
const max_encoded_frame_len = 4096;

const Frame = struct {
    @"$kind": []const u8,
    http_proxy: ?[]const u8 = null,
    HTTP_PROXY: ?[]const u8 = null,
    https_proxy: ?[]const u8 = null,
    HTTPS_PROXY: ?[]const u8 = null,
    all_proxy: ?[]const u8 = null,
    ALL_PROXY: ?[]const u8 = null,
};

pub const Prepared = struct {
    arguments: []const []const u8,
    environ: std.process.Environ,
    environment_map: ?std.process.Environ.Map = null,
    owns_arguments: bool = false,

    pub fn map(self: *const Prepared, fallback: *const std.process.Environ.Map) *const std.process.Environ.Map {
        return if (self.environment_map) |*environment_map| environment_map else fallback;
    }

    pub fn deinit(self: *Prepared, allocator: std.mem.Allocator) void {
        if (self.environment_map) |*environment_map| {
            self.environ.block.deinit(allocator);
            environment_map.deinit();
        }
        if (self.owns_arguments) allocator.free(self.arguments);
        self.* = undefined;
    }
};

/// Removes the private startup marker and, only when it is present, consumes
/// one framed environment message from stdin. The reconstructed environment
/// retains all variables that survived elevation and overlays the six standard
/// proxy variables supplied by the unprivileged GTK process.
pub fn prepare(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    initial_environ: std.process.Environ,
    arguments: []const []const u8,
) !Prepared {
    var marker_count: usize = 0;
    for (arguments) |argument| {
        if (std.mem.eql(u8, argument, marker)) marker_count += 1;
    }
    if (marker_count == 0) return .{ .arguments = arguments, .environ = initial_environ };
    if (marker_count != 1) return error.InvalidProxyEnvironmentMarker;

    const filtered = try allocator.alloc([]const u8, arguments.len - 1);
    errdefer allocator.free(filtered);
    var filtered_index: usize = 0;
    for (arguments) |argument| {
        if (std.mem.eql(u8, argument, marker)) continue;
        filtered[filtered_index] = argument;
        filtered_index += 1;
    }

    const raw_line = reader.takeDelimiter('\n') catch return error.InvalidProxyEnvironmentFrame;
    const line_with_cr = raw_line orelse return error.MissingProxyEnvironmentFrame;
    const line = std.mem.trimEnd(u8, line_with_cr, "\r");
    if (line.len > max_encoded_frame_len or
        !std.mem.startsWith(u8, line, frame_prefix) or
        !std.mem.endsWith(u8, line, frame_suffix))
    {
        return error.InvalidProxyEnvironmentFrame;
    }

    const encoded = line[frame_prefix.len .. line.len - frame_suffix.len];
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch
        return error.InvalidProxyEnvironmentFrame;
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    std.base64.standard.Decoder.decode(decoded, encoded) catch
        return error.InvalidProxyEnvironmentFrame;

    var parsed = std.json.parseFromSlice(Frame, allocator, decoded, .{}) catch
        return error.InvalidProxyEnvironmentFrame;
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.@"$kind", "proxy.environment"))
        return error.InvalidProxyEnvironmentFrame;

    var environment_map = try initial_environ.createMap(allocator);
    errdefer environment_map.deinit();
    inline for (.{
        "http_proxy",
        "HTTP_PROXY",
        "https_proxy",
        "HTTPS_PROXY",
        "all_proxy",
        "ALL_PROXY",
    }) |name| {
        if (@field(parsed.value, name)) |value| {
            if (std.mem.findScalar(u8, value, 0) != null) return error.InvalidProxyEnvironmentFrame;
            try environment_map.put(name, value);
        }
    }

    const environ: std.process.Environ = .{
        .block = try environment_map.createPosixBlock(allocator, .{}),
    };
    return .{
        .arguments = filtered,
        .environ = environ,
        .environment_map = environment_map,
        .owns_arguments = true,
    };
}

fn encodeTestFrame(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    const encoded_len = std.base64.standard.Encoder.calcSize(json.len);
    const result = try allocator.alloc(u8, frame_prefix.len + encoded_len + frame_suffix.len + 1);
    @memcpy(result[0..frame_prefix.len], frame_prefix);
    _ = std.base64.standard.Encoder.encode(
        result[frame_prefix.len .. frame_prefix.len + encoded_len],
        json,
    );
    const suffix_start = frame_prefix.len + encoded_len;
    @memcpy(result[suffix_start .. suffix_start + frame_suffix.len], frame_suffix);
    result[result.len - 1] = '\n';
    return result;
}

test "proxy environment marker overlays variables and is removed" {
    const allocator = std.testing.allocator;
    var initial_map = std.process.Environ.Map.init(allocator);
    defer initial_map.deinit();
    try initial_map.put("PKEXEC_UID", "1000");
    const initial_environ: std.process.Environ = .{
        .block = try initial_map.createPosixBlock(allocator, .{}),
    };
    defer initial_environ.block.deinit(allocator);

    const frame = try encodeTestFrame(allocator,
        \\{"$kind":"proxy.environment","http_proxy":"http://user:p%40ss@proxy:443/","ALL_PROXY":"http://fallback:8080/"}
    );
    defer allocator.free(frame);
    var reader = std.Io.Reader.fixed(frame);
    const args = [_][]const u8{ "install", "example", marker, "--ui-mode" };
    var prepared = try prepare(allocator, &reader, initial_environ, &args);
    defer prepared.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), prepared.arguments.len);
    try std.testing.expectEqualStrings("install", prepared.arguments[0]);
    try std.testing.expectEqualStrings("--ui-mode", prepared.arguments[2]);
    const map_value = prepared.map(&initial_map);
    try std.testing.expectEqualStrings("1000", map_value.get("PKEXEC_UID").?);
    try std.testing.expectEqualStrings("http://user:p%40ss@proxy:443/", map_value.get("http_proxy").?);
    try std.testing.expectEqualStrings("http://fallback:8080/", map_value.get("ALL_PROXY").?);
}

test "ordinary invocation does not consume stdin" {
    const allocator = std.testing.allocator;
    var initial_map = std.process.Environ.Map.init(allocator);
    defer initial_map.deinit();
    const initial_environ: std.process.Environ = .{
        .block = try initial_map.createPosixBlock(allocator, .{}),
    };
    defer initial_environ.block.deinit(allocator);
    var reader = std.Io.Reader.fixed("");
    const args = [_][]const u8{ "search", "example" };
    var prepared = try prepare(allocator, &reader, initial_environ, &args);
    defer prepared.deinit(allocator);
    try std.testing.expect(prepared.environment_map == null);
    try std.testing.expect(prepared.map(&initial_map) == &initial_map);
}

test "missing proxy environment frame fails closed" {
    var reader = std.Io.Reader.fixed("");
    const args = [_][]const u8{ "install", marker };
    try std.testing.expectError(
        error.MissingProxyEnvironmentFrame,
        prepare(std.testing.allocator, &reader, .empty, &args),
    );
}
