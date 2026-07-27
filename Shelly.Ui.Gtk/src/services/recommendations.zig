const std = @import("std");
const HttpClient = @import("ShellyHttp");
const xdg_paths = @import("xdg_paths.zig").xdg_paths;
const RecommendCategory = @import("../models/recommendation.zig").RecommendCategory;

pub const url = "https://www.seafoam-labs.org/recommend.json";
pub const max_size: usize = 1 * 1024 * 1024;
pub const cache_ttl_seconds: i64 = 24 * 60 * 60;

const cache_subdir = "shelly";
const cache_filename = "recommend.json";

const timeout: std.Io.Timeout = .{ .duration = .{
    .raw = std.Io.Duration.fromMilliseconds(3000),
    .clock = .awake,
} };

const user_agent = "Shelly-ALPM/3";

const CacheEnvelope = struct {
    timestamp: i64 = 0,
    categories: []const RecommendCategory = &.{},
};

pub fn load(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
) []const RecommendCategory {
    return loadOrFetch(alloc, io, env, false);
}

pub fn reload(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
) []const RecommendCategory {
    return loadOrFetch(alloc, io, env, true);
}

fn loadOrFetch(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    force: bool,
) []const RecommendCategory {
    const cache_path = resolveCachePath(alloc, env) catch return fetchWithoutCache(alloc, io);
    defer alloc.free(cache_path);

    const now = nowSeconds(io);

    if (!force) {
        if (readFreshCache(alloc, io, cache_path, now)) |cats| return cats;
    }

    if (fetchAndCache(alloc, io, cache_path, now)) |cats| return cats;

    if (readAnyCache(alloc, io, cache_path)) |cats| return cats;

    return &.{};
}

fn resolveCachePath(alloc: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    const cache_home = try xdg_paths.xdgCacheHome(alloc, env);
    defer alloc.free(cache_home);
    return std.fs.path.join(alloc, &.{ cache_home, cache_subdir, cache_filename });
}

fn fetchWithoutCache(alloc: std.mem.Allocator, io: std.Io) []const RecommendCategory {
    const bytes = fetchBytes(alloc, io) orelse return &.{};
    defer alloc.free(bytes);
    return parseCategories(alloc, bytes) catch &.{};
}

fn readFreshCache(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    now: i64,
) ?[]const RecommendCategory {
    const env = readEnvelope(alloc, io, path) orelse return null;
    if (now - env.timestamp > cache_ttl_seconds) return null;
    return env.categories;
}

fn readAnyCache(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ?[]const RecommendCategory {
    const env = readEnvelope(alloc, io, path) orelse return null;
    return env.categories;
}

fn readEnvelope(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ?CacheEnvelope {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(max_size)) catch return null;
    defer alloc.free(bytes);
    const parsed = std.json.parseFromSlice(
        CacheEnvelope,
        alloc,
        bytes,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) catch return null;
    return parsed.value;
}

fn fetchAndCache(
    alloc: std.mem.Allocator,
    io: std.Io,
    cache_path: []const u8,
    now: i64,
) ?[]const RecommendCategory {
    const bytes = fetchBytes(alloc, io) orelse return null;
    defer alloc.free(bytes);

    const categories = parseCategories(alloc, bytes) catch return null;

    writeCache(io, cache_path, now, bytes);
    return categories;
}

fn fetchBytes(alloc: std.mem.Allocator, io: std.Io) ?[]u8 {
    var client: HttpClient = .{ .allocator = alloc, .io = io, .connect_timeout = timeout };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();

    const response = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &body.writer,
        .headers = .{ .user_agent = .{ .override = user_agent } },
    }) catch return null;

    if (response.status.class() != .success) return null;

    return body.toOwnedSlice() catch null;
}

fn writeCache(io: std.Io, path: []const u8, timestamp: i64, raw_payload: []const u8) void {
    if (std.fs.path.dirname(path)) |directory| {
        std.Io.Dir.cwd().createDirPath(io, directory) catch {};
    }

    var buffer: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer buffer.deinit();

    buffer.writer.print("{{\"timestamp\":{d},\"categories\":", .{timestamp}) catch return;
    buffer.writer.writeAll(raw_payload) catch return;
    buffer.writer.writeAll("}") catch return;

    std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = buffer.writer.buffered(),
    }) catch {};
}

fn parseCategories(alloc: std.mem.Allocator, bytes: []const u8) ![]const RecommendCategory {
    const parsed = try std.json.parseFromSlice(
        []RecommendCategory,
        alloc,
        bytes,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    return parsed.value;
}

fn nowSeconds(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toSeconds();
}

test "envelope round-trips categories through writeCache + readEnvelope" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var abs_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const abs_len = try tmp.dir.realPath(std.testing.io, &abs_buf);
    const cache_root = abs_buf[0..abs_len];

    const path = try std.fs.path.join(std.testing.allocator, &.{ cache_root, "recommend.json" });
    defer std.testing.allocator.free(path);

    const raw_payload = "[{\"name\":\"audio\",\"packages\":[\"pulseaudio\",\"pipewire\"]}]";
    writeCache(std.testing.io, path, 99_999_999_999, raw_payload);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const envelope = readEnvelope(arena.allocator(), std.testing.io, path) orelse {
        try std.testing.expect(false);
        return error.UnreachableTestBranch;
    };
    try std.testing.expectEqual(@as(i64, 99_999_999_999), envelope.timestamp);
    try std.testing.expectEqual(@as(usize, 1), envelope.categories.len);
    try std.testing.expectEqualStrings("audio", envelope.categories[0].name);
    try std.testing.expectEqualStrings("pulseaudio", envelope.categories[0].packages[0]);
    try std.testing.expectEqualStrings("pipewire", envelope.categories[0].packages[1]);
}

test "load serves a fresh cache without requiring network" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var abs_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const abs_len = try tmp.dir.realPath(std.testing.io, &abs_buf);
    const cache_root = abs_buf[0..abs_len];

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    try env.put("XDG_CACHE_HOME", cache_root);

    const cache_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ cache_root, "shelly", "recommend.json" },
    );
    defer std.testing.allocator.free(cache_path);

    const now = std.Io.Clock.real.now(std.testing.io).toSeconds();
    const payload = "[{\"name\":\"dev\",\"packages\":[\"base-devel\"]}]";
    writeCache(std.testing.io, cache_path, now, payload);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cats = load(arena.allocator(), std.testing.io, &env);
    try std.testing.expectEqual(@as(usize, 1), cats.len);
    try std.testing.expectEqualStrings("dev", cats[0].name);
    try std.testing.expectEqualStrings("base-devel", cats[0].packages[0]);
}

test "refresh still serves cache when the network is unreachable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var abs_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const abs_len = try tmp.dir.realPath(std.testing.io, &abs_buf);
    const cache_root = abs_buf[0..abs_len];

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    try env.put("XDG_CACHE_HOME", cache_root);

    const cache_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ cache_root, "shelly", "recommend.json" },
    );
    defer std.testing.allocator.free(cache_path);

    const now = std.Io.Clock.real.now(std.testing.io).toSeconds();
    const payload = "[{\"name\":\"dev\",\"packages\":[\"base-devel\"]}]";
    writeCache(std.testing.io, cache_path, now, payload);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cats = reload(arena.allocator(), std.testing.io, &env);
    try std.testing.expectEqual(@as(usize, 1), cats.len);
    try std.testing.expectEqualStrings("dev", cats[0].name);
    try std.testing.expectEqualStrings("base-devel", cats[0].packages[0]);
}

test "readAnyCache returns stale data for offline fallback" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var abs_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const abs_len = try tmp.dir.realPath(std.testing.io, &abs_buf);
    const cache_root = abs_buf[0..abs_len];

    const path = try std.fs.path.join(std.testing.allocator, &.{ cache_root, "recommend.json" });
    defer std.testing.allocator.free(path);

    const payload = "[{\"name\":\"legacy\",\"packages\":[\"old-pkg\"]}]";
    writeCache(std.testing.io, path, 0, payload);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cats = readAnyCache(arena.allocator(), std.testing.io, path) orelse {
        try std.testing.expect(false);
        return error.UnreachableTestBranch;
    };
    try std.testing.expectEqual(@as(usize, 1), cats.len);
    try std.testing.expectEqualStrings("legacy", cats[0].name);
}

test "parseCategories tolerates unknown fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cats = try parseCategories(
        arena.allocator(),
        "[{\"name\":\"video\",\"packages\":[\"vlc\"],\"extra\":42}]",
    );
    try std.testing.expectEqualStrings("video", cats[0].name);
    try std.testing.expectEqualStrings("vlc", cats[0].packages[0]);
}
