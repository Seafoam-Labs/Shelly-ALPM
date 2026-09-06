const std = @import("std");

pub const appimage = struct {
    pub const UpdateType = enum {
        none,
        static_url,
        github,
        gitlab,
        codeberg,
        forgejo,
    };

    pub const AppImage = struct {
        name: []const u8,
        version: []const u8 = "Unknown",
        release_tag: ?[]const u8 = null,
        raw_update_info: []const u8 = "",
        icon_name: []const u8 = "",
        description: []const u8 = "",
        desktop_name: []const u8 = "",
        size_on_disk: u64 = 0,
        environment_variables: []const @import("environment.zig").Variable = &.{},
        command_line_args: []const u8 = "",
        path: []const u8 = "",
        update_url: []const u8 = "",
        update_type: UpdateType = .none,
        repo_owner: ?[]const u8 = null,
        repo_name: ?[]const u8 = null,
        allow_prerelease: bool = false,
    };

    pub const AppImageUpdate = struct {
        name: []const u8,
        version: []const u8,
        download_url: []const u8,
        is_update_available: bool,

        pub fn deinit(self: AppImageUpdate, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
            allocator.free(self.version);
            allocator.free(self.download_url);
        }
    };

    /// Owns an update slice and every string held by its entries.
    pub const UpdateList = struct {
        allocator: std.mem.Allocator,
        items: []AppImageUpdate,

        pub fn init(allocator: std.mem.Allocator, items: []AppImageUpdate) UpdateList {
            return .{ .allocator = allocator, .items = items };
        }

        pub fn deinit(self: *UpdateList) void {
            for (self.items) |update| update.deinit(self.allocator);
            self.allocator.free(self.items);
            self.* = undefined;
        }
    };
};
