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

pub const InstalledPackage = struct {
    Name: []const u8,
    Version: []const u8 = "",
    InstalledFrom: ?[]const u8 = null,
};

/// marks one copy per installed name: its recorded origin, else the only copy
/// with the installed version, else the first copy.
pub fn markInstalled(allocator: std.mem.Allocator, available: []Package, installed: []const InstalledPackage) !void {
    if (available.len == 0 or installed.len == 0) return;
    var by_name: std.HashMapUnmanaged([]const u8, usize, InstalledNameContext, std.hash_map.default_max_load_percentage) = .empty;
    defer by_name.deinit(allocator);
    try by_name.ensureTotalCapacity(allocator, @intCast(installed.len));
    const copies = try allocator.alloc(CopyMatches, installed.len);
    defer allocator.free(copies);
    @memset(copies, .{});
    for (installed, 0..) |pkg, position| by_name.putAssumeCapacity(pkg.Name, position);

    for (available, 0..) |row, index| {
        const position = by_name.get(row.Name) orelse continue;
        const pkg = installed[position];
        const matches = &copies[position];
        if (matches.first == null) matches.first = index;
        if (pkg.InstalledFrom) |origin| {
            if (matches.origin == null and std.mem.eql(u8, row.Repository, origin)) matches.origin = index;
        } else if (pkg.Version.len > 0 and std.mem.eql(u8, row.Version, pkg.Version)) {
            if (matches.version == null) matches.version = index;
            matches.version_count += 1;
        }
    }

    for (installed, copies) |pkg, matches| {
        const first = matches.first orelse continue;
        const known: ?usize = if (pkg.InstalledFrom != null)
            matches.origin
        else if (matches.version_count == 1)
            matches.version
        else
            null;
        const row = &available[known orelse first];
        row.Installed = true;
        if (pkg.InstalledFrom) |origin| {
            row.InstalledFrom = origin;
        } else if (known != null) {
            row.InstalledFrom = row.Repository;
            row.InstalledFromInferred = true;
        }
        // keeps the target a bare name, so reinstalling does not switch repository.
        row.InstalledOriginUnknown = known == null;
    }
}

/// indexes into the available list.
const CopyMatches = struct {
    first: ?usize = null,
    origin: ?usize = null,
    version: ?usize = null,
    version_count: usize = 0,
};

/// keeps origins valid after the installed list is freed.
pub fn ownInstalledOrigins(allocator: std.mem.Allocator, available: []Package) !void {
    for (available) |*pkg| {
        if (pkg.InstalledFrom) |origin| pkg.InstalledFrom = try allocator.dupe(u8, origin);
    }
}

/// an empty repository matches every copy.
pub const Selection = struct {
    name: []const u8,
    repository: []const u8 = "",

    pub fn matches(self: Selection, pkg: Package) bool {
        if (!std.mem.eql(u8, self.name, pkg.Name)) return false;
        return self.repository.len == 0 or std.mem.eql(u8, self.repository, pkg.Repository);
    }
};

/// `repo/name`, or the bare name when the repository or origin is unknown.
pub fn packageTarget(allocator: std.mem.Allocator, pkg: Package) ![]const u8 {
    if (pkg.Repository.len == 0 or std.mem.eql(u8, pkg.Repository, "local") or pkg.InstalledOriginUnknown)
        return allocator.dupe(u8, pkg.Name);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ pkg.Repository, pkg.Name });
}

pub const Package = struct {
    Name: []const u8 = "",
    Version: []const u8 = "",
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
    BuildDate: []const u8 = "",
    DownloadSize: i64 = 0,
    InstalledSize: i64 = 0,
    Installed: bool = false,
    InstalledFrom: ?[]const u8 = null,
    /// guessed from a matching version.
    InstalledFromInferred: bool = false,
    /// marked installed, but may have come from another repository.
    InstalledOriginUnknown: bool = false,
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
            const installed = [_]InstalledPackage{ .{ .Name = "Demo" }, .{ .Name = "demo" }, .{ .Name = "absent" } };
            try markInstalled(allocator, &available, &installed);
            // names match without case; with no origin or version, the first copy wins.
            const expected = [_]bool{ true, false, false, true, false };
            for (available, expected) |pkg, want| try std.testing.expectEqual(want, pkg.Installed);
            try std.testing.expectEqualStrings("DEMO", available[1].Name);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "installed matching marks only the repository copy a package came from" {
    var available = [_]Package{
        .{ .Name = "foo", .Repository = "first", .Version = "1-1" },
        .{ .Name = "foo", .Repository = "second", .Version = "1-1" },
        .{ .Name = "bar", .Repository = "first", .Version = "2-1" },
        .{ .Name = "bar", .Repository = "second", .Version = "2-2" },
    };
    const installed = [_]InstalledPackage{
        .{ .Name = "foo", .Version = "1-1", .InstalledFrom = "second" },
        .{ .Name = "bar", .Version = "2-2" },
    };
    try markInstalled(std.testing.allocator, &available, &installed);
    try std.testing.expect(!available[0].Installed);
    try std.testing.expect(available[1].Installed);
    try std.testing.expectEqualStrings("second", available[1].InstalledFrom.?);
    try std.testing.expect(!available[2].Installed);
    try std.testing.expect(available[3].Installed);
    try std.testing.expectEqualStrings("second", available[3].InstalledFrom.?);
    try std.testing.expect(!available[1].InstalledFromInferred);
    try std.testing.expect(available[3].InstalledFromInferred);

    const allocator = std.testing.allocator;
    const qualified = try packageTarget(allocator, available[1]);
    defer allocator.free(qualified);
    try std.testing.expectEqualStrings("second/foo", qualified);
    const bare = try packageTarget(allocator, .{ .Name = "foo", .Repository = "local" });
    defer allocator.free(bare);
    try std.testing.expectEqualStrings("foo", bare);

    const any: Selection = .{ .name = "foo" };
    const exact: Selection = .{ .name = "foo", .repository = "second" };
    try std.testing.expect(any.matches(available[0]) and any.matches(available[1]));
    try std.testing.expect(!exact.matches(available[0]) and exact.matches(available[1]));
}

test "installed matching keeps an unlisted origin out of the install target" {
    var available = [_]Package{
        .{ .Name = "foo", .Repository = "extra", .Version = "1-1" },
    };
    const installed = [_]InstalledPackage{
        .{ .Name = "foo", .Version = "1-1", .InstalledFrom = "testing" },
    };
    try markInstalled(std.testing.allocator, &available, &installed);
    try std.testing.expect(available[0].Installed);
    try std.testing.expectEqualStrings("testing", available[0].InstalledFrom.?);
    const target = try packageTarget(std.testing.allocator, available[0]);
    defer std.testing.allocator.free(target);
    try std.testing.expectEqualStrings("foo", target);
}

test "installed matching keeps the repository of a copy whose origin is unknown" {
    var available = [_]Package{
        .{ .Name = "bash", .Repository = "core", .Version = "5.3-2" },
        .{ .Name = "foo", .Repository = "first", .Version = "1-1" },
        .{ .Name = "foo", .Repository = "second", .Version = "1-1" },
    };
    const installed = [_]InstalledPackage{
        .{ .Name = "bash", .Version = "5.3-1" },
        .{ .Name = "foo", .Version = "1-1" },
    };
    try markInstalled(std.testing.allocator, &available, &installed);
    try std.testing.expect(available[0].Installed);
    try std.testing.expectEqualStrings("core", available[0].Repository);
    try std.testing.expect(available[0].InstalledOriginUnknown);
    try std.testing.expect(available[0].InstalledFrom == null);
    try std.testing.expect(available[1].Installed and !available[2].Installed);
    try std.testing.expectEqualStrings("first", available[1].Repository);
    try std.testing.expect(available[1].InstalledOriginUnknown);
    const target = try packageTarget(std.testing.allocator, available[0]);
    defer std.testing.allocator.free(target);
    try std.testing.expectEqualStrings("bash", target);
}

test "installed origins outlive the installed list they came from" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var available = [_]Package{.{ .Name = "foo", .Repository = "extra", .Version = "1-1" }};
    const origin = try std.testing.allocator.dupe(u8, "extra");
    const installed = [_]InstalledPackage{.{ .Name = "foo", .Version = "1-1", .InstalledFrom = origin }};
    try markInstalled(std.testing.allocator, &available, &installed);
    try ownInstalledOrigins(arena.allocator(), &available);
    @memset(origin, 0);
    std.testing.allocator.free(origin);
    try std.testing.expectEqualStrings("extra", available[0].InstalledFrom.?);
}

test "empty installed matching does not allocate or clear existing flags" {
    var available = [_]Package{.{ .Name = "demo", .Installed = true }};
    try markInstalled(std.testing.failing_allocator, &available, &.{});
    try std.testing.expect(available[0].Installed);
    try markInstalled(std.testing.failing_allocator, &.{}, &.{.{ .Name = "demo" }});
}
