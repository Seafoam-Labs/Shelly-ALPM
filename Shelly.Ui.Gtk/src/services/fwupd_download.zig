//! Client-side firmware payload download: remote resolution, checksum-verified
//! cache under `$XDG_CACHE_HOME/shelly/fwupd/`, and throttled progress reporting.
//!
//! GTK-free and daemon-free apart from the injected `Backend`: the page drives
//! its own "Downloading… x%" UI because the daemon's Status/Percentage only
//! cover the flash stage. The progress callback runs on the worker thread;
//! callers marshal to the main loop themselves.
//!
//! Cache rules: verify a cached file before
//! reuse, download to a `.part` file and rename on success, delete partials on
//! every failure. Local/directory remotes resolve to a file path directly; the
//! daemon verifies those payloads on Install.

const std = @import("std");
const diagnostics = @import("diagnostics");
const HttpClient = @import("ShellyHttp");
const models = @import("../models/fwupd.zig");
const fwupd = @import("fwupd.zig");
const xdg_paths = @import("xdg_paths.zig").xdg_paths;

const log = std.log.scoped(.fwupd);
const Io = std.Io;

pub const Error = fwupd.Error || error{
    RemoteNotFound,
    NoPayloadLocation,
    ReleaseWithoutChecksums,
    InvalidChecksum,
    ChecksumMismatch,
    DownloadFailed,
    FileFailed,
};

/// Worker-thread progress sink. `total` is the release `Size` (0 = unknown).
pub const Progress = struct {
    ctx: ?*anyopaque = null,
    on_progress: ?*const fn (ctx: ?*anyopaque, received: u64, total: u64) void = null,

    fn report(self: Progress, received: u64, total: u64) void {
        if (self.on_progress) |f| f(self.ctx, received, total);
    }
};

/// Resolve and fetch a release payload, returning an absolute file path owned
/// by `alloc`. fwupd call failures surface as `error.DownloadFailed` with
/// `backend.lastFailure()` set for friendly error text.
pub fn fetchPayload(
    backend: fwupd.Backend,
    alloc: std.mem.Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    release: models.Release,
    user_agent: []const u8,
    progress: Progress,
) Error![]const u8 {
    const remotes = try backend.getRemotes(alloc);
    const remote = findRemote(remotes, release.remote_id) orelse return error.RemoteNotFound;
    const location = models.resolvePayloadUrl(alloc, release, remote) catch return error.NoPayloadLocation;
    switch (location) {
        .path => |path| return alloc.dupe(u8, path),
        .url => |url| return downloadToCache(alloc, io, env, remote, release, url, user_agent, progress),
    }
}

fn findRemote(remotes: []const models.Remote, remote_id: []const u8) ?models.Remote {
    if (remote_id.len == 0) return null;
    for (remotes) |remote| {
        if (std.mem.eql(u8, remote.remote_id, remote_id)) return remote;
    }
    return null;
}

/// `$XDG_CACHE_HOME/shelly/fwupd/<url-host>/<url-basename>`.
pub fn cachePath(alloc: std.mem.Allocator, env: *const std.process.Environ.Map, url: []const u8) Error![]const u8 {
    const uri = std.Uri.parse(url) catch return error.DownloadFailed;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host_component = uri.host orelse return error.DownloadFailed;
    const host = host_component.toRaw(&host_buf) catch return error.DownloadFailed;
    if (host.len == 0 or std.mem.indexOfScalar(u8, host, '/') != null) return error.DownloadFailed;
    const base = cacheBasename(url);
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) return error.DownloadFailed;
    const cache_home = xdg_paths.xdgCacheHome(alloc, env) catch return error.FileFailed;
    defer alloc.free(cache_home);
    return std.fs.path.join(alloc, &.{ cache_home, "shelly", "fwupd", host, base });
}

/// Cache filename from a payload URL: query/fragment dropped, and the `/auth`
/// suffix that fwupd appends for authenticated remotes kept out of the name.
/// The request URL itself is not modified.
pub fn cacheBasename(url: []const u8) []const u8 {
    var path = url;
    if (std.mem.indexOfAny(u8, path, "?#")) |i| path = path[0..i];
    if (std.mem.endsWith(u8, path, "/auth")) path = path[0 .. path.len - "/auth".len];
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}

fn downloadToCache(
    alloc: std.mem.Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    remote: models.Remote,
    release: models.Release,
    url: []const u8,
    user_agent: []const u8,
    progress: Progress,
) Error![]const u8 {
    // A download-kind remote can still carry file:// locations.
    if (std.mem.startsWith(u8, url, "file://")) return alloc.dupe(u8, url["file://".len..]);

    const checksum = models.pickChecksum(release.checksum) orelse return error.ReleaseWithoutChecksums;
    const path = try cachePath(alloc, env, url);
    const dir_path = std.fs.path.dirname(path) orelse return error.FileFailed;
    const base = std.fs.path.basename(path);
    var dir = Io.Dir.cwd().createDirPathOpen(io, dir_path, .{}) catch return error.FileFailed;
    defer dir.close(io);

    // Cached file: reuse when the digest matches, else drop and re-download.
    if (dir.openFile(io, base, .{})) |cached| {
        cached.close(io);
        const valid = models.verifyFile(io, dir, base, checksum) catch false;
        if (valid) return path;
        dir.deleteFile(io, base) catch {};
    } else |_| {}

    const part = try alloc.print("{s}.part", .{base});
    var part_done = false;
    defer if (!part_done) dir.deleteFile(io, part) catch {};

    var auth_buf: [512]u8 = undefined;
    var auth_header: [1]std.http.Header = undefined;
    var privileged: []const std.http.Header = &.{};
    if (remote.username.len > 0) {
        // Dormant without ALLOW_AUTHENTICATION, but embargo remotes carry
        // credentials on the wire; send them as a privileged header so they
        // are stripped on cross-domain redirects.
        const creds = try alloc.print("{s}:{s}", .{ remote.username, remote.password });
        const encoder = std.base64.standard.Encoder;
        const encoded_len = encoder.calcSize(creds.len);
        if ("Basic ".len + encoded_len <= auth_buf.len) {
            @memcpy(auth_buf[0.."Basic ".len], "Basic ");
            _ = encoder.encode(auth_buf["Basic ".len..][0..encoded_len], creds);
            auth_header[0] = .{ .name = "Authorization", .value = auth_buf[0 .. "Basic ".len + encoded_len] };
            privileged = &auth_header;
        }
    }

    var counting: CountingWriter = undefined;
    const status = blk: {
        const file = dir.createFile(io, part, .{}) catch return error.FileFailed;
        defer file.close(io);
        var write_buf: [64 * 1024]u8 = undefined;
        var file_writer = file.writer(io, &write_buf);
        counting = CountingWriter.init(io, &file_writer.interface, release.size, progress);

        var client: HttpClient = .{ .allocator = alloc, .io = io };
        defer client.deinit();
        const result = client.fetch(.{
            .location = .{ .url = url },
            .headers = .{ .user_agent = .{ .override = user_agent } },
            .privileged_headers = privileged,
            .response_writer = &counting.writer,
        }) catch |err| {
            log.warn("Firmware download from {0f} failed: {1s}", .{ diagnostics.safe(url), @errorName(err) });
            return error.DownloadFailed;
        };
        counting.writer.flush() catch return error.FileFailed;
        file_writer.interface.flush() catch return error.FileFailed;
        break :blk result.status;
    };
    if (status != .ok) {
        log.warn("Firmware download from {0f} returned HTTP {1d}", .{ diagnostics.safe(url), @intFromEnum(status) });
        return error.DownloadFailed;
    }

    const valid = models.verifyFile(io, dir, part, checksum) catch |err| switch (err) {
        error.InvalidChecksum => return error.InvalidChecksum,
        else => return error.FileFailed,
    };
    if (!valid) {
        log.warn("Firmware payload from {0f} failed checksum verification", .{diagnostics.safe(url)});
        return error.ChecksumMismatch;
    }
    dir.rename(part, dir, base, io) catch return error.FileFailed;
    part_done = true;
    counting.finish();
    return path;
}

/// Report at most every ~256 KiB or ~100 ms so a fast download does not flood
/// the main loop with idle sources.
pub fn shouldReport(last_bytes: u64, last_ms: i64, received: u64, now_ms: i64) bool {
    return received - last_bytes >= 256 * 1024 or now_ms - last_ms >= 100;
}

/// Unbuffered `std.Io.Writer` that tees into the payload file writer, counts
/// bytes and reports throttled progress. `total` is the expected size (0 when
/// the release carries no Size).
pub const CountingWriter = struct {
    writer: Io.Writer,
    io: Io,
    sink: *Io.Writer,
    received: u64 = 0,
    total: u64 = 0,
    progress: Progress = .{},
    last_bytes: u64 = 0,
    last_ms: i64 = 0,

    pub fn init(io: Io, sink: *Io.Writer, total: u64, progress: Progress) CountingWriter {
        return .{
            .writer = .{ .vtable = &vtable, .buffer = &.{} },
            .io = io,
            .sink = sink,
            .total = total,
            .progress = progress,
        };
    }

    const vtable: Io.Writer.VTable = .{ .drain = drain };

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *CountingWriter = @fieldParentPtr("writer", w);
        var written: usize = 0;
        for (data[0 .. data.len - 1]) |chunk| {
            self.sink.writeAll(chunk) catch return error.WriteFailed;
            written += chunk.len;
        }
        // The last element is written splat times in total (not in addition
        // to the single pass); splat may be zero.
        const last = data[data.len - 1];
        for (0..splat) |_| {
            self.sink.writeAll(last) catch return error.WriteFailed;
            written += last.len;
        }
        self.received += written;
        const now = Io.Timestamp.now(self.io, .awake).toMilliseconds();
        if (shouldReport(self.last_bytes, self.last_ms, self.received, now)) {
            self.last_bytes = self.received;
            self.last_ms = now;
            self.progress.report(self.received, self.total);
        }
        return written;
    }

    /// Final report so the UI always sees the completed byte count.
    pub fn finish(self: *CountingWriter) void {
        self.progress.report(self.received, self.total);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const enums = @import("fwupd_enums.zig");

fn testEnv(map: *std.process.Environ.Map) !void {
    try map.put("XDG_CACHE_HOME", "/tmp/shelly-test-cache");
}

test "fwupd download cache path uses the shelly/fwupd namespace and url host" {
    var map: std.process.Environ.Map = .init(testing.allocator);
    defer map.deinit();
    try testEnv(&map);
    const path = try cachePath(testing.allocator, &map, "https://cdn.lvfs.org/firmware/1.2.cab");
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/tmp/shelly-test-cache/shelly/fwupd/cdn.lvfs.org/1.2.cab", path);

    // HOME fallback when XDG_CACHE_HOME is unset.
    var home_map: std.process.Environ.Map = .init(testing.allocator);
    defer home_map.deinit();
    try home_map.put("HOME", "/home/test");
    const home_path = try cachePath(testing.allocator, &home_map, "https://fwupd.org/downloads/fw.cab");
    defer testing.allocator.free(home_path);
    try testing.expectEqualStrings("/home/test/.cache/shelly/fwupd/fwupd.org/fw.cab", home_path);

    try testing.expectError(error.DownloadFailed, cachePath(testing.allocator, &map, "not a url"));
}

test "fwupd download cache basename strips query and the /auth suffix" {
    try testing.expectEqualStrings("fw.cab", cacheBasename("https://cdn.example/fw.cab"));
    try testing.expectEqualStrings("fw.cab", cacheBasename("https://cdn.example/fw.cab?token=abc"));
    try testing.expectEqualStrings("fw.cab", cacheBasename("https://cdn.example/fw.cab#frag"));
    try testing.expectEqualStrings("fw.cab", cacheBasename("https://embargo.example/fw.cab/auth"));
    try testing.expectEqualStrings("fw.cab", cacheBasename("https://embargo.example/fw.cab/auth?x=1"));
}

test "fwupd download progress throttle reports on size or time" {
    try testing.expect(!shouldReport(0, 1000, 1024, 1050));
    try testing.expect(shouldReport(0, 1000, 256 * 1024, 1050));
    try testing.expect(shouldReport(0, 1000, 1024, 1100));
    try testing.expect(shouldReport(0, 0, 1, 1_000_000));
    try testing.expect(!shouldReport(256 * 1024, 1000, 256 * 1024 + 1, 1050));
}

const ProgressCapture = struct {
    calls: usize = 0,
    last_received: u64 = 0,
    last_total: u64 = 0,

    fn progress(self: *ProgressCapture) Progress {
        return .{
            .ctx = self,
            .on_progress = struct {
                fn f(ctx: ?*anyopaque, received: u64, total: u64) void {
                    const cap: *ProgressCapture = @ptrCast(@alignCast(ctx.?));
                    cap.calls += 1;
                    cap.last_received = received;
                    cap.last_total = total;
                }
            }.f,
        };
    }
};

test "fwupd download counting writer tees bytes and counts splats" {
    var sink = std.Io.Writer.Allocating.init(testing.allocator);
    defer sink.deinit();
    var capture = ProgressCapture{};
    var counting = CountingWriter.init(testing.io, &sink.writer, 10, capture.progress());

    try counting.writer.writeAll("abc");
    // "de" once plus the last chunk "fg" twice in total: 2 + 2*2 = 6 bytes.
    const chunks = [_][]const u8{ "de", "fg" };
    try testing.expectEqual(@as(usize, 6), try counting.writer.writeSplat(&chunks, 2));
    try testing.expectEqual(@as(u64, 9), counting.received);
    try testing.expectEqualStrings("abcdefgfg", sink.written());

    counting.finish();
    try testing.expect(capture.calls >= 1);
    try testing.expectEqual(@as(u64, 9), capture.last_received);
    try testing.expectEqual(@as(u64, 10), capture.last_total);
}

test "fwupd download fetchPayload resolves local and directory remotes without HTTP" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var map: std.process.Environ.Map = .init(testing.allocator);
    defer map.deinit();

    var fake = fwupd.FakeBackend{
        .remotes = &.{
            .{ .remote_id = "local-remote", .kind = .local, .filename_cache = "/var/cache/fwupd/lvfs.xml.gz" },
            .{ .remote_id = "dir-remote", .kind = .directory },
        },
    };
    const local_release = models.Release{
        .remote_id = "local-remote",
        .locations = &.{"https://cdn.example/fw.cab"},
    };
    const local_path = try fetchPayload(fake.backend(), alloc, threaded.io(), &map, local_release, "shelly/test", .{});
    try testing.expectEqualStrings("/var/cache/fwupd/fw.cab", local_path);

    const dir_release = models.Release{
        .remote_id = "dir-remote",
        .locations = &.{"file:///srv/firmware/fw.cab"},
    };
    const dir_path = try fetchPayload(fake.backend(), alloc, threaded.io(), &map, dir_release, "shelly/test", .{});
    try testing.expectEqualStrings("/srv/firmware/fw.cab", dir_path);

    // Missing remote and missing location are distinct hard errors.
    const orphan = models.Release{ .remote_id = "gone", .locations = &.{"https://x/fw.cab"} };
    try testing.expectError(error.RemoteNotFound, fetchPayload(fake.backend(), alloc, threaded.io(), &map, orphan, "shelly/test", .{}));
    const no_loc = models.Release{ .remote_id = "dir-remote" };
    try testing.expectError(error.NoPayloadLocation, fetchPayload(fake.backend(), alloc, threaded.io(), &map, no_loc, "shelly/test", .{}));
}

test "fwupd download requires checksums for download remotes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var map: std.process.Environ.Map = .init(testing.allocator);
    defer map.deinit();
    try testEnv(&map);

    var fake = fwupd.FakeBackend{
        .remotes = &.{.{ .remote_id = "lvfs", .kind = .download, .uri = "https://fwupd.org/downloads/firmware.xml.gz" }},
    };
    const release = models.Release{ .remote_id = "lvfs", .locations = &.{"https://cdn.example/fw.cab"} };
    try testing.expectError(
        error.ReleaseWithoutChecksums,
        fetchPayload(fake.backend(), arena.allocator(), threaded.io(), &map, release, "shelly/test", .{}),
    );
}

// ---------------------------------------------------------------------------
// Live local-HTTP-server tests (loopback, no daemon, no display)
// ---------------------------------------------------------------------------

const TestServer = struct {
    io: Io,
    server: Io.net.Server,
    hits: usize = 0,
    payload: []const u8,
    status: []const u8 = "200 OK",

    fn init(io: Io, payload: []const u8) !TestServer {
        var address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        return .{
            .io = io,
            .server = try address.listen(io, .{ .reuse_address = true }),
            .payload = payload,
        };
    }

    fn port(self: *const TestServer) u16 {
        return self.server.socket.address.getPort();
    }

    fn deinit(self: *TestServer) void {
        self.server.deinit(self.io);
    }

    /// Serve exactly one request per call; run on a detached thread.
    fn serveOne(self: *TestServer) void {
        var stream = self.server.accept(self.io) catch return;
        defer stream.close(self.io);
        var read_buf: [4096]u8 = undefined;
        var reader = stream.reader(self.io, &read_buf);
        // Consume the request head.
        while (true) {
            const line = reader.interface.takeDelimiter('\n') catch return;
            if (line == null) return;
            if (std.mem.eql(u8, std.mem.trimEnd(u8, line.?, "\r"), "")) break;
        }
        // The test thread reads hits only after joining the server thread.
        self.hits += 1;
        var write_buf: [4096]u8 = undefined;
        var writer = stream.writer(self.io, &write_buf);
        var head_buf: [128]u8 = undefined;
        const head = std.fmt.bufPrint(&head_buf, "HTTP/1.1 {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ self.status, self.payload.len }) catch return;
        writer.interface.writeAll(head) catch return;
        writer.interface.writeAll(self.payload) catch return;
        writer.interface.flush() catch return;
    }
};

fn sha256Hex(data: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

const DownloadFixture = struct {
    threaded: std.Io.Threaded,
    map: std.process.Environ.Map,
    tmp: testing.TmpDir,
    fake: fwupd.FakeBackend,
    release: models.Release,
    hex: [64]u8,
    locations: [1][]const u8 = .{""},

    fn init(payload: []const u8) !DownloadFixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var map: std.process.Environ.Map = .init(testing.allocator);
        errdefer map.deinit();
        const cache_root = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        defer testing.allocator.free(cache_root);
        try map.put("XDG_CACHE_HOME", cache_root);
        return .{
            .threaded = .init(testing.allocator, .{}),
            .map = map,
            .tmp = tmp,
            .fake = .{
                .remotes = &.{.{ .remote_id = "lvfs", .kind = .download }},
            },
            .release = .{
                .remote_id = "lvfs",
                .size = payload.len,
            },
            .hex = sha256Hex(payload),
        };
    }

    fn deinit(self: *DownloadFixture) void {
        self.threaded.deinit();
        self.map.deinit();
        self.tmp.cleanup();
    }

    fn pointAt(self: *DownloadFixture, url_buf: []u8, port: u16) !void {
        self.release.checksum = &self.hex;
        const url = try std.fmt.bufPrint(url_buf, "http://127.0.0.1:{d}/fw.cab", .{port});
        self.locations = .{url};
        self.release.locations = &self.locations;
    }
};

fn expectAbsent(io: Io, alloc: std.mem.Allocator, parts: []const []const u8) !void {
    const path = try std.fs.path.join(alloc, parts);
    defer alloc.free(path);
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, path, .{}));
}

fn expectAbsentSuffix(io: Io, alloc: std.mem.Allocator, path: []const u8, suffix: []const u8) !void {
    const joined = try std.mem.concat(alloc, u8, &.{ path, suffix });
    defer alloc.free(joined);
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, joined, .{}));
}

test "fwupd download fetches, verifies, caches and reuses a payload" {
    const payload = "firmware payload bytes for the cache test";
    var fixture = try DownloadFixture.init(payload);
    defer fixture.deinit();
    const io = fixture.threaded.io();
    // fetchPayload returns arena-owned strings, like the page's install arena.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var server = try TestServer.init(io, payload);
    defer server.deinit();
    var url_buf: [64]u8 = undefined;
    try fixture.pointAt(&url_buf, server.port());

    const worker = try std.Thread.spawn(.{}, TestServer.serveOne, .{&server});
    var capture = ProgressCapture{};
    const path = try fetchPayload(fixture.fake.backend(), alloc, io, &fixture.map, fixture.release, "shelly/test fwupd/2.1.10", capture.progress());
    worker.join();

    try testing.expectEqual(@as(usize, 1), server.hits);
    try testing.expect(std.mem.endsWith(u8, path, "/shelly/fwupd/127.0.0.1/fw.cab"));
    const cached = try Io.Dir.cwd().readFileAlloc(io, path, testing.allocator, .limited(4096));
    defer testing.allocator.free(cached);
    try testing.expectEqualStrings(payload, cached);
    try testing.expectEqual(@as(u64, payload.len), capture.last_received);
    // No .part leftovers.
    try expectAbsentSuffix(io, testing.allocator, path, ".part");

    // Second fetch reuses the cache without touching the server.
    const again = try fetchPayload(fixture.fake.backend(), alloc, io, &fixture.map, fixture.release, "shelly/test", .{});
    try testing.expectEqualStrings(path, again);
    try testing.expectEqual(@as(usize, 1), server.hits);

    // A corrupted cache entry is dropped and re-downloaded.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "corrupted" });
    const worker2 = try std.Thread.spawn(.{}, TestServer.serveOne, .{&server});
    const redownloaded = try fetchPayload(fixture.fake.backend(), alloc, io, &fixture.map, fixture.release, "shelly/test", .{});
    worker2.join();
    try testing.expectEqual(@as(usize, 2), server.hits);
    const fresh = try Io.Dir.cwd().readFileAlloc(io, redownloaded, testing.allocator, .limited(4096));
    defer testing.allocator.free(fresh);
    try testing.expectEqualStrings(payload, fresh);
}

test "fwupd download deletes partials on checksum mismatch and HTTP errors" {
    const payload = "expected payload";
    var fixture = try DownloadFixture.init(payload);
    defer fixture.deinit();
    const io = fixture.threaded.io();
    const cache_root = fixture.map.get("XDG_CACHE_HOME").?;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Server sends different bytes than the checksum covers.
    var server = try TestServer.init(io, "wrong payload!!!");
    defer server.deinit();
    var url_buf: [64]u8 = undefined;
    try fixture.pointAt(&url_buf, server.port());
    const worker = try std.Thread.spawn(.{}, TestServer.serveOne, .{&server});
    try testing.expectError(
        error.ChecksumMismatch,
        fetchPayload(fixture.fake.backend(), alloc, io, &fixture.map, fixture.release, "shelly/test", .{}),
    );
    worker.join();
    try expectAbsent(io, testing.allocator, &.{ cache_root, "shelly", "fwupd", "127.0.0.1", "fw.cab" });
    try expectAbsent(io, testing.allocator, &.{ cache_root, "shelly", "fwupd", "127.0.0.1", "fw.cab.part" });

    // HTTP 404 also leaves no partial behind.
    var bad_server = try TestServer.init(io, "not found");
    defer bad_server.deinit();
    bad_server.status = "404 Not Found";
    try fixture.pointAt(&url_buf, bad_server.port());
    const worker2 = try std.Thread.spawn(.{}, TestServer.serveOne, .{&bad_server});
    try testing.expectError(
        error.DownloadFailed,
        fetchPayload(fixture.fake.backend(), alloc, io, &fixture.map, fixture.release, "shelly/test", .{}),
    );
    worker2.join();
    try expectAbsent(io, testing.allocator, &.{ cache_root, "shelly", "fwupd", "127.0.0.1", "fw.cab.part" });
}