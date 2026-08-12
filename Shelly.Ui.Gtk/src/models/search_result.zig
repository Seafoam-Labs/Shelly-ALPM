const std = @import("std");
const AurPackage = @import("aur_package.zig").AurPackage;
const Hit = @import("flatpak.zig").Hit;

pub const Source = enum(u8) {
    standard,
    aur,
    flatpak,
};

pub const SearchResult = struct {
    source: Source = .standard,
    name: [:0]const u8 = "",
    install_target: [:0]const u8 = "",
    version: [:0]const u8 = "",
    description: [:0]const u8 = "",
    repository: [:0]const u8 = "",
    installed: bool = false,
    out_of_date: bool = false,
    verified: bool = false,
    aur: ?AurPackage = null,
    flatpak: ?Hit = null,
};

pub fn clone(allocator: std.mem.Allocator, item: SearchResult) !SearchResult {
    return .{
        .source = item.source,
        .name = try allocator.dupeZ(u8, item.name),
        .install_target = try allocator.dupeZ(u8, item.install_target),
        .version = try allocator.dupeZ(u8, item.version),
        .description = try allocator.dupeZ(u8, item.description),
        .repository = try allocator.dupeZ(u8, item.repository),
        .installed = item.installed,
        .out_of_date = item.out_of_date,
        .verified = item.verified,
        .aur = if (item.aur) |value| try AurPackage.clone(allocator, value) else null,
        .flatpak = if (item.flatpak) |value| try Hit.clone(allocator, value) else null,
    };
}

test "SearchResult defaults to a standard package" {
    try std.testing.expectEqual(Source.standard, (SearchResult{}).source);
    try std.testing.expectEqualStrings("", (SearchResult{}).name);
    try std.testing.expect(!(SearchResult{}).installed);
    try std.testing.expect((SearchResult{}).aur == null);
    try std.testing.expect((SearchResult{}).flatpak == null);
}

test "SearchResult clone deep-copies aur and flatpak payloads" {
    const item = SearchResult{
        .source = .aur,
        .name = "polymc",
        .install_target = "polymc",
        .version = "7.1-2",
        .description = "Minecraft launcher",
        .repository = "AUR",
        .out_of_date = true,
        .aur = .{
            .Id = 2160856,
            .Name = "polymc",
            .PackageBaseId = 174947,
            .PackageBase = "polymc",
            .Version = "7.1-2",
            .Description = "Minecraft launcher",
            .Url = "https://github.com/PolyMC/PolyMC",
            .NumVotes = 74,
            .Popularity = 1.766204,
            .Maintainer = "LennyLennington",
            .FirstSubmitted = 1641934424,
            .LastModified = 1783993900,
            .UrlPath = "/cgit/aur.git/snapshot/polymc.tar.gz",
            .Depends = &.{ "java-runtime", "libgl" },
            .License = &.{"GPL3"},
        },
    };

    const copy = try clone(std.testing.allocator, item);
    defer {
        std.testing.allocator.free(copy.name);
        std.testing.allocator.free(copy.install_target);
        std.testing.allocator.free(copy.version);
        std.testing.allocator.free(copy.description);
        std.testing.allocator.free(copy.repository);
        const aur = copy.aur.?;
        std.testing.allocator.free(aur.Name);
        std.testing.allocator.free(aur.PackageBase);
        std.testing.allocator.free(aur.Version);
        std.testing.allocator.free(aur.Description.?);
        std.testing.allocator.free(aur.Url.?);
        std.testing.allocator.free(aur.Maintainer.?);
        std.testing.allocator.free(aur.UrlPath);
        for (aur.Depends.?) |value| std.testing.allocator.free(value);
        std.testing.allocator.free(aur.Depends.?);
        for (aur.License.?) |value| std.testing.allocator.free(value);
        std.testing.allocator.free(aur.License.?);
    }

    try std.testing.expectEqualStrings("polymc", copy.name);
    try std.testing.expectEqual(@as(u32, 74), copy.aur.?.NumVotes);
    try std.testing.expectEqualStrings("libgl", copy.aur.?.Depends.?[1]);
    try std.testing.expect(copy.flatpak == null);
}
