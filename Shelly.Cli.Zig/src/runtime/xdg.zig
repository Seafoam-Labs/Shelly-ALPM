const std = @import("std");
const user_account = @import("Zigalpm").user_account;
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
            if (try homeFromAccount(context, user, null)) |home| return home;
        }
    }
    if (getEnv(context, "DOAS_USER")) |user| {
        if (user.len > 0 and !std.mem.eql(u8, user, "root")) {
            if (try homeFromAccount(context, user, null)) |home| return home;
        }
    }
    if (getEnv(context, "PKEXEC_UID")) |uid| {
        if (uid.len > 0) {
            if (try homeFromAccount(context, null, uid)) |home| return home;
        }
    }
    return getEnv(context, "HOME") orelse return error.HomeNotConfigured;
}

fn homeFromAccount(
    context: *const runtime.RuntimeContext,
    wanted_user: ?[]const u8,
    wanted_uid: ?[]const u8,
) !?[]const u8 {
    const account = if (wanted_user) |user|
        try user_account.byName(context.allocator, user)
    else if (wanted_uid) |uid|
        try user_account.byUidText(context.allocator, uid)
    else
        null;
    const found = account orelse return null;
    defer found.deinit(context.allocator);
    if (found.home.len == 0) return null;
    return try context.allocator.dupe(u8, found.home);
}

pub fn getEnv(context: *const runtime.RuntimeContext, key: []const u8) ?[]const u8 {
    const environment = context.environment orelse return null;
    return environment.get(key);
}

test "NSS XDG paths resolve the caller before falling back to HOME" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const account = (try user_account.byName(allocator, "nobody")) orelse return error.SkipZigTest;
    const uid = try std.fmt.allocPrint(allocator, "{d}", .{account.uid});
    var stdout = std.Io.Writer.Discarding.init(&.{});
    var stderr = std.Io.Writer.Discarding.init(&.{});
    for ([_][]const u8{ "SUDO_USER", "DOAS_USER", "PKEXEC_UID" }) |marker| {
        var environment = std.process.Environ.Map.init(allocator);
        try environment.put(marker, if (std.mem.eql(u8, marker, "PKEXEC_UID")) uid else account.username);
        const context: runtime.RuntimeContext = .{
            .allocator = allocator,
            .io = std.testing.io,
            .stdout = &stdout.writer,
            .stderr = &stderr.writer,
            .environment = &environment,
        };
        try std.testing.expectEqualStrings(account.home, try invokingUserHome(&context));
        try environment.put("HOME", "/root");
        try std.testing.expectEqualStrings(account.home, try invokingUserHome(&context));
        try std.testing.expectEqualStrings(try std.fs.path.join(allocator, &.{ account.home, ".cache" }), try cacheHome(&context));
        try environment.put("XDG_CACHE_HOME", "/tmp/custom-cache");
        try std.testing.expectEqualStrings("/tmp/custom-cache", try cacheHome(&context));
    }
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
