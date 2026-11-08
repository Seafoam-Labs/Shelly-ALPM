//! Atoll catalog pages.
const std = @import("std");
const Http = @import("ShellyHttp");
const AurPackage = @import("../models/packages.zig").AurPackage;
const source = @import("../models/settings.zig");
pub const page_size = 50;

pub const Page = struct {
    packages: std.json.Parsed([]AurPackage),
    page: u32,
    total_pages: u32,
};

pub fn pageUrl(allocator: std.mem.Allocator, page: u32) ![]u8 {
    if (page == 0) return error.InvalidCatalogPage;
    return std.fmt.allocPrint(allocator, "{s}/v1/packages?page={d}&limit={d}&sortBy=Votes&order=Desc", .{ source.aurUrl(true), page, page_size });
}

pub fn fetch(allocator: std.mem.Allocator, io: std.Io, page: u32) !Page {
    const url = try pageUrl(allocator, page);
    defer allocator.free(url);
    var client: Http = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    const bytes = try allocator.alloc(u8, 2 * 1024 * 1024);
    defer allocator.free(bytes);
    var writer = std.Io.Writer.fixed(bytes);
    const response = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &writer, .headers = .{ .user_agent = .{ .override = "Shelly-TUI" } } });
    if (response.status != .ok) return error.CatalogHttpFailure;
    return parse(allocator, writer.buffered(), page);
}

const Entry = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    version: ?[]const u8 = null,
    numVotes: ?i64 = null,
    popularity: ?f64 = null,
    outOfDate: ?i64 = null,
    url: ?[]const u8 = null,
    maintainer: ?[]const u8 = null,
    packageBase: ?[]const u8 = null,
    firstSubmitted: ?i64 = null,
    lastModified: ?i64 = null,
    license: ?[]const []const u8 = null,
    depends: ?[]const []const u8 = null,
    makeDepends: ?[]const []const u8 = null,
    optDepends: ?[]const []const u8 = null,
    provides: ?[]const []const u8 = null,
};
const WirePage = struct { items: []const Entry, page: u32, totalPages: u32 };

fn parse(allocator: std.mem.Allocator, body: []const u8, requested: u32) !Page {
    var parsed = try std.json.parseFromSlice(WirePage, allocator, body, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    const wire = parsed.value;
    if (requested == 0 or wire.page != requested or wire.items.len > page_size or (wire.totalPages > 0 and wire.page > wire.totalPages) or (wire.totalPages == 0 and wire.items.len > 0)) return error.InvalidCatalogPage;
    const items = try parsed.arena.allocator().alloc(AurPackage, wire.items.len);
    for (wire.items, items) |item, *pkg| {
        if (item.name.len == 0) return error.InvalidCatalogPage;
        pkg.* = .{
            .Name = item.name,
            .PackageBase = item.packageBase orelse item.name,
            .Version = item.version orelse "",
            .Description = item.description,
            .NumVotes = item.numVotes orelse 0,
            .Popularity = item.popularity orelse 0,
            .OutOfDate = item.outOfDate,
            .Url = item.url,
            .Maintainer = item.maintainer,
            .FirstSubmitted = item.firstSubmitted orelse 0,
            .LastModified = item.lastModified orelse 0,
            .License = item.license,
            .Depends = item.depends,
            .MakeDepends = item.makeDepends,
            .OptDepends = item.optDepends,
            .Provides = item.provides,
            .AurBaseUrl = source.aurUrl(true),
        };
    }
    return .{ .packages = .{ .arena = parsed.arena, .value = items }, .page = wire.page, .total_pages = wire.totalPages };
}

test "catalog pages own metadata and request fifty packages ordered by votes" {
    const allocator = std.testing.allocator;
    const url = try pageUrl(allocator, 2);
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://atoll.seafoam-labs.org/v1/packages?page=2&limit=50&sortBy=Votes&order=Desc", url);
    const body = try allocator.dupe(u8, "{\"page\":2,\"totalPages\":3,\"items\":[{\"name\":\"demo\",\"version\":\"1\",\"numVotes\":12,\"depends\":[\"libdemo\"]}]}");
    const page = try parse(allocator, body, 2);
    allocator.free(body);
    defer page.packages.deinit();
    try std.testing.expectEqual(@as(u32, 3), page.total_pages);
    try std.testing.expectEqualStrings("demo", page.packages.value[0].Name);
    try std.testing.expectEqualStrings("libdemo", page.packages.value[0].Depends.?[0]);
    try std.testing.expectEqual(@as(i64, 12), page.packages.value[0].NumVotes);
}

test "catalog rejects mismatched or invalid page metadata" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidCatalogPage, pageUrl(allocator, 0));
    try std.testing.expectError(error.InvalidCatalogPage, parse(allocator, "{\"page\":2,\"totalPages\":2,\"items\":[]}", 1));
    try std.testing.expectError(error.InvalidCatalogPage, parse(allocator, "{\"page\":1,\"totalPages\":0,\"items\":[{\"name\":\"demo\"}]}", 1));
    const empty = try parse(allocator, "{\"page\":1,\"totalPages\":0,\"items\":[]}", 1);
    defer empty.packages.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.packages.value.len);
}
