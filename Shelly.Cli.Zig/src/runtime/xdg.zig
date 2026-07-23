const std = @import("std");
const runtime = @import("context.zig");

pub fn configHome(context: *const runtime.RuntimeContext) ![]const u8 {
    return resolve(context, "XDG_CONFIG_HOME", &.{".config"});
}

pub fn cacheHome(context: *const runtime.RuntimeContext) ![]const u8 {
    return resolve(context, "XDG_CACHE_HOME", &.{".cache"});
}

pub fn dataHome(context: *const runtime.RuntimeContext) ![]const u8 {
    return resolve(context, "XDG_DATA_HOME", &.{ ".local", "share" });
}

pub fn stateHome(context: *const runtime.RuntimeContext) ![]const u8 {
    return resolve(context, "XDG_STATE_HOME", &.{ ".local", "state" });
}

pub fn binHome(context: *const runtime.RuntimeContext) ![]const u8 {
    return resolve(context, "XDG_BIN_HOME", &.{ ".local", "bin" });
}

pub fn configPath(context: *const runtime.RuntimeContext) ![]const u8 {
    return std.fs.path.join(context.allocator, &.{ try configHome(context), "shelly", "config.json" });
}

pub fn shellyCache(context: *const runtime.RuntimeContext, parts: []const []const u8) ![]const u8 {
    var path_parts: std.ArrayList([]const u8) = .empty;
    try path_parts.appendSlice(context.allocator, &.{ try cacheHome(context), "Shelly" });
    try path_parts.appendSlice(context.allocator, parts);
    return std.fs.path.join(context.allocator, path_parts.items);
}

pub fn shellyData(context: *const runtime.RuntimeContext, parts: []const []const u8) ![]const u8 {
    var path_parts: std.ArrayList([]const u8) = .empty;
    try path_parts.appendSlice(context.allocator, &.{ try dataHome(context), "Shelly" });
    try path_parts.appendSlice(context.allocator, parts);
    return std.fs.path.join(context.allocator, path_parts.items);
}

fn resolve(
    context: *const runtime.RuntimeContext,
    variable: []const u8,
    fallback_parts: []const []const u8,
) ![]const u8 {
    if (getEnv(context, variable)) |value| {
        if (value.len > 0 and std.fs.path.isAbsolute(value)) return value;
    }

    const home = try invokingUserHome(context);
    var path_parts: std.ArrayList([]const u8) = .empty;
    try path_parts.append(context.allocator, home);
    try path_parts.appendSlice(context.allocator, fallback_parts);
    return std.fs.path.join(context.allocator, path_parts.items);
}

fn invokingUserHome(context: *const runtime.RuntimeContext) ![]const u8 {
    if (getEnv(context, "SUDO_USER")) |user| {
        if (user.len > 0 and !std.mem.eql(u8, user, "root")) {
            if (try homeFromPasswd(context, user, null)) |home| return home;
        }
    }
    if (getEnv(context, "DOAS_USER")) |user| {
        if (user.len > 0 and !std.mem.eql(u8, user, "root")) {
            if (try homeFromPasswd(context, user, null)) |home| return home;
        }
    }
    if (getEnv(context, "PKEXEC_UID")) |uid| {
        if (uid.len > 0) {
            if (try homeFromPasswd(context, null, uid)) |home| return home;
        }
    }
    return getEnv(context, "HOME") orelse return error.HomeNotConfigured;
}

fn homeFromPasswd(
    context: *const runtime.RuntimeContext,
    wanted_user: ?[]const u8,
    wanted_uid: ?[]const u8,
) !?[]const u8 {
    const contents = std.Io.Dir.cwd().readFileAlloc(
        context.io,
        "/etc/passwd",
        context.allocator,
        .limited(1024 * 1024),
    ) catch return null;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        const user = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const uid = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const home = fields.next() orelse continue;
        if (wanted_user) |expected| {
            if (std.mem.eql(u8, user, expected)) return home;
        } else if (wanted_uid) |expected| {
            if (std.mem.eql(u8, uid, expected)) return home;
        }
    }
    return null;
}

pub fn getEnv(context: *const runtime.RuntimeContext, key: []const u8) ?[]const u8 {
    const environment = context.environment orelse return null;
    return environment.get(key);
}

test "uses absolute XDG paths and rejects relative overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environment = std.process.Environ.Map.init(arena.allocator());
    try environment.put("HOME", "/home/tester");
    try environment.put("XDG_CONFIG_HOME", "/tmp/config-root");
    try environment.put("XDG_CACHE_HOME", "relative-cache");
    var stdout = std.Io.Writer.Discarding.init(&.{});
    var stderr = std.Io.Writer.Discarding.init(&.{});
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .environment = &environment,
    };
    try std.testing.expectEqualStrings("/tmp/config-root", try configHome(&context));
    try std.testing.expectEqualStrings("/home/tester/.cache", try cacheHome(&context));
    try std.testing.expectEqualStrings(
        "/home/tester/.cache/Shelly/db",
        try shellyCache(&context, &.{"db"}),
    );
    try std.testing.expectEqualStrings(
        "/tmp/config-root/shelly/config.json",
        try configPath(&context),
    );
}
