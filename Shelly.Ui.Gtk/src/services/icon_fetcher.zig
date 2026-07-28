const std = @import("std");
const Io = std.Io;
const flate = std.compress.flate;
const runtime = @import("runtime.zig");
const RELEASE_URL = "https://api.github.com/repos/Seafoam-Labs/shelly-icon-stream/releases/latest";
const USER_AGENT = "shelly-notifications";

const Asset = struct {
    name: []const u8 = "",
    digest: []const u8 = "",
    browser_download_url: []const u8 = "",
};
const Release = struct {
    tarball_url: []const u8 = "",
    assets: []Asset = &.{},
};

pub const IconDownloadService = struct {
    allocator: std.mem.Allocator,
    io: Io,

    pub fn init(allocator: std.mem.Allocator, io: Io) IconDownloadService {
        return .{ .allocator = allocator, .io = io };
    }

    fn download_unpack_icons(self: *IconDownloadService) !bool {
        const a = self.allocator;
        const io = self.io;

        const home = runtime.environ_map.get("HOME") orelse return error.NoHome;
        const icon_folder = try std.fs.path.join(a, &.{ home, ".local/share/shelly-icons" });
        defer a.free(icon_folder);

        var dir = try Io.Dir.cwd().createDirPathOpen(io, icon_folder, .{});
        defer dir.close(io);

        const release_json = try self.http_get(RELEASE_URL);
        defer a.free(release_json);

        const parsed = try std.json.parseFromSlice(Release, a, release_json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const release = parsed.value;

        var chosen: ?Asset = null;
        for (release.assets) |asset| {
            if (std.mem.endsWith(u8, asset.name, ".tar.gz") and asset.digest.len > 0) {
                chosen = asset;
                break;
            }
        }

        if (chosen) |asset| {
            if (dir.readFileAlloc(io, ".hash", a, .limited(4096))) |current| {
                defer a.free(current);
                if (std.mem.eql(
                    u8,
                    std.mem.trim(u8, current, " \n\r\t"),
                    std.mem.trim(u8, asset.digest, " \n\r\t"),
                )) {
                    std.log.info("icons: hash matches, skipping download", .{});
                    return true;
                }
            } else |_| {
                std.log.info("icons: failed to read hash file probably missing", .{});
            }
        }

        const download_url = if (chosen) |asset|
            (if (asset.browser_download_url.len > 0) asset.browser_download_url else release.tarball_url)
        else
            release.tarball_url;
        if (download_url.len == 0) return false;

        const tar_gz = try self.http_get(download_url);
        defer a.free(tar_gz);

        try unpack(io, dir, tar_gz);

        if (chosen) |asset| {
            if (asset.digest.len > 0) {
                try dir.writeFile(io, .{ .sub_path = ".hash", .data = asset.digest });
            }
        }

        return true;
    }

    fn http_get(self: *IconDownloadService, url: []const u8) ![]u8 {
        const a = self.allocator;
        var client = std.http.Client{ .allocator = a, .io = self.io };
        defer client.deinit();

        var aw = std.Io.Writer.Allocating.init(a);
        defer aw.deinit();

        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .extra_headers = &.{
                .{ .name = "User-Agent", .value = USER_AGENT },
                .{ .name = "Accept", .value = "application/vnd.github+json" },
            },
            .response_writer = &aw.writer,
        });
        if (result.status != .ok) {
            std.debug.print("[icons] HTTP {d} for {s}\n", .{ @intFromEnum(result.status), url });
            return error.HttpError;
        }
        return aw.toOwnedSlice();
    }
};

fn unpack(io: Io, dir: Io.Dir, tar_gz: []const u8) !void {
    var src = Io.Reader.fixed(tar_gz);
    var window: [flate.max_window_len]u8 = undefined;
    var dec = flate.Decompress.init(&src, .gzip, &window);
    try std.tar.extract(io, dir, &dec.reader, .{});
}

pub fn downloadIconsInBackground(allocator: std.mem.Allocator, io: Io) void {
    const thread = std.Thread.spawn(.{}, worker, .{ allocator, io }) catch |e| {
        std.debug.print("[icons] spawn failed: {any}\n", .{e});
        return;
    };
    thread.detach();
}

fn worker(allocator: std.mem.Allocator, io: Io) void {
    var svc = IconDownloadService.init(allocator, io);
    _ = svc.download_unpack_icons() catch |e| {
        std.debug.print("[icons] download failed: {any}\n", .{e});
    };
}
