const std = @import("std");
const user_account = @import("PackageManager").user_account;
const runtime = @import("context.zig");
const elevation = @import("elevation.zig");

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

/// Native update previews keep copies of the package databases here. A root
/// run uses root's own cache, so it never leaves root-owned files in the
/// invoking user's cache that a later unprivileged preview cannot replace.
pub fn previewDatabase(context: *const runtime.RuntimeContext) ![]const u8 {
    return previewDatabaseFor(context, elevation.isRoot());
}

fn previewDatabaseFor(context: *const runtime.RuntimeContext, as_root: bool) ![]const u8 {
    if (!as_root) return shellyCache(context, &.{"db"});
    const account = (try user_account.byUid(context.allocator, 0)) orelse return error.HomeNotConfigured;
    defer account.deinit(context.allocator);
    if (account.home.len == 0) return error.HomeNotConfigured;
    return std.fs.path.join(context.allocator, &.{ account.home, ".cache", "Shelly", "db" });
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
    return invokingUserHomeFor(context, std.c.geteuid());
}

fn invokingUserHomeFor(context: *const runtime.RuntimeContext, effective_uid: std.c.uid_t) ![]const u8 {
    if (effective_uid != 0) {
        if (getEnv(context, "HOME")) |home| {
            if (std.fs.path.isAbsolute(home)) return home;
        }
        return error.HomeNotConfigured;
    }
    const account = try user_account.callerFor(context.allocator, effective_uid, getEnv(context, "SUDO_USER"), getEnv(context, "DOAS_USER"), getEnv(context, "PKEXEC_UID"));
    defer account.deinit(context.allocator);
    if (account.home.len == 0) return error.HomeNotConfigured;
    return context.allocator.dupe(u8, account.home);
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
        try std.testing.expectEqualStrings(account.home, try invokingUserHomeFor(&context, 0));
        try environment.put("HOME", "/root");
        try std.testing.expectEqualStrings(account.home, try invokingUserHomeFor(&context, 0));
        if (elevation.isRoot()) try std.testing.expectEqualStrings(try std.fs.path.join(allocator, &.{ account.home, ".cache" }), try cacheHome(&context));
        try environment.put("XDG_CACHE_HOME", "/tmp/custom-cache");
        try std.testing.expectEqualStrings("/tmp/custom-cache", try cacheHome(&context));
    }
}

test "root previews keep their databases out of the invoking user's cache" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const account = (try user_account.byName(allocator, "nobody")) orelse return error.SkipZigTest;
    const root = (try user_account.byUid(allocator, 0)) orelse return error.SkipZigTest;
    var environment = std.process.Environ.Map.init(allocator);
    try environment.put("SUDO_USER", account.username);
    try environment.put("HOME", "/home/tester");
    try environment.put("XDG_CACHE_HOME", "/tmp/custom-cache");
    var stdout = std.Io.Writer.Discarding.init(&.{});
    var stderr = std.Io.Writer.Discarding.init(&.{});
    const context: runtime.RuntimeContext = .{
        .allocator = allocator,
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .environment = &environment,
    };
    try std.testing.expectEqualStrings("/tmp/custom-cache/Shelly/db", try previewDatabaseFor(&context, false));
    try std.testing.expectEqualStrings(
        try std.fs.path.join(allocator, &.{ root.home, ".cache", "Shelly", "db" }),
        try previewDatabaseFor(&context, true),
    );
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
    // Direct root falls back to its account home, regardless of HOME.
    const expected_home = if (elevation.isRoot()) blk: {
        const root = (try user_account.byUid(arena.allocator(), 0)) orelse return error.InvokingUserUnavailable;
        break :blk root.home;
    } else "/home/tester";
    try std.testing.expectEqualStrings(
        try std.fs.path.join(arena.allocator(), &.{ expected_home, ".cache" }),
        try cacheHome(&context),
    );
    try std.testing.expectEqualStrings(
        try std.fs.path.join(arena.allocator(), &.{ expected_home, ".cache", "Shelly", "db" }),
        try shellyCache(&context, &.{"db"}),
    );
    try std.testing.expectEqualStrings(
        "/tmp/config-root/shelly/config.json",
        try configPath(&context),
    );
}
