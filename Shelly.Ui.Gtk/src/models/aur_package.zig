const std = @import("std");

pub const AurPackage = struct {
    Id: u32,
    Name: [:0]const u8,
    PackageBaseId: u32,
    PackageBase: [:0]const u8,
    Version: [:0]const u8,
    Description: ?[:0]const u8 = null,
    Url: ?[:0]const u8 = null,
    NumVotes: u32,
    Popularity: f64,
    OutOfDate: ?i64 = null,
    Maintainer: ?[:0]const u8 = null,
    FirstSubmitted: i64,
    LastModified: i64,
    UrlPath: [:0]const u8,
    Depends: ?[]const [:0]const u8 = null,
    MakeDepends: ?[]const [:0]const u8 = null,
    OptDepends: ?[]const [:0]const u8 = null,
    CheckDepends: ?[]const [:0]const u8 = null,
    Conflicts: ?[]const [:0]const u8 = null,
    Provides: ?[]const [:0]const u8 = null,
    Replaces: ?[]const [:0]const u8 = null,
    Groups: ?[]const [:0]const u8 = null,
    License: ?[]const [:0]const u8 = null,
    Keywords: ?[]const [:0]const u8 = null,
    Explicit: bool = false,

    pub fn clone(allocator: std.mem.Allocator, source: AurPackage) !AurPackage {
        return .{
            .Id = source.Id,
            .Name = try allocator.dupeZ(u8, source.Name),
            .PackageBaseId = source.PackageBaseId,
            .PackageBase = try allocator.dupeZ(u8, source.PackageBase),
            .Version = try allocator.dupeZ(u8, source.Version),
            .Description = if (source.Description) |value| try allocator.dupeZ(u8, value) else null,
            .Url = if (source.Url) |value| try allocator.dupeZ(u8, value) else null,
            .NumVotes = source.NumVotes,
            .Popularity = source.Popularity,
            .OutOfDate = source.OutOfDate,
            .Maintainer = if (source.Maintainer) |value| try allocator.dupeZ(u8, value) else null,
            .FirstSubmitted = source.FirstSubmitted,
            .LastModified = source.LastModified,
            .UrlPath = try allocator.dupeZ(u8, source.UrlPath),
            .Depends = try cloneOptionalStrings(allocator, source.Depends),
            .MakeDepends = try cloneOptionalStrings(allocator, source.MakeDepends),
            .OptDepends = try cloneOptionalStrings(allocator, source.OptDepends),
            .CheckDepends = try cloneOptionalStrings(allocator, source.CheckDepends),
            .Conflicts = try cloneOptionalStrings(allocator, source.Conflicts),
            .Provides = try cloneOptionalStrings(allocator, source.Provides),
            .Replaces = try cloneOptionalStrings(allocator, source.Replaces),
            .Groups = try cloneOptionalStrings(allocator, source.Groups),
            .License = try cloneOptionalStrings(allocator, source.License),
            .Keywords = try cloneOptionalStrings(allocator, source.Keywords),
            .Explicit = source.Explicit,
        };
    }

    fn cloneOptionalStrings(
        allocator: std.mem.Allocator,
        source: ?[]const [:0]const u8,
    ) !?[]const [:0]const u8 {
        const values = source orelse return null;
        const result = try allocator.alloc([:0]const u8, values.len);
        for (values, 0..) |value, index| result[index] = try allocator.dupeZ(u8, value);
        return result;
    }
};
