const std = @import("std");
const Io = std.Io;
const AurPackage = @import("../models/aur_package.zig").AurPackage;

pub const AtollApiService = struct {
    pub const base_url = "https://atoll.seafoam-labs.org";

    pub const page_size: u32 = 50;

    pub const SortBy = enum {
        name,
        votes,
        popularity,
        version,

        fn param(self: SortBy) []const u8 {
            return switch (self) {
                .name => "Name",
                .votes => "Votes",
                .popularity => "Popularity",
                .version => "Version",
            };
        }
    };

    pub const Order = enum {
        asc,
        desc,

        fn param(self: Order) []const u8 {
            return switch (self) {
                .asc => "Asc",
                .desc => "Desc",
            };
        }
    };

    pub const By = enum {
        relevance,
        name,
        provides,
        words,

        fn param(self: By) []const u8 {
            return switch (self) {
                .relevance => "Relevance",
                .name => "Name",
                .provides => "Provides",
                .words => "Words",
            };
        }
    };

    pub const IndexPage = struct {
        packages: []AurPackage,
        page: u32,
        total_pages: u32,
        total_items: u64,
    };

    allocator: std.mem.Allocator,
    io: Io,
    client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator, io: Io) AtollApiService {
        return .{
            .allocator = allocator,
            .io = io,
            .client = .{ .allocator = allocator, .io = io },
        };
    }

    pub fn deinit(self: *AtollApiService) void {
        self.client.deinit();
    }

    pub fn getIndexPage(
        self: *AtollApiService,
        page: u32,
        limit: u32,
        sort_by: SortBy,
        order: Order,
    ) !IndexPage {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/v1/packages?page={d}&limit={d}&sortBy={s}&order={s}",
            .{ base_url, page, limit, sort_by.param(), order.param() },
        );
        defer self.allocator.free(url);

        const body = try self.fetchBody(url);
        defer self.allocator.free(body);

        return self.parseIndexPage(body);
    }

    pub fn search(self: *AtollApiService, query: []const u8, by: By) ![]AurPackage {
        const encoded = try self.percentEncode(query);
        defer self.allocator.free(encoded);

        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/v1/search?query={s}&by={s}",
            .{ base_url, encoded, by.param() },
        );
        defer self.allocator.free(url);

        const body = try self.fetchBody(url);
        defer self.allocator.free(body);

        return self.parseSearch(body);
    }

    fn percentEncode(self: *AtollApiService, value: []const u8) ![]u8 {
        var out: Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        try std.Uri.Component.percentEncode(&out.writer, value, isQueryChar);
        return out.toOwnedSlice();
    }

    fn isQueryChar(char: u8) bool {
        return std.ascii.isAlphanumeric(char) or
            char == '-' or char == '.' or char == '_' or char == '~';
    }

    fn fetchBody(self: *AtollApiService, url: []const u8) ![]u8 {
        var body: Io.Writer.Allocating = .init(self.allocator);
        defer body.deinit();

        const result = try self.client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &body.writer,
        });

        if (result.status != .ok) return error.HttpRequestFailed;

        return body.toOwnedSlice();
    }

    fn parseIndexPage(self: *AtollApiService, json: []const u8) !IndexPage {
        const parsed = try std.json.parseFromSlice(
            WireIndexResponse,
            self.allocator,
            json,
            parse_options,
        );

        const wire = parsed.value;
        const items = wire.items orelse &.{};

        const packages = try self.allocator.alloc(AurPackage, items.len);
        for (items, 0..) |item, index| {
            packages[index] = try mapIndexEntry(self.allocator, item);
        }

        return .{
            .packages = packages,
            .page = @intCast(@min(@max(wire.page orelse 0, 0), std.math.maxInt(u32))),
            .total_pages = @intCast(@min(@max(wire.totalPages orelse 0, 0), std.math.maxInt(u32))),
            .total_items = @intCast(@max(wire.totalItems orelse 0, 0)),
        };
    }

    fn parseSearch(self: *AtollApiService, json: []const u8) ![]AurPackage {
        const parsed = try std.json.parseFromSlice(
            []const WireMetadata,
            self.allocator,
            json,
            parse_options,
        );

        const packages = try self.allocator.alloc(AurPackage, parsed.value.len);
        for (parsed.value, 0..) |item, index| {
            packages[index] = try mapMetadata(self.allocator, item);
        }

        return packages;
    }

    const parse_options = std.json.ParseOptions{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    };

    const WireIndexEntry = struct {
        name: []const u8 = "",
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

    const WireIndexResponse = struct {
        items: ?[]const WireIndexEntry = null,
        page: ?i64 = null,
        limit: ?i64 = null,
        totalItems: ?i64 = null,
        totalPages: ?i64 = null,
    };

    const WireMetadata = struct {
        id: ?i64 = null,
        name: []const u8 = "",
        packageBaseId: ?i64 = null,
        packageBase: ?[]const u8 = null,
        version: ?[]const u8 = null,
        description: ?[]const u8 = null,
        url: ?[]const u8 = null,
        numVotes: ?i64 = null,
        popularity: ?f64 = null,
        outOfDate: ?i64 = null,
        maintainer: ?[]const u8 = null,
        firstSubmitted: ?i64 = null,
        lastModified: ?i64 = null,
        urlPath: ?[]const u8 = null,
        depends: ?[]const []const u8 = null,
        makeDepends: ?[]const []const u8 = null,
        optDepends: ?[]const []const u8 = null,
        checkDepends: ?[]const []const u8 = null,
        conflicts: ?[]const []const u8 = null,
        provides: ?[]const []const u8 = null,
        replaces: ?[]const []const u8 = null,
        groups: ?[]const []const u8 = null,
        license: ?[]const []const u8 = null,
        keywords: ?[]const []const u8 = null,
    };

    fn mapIndexEntry(allocator: std.mem.Allocator, wire: WireIndexEntry) !AurPackage {
        return .{
            .Id = 0,
            .Name = try allocator.dupeZ(u8, wire.name),
            .PackageBaseId = 0,
            .PackageBase = try allocator.dupeZ(u8, wire.packageBase orelse wire.name),
            .Version = try allocator.dupeZ(u8, wire.version orelse ""),
            .Description = try dupeOptionalZ(allocator, wire.description),
            .Url = try dupeOptionalZ(allocator, wire.url),
            .NumVotes = toU32(wire.numVotes),
            .Popularity = wire.popularity orelse 0,
            .OutOfDate = wire.outOfDate,
            .Maintainer = try dupeOptionalZ(allocator, wire.maintainer),
            .FirstSubmitted = wire.firstSubmitted orelse 0,
            .LastModified = wire.lastModified orelse 0,
            .UrlPath = try allocator.dupeZ(u8, ""),
            .Depends = try dupeStrings(allocator, wire.depends),
            .MakeDepends = try dupeStrings(allocator, wire.makeDepends),
            .OptDepends = try dupeStrings(allocator, wire.optDepends),
            .Provides = try dupeStrings(allocator, wire.provides),
            .License = try dupeStrings(allocator, wire.license),
        };
    }

    fn mapMetadata(allocator: std.mem.Allocator, wire: WireMetadata) !AurPackage {
        return .{
            .Id = toU32(wire.id),
            .Name = try allocator.dupeZ(u8, wire.name),
            .PackageBaseId = toU32(wire.packageBaseId),
            .PackageBase = try allocator.dupeZ(u8, wire.packageBase orelse wire.name),
            .Version = try allocator.dupeZ(u8, wire.version orelse ""),
            .Description = try dupeOptionalZ(allocator, wire.description),
            .Url = try dupeOptionalZ(allocator, wire.url),
            .NumVotes = toU32(wire.numVotes),
            .Popularity = wire.popularity orelse 0,
            .OutOfDate = wire.outOfDate,
            .Maintainer = try dupeOptionalZ(allocator, wire.maintainer),
            .FirstSubmitted = wire.firstSubmitted orelse 0,
            .LastModified = wire.lastModified orelse 0,
            .UrlPath = try allocator.dupeZ(u8, wire.urlPath orelse ""),
            .Depends = try dupeStrings(allocator, wire.depends),
            .MakeDepends = try dupeStrings(allocator, wire.makeDepends),
            .OptDepends = try dupeStrings(allocator, wire.optDepends),
            .CheckDepends = try dupeStrings(allocator, wire.checkDepends),
            .Conflicts = try dupeStrings(allocator, wire.conflicts),
            .Provides = try dupeStrings(allocator, wire.provides),
            .Replaces = try dupeStrings(allocator, wire.replaces),
            .Groups = try dupeStrings(allocator, wire.groups),
            .License = try dupeStrings(allocator, wire.license),
            .Keywords = try dupeStrings(allocator, wire.keywords),
        };
    }

    fn dupeOptionalZ(allocator: std.mem.Allocator, value: ?[]const u8) !?[:0]const u8 {
        const raw = value orelse return null;
        const duped: [:0]const u8 = try allocator.dupeZ(u8, raw);
        return duped;
    }

    fn dupeStrings(
        allocator: std.mem.Allocator,
        source: ?[]const []const u8,
    ) !?[]const [:0]const u8 {
        const values = source orelse return null;
        const result = try allocator.alloc([:0]const u8, values.len);
        for (values, 0..) |value, index| result[index] = try allocator.dupeZ(u8, value);
        return result;
    }

    fn toU32(value: ?i64) u32 {
        const raw = value orelse return 0;
        if (raw <= 0) return 0;
        return @intCast(@min(raw, std.math.maxInt(u32)));
    }
};

const testing = std.testing;

fn makeService(arena: *std.heap.ArenaAllocator, io: std.Io) AtollApiService {
    return AtollApiService.init(arena.allocator(), io);
}

test "parseIndexPage maps a real Atoll index response" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var svc = makeService(&arena, testing.io);
    defer svc.deinit();

    const json =
        \\{"items":[{"name":"yay","createdAt":"2026-08-21T19:29:03.4196219+00:00",
        \\"updatedAt":"2026-08-21T19:29:03.4196219+00:00",
        \\"headRevisionId":"04762df5f26c37a6c1c3ce77108bea56ee5f94bf9aece804d5499455378d88bf",
        \\"revisionCount":1,
        \\"description":"Yet another yogurt. Pacman wrapper and AUR helper written in go.",
        \\"version":"13.0.1-1","numVotes":2653,"popularity":28.983324,"outOfDate":null,
        \\"url":"https://github.com/Jguer/yay","maintainer":"jguer","packageBase":"yay",
        \\"firstSubmitted":1475688004,"lastModified":1781905288,
        \\"license":["GPL-3.0-or-later"],"depends":["pacman>6.1","git"],
        \\"makeDepends":["go>=1.24"],"optDepends":["sudo","doas"],"provides":[]}],
        \\"page":1,"limit":50,"totalItems":119373,"totalPages":2388}
    ;

    const index = try svc.parseIndexPage(json);

    try testing.expectEqual(@as(usize, 1), index.packages.len);
    try testing.expectEqual(@as(u32, 1), index.page);
    try testing.expectEqual(@as(u32, 2388), index.total_pages);
    try testing.expectEqual(@as(u64, 119373), index.total_items);

    const pkg = index.packages[0];
    try testing.expectEqualStrings("yay", pkg.Name);
    try testing.expectEqualStrings("yay", pkg.PackageBase);
    try testing.expectEqualStrings("13.0.1-1", pkg.Version);
    try testing.expectEqualStrings("Yet another yogurt. Pacman wrapper and AUR helper written in go.", pkg.Description.?);
    try testing.expectEqualStrings("https://github.com/Jguer/yay", pkg.Url.?);
    try testing.expectEqualStrings("jguer", pkg.Maintainer.?);
    try testing.expectEqual(@as(u32, 2653), pkg.NumVotes);
    try testing.expectEqual(@as(f64, 28.983324), pkg.Popularity);
    try testing.expect(pkg.OutOfDate == null);
    try testing.expectEqual(@as(i64, 1475688004), pkg.FirstSubmitted);
    try testing.expectEqual(@as(i64, 1781905288), pkg.LastModified);
    try testing.expectEqualStrings("GPL-3.0-or-later", pkg.License.?[0]);
    try testing.expectEqual(@as(usize, 2), pkg.Depends.?.len);
    try testing.expectEqualStrings("pacman>6.1", pkg.Depends.?[0]);
    try testing.expectEqualStrings("git", pkg.Depends.?[1]);
    try testing.expectEqualStrings("go>=1.24", pkg.MakeDepends.?[0]);
    try testing.expectEqualStrings("sudo", pkg.OptDepends.?[0]);
    try testing.expectEqualStrings("doas", pkg.OptDepends.?[1]);
    try testing.expectEqual(@as(usize, 0), pkg.Provides.?.len);
    try testing.expectEqualStrings("", pkg.UrlPath);
}

test "parseIndexPage maps a split package row" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var svc = makeService(&arena, testing.io);
    defer svc.deinit();

    const json =
        \\{"items":[{"name":"0ad-data-git",
        \\"description":"Cross-platform, 3D and historically-based real-time strategy game (git version) (data files)",
        \\"version":"1:a26.r2110.g14a5ccee52-1","numVotes":8,"popularity":0.016441,
        \\"outOfDate":null,"url":"https://play0ad.com","maintainer":"tuxayo",
        \\"packageBase":"0ad-git","firstSubmitted":1473420716,"lastModified":1765833977,
        \\"license":["cc-by-nc-sa-3.0"],"depends":[],"makeDepends":["boost","cmake"],
        \\"optDepends":[],"provides":["0ad-data"]}],
        \\"page":1,"limit":50,"totalItems":1,"totalPages":1}
    ;

    const index = try svc.parseIndexPage(json);

    const pkg = index.packages[0];
    try testing.expectEqualStrings("0ad-data-git", pkg.Name);
    try testing.expectEqualStrings("0ad-git", pkg.PackageBase);
    try testing.expectEqual(@as(usize, 0), pkg.Depends.?.len);
    try testing.expectEqual(@as(usize, 0), pkg.OptDepends.?.len);
    try testing.expectEqual(@as(usize, 2), pkg.MakeDepends.?.len);
    try testing.expectEqualStrings("0ad-data", pkg.Provides.?[0]);
    try testing.expectEqualStrings("cc-by-nc-sa-3.0", pkg.License.?[0]);
    try testing.expectEqual(@as(i64, 1473420716), pkg.FirstSubmitted);
    try testing.expectEqual(@as(i64, 1765833977), pkg.LastModified);
}

test "parseIndexPage keeps nulls for a package absent from the dump" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var svc = makeService(&arena, testing.io);
    defer svc.deinit();

    const json =
        \\{"items":[{"name":"pruned-pkg","description":null,"version":null,
        \\"numVotes":null,"popularity":null,"outOfDate":null,"url":null,
        \\"maintainer":null,"packageBase":null,"firstSubmitted":null,
        \\"lastModified":null,"license":null,"depends":null,"makeDepends":null,
        \\"optDepends":null,"provides":null}],
        \\"page":1,"limit":50,"totalItems":1,"totalPages":1}
    ;

    const index = try svc.parseIndexPage(json);

    const pkg = index.packages[0];
    try testing.expectEqualStrings("pruned-pkg", pkg.PackageBase);
    try testing.expect(pkg.Url == null);
    try testing.expect(pkg.Maintainer == null);
    try testing.expect(pkg.License == null);
    try testing.expect(pkg.Depends == null);
    try testing.expect(pkg.MakeDepends == null);
    try testing.expect(pkg.OptDepends == null);
    try testing.expect(pkg.Provides == null);
    try testing.expectEqual(@as(i64, 0), pkg.FirstSubmitted);
    try testing.expectEqual(@as(i64, 0), pkg.LastModified);
}

test "parseIndexPage tolerates an empty page" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var svc = makeService(&arena, testing.io);
    defer svc.deinit();

    const index = try svc.parseIndexPage(
        \\{"items":[],"page":7,"limit":50,"totalItems":301,"totalPages":7}
    );

    try testing.expectEqual(@as(usize, 0), index.packages.len);
    try testing.expectEqual(@as(u32, 7), index.page);
    try testing.expectEqual(@as(u32, 7), index.total_pages);
}

test "parseIndexPage keeps an out-of-date marker" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var svc = makeService(&arena, testing.io);
    defer svc.deinit();

    const index = try svc.parseIndexPage(
        \\{"items":[{"name":"stale","version":"1-1","outOfDate":1787340543}],
        \\"page":1,"limit":50,"totalItems":1,"totalPages":1}
    );

    try testing.expectEqual(@as(?i64, 1787340543), index.packages[0].OutOfDate);
    try testing.expectEqualStrings("", index.packages[0].Description orelse "");
}

test "parseSearch maps the full Atoll metadata shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var svc = makeService(&arena, testing.io);
    defer svc.deinit();

    const json =
        \\[{"id":2131240,"name":"yay","packageBaseId":115973,"packageBase":"yay",
        \\"version":"13.0.1-1","description":"Yet another yogurt.",
        \\"url":"https://github.com/Jguer/yay","numVotes":2654,"popularity":33.082352,
        \\"outOfDate":null,"maintainer":"jguer","submitter":"jguer",
        \\"firstSubmitted":1475688004,"lastModified":1781905288,
        \\"urlPath":"/cgit/aur.git/snapshot/yay.tar.gz","depends":["pacman>6.1","git"],
        \\"makeDepends":["go>=1.24"],"optDepends":["sudo"],"conflicts":[],"provides":[],
        \\"license":["GPL-3.0-or-later"],"keywords":["go"],"coMaintainers":[],
        \\"checkDepends":[],"groups":[],"replaces":[]}]
    ;

    const packages = try svc.parseSearch(json);

    try testing.expectEqual(@as(usize, 1), packages.len);
    const pkg = packages[0];
    try testing.expectEqual(@as(u32, 2131240), pkg.Id);
    try testing.expectEqualStrings("yay", pkg.Name);
    try testing.expectEqual(@as(u32, 115973), pkg.PackageBaseId);
    try testing.expectEqualStrings("https://github.com/Jguer/yay", pkg.Url.?);
    try testing.expectEqualStrings("jguer", pkg.Maintainer.?);
    try testing.expectEqual(@as(i64, 1475688004), pkg.FirstSubmitted);
    try testing.expectEqual(@as(i64, 1781905288), pkg.LastModified);
    try testing.expectEqualStrings("/cgit/aur.git/snapshot/yay.tar.gz", pkg.UrlPath);
    try testing.expectEqualStrings("pacman>6.1", pkg.Depends.?[0]);
    try testing.expectEqualStrings("go>=1.24", pkg.MakeDepends.?[0]);
    try testing.expectEqualStrings("GPL-3.0-or-later", pkg.License.?[0]);
    try testing.expectEqual(@as(usize, 0), pkg.Conflicts.?.len);
}

test "parseSearch handles an empty result set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var svc = makeService(&arena, testing.io);
    defer svc.deinit();

    const packages = try svc.parseSearch("[]");

    try testing.expectEqual(@as(usize, 0), packages.len);
}

test "percentEncode escapes characters that are not query safe" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var svc = makeService(&arena, testing.io);
    defer svc.deinit();

    const encoded = try svc.percentEncode("hello world&x=1");
    try testing.expectEqualStrings("hello%20world%26x%3D1", encoded);

    const plain = try svc.percentEncode("yay-bin");
    try testing.expectEqualStrings("yay-bin", plain);
}

test "live: getIndexPage returns a page of packages" {
    var event_loop: std.Io.Threaded = .init(testing.allocator, .{});
    defer event_loop.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var svc = makeService(&arena, event_loop.io());
    defer svc.deinit();

    const index = try svc.getIndexPage(1, 3, .votes, .desc);

    try testing.expectEqual(@as(u32, 1), index.page);
    try testing.expect(index.packages.len > 0);
    try testing.expect(index.packages.len <= 3);
    try testing.expect(index.total_pages > 1);
    try testing.expect(index.packages[0].Name.len > 0);
    try testing.expect(index.packages[0].PackageBase.len > 0);
}

test "live: search finds a package by name" {
    var event_loop: std.Io.Threaded = .init(testing.allocator, .{});
    defer event_loop.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var svc = makeService(&arena, event_loop.io());
    defer svc.deinit();

    const packages = try svc.search("yay", .name);

    try testing.expect(packages.len > 0);
    try testing.expectEqualStrings("yay", packages[0].Name);
    try testing.expect(packages[0].Depends.?.len > 0);
}
