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
    InstalledFrom: ?[]const u8 = null,
    InstalledFromInferred: bool = false,
    AvailableFrom: []const RepositoryVersion = &.{},
};

pub const RepositoryVersion = struct {
    Repository: []const u8 = "",
    Version: []const u8 = "",
};

const FileNode = struct { Name: []const u8, Files: []const FileNode };

pub const RepositoryCopy = struct {
    repository: []const u8,
    version: []const u8,
};

pub const InstalledCopy = struct {
    index: usize,
    /// false when the origin is unknown; the row then shows as `local`.
    known: bool,
};

/// recorded or inferred origin, else the only copy with the installed version,
/// else the first copy, marked unknown.
pub fn installedCopy(copies: []const RepositoryCopy, installed: Package) ?InstalledCopy {
    if (copies.len == 0) return null;
    if (installed.InstalledFrom) |origin| {
        for (copies, 0..) |copy, index| {
            if (std.mem.eql(u8, copy.repository, origin)) return .{ .index = index, .known = true };
        }
        return .{ .index = 0, .known = false };
    }
    if (installed.Version.len == 0) return .{ .index = 0, .known = false };
    var match: ?usize = null;
    for (copies, 0..) |copy, index| {
        if (!std.mem.eql(u8, copy.version, installed.Version)) continue;
        if (match != null) return .{ .index = 0, .known = false };
        match = index;
    }
    if (match) |index| return .{ .index = index, .known = true };
    return .{ .index = 0, .known = false };
}

/// `repo/name`, or the bare name when the repository is unknown.
pub fn packageTarget(allocator: std.mem.Allocator, name: []const u8, repository: []const u8) ![:0]u8 {
    if (repository.len == 0 or std.mem.eql(u8, repository, "local"))
        return allocator.dupeSentinel(u8, name, 0);
    return std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ repository, name }, 0);
}

/// the package name of a `repo/name` target. file paths and archives are
/// returned unchanged.
pub fn packageName(value: []const u8) []const u8 {
    if (value.len == 0 or value[0] == '/' or value[0] == '.' or value[0] == '~') return value;
    const slash = std.mem.indexOfScalar(u8, value, '/') orelse return value;
    if (slash == 0 or std.mem.indexOfScalarPos(u8, value, slash + 1, '/') != null) return value;
    const name = value[slash + 1 ..];
    if (name.len == 0 or std.ascii.findIgnoreCase(name, ".pkg.tar") != null) return value;
    inline for (.{ ".tar", ".tar.gz", ".tgz", ".tar.zst", ".tzst" }) |suffix| {
        if (std.ascii.endsWithIgnoreCase(name, suffix)) return value;
    }
    return name;
}

/// Build the Packages tab from repository results, prioritizing installed package
/// metadata over sync repository metadata. The returned slice borrows strings from both inputs.
pub fn repositoryPackageList(allocator: std.mem.Allocator, available: []const Package, installed: ?[]const Package) ![]Package {
    const packages = try allocator.dupe(Package, available);
    errdefer allocator.free(packages);

    if (installed) |local| {
        var rows: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(usize)) = .empty;
        defer {
            var it = rows.valueIterator();
            while (it.next()) |list| list.deinit(allocator);
            rows.deinit(allocator);
        }
        for (packages, 0..) |pkg, index| {
            const entry = try rows.getOrPut(allocator, pkg.Name);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(allocator, index);
        }
        var owners: std.AutoHashMapUnmanaged(usize, struct { pkg: *const Package, known: bool }) = .empty;
        defer owners.deinit(allocator);
        var copies: std.ArrayListUnmanaged(RepositoryCopy) = .empty;
        defer copies.deinit(allocator);
        for (local) |*ipkg| {
            const indexes = rows.get(ipkg.Name) orelse continue;
            copies.clearRetainingCapacity();
            for (indexes.items) |index| try copies.append(allocator, .{ .repository = packages[index].Repository, .version = packages[index].Version });
            const choice = installedCopy(copies.items, ipkg.*) orelse continue;
            try owners.put(allocator, indexes.items[choice.index], .{ .pkg = ipkg, .known = choice.known });
        }

        for (packages, 0..) |*pkg, index| {
            if (owners.get(index)) |owner| {
                const ipkg = owner.pkg;
                pkg.Installed = true;
                pkg.Version = ipkg.Version;
                // keeps the target a bare name; details still show the origin.
                if (!owner.known) pkg.Repository = ipkg.Repository;
                pkg.InstalledFrom = ipkg.InstalledFrom;
                pkg.InstalledFromInferred = ipkg.InstalledFromInferred;
                if (owner.known and ipkg.InstalledFrom == null) {
                    pkg.InstalledFrom = pkg.Repository;
                    pkg.InstalledFromInferred = true;
                }
                pkg.InstallDate = ipkg.InstallDate;
                pkg.InstalledSize = ipkg.InstalledSize;
                pkg.InstallReason = ipkg.InstallReason;
                if (ipkg.BuildDate.len > 0) {
                    pkg.BuildDate = ipkg.BuildDate;
                }
                pkg.Explicit = std.mem.eql(u8, ipkg.InstallReason, "Explicit");
            } else {
                pkg.Installed = false;
                pkg.InstallDate = null;
                pkg.Explicit = false;
            }
        }
    }

    return packages;
}

test "repository package list marks only the repository copy a package was installed from" {
    const available = [_]Package{
        .{ .Name = "foo", .Repository = "first", .Version = "1-1" },
        .{ .Name = "foo", .Repository = "second", .Version = "1-1" },
        .{ .Name = "bar", .Repository = "first", .Version = "2-1" },
        .{ .Name = "bar", .Repository = "second", .Version = "2-2" },
        .{ .Name = "baz", .Repository = "first", .Version = "3-1" },
        .{ .Name = "baz", .Repository = "second", .Version = "3-1" },
    };
    const installed = [_]Package{
        .{ .Name = "foo", .Repository = "local", .Version = "1-1", .InstalledFrom = "second" },
        .{ .Name = "bar", .Repository = "local", .Version = "2-2" },
        .{ .Name = "baz", .Repository = "local", .Version = "3-1" },
    };
    const packages = try repositoryPackageList(std.testing.allocator, &available, &installed);
    defer std.testing.allocator.free(packages);

    try std.testing.expect(!packages[0].Installed);
    try std.testing.expect(packages[1].Installed);
    try std.testing.expectEqualStrings("second", packages[1].Repository);
    try std.testing.expectEqualStrings("second", packages[1].InstalledFrom.?);
    try std.testing.expect(!packages[2].Installed);
    try std.testing.expect(packages[3].Installed);
    try std.testing.expectEqualStrings("second", packages[3].Repository);
    try std.testing.expect(packages[3].InstalledFromInferred);
    try std.testing.expect(packages[4].Installed);
    try std.testing.expectEqualStrings("local", packages[4].Repository);
    try std.testing.expect(!packages[5].Installed);
}

test "installedCopy keeps an origin outside the listed repositories" {
    const copies = [_]RepositoryCopy{ .{ .repository = "first", .version = "1-1" }, .{ .repository = "second", .version = "1-1" } };
    const disabled = installedCopy(&copies, .{ .Name = "foo", .Version = "1-1", .InstalledFrom = "testing" }).?;
    try std.testing.expectEqual(@as(usize, 0), disabled.index);
    try std.testing.expect(!disabled.known);
    try std.testing.expect(installedCopy(&.{}, .{ .Name = "foo" }) == null);
}

test "repository package list keeps an unlisted origin out of the install target" {
    const available = [_]Package{
        .{ .Name = "foo", .Repository = "extra", .Version = "1-1" },
    };
    const installed = [_]Package{
        .{ .Name = "foo", .Repository = "local", .Version = "1-1", .InstalledFrom = "testing" },
    };
    const packages = try repositoryPackageList(std.testing.allocator, &available, &installed);
    defer std.testing.allocator.free(packages);
    try std.testing.expect(packages[0].Installed);
    try std.testing.expectEqualStrings("local", packages[0].Repository);
    try std.testing.expectEqualStrings("testing", packages[0].InstalledFrom.?);
    const target = try packageTarget(std.testing.allocator, packages[0].Name, packages[0].Repository);
    defer std.testing.allocator.free(target);
    try std.testing.expectEqualStrings("foo", target);
}

test "packageTarget names the repository unless it is unknown" {
    const allocator = std.testing.allocator;
    const qualified = try packageTarget(allocator, "foo", "extra");
    defer allocator.free(qualified);
    try std.testing.expectEqualStrings("extra/foo", qualified);
    const local = try packageTarget(allocator, "foo", "local");
    defer allocator.free(local);
    try std.testing.expectEqualStrings("foo", local);
    const empty = try packageTarget(allocator, "foo", "");
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("foo", empty);
}

test "packageName strips the repository but keeps file paths" {
    try std.testing.expectEqualStrings("foo", packageName("extra/foo"));
    try std.testing.expectEqualStrings("python-zope.interface", packageName("extra/python-zope.interface"));
    try std.testing.expectEqualStrings("foo", packageName("foo"));
    try std.testing.expectEqualStrings("build/demo-1-1-any.pkg.tar.zst", packageName("build/demo-1-1-any.pkg.tar.zst"));
    try std.testing.expectEqualStrings("build/Demo-1-1-any.PKG.TAR.XZ", packageName("build/Demo-1-1-any.PKG.TAR.XZ"));
    try std.testing.expectEqualStrings("/tmp/demo.pkg.tar.zst", packageName("/tmp/demo.pkg.tar.zst"));
    try std.testing.expectEqualStrings("org.example.App", packageName("org.example.App"));
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
    try std.testing.expectEqualStrings("local", packages[0].Repository);
    try std.testing.expectEqualStrings("1.0", packages[0].Version);
    try std.testing.expect(packages[0].Installed);
    try std.testing.expect(packages[0].Explicit);
    try std.testing.expectEqualStrings("2026-10-27", packages[0].InstallDate.?);
    try std.testing.expectEqualStrings("library", packages[1].Name);
    try std.testing.expectEqualStrings("local", packages[1].Repository);
    try std.testing.expect(packages[1].Installed);
    try std.testing.expect(!packages[1].Explicit);
    try std.testing.expectEqualStrings("available", packages[2].Name);
    try std.testing.expect(!packages[2].Installed);
    try std.testing.expect(!packages[2].Explicit);
    try std.testing.expectEqual(null, packages[2].InstallDate);
}

test "repository package list prioritizes installed package version and metadata" {
    const available = [_]Package{
        .{
            .Name = "plasma5support",
            .Version = "6.7.5-1.1",
            .Repository = "cachyos-extra-v3",
            .InstalledSize = 0,
        },
        .{
            .Name = "uninstalled-pkg",
            .Version = "1.0.0",
            .Repository = "extra",
        },
    };

    const installed = [_]Package{
        .{
            .Name = "plasma5support",
            .Version = "6.8.0-1",
            .Repository = "local",
            .InstalledSize = 123456,
            .InstallReason = "Explicit",
            .InstallDate = "2026-10-14",
        },
        .{
            .Name = "local-only-pkg",
            .Version = "2.0.0",
            .Repository = "local",
            .InstallReason = "Dependency",
        },
    };

    const packages = try repositoryPackageList(std.testing.allocator, &available, &installed);
    defer std.testing.allocator.free(packages);

    try std.testing.expectEqual(@as(usize, 2), packages.len);

    try std.testing.expectEqualStrings("plasma5support", packages[0].Name);
    try std.testing.expectEqualStrings("6.8.0-1", packages[0].Version);
    try std.testing.expectEqualStrings("local", packages[0].Repository);
    try std.testing.expectEqual(true, packages[0].Installed);
    try std.testing.expectEqual(true, packages[0].Explicit);
    try std.testing.expectEqual(@as(i64, 123456), packages[0].InstalledSize);

    try std.testing.expectEqualStrings("uninstalled-pkg", packages[1].Name);
    try std.testing.expectEqualStrings("1.0.0", packages[1].Version);
    try std.testing.expectEqualStrings("extra", packages[1].Repository);
    try std.testing.expectEqual(false, packages[1].Installed);
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
