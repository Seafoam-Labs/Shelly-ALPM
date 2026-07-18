const std = @import("std");

pub const xdg_paths = struct {
    /// `XDG_DATA_HOME` or `$HOME/.local/share`.
    pub fn xdgDataHome(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
        if (env.get("XDG_DATA_HOME")) |v| return try allocator.dupe(u8, v);
        const home: []const u8 = env.get("HOME") orelse return error.HomeNotSet;
        return std.fs.path.join(allocator, &.{ home, ".local", "share" });
    }

    /// `XDG_CONFIG_HOME` or `$HOME/.config`.
    pub fn xdgConfigHome(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
        if (env.get("XDG_CONFIG_HOME")) |v| return try allocator.dupe(u8, v);
        const home: []const u8 = env.get("HOME") orelse return error.HomeNotSet;
        return std.fs.path.join(allocator, &.{ home, ".config" });
    }

    /// `XDG_CACHE_HOME` or `$HOME/.cache`.
    pub fn xdgCacheHome(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
        if (env.get("XDG_CACHE_HOME")) |v| return try allocator.dupe(u8, v);
        const home: []const u8 = env.get("HOME") orelse return error.HomeNotSet;
        return std.fs.path.join(allocator, &.{ home, ".cache" });
    }

    /// `XDG_STATE_HOME` or `$HOME/.local/state`.
    pub fn xdgStateHome(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
        if (env.get("XDG_STATE_HOME")) |v| return try allocator.dupe(u8, v);
        const home: []const u8 = env.get("HOME") orelse return error.HomeNotSet;
        return std.fs.path.join(allocator, &.{ home, ".local", "state" });
    }
};

test "xdgConfigHome honors XDG_CONFIG_HOME" {
    var map: std.process.Environ.Map = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("XDG_CONFIG_HOME", "/custom/config");

    const path = try xdg_paths.xdgConfigHome(std.testing.allocator, &map);
    defer std.testing.allocator.free(path);

    try std.testing.expectEqualStrings("/custom/config", path);
}

test "xdgConfigHome falls back to HOME" {
    var map: std.process.Environ.Map = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("HOME", "/home/test");

    const path = try xdg_paths.xdgConfigHome(std.testing.allocator, &map);
    defer std.testing.allocator.free(path);

    try std.testing.expectEqualStrings("/home/test/.config", path);
}

test "xdgConfigHome errors when HOME is missing" {
    var map: std.process.Environ.Map = .init(std.testing.allocator);
    defer map.deinit();

    try std.testing.expectError(error.HomeNotSet, xdg_paths.xdgConfigHome(std.testing.allocator, &map));
}
