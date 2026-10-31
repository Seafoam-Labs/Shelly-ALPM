const std = @import("std");
const Http = @import("ShellyHttp");
const data = @import("../models/flatpak.zig");
const Allocator = std.mem.Allocator;
pub const max_bytes = 8 * 1024 * 1024;

pub fn validUrl(url: []const u8) bool {
    for (url) |c| if (c <= 0x20 or c == 0x7f) return false;
    const uri = std.Uri.parse(url) catch return false;
    return (std.ascii.eqlIgnoreCase(uri.scheme, "https") or std.ascii.eqlIgnoreCase(uri.scheme, "http")) and uri.host != null and !uri.host.?.isEmpty();
}

/// Pick a suitably sized variant per screenshot, rather than browsing duplicates.
pub fn variant(shot: data.AppstreamScreenshot) ?data.AppstreamImage {
    var chosen: ?data.AppstreamImage = null;
    for (shot.Images) |img| {
        if (!validUrl(img.Url)) continue;
        if (chosen == null or (img.Width >= 800 and (chosen.?.Width < 800 or img.Width < chosen.?.Width)) or
            (img.Width < 800 and chosen.?.Width < 800 and img.Width > chosen.?.Width)) chosen = img;
    }
    return chosen;
}

pub const Item = struct { url: []const u8, caption: []const u8 };
pub fn collect(alloc: Allocator, app: *const data.AppstreamApp) ![]Item {
    var items: std.ArrayList(Item) = .empty;
    errdefer {
        for (items.items) |item| {
            alloc.free(item.url);
            alloc.free(item.caption);
        }
        items.deinit(alloc);
    }
    for (app.Screenshots) |shot| {
        const img = variant(shot) orelse continue;
        const url = try alloc.dupe(u8, img.Url);
        errdefer alloc.free(url);
        const caption = try alloc.dupe(u8, shot.Caption);
        errdefer alloc.free(caption);
        try items.append(alloc, .{ .url = url, .caption = caption });
    }
    return items.toOwnedSlice(alloc);
}
pub fn freeItems(alloc: Allocator, items: []Item) void {
    for (items) |item| {
        alloc.free(item.url);
        alloc.free(item.caption);
    }
    alloc.free(items);
}

/// Bounds decoded allocations before handing PNG/JPEG bytes to the decoder.
pub fn dimensions(bytes: []const u8) !struct { width: u16, height: u16 } {
    var w: u32 = 0;
    var h: u32 = 0;
    if (bytes.len >= 24 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n") and std.mem.eql(u8, bytes[12..16], "IHDR")) {
        w = std.mem.readInt(u32, bytes[16..20], .big);
        h = std.mem.readInt(u32, bytes[20..24], .big);
    } else if (bytes.len >= 2 and bytes[0] == 0xff and bytes[1] == 0xd8) {
        var i: usize = 2;
        while (i + 3 < bytes.len) {
            if (bytes[i] != 0xff) return error.InvalidImage;
            while (i < bytes.len and bytes[i] == 0xff) : (i += 1) {}
            if (i >= bytes.len) break;
            const marker = bytes[i];
            i += 1;
            if (marker == 0xd9 or marker == 0xda) break;
            if (marker == 0x01 or (marker >= 0xd0 and marker <= 0xd7)) continue;
            if (i + 2 > bytes.len) break;
            const len = std.mem.readInt(u16, bytes[i..][0..2], .big);
            if (len < 2 or len > bytes.len - i) return error.InvalidImage;
            if (marker >= 0xc0 and marker <= 0xcf and marker != 0xc4 and marker != 0xc8 and marker != 0xcc) {
                if (len < 8) return error.InvalidImage;
                h = std.mem.readInt(u16, bytes[i + 3 ..][0..2], .big);
                w = std.mem.readInt(u16, bytes[i + 5 ..][0..2], .big);
                break;
            }
            i += len;
        }
    } else return error.UnsupportedImageFormat;
    if (w == 0 or h == 0) return error.InvalidImage;
    if (w > 4096 or h > 4096 or @as(u64, w) * h > 8 * 1024 * 1024) return error.ImageTooLarge;
    return .{ .width = @intCast(w), .height = @intCast(h) };
}

pub const Job = struct {
    generation: u64 = 0,
    url: []const u8,
    canceled: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    bytes: ?[]u8 = null,
    failure: ?anyerror = null,

    pub fn run(self: *Job) void {
        defer self.done.store(true, .release);
        var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        self.bytes = download(std.heap.page_allocator, threaded.io(), self.url, &self.canceled) catch |err| {
            self.failure = err;
            return;
        };
    }
    pub fn deinit(self: *Job, alloc: Allocator) void {
        if (self.bytes) |bytes| std.heap.page_allocator.free(bytes);
        alloc.free(self.url);
        alloc.destroy(self);
    }
};

pub fn download(alloc: Allocator, io: std.Io, url: []const u8, canceled: *const std.atomic.Value(bool)) ![]u8 {
    if (!validUrl(url)) return error.InvalidImageUrl;
    if (canceled.load(.acquire)) return error.Canceled;
    const bytes = try alloc.alloc(u8, max_bytes);
    errdefer alloc.free(bytes);
    var results: [2]union(enum) { fetch: anyerror!usize, abort: anyerror!void } = undefined;
    var select: std.Io.Select(@TypeOf(results[0])) = .init(io, &results);
    defer select.cancelDiscard();
    select.async(.fetch, fetch, .{ alloc, io, url, bytes });
    select.async(.abort, watchdog, .{ io, canceled });
    const len = switch (try select.await()) {
        .fetch => |result| try result,
        .abort => |result| {
            try result;
            return error.Canceled;
        },
    };
    select.cancelDiscard();
    _ = try dimensions(bytes[0..len]);
    return alloc.realloc(bytes, len);
}
fn watchdog(io: std.Io, canceled: *const std.atomic.Value(bool)) !void {
    for (0..150) |_| {
        if (canceled.load(.acquire)) return error.Canceled;
        try io.sleep(.fromMilliseconds(100), .awake);
    }
    return error.ImageDownloadTimedOut;
}
fn fetch(alloc: Allocator, io: std.Io, url: []const u8, bytes: []u8) !usize {
    var client: Http = .{ .allocator = alloc, .io = io };
    defer client.deinit();
    var writer = std.Io.Writer.fixed(bytes);
    const response = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &writer, .redirect_behavior = .init(3), .headers = .{ .user_agent = .{ .override = "Shelly-TUI" } } });
    if (response.status.class() != .success) return error.ImageHttpFailure;
    return writer.end;
}

test "screenshot variants validate URLs and prefer a useful bounded preview" {
    const shot: data.AppstreamScreenshot = .{ .Images = &.{
        .{ .Url = "file:///tmp/picture.png", .Width = 800 },
        .{ .Url = "https://example.test/small.png", .Width = 320 },
        .{ .Url = "https://example.test/large.png", .Width = 1920 },
        .{ .Url = "https://example.test/preview.png", .Width = 800 },
    } };
    try std.testing.expectEqualStrings("https://example.test/preview.png", variant(shot).?.Url);
    try std.testing.expect(!validUrl("https://example.test/a\n"));
    try std.testing.expect(!validUrl("/icons/relative.png"));
    try std.testing.expect(variant(.{ .Images = &.{.{ .Url = "file:///tmp/test" }} }) == null);
    var app: data.AppstreamApp = .{ .Screenshots = &.{ shot, .{ .Caption = "Second", .Images = &.{.{ .Url = "https://example.test/second.png" }} } } };
    const items = try collect(std.testing.allocator, &app);
    defer freeItems(std.testing.allocator, items);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("Second", items[1].caption);
    try std.testing.expect(@intFromPtr(items[0].url.ptr) != @intFromPtr(variant(shot).?.Url.ptr));
}

test "image headers reject oversized dimensions and malformed files before decode" {
    var png: [24]u8 = @splat(0);
    @memcpy(png[0..8], "\x89PNG\r\n\x1a\n");
    @memcpy(png[12..16], "IHDR");
    std.mem.writeInt(u32, png[16..20], 800, .big);
    std.mem.writeInt(u32, png[20..24], 600, .big);
    const size = try dimensions(&png);
    try std.testing.expectEqual(@as(u16, 800), size.width);
    std.mem.writeInt(u32, png[16..20], 100000, .big);
    try std.testing.expectError(error.ImageTooLarge, dimensions(&png));
    try std.testing.expectError(error.UnsupportedImageFormat, dimensions("not an image"));
    const jpeg = [_]u8{ 0xff, 0xd8, 0xff, 0xc0, 0, 8, 8, 0x02, 0x58, 0x03, 0x20, 0 };
    try std.testing.expectEqual(@as(u16, 600), (try dimensions(&jpeg)).height);
    try std.testing.expectError(error.InvalidImage, dimensions(jpeg[0..7]));
}

test "image download cancellation does not wait for a response" {
    var canceled: std.atomic.Value(bool) = .init(true);
    // Invalid input and already-cancelled work never start a network operation.
    try std.testing.expectError(error.InvalidImageUrl, download(std.testing.allocator, std.testing.io, "file:///tmp/test", &canceled));
    try std.testing.expectError(error.Canceled, download(std.testing.allocator, std.testing.io, "https://example.test/image.png", &canceled));
}
