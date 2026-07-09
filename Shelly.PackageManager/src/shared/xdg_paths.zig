const std = @import("std");

pub const xdg_paths = struct {
    pub fn xdgDataHome(allocator: std.mem.Allocator, environ: std.process.Environ) ![]u8 {
        if (environ.getPosix("XDG_DATA_HOME")) |v| return try allocator.dupe(u8, v);
        const home: []const u8 = environ.getPosix("HOME") orelse return error.HomeNotSet;
        return std.fs.path.join(allocator, &.{ home, ".local", "share" });
    }

    pub fn xdgConfigHome(allocator: std.mem.Allocator, environ: std.process.Environ) ![]u8 {
        if (environ.getPosix("XDG_CONFIG_HOME")) |v| return try allocator.dupe(u8, v);
        const home: []const u8 = environ.getPosix("HOME") orelse return error.HomeNotSet;
        return std.fs.path.join(allocator, &.{ home, ".config" });
    }

    pub fn xdgCacheHome(allocator: std.mem.Allocator, environ: std.process.Environ) ![]u8 {
        if (environ.getPosix("XDG_CACHE_HOME")) |v| return try allocator.dupe(u8, v);
        const home: []const u8 = environ.getPosix("HOME") orelse return error.HomeNotSet;
        return std.fs.path.join(allocator, &.{ home, ".cache" });
    }

    pub fn xdgStateHome(allocator: std.mem.Allocator, environ: std.process.Environ) ![]u8 {
        if (environ.getPosix("XDG_STATE_HOME")) |v| return try allocator.dupe(u8, v);
        const home: []const u8 = environ.getPosix("HOME") orelse return error.HomeNotSet;
        return std.fs.path.join(allocator, &.{ home, ".local", "state" });
    }
};
