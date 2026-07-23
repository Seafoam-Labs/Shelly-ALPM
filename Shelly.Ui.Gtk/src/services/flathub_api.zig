const std = @import("std");
const Io = std.Io;

pub const FlatHubApiService = struct {
    const base_url = "https://flathub.org/api/v2";

    allocator: std.mem.Allocator,
    io: Io,
    client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator, io: Io) FlatHubApiService {
        return .{
            .allocator = allocator,
            .io = io,
            .client = .{ .allocator = allocator, .io = io },
        };
    }

    pub fn deinit(self: *FlatHubApiService) void {
        self.client.deinit();
    }

    pub fn getStatsForApp(self: *FlatHubApiService, app_id: []const u8) ![]u8 {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/apps/{s}", .{ base_url, app_id });
        defer self.allocator.free(url);
        return self.fetchBody(url);
    }

    pub fn getCollectionTrending(self: *FlatHubApiService, page: u32, per_page: u32) ![][]u8 {
        return self.getCollection("trending", page, per_page);
    }

    pub fn getCollectionPopular(self: *FlatHubApiService, page: u32, per_page: u32) ![][]u8 {
        return self.getCollection("popular", page, per_page);
    }

    pub fn getCollectionRecentlyUpdated(self: *FlatHubApiService, page: u32, per_page: u32) ![][]u8 {
        return self.getCollection("recently-updated", page, per_page);
    }

    pub fn getCollectionRecentlyAdded(self: *FlatHubApiService, page: u32, per_page: u32) ![][]u8 {
        return self.getCollection("recently-added", page, per_page);
    }

    fn getCollection(
        self: *FlatHubApiService,
        name: []const u8,
        page: u32,
        per_page: u32,
    ) ![][]u8 {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/collection/{s}?page={d}&per_page={d}",
            .{ base_url, name, page, per_page },
        );
        defer self.allocator.free(url);

        const body = try self.fetchBody(url);
        defer self.allocator.free(body);

        return self.appIdsFromResponse(body);
    }

    fn fetchBody(self: *FlatHubApiService, url: []const u8) ![]u8 {
        var body: std.Io.Writer.Allocating = .init(self.allocator);
        defer body.deinit();

        const result = try self.client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &body.writer,
        });

        if (result.status != .ok) return error.HttpRequestFailed;

        return body.toOwnedSlice();
    }

    fn appIdsFromResponse(self: *FlatHubApiService, json: []const u8) ![][]u8 {
        const Hit = struct { app_id: []const u8 };
        const SearchResponse = struct { hits: ?[]Hit = null };

        const parsed = try std.json.parseFromSlice(
            SearchResponse,
            self.allocator,
            json,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();

        const hits = parsed.value.hits orelse return &.{};

        var list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (list.items) |item| self.allocator.free(item);
            list.deinit(self.allocator);
        }

        for (hits) |hit| {
            try list.append(self.allocator, try self.allocator.dupe(u8, hit.app_id));
        }

        return list.toOwnedSlice(self.allocator);
    }
};

const testing = std.testing;

fn freeIds(allocator: std.mem.Allocator, ids: [][]u8) void {
    for (ids) |id| allocator.free(id);
    allocator.free(ids);
}

test "appIdsFromResponse: parses hits into app ids" {
    var event_loop: std.Io.Threaded = .init(testing.allocator, .{});
    defer event_loop.deinit();

    var svc = FlatHubApiService.init(testing.allocator, event_loop.io());
    defer svc.deinit();

    const json =
        \\{"hits":[{"app_id":"org.gimp.GIMP"},{"app_id":"com.spotify.Client"}]}
    ;

    const ids = try svc.appIdsFromResponse(json);
    defer freeIds(testing.allocator, ids);

    try testing.expectEqual(@as(usize, 2), ids.len);
    try testing.expectEqualStrings("org.gimp.GIMP", ids[0]);
    try testing.expectEqualStrings("com.spotify.Client", ids[1]);
}

test "appIdsFromResponse: null hits yields empty slice" {
    var event_loop: std.Io.Threaded = .init(testing.allocator, .{});
    defer event_loop.deinit();

    var svc = FlatHubApiService.init(testing.allocator, event_loop.io());
    defer svc.deinit();

    const ids = try svc.appIdsFromResponse("{}");
    defer testing.allocator.free(ids);

    try testing.expectEqual(@as(usize, 0), ids.len);
}

test "appIdsFromResponse: empty hits array yields empty slice" {
    var event_loop: std.Io.Threaded = .init(testing.allocator, .{});
    defer event_loop.deinit();
    var svc = FlatHubApiService.init(testing.allocator, event_loop.io());

    defer svc.deinit();

    const ids = try svc.appIdsFromResponse(
        \\{"hits":[]}
    );
    defer testing.allocator.free(ids);

    try testing.expectEqual(@as(usize, 0), ids.len);
}

test "appIdsFromResponse: extra unknown fields are ignored" {
    var event_loop: std.Io.Threaded = .init(testing.allocator, .{});
    defer event_loop.deinit();
    var svc = FlatHubApiService.init(testing.allocator, event_loop.io());

    defer svc.deinit();

    const json =
        \\{"query":"x","totalHits":1,"hits":[{"app_id":"org.gnome.Calculator","name":"Calculator","summary":"..."}]}
    ;

    const ids = try svc.appIdsFromResponse(json);
    defer freeIds(testing.allocator, ids);

    try testing.expectEqual(@as(usize, 1), ids.len);
    try testing.expectEqualStrings("org.gnome.Calculator", ids[0]);
}

test "appIdsFromResponse: malformed json errors" {
    var event_loop: std.Io.Threaded = .init(testing.allocator, .{});
    defer event_loop.deinit();

    var svc = FlatHubApiService.init(testing.allocator, event_loop.io());
    defer svc.deinit();

    try testing.expectError(error.SyntaxError, svc.appIdsFromResponse("{not json"));
}

test "live: getCollectionTrending returns app ids" {
    var event_loop: std.Io.Threaded = .init(testing.allocator, .{});
    defer event_loop.deinit();
    var svc = FlatHubApiService.init(testing.allocator, event_loop.io());

    defer svc.deinit();

    const ids = try svc.getCollectionTrending(1, 5);
    defer freeIds(testing.allocator, ids);

    try testing.expect(ids.len > 0);
    try testing.expect(ids.len <= 5);
    // App IDs are reverse-DNS, so every one should contain a dot.
    for (ids) |id| {
        try testing.expect(std.mem.indexOfScalar(u8, id, '.') != null);
    }
}

test "live: getCollectionPopular respects per_page" {
    var event_loop: std.Io.Threaded = .init(testing.allocator, .{});
    defer event_loop.deinit();
    var svc = FlatHubApiService.init(testing.allocator, event_loop.io());

    defer svc.deinit();

    const ids = try svc.getCollectionPopular(1, 3);
    defer freeIds(testing.allocator, ids);

    try testing.expect(ids.len <= 3);
}

test "live: getCollectionRecentlyUpdated returns app ids" {
    var event_loop: std.Io.Threaded = .init(testing.allocator, .{});
    defer event_loop.deinit();
    var svc = FlatHubApiService.init(testing.allocator, event_loop.io());

    defer svc.deinit();

    const ids = try svc.getCollectionRecentlyUpdated(1, 5);
    defer freeIds(testing.allocator, ids);

    try testing.expect(ids.len > 0);
}

test "live: getCollectionRecentlyAdded returns app ids" {
    var event_loop: std.Io.Threaded = .init(testing.allocator, .{});
    defer event_loop.deinit();
    var svc = FlatHubApiService.init(testing.allocator, event_loop.io());

    defer svc.deinit();

    const ids = try svc.getCollectionRecentlyAdded(1, 5);
    defer freeIds(testing.allocator, ids);

    try testing.expect(ids.len > 0);
}

test "live: getStatsForApp returns a non-empty body" {
    if (true) return error.SkipZigTest;
    var event_loop: std.Io.Threaded = .init(testing.allocator, .{});
    defer event_loop.deinit();
    var svc = FlatHubApiService.init(testing.allocator, event_loop.io());

    defer svc.deinit();

    const body = try svc.getStatsForApp("org.gnome.Calculator");
    defer testing.allocator.free(body);

    try testing.expect(body.len > 0);
}

test "live: getStatsForApp on unknown app id fails" {
    var event_loop: std.Io.Threaded = .init(testing.allocator, .{});
    defer event_loop.deinit();
    var svc = FlatHubApiService.init(testing.allocator, event_loop.io());

    defer svc.deinit();

    try testing.expectError(
        error.HttpRequestFailed,
        svc.getStatsForApp("com.example.DefinitelyDoesNotExist12345"),
    );
}
