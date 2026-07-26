const std = @import("std");
const HttpClient = @import("ShellyHttp");
const RecommendCategory = @import("../models/recommendation.zig").RecommendCategory;

pub const url = "https://www.seafoam-labs.org/recommend.json";
pub const max_size: usize = 1 * 1024 * 1024;

const timeout: std.Io.Timeout = .{ .duration = .{
    .raw = std.Io.Duration.fromMilliseconds(500),
    .clock = .awake,
} };

const user_agent = "Shelly-ALPM/3";

pub fn load(alloc: std.mem.Allocator, io: std.Io) []const RecommendCategory {
    var client: HttpClient = .{ .allocator = alloc, .io = io, .connect_timeout = timeout };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();

    const response = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &body.writer,
        .headers = .{ .user_agent = .{ .override = user_agent } },
    }) catch return &.{};

    if (response.status.class() != .success) return &.{};

    const body_bytes = body.toOwnedSlice() catch return &.{};

    const parsed = std.json.parseFromSlice(
        []RecommendCategory,
        alloc,
        body_bytes,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) catch return &.{};

    return parsed.value;
}
