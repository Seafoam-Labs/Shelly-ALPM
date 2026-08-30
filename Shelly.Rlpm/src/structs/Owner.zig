const Owner = @This();

const std = @import("std");
const Database = @import("Database.zig");

allocator: std.mem.Allocator,
local: Database,
sync_databases: std.ArrayList(Database),
root: []const u8,
database_path: []const u8,
log_file: []const u8,
gpg_directory: []const u8,
cache_directory: []const u8,
hook_directory: []const u8,
architectures: []const u8,
ignore_pacakages: [][]const u8,
ignore_groups: [][]const u8,
assume_installed: [][]const u8,

pub fn init(
    allocator: std.mem.Allocator,
    root: []const u8,
    database_path: []const u8,
    log_file: []const u8,
    gpg_directory: []const u8,
    cache_directory: []const u8,
    hook_directory: []const u8,
    architectures: []const u8,
    ignore_pacakages: [][]const u8,
    ignore_groups: [][]const u8,
    assume_installed: [][]const u8,
) !Owner {
    return .{
        .allocator = allocator,
        .root = root,
        .database_path = database_path,
        .log_file = log_file,
        .gpg_directory = gpg_directory,
        .cache_directory = cache_directory,
        .hook_directory = hook_directory,
        .architectures = architectures,
        .ignore_pacakages = ignore_pacakages,
        .ignore_groups = ignore_groups,
        .assume_installed = assume_installed,
    };
}
