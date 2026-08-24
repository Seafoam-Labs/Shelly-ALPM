const std = @import("std");

pub const Package = struct {
    Name: []const u8 = "",
    Version: []const u8 = "",
    Size: i64 = 0,
    Description: []const u8 = "",
    Url: ?[]const u8 = null,
    Repository: []const u8 = "",
    Replaces: []const []const u8 = &.{},
    Licenses: []const []const u8 = &.{},
    Groups: []const []const u8 = &.{},
    Provides: []const []const u8 = &.{},
    Depends: []const []const u8 = &.{},
    OptDepends: []const []const u8 = &.{},
    OptDependsInstalled: []const bool = &.{},
    Conflicts: []const []const u8 = &.{},
    PackageFile: ?FileNode = null,
    InstallReason: []const u8 = "",
    BuildDate: []const u8 = "",
    InstallDate: ?[]const u8 = null,
    DownloadSize: i64 = 0,
    InstalledSize: i64 = 0,
    RequiredBy: []const []const u8 = &.{},
    OptionalFor: []const []const u8 = &.{},
    Installed: bool = false,
    Explicit: bool = false,
};

const FileNode = struct { Name: []const u8, Files: []const FileNode };

test "package model preserves optional dependency installation state" {
    const parsed = try std.json.parseFromSlice(
        Package,
        std.testing.allocator,
        "{\"Name\":\"editor\",\"OptDepends\":[\"spellcheck: Spell checking\",\"plugins: Plugin support\"],\"OptDependsInstalled\":[true,false]}",
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.value.OptDepends.len);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, parsed.value.OptDependsInstalled);
}
