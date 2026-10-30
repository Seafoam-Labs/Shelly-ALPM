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

/// Build the Packages tab from repository results, using local packages only
/// for installation metadata. The returned slice borrows strings from both inputs.
pub fn repositoryPackageList(allocator: std.mem.Allocator, available: []const Package, installed: ?[]const Package) ![]Package {
    const packages = try allocator.dupe(Package, available);
    errdefer allocator.free(packages);

    if (installed) |local| {
        var map: std.StringHashMapUnmanaged(*const Package) = .empty;
        defer map.deinit(allocator);
        for (local) |*pkg| try map.put(allocator, pkg.Name, pkg);

        for (packages) |*pkg| {
            const ipkg = map.get(pkg.Name);
            pkg.Installed = ipkg != null;
            pkg.InstallDate = if (ipkg) |value| value.InstallDate else null;
            pkg.Explicit = if (ipkg) |value| std.mem.eql(u8, value.InstallReason, "Explicit") else false;
        }
    }

    return packages;
}

test "repository package list excludes foreign and hidden installed packages" {
    const available = [_]Package{
        .{ .Name = "editor", .Repository = "extra", .Version = "2.0" },
        .{ .Name = "library", .Repository = "third-party" },
        .{ .Name = "available", .Repository = "core" },
    };
    const installed = [_]Package{
        .{ .Name = "editor", .Repository = "local", .Version = "1.0", .InstallReason = "Explicit", .InstallDate = "2026-10-27" },
        .{ .Name = "library", .Repository = "local", .InstallReason = "Dependency" },
        .{ .Name = "code-marketplace", .Repository = "local", .InstallReason = "Explicit" },
        .{ .Name = "local-only", .Repository = "local" },
        .{ .Name = "hidden-repository-package", .Repository = "local" },
    };
    const packages = try repositoryPackageList(std.testing.allocator, &available, &installed);
    defer std.testing.allocator.free(packages);

    try std.testing.expectEqual(@as(usize, 3), packages.len);
    try std.testing.expectEqualStrings("editor", packages[0].Name);
    try std.testing.expectEqualStrings("extra", packages[0].Repository);
    try std.testing.expectEqualStrings("2.0", packages[0].Version);
    try std.testing.expect(packages[0].Installed);
    try std.testing.expect(packages[0].Explicit);
    try std.testing.expectEqualStrings("2026-10-27", packages[0].InstallDate.?);
    try std.testing.expectEqualStrings("library", packages[1].Name);
    try std.testing.expectEqualStrings("third-party", packages[1].Repository);
    try std.testing.expect(packages[1].Installed);
    try std.testing.expect(!packages[1].Explicit);
    try std.testing.expectEqualStrings("available", packages[2].Name);
    try std.testing.expect(!packages[2].Installed);
    try std.testing.expect(!packages[2].Explicit);
    try std.testing.expectEqual(null, packages[2].InstallDate);
}

test "repository package list stays empty without repository results" {
    const installed = [_]Package{.{ .Name = "code-marketplace", .Repository = "local" }};
    const packages = try repositoryPackageList(std.testing.allocator, &.{}, &installed);
    defer std.testing.allocator.free(packages);
    try std.testing.expectEqual(@as(usize, 0), packages.len);
}

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
