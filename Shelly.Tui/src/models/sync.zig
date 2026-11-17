const std = @import("std");
const AppImageUpdate = @import("appimage.zig").AppImageUpdate;

/// owns the arenas backing value.
pub const ParsedCheckUpdates = struct {
    value: CheckUpdates,
    arenas: [4]?*std.heap.ArenaAllocator,

    pub fn fromSources(native: std.json.Parsed([]CheckUpdatesPackage), aur: ?std.json.Parsed([]CheckUpdatesAur), flatpak: ?std.json.Parsed([]CheckUpdatesFlatpak), appimage: ?std.json.Parsed([]AppImageUpdate)) ParsedCheckUpdates {
        return .{
            .value = .{ .Packages = native.value, .Aur = if (aur) |parsed| parsed.value else &.{}, .Flatpak = if (flatpak) |parsed| parsed.value else &.{}, .AppImage = if (appimage) |parsed| parsed.value else &.{} },
            .arenas = .{ native.arena, if (aur) |parsed| parsed.arena else null, if (flatpak) |parsed| parsed.arena else null, if (appimage) |parsed| parsed.arena else null },
        };
    }

    pub fn fromParsed(parsed: std.json.Parsed(CheckUpdates)) ParsedCheckUpdates {
        return .{ .value = parsed.value, .arenas = .{ parsed.arena, null, null, null } };
    }

    pub fn deinit(self: ParsedCheckUpdates) void {
        for (self.arenas) |maybe_arena| if (maybe_arena) |arena| {
            const allocator = arena.child_allocator;
            arena.deinit();
            allocator.destroy(arena);
        };
    }
};

pub const CheckUpdates = struct {
    Packages: []CheckUpdatesPackage = &.{},
    Aur: []CheckUpdatesAur = &.{},
    Flatpak: []CheckUpdatesFlatpak = &.{},
    AppImage: []AppImageUpdate = &.{},

    pub fn count(self: *const CheckUpdates) usize {
        return self.Packages.len + self.Aur.len + self.Flatpak.len + self.AppImage.len;
    }
};

pub const CheckUpdatesPackage = struct {
    Name: []const u8 = "",
    CurrentVersion: []const u8 = "",
    NewVersion: []const u8 = "",
    DownloadSize: i64 = 0,
    SizeDifference: i64 = 0,
    Description: []const u8 = "",
    Url: []const u8 = "",
    Repository: []const u8 = "",
    InstalledSize: i64 = 0,
    Depends: []const []const u8 = &.{},
    OptDepends: []const []const u8 = &.{},
    Licenses: []const []const u8 = &.{},
    Provides: []const []const u8 = &.{},
    Conflicts: []const []const u8 = &.{},
    Groups: []const []const u8 = &.{},
};

pub const CheckUpdatesAur = struct {
    Name: []const u8 = "",
    Version: []const u8 = "",
    NewVersion: []const u8 = "",
    DownloadSize: i64 = 0,
    Url: []const u8 = "",
    PackageBase: []const u8 = "",
    Description: []const u8 = "",
};

pub const CheckUpdatesFlatpak = struct {
    Id: []const u8 = "",
    Name: []const u8 = "",
    Version: []const u8 = "",
    NewVersion: []const u8 = "",
    Arch: []const u8 = "",
    Branch: []const u8 = "",
    LatestCommit: []const u8 = "",
    Summary: []const u8 = "",
    Kind: i32 = 0,
    Remote: []const u8 = "",
    InstallLevel: i32 = 0,
    Permissions: []const []const u8 = &.{},
    InstalledSize: u64 = 0,
    Ref: []const u8 = "",
    FullRef: []const u8 = "",
};

test "combined updates retain source arrays and release every enabled source" {
    const Case = struct {
        fn make(allocator: std.mem.Allocator, aur_enabled: bool, flatpak_enabled: bool) !ParsedCheckUpdates {
            const native = try std.json.parseFromSlice([]CheckUpdatesPackage, allocator,
                \\[{"Name":"native","Depends":["libc"],"Licenses":["MIT"]}]
            , .{ .allocate = .alloc_always });
            errdefer native.deinit();
            var aur: ?std.json.Parsed([]CheckUpdatesAur) = null;
            errdefer if (aur) |parsed| parsed.deinit();
            var flatpak: ?std.json.Parsed([]CheckUpdatesFlatpak) = null;
            errdefer if (flatpak) |parsed| parsed.deinit();
            if (aur_enabled) aur = try std.json.parseFromSlice([]CheckUpdatesAur, allocator,
                \\[{"Name":"aur","PackageBase":"split"}]
            , .{ .allocate = .alloc_always });
            if (flatpak_enabled) flatpak = try std.json.parseFromSlice([]CheckUpdatesFlatpak, allocator,
                \\[{"Id":"org.example.App","Permissions":["network"]}]
            , .{ .allocate = .alloc_always });
            const appimage = try std.json.parseFromSlice([]AppImageUpdate, allocator, "[{\"Name\":\"Editor\",\"Version\":\"2\",\"DownloadUrl\":\"https://example.org/Editor.AppImage\",\"IsUpdateAvailable\":true}]", .{ .allocate = .alloc_always });
            return ParsedCheckUpdates.fromSources(native, aur, flatpak, appimage);
        }

        fn run(allocator: std.mem.Allocator) !void {
            for ([_]bool{ false, true }) |aur_enabled| {
                for ([_]bool{ false, true }) |flatpak_enabled| {
                    const combined = try make(allocator, aur_enabled, flatpak_enabled);
                    defer combined.deinit();
                    try std.testing.expectEqualStrings("Editor", combined.value.AppImage[0].Name);
                    try std.testing.expectEqualStrings("libc", combined.value.Packages[0].Depends[0]);
                    try std.testing.expectEqual(@intFromBool(aur_enabled), combined.value.Aur.len);
                    try std.testing.expectEqual(@intFromBool(flatpak_enabled), combined.value.Flatpak.len);
                    if (aur_enabled) try std.testing.expectEqualStrings("split", combined.value.Aur[0].PackageBase);
                    if (flatpak_enabled) try std.testing.expectEqualStrings("network", combined.value.Flatpak[0].Permissions[0]);
                }
            }
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}
