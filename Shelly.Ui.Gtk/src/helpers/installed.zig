const std = @import("std");
const AurPackage = @import("../models/aur_package.zig").AurPackage;
const Flatpak = @import("../models/flatpak.zig").Flatpak;

/// AUR packages are installed when their package name is in the installed
/// list. Split packages share a package base but install independently, so the
/// base is never treated as an installed name.
pub fn aurInstalledContains(installed_names: []const []const u8, name: []const u8) bool {
    for (installed_names) |installed| {
        if (std.mem.eql(u8, installed, name)) return true;
    }
    return false;
}

/// Flatpak packages are matched by application ID, never by display name.
pub fn flatpakInstalledContains(installed_ids: []const []const u8, id: []const u8) bool {
    if (id.len == 0) return false;
    for (installed_ids) |installed| {
        if (std.mem.eql(u8, installed, id)) return true;
    }
    return false;
}

/// Appends each installed AUR package's name as an owned sentinel string.
pub fn appendAurInstalledNames(
    allocator: std.mem.Allocator,
    packages: []const AurPackage,
    names: *std.ArrayListUnmanaged([:0]const u8),
) !void {
    for (packages) |package| {
        try names.append(allocator, try allocator.dupeSentinel(u8, package.Name, 0));
    }
}

/// Appends each installed Flatpak's application ID as an owned sentinel string.
pub fn appendFlatpakInstalledIds(
    allocator: std.mem.Allocator,
    flatpaks: []const Flatpak,
    ids: *std.ArrayListUnmanaged([:0]const u8),
) !void {
    for (flatpaks) |flatpak| {
        if (flatpak.Id.len == 0) continue;
        try ids.append(allocator, try allocator.dupeSentinel(u8, flatpak.Id, 0));
    }
}

fn freeNames(allocator: std.mem.Allocator, names: *std.ArrayListUnmanaged([:0]const u8)) void {
    for (names.items) |name| allocator.free(name);
    names.deinit(allocator);
}

test "aurInstalledContains matches package names only" {
    const installed = [_][]const u8{ "foo", "bar", "baz" };

    try std.testing.expect(aurInstalledContains(&installed, "bar"));
    try std.testing.expect(aurInstalledContains(&installed, "foo"));
    // Split siblings share the base but are separate packages.
    try std.testing.expect(!aurInstalledContains(&installed, "foo-docs"));
    try std.testing.expect(!aurInstalledContains(&installed, "bar-git"));
    try std.testing.expect(!aurInstalledContains(&installed, "qux"));
    try std.testing.expect(!aurInstalledContains(&.{}, "bar"));
}

test "flatpakInstalledContains matches application IDs only" {
    const installed = [_][]const u8{ "org.gnome.Calculator", "org.kde.kate" };

    try std.testing.expect(flatpakInstalledContains(&installed, "org.kde.kate"));
    try std.testing.expect(!flatpakInstalledContains(&installed, "Kate"));
    try std.testing.expect(!flatpakInstalledContains(&installed, ""));
    try std.testing.expect(!flatpakInstalledContains(&.{}, "org.kde.kate"));
}

test "appendAurInstalledNames adds one name per installed package" {
    const allocator = std.testing.allocator;

    const packages = [_]AurPackage{
        .{ .Id = 1, .Name = "kate", .PackageBaseId = 1, .PackageBase = "kate", .Version = "1", .NumVotes = 0, .Popularity = 0, .FirstSubmitted = 0, .LastModified = 0, .UrlPath = "" },
        .{ .Id = 2, .Name = "foo-docs", .PackageBaseId = 2, .PackageBase = "foo", .Version = "1", .NumVotes = 0, .Popularity = 0, .FirstSubmitted = 0, .LastModified = 0, .UrlPath = "" },
    };

    var names: std.ArrayListUnmanaged([:0]const u8) = .empty;
    try appendAurInstalledNames(allocator, &packages, &names);

    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    try std.testing.expectEqualStrings("kate", names.items[0]);
    try std.testing.expectEqualStrings("foo-docs", names.items[1]);
    freeNames(allocator, &names);
}
