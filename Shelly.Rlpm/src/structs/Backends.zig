const std = @import("std");
const Database = @import("Database.zig");
const Io = std.Io;

pub const DirectoryInfo = union(enum) {
    missing,
    not_directory,
    directory: std.Io.File.Permissions,
};

pub const LocalBackend = struct {
    directory: []u8,

    pub fn validate(
        self: *const LocalBackend,
        database: *const Database,
    ) !void {
        if (self.directory.len == 0) {
            return error.MissingDatabasePath;
        }

        if (!canAccessDirectory(database.path)) {
            return error.AccessDenied;
        }
    }
};

pub fn inspectDirectory(
    io: std.Io,
    path: []const u8,
) !DirectoryInfo {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => .missing,
            error.NotDir => .not_directory,
            else => return err,
        };
    };

    if (stat.kind != .directory) {
        return .not_directory;
    }

    return .{ .directory = stat.permissions };
}

pub fn canAccessDirectory(path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();

    const stat = cwd.statFile(io, path, .{}) catch return false;
    if (stat.kind != .directory) return false;

    cwd.access(io, path, .{
        .read = true,
        .write = true,
        .execute = true,
    }) catch return false;

    return true;
}
