//! Atoll catalog pages.
const std = @import("std");
const Http = @import("ShellyHttp");
const AurPackage = @import("../models/packages.zig").AurPackage;
const source = @import("../models/settings.zig");
pub const page_size = 50;
pub const request_timeout: std.Io.Duration = .fromSeconds(15);

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
    return fetchUrl(allocator, io, url, page, request_timeout);
}

fn fetchUrl(allocator: std.mem.Allocator, io: std.Io, url: []const u8, page: u32, timeout: std.Io.Duration) !Page {
    const bytes = try allocator.alloc(u8, 2 * 1024 * 1024);
    defer allocator.free(bytes);
    var results: [2]union(enum) { response: anyerror!usize, deadline: anyerror!void } = undefined;
    var select: std.Io.Select(@TypeOf(results[0])) = .init(io, &results);
    defer select.cancelDiscard();
    select.async(.response, fetchBody, .{ allocator, io, url, bytes });
    select.async(.deadline, waitForDeadline, .{ io, timeout });
    const size = switch (try select.await()) {
        .response => |result| try result,
        .deadline => |result| {
            try result;
            return error.CatalogRequestTimedOut;
        },
    };
    select.cancelDiscard();
    return parse(allocator, bytes[0..size], page);
}

fn waitForDeadline(io: std.Io, timeout: std.Io.Duration) !void {
    try io.sleep(timeout, .awake);
}

fn fetchBody(allocator: std.mem.Allocator, io: std.Io, url: []const u8, bytes: []u8) !usize {
    var client: Http = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    var request = try client.request(.GET, try std.Uri.parse(url), .{
        .headers = .{ .user_agent = .{ .override = "Shelly-TUI" } },
        .redirect_behavior = .init(3),
        .keep_alive = false,
    });
    defer {
        request.markConnectionClosing();
        request.deinit();
    }
    try request.sendBodiless();
    var redirects: [8 * 1024]u8 = undefined;
    var response = try request.receiveHead(&redirects);
    if (response.head.status != .ok) return error.CatalogHttpFailure;
    const decompress_size: usize = switch (response.head.content_encoding) {
        .identity => 0,
        .zstd => std.compress.zstd.default_window_len,
        .deflate, .gzip => std.compress.flate.max_window_len,
        .compress => return error.UnsupportedCompressionMethod,
    };
    const decompress_buffer = try allocator.alloc(u8, decompress_size);
    defer allocator.free(decompress_buffer);
    var transfer_buffer: [4096]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    var writer = std.Io.Writer.fixed(bytes);
    _ = try reader.streamRemaining(&writer);
    return writer.end;
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

test "catalog deadline covers stalled headers and stalled response bodies" {
    const Server = struct {
        io: std.Io,
        listener: std.Io.net.Server,
        mode: enum { complete, stalled_headers, stalled_body },
        closed: std.atomic.Value(bool) = .init(false),

        fn serve(self: *@This()) !void {
            const stream = try self.listener.accept(self.io);
            defer stream.close(self.io);
            var read_buffer: [2048]u8 = undefined;
            var reader = stream.reader(self.io, &read_buffer);
            while (try reader.interface.takeDelimiter('\n')) |line| {
                if (std.mem.eql(u8, line, "\r")) break;
            }
            if (self.mode != .stalled_headers) {
                const body = "{\"page\":1,\"totalPages\":0,\"items\":[]}";
                var write_buffer: [1024]u8 = undefined;
                var writer = stream.writer(self.io, &write_buffer);
                try writer.interface.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{
                    body.len, if (self.mode == .complete) body else body[0..1],
                });
                try writer.interface.flush();
            }
            if (self.mode != .complete) {
                try self.io.sleep(.fromSeconds(5), .awake);
                self.closed.store(true, .release);
            }
        }
    };
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    for ([_]@FieldType(Server, "mode"){ .complete, .stalled_headers, .stalled_body }) |mode| {
        var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var server: Server = .{ .io = io, .listener = try address.listen(io, .{ .reuse_address = true }), .mode = mode };
        defer server.listener.deinit(io);
        var serving = try io.concurrent(Server.serve, .{&server});
        defer _ = serving.cancel(io) catch {};
        const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/v1/packages", .{server.listener.socket.address.getPort()});
        defer std.testing.allocator.free(url);
        if (mode == .complete) {
            const page = try fetchUrl(std.testing.allocator, io, url, 1, .fromSeconds(2));
            defer page.packages.deinit();
            try std.testing.expectEqual(@as(usize, 0), page.packages.value.len);
            try serving.await(io);
        } else {
            try std.testing.expectError(error.CatalogRequestTimedOut, fetchUrl(std.testing.allocator, io, url, 1, .fromMilliseconds(200)));
            try std.testing.expect(!server.closed.load(.acquire));
        }
    }
}
