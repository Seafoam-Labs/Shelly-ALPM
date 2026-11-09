const std = @import("std");

const InstalledNameContext = struct {
    pub fn hash(_: InstalledNameContext, name: []const u8) u64 {
        var hasher = std.hash.Fnv1a_64.init();
        for (name) |byte| hasher.update(&.{std.ascii.toLower(byte)});
        return hasher.final();
    }

    pub fn eql(_: InstalledNameContext, a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }
};

pub fn markInstalled(allocator: std.mem.Allocator, available: []Package, installed: []const Package) !void {
    if (available.len == 0 or installed.len == 0) return;
    var names: std.HashMap([]const u8, void, InstalledNameContext, std.hash_map.default_max_load_percentage) = .init(allocator);
    defer names.deinit();
    try names.ensureTotalCapacity(@intCast(installed.len));
    for (installed) |pkg| names.putAssumeCapacity(pkg.Name, {});
    for (available) |*pkg| {
        if (names.contains(pkg.Name)) pkg.Installed = true;
    }
}

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
};

/// AUR package as emitted by `shelly search aur --ui-mode`. Field names
/// mirror the CLI's PascalCase JSON keys, not the AUR RPC names.
pub const AurPackage = struct {
    /// Frontend-only source identity, populated from the CLI configuration.
    AurBaseUrl: []const u8 = "https://aur.archlinux.org",
    /// Local state populated from the installed-package query, not AUR search.
    Installed: bool = false,
    Id: i64 = 0,
    Name: []const u8 = "",
    PackageBaseId: i64 = 0,
    PackageBase: []const u8 = "",
    Version: []const u8 = "",
    Description: ?[]const u8 = null,
    Url: ?[]const u8 = null,
    NumVotes: i64 = 0,
    Popularity: f64 = 0,
    OutOfDate: ?i64 = null,
    Maintainer: ?[]const u8 = null,
    FirstSubmitted: i64 = 0,
    LastModified: i64 = 0,
    UrlPath: ?[]const u8 = null,
    Depends: ?[]const []const u8 = null,
    MakeDepends: ?[]const []const u8 = null,
    OptDepends: ?[]const []const u8 = null,
    CheckDepends: ?[]const []const u8 = null,
    Conflicts: ?[]const []const u8 = null,
    Provides: ?[]const []const u8 = null,
    Replaces: ?[]const []const u8 = null,
    Groups: ?[]const []const u8 = null,
    License: ?[]const []const u8 = null,
    Keywords: ?[]const []const u8 = null,
    Explicit: bool = false,
};

const FileNode = struct { Name: []const u8, Files: []const FileNode };

test "installed matching preserves case folding, duplicates and existing flags" {
    const Case = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var available = [_]Package{
                .{ .Name = "demo", .Repository = "core" },
                .{ .Name = "DEMO", .Repository = "extra" },
                .{ .Name = "other" },
                .{ .Name = "previous", .Installed = true },
                .{ .Name = "demo-tools" },
            };
            const installed = [_]Package{ .{ .Name = "Demo" }, .{ .Name = "demo" }, .{ .Name = "absent" } };
            try markInstalled(allocator, &available, &installed);
            const expected = [_]bool{ true, true, false, true, false };
            for (available, expected) |pkg, want| try std.testing.expectEqual(want, pkg.Installed);
            try std.testing.expectEqualStrings("DEMO", available[1].Name);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "empty installed matching does not allocate or clear existing flags" {
    var available = [_]Package{.{ .Name = "demo", .Installed = true }};
    try markInstalled(std.testing.failing_allocator, &available, &.{});
    try std.testing.expect(available[0].Installed);
    try markInstalled(std.testing.failing_allocator, &.{}, &available);
}
