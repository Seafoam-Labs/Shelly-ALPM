const std = @import("std");
const diagnostics = @import("diagnostics");
const HttpClient = @import("ShellyHttp");
const Io = std.Io;
const flate = std.compress.flate;
const runtime = @import("runtime.zig");
const xdg_paths = @import("xdg_paths.zig").xdg_paths;
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

    fn cache_folder(self: *IconDownloadService) ![]u8 {
        const a = self.allocator;
        const data_home = try xdg_paths.xdgDataHome(a, runtime.environ_map);
        defer a.free(data_home);
        return std.fs.path.join(a, &.{ data_home, "shelly-icons" });
    }

    fn remove_cached_icons(self: *IconDownloadService) !void {
        const icon_folder = try self.cache_folder();
        defer self.allocator.free(icon_folder);
        try Io.Dir.cwd().deleteTree(self.io, icon_folder);
    }

    fn download_unpack_icons(self: *IconDownloadService) !bool {
        const a = self.allocator;
        const io = self.io;

        const icon_folder = try self.cache_folder();
        defer a.free(icon_folder);

        var dir = try Io.Dir.cwd().createDirPathOpen(io, icon_folder, .{});
        defer dir.close(io);

        const release_json = try self.http_get(RELEASE_URL, &.{
            .{ .name = "Accept", .value = "application/vnd.github+json" },
        });
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
                std.log.info("Could not read the icon-cache version file.", .{});
            }
        }

        const download_url = if (chosen) |asset|
            (if (asset.browser_download_url.len > 0) asset.browser_download_url else release.tarball_url)
        else
            release.tarball_url;
        if (download_url.len == 0) return false;

        const tar_gz = try self.http_get(download_url, &.{});
        defer a.free(tar_gz);

        try unpack(io, dir, tar_gz);

        if (chosen) |asset| {
            if (asset.digest.len > 0) {
                try dir.writeFile(io, .{ .sub_path = ".hash", .data = asset.digest });
            }
        }

        return true;
    }

    fn http_get(self: *IconDownloadService, url: []const u8, extra_headers: []const std.http.Header) ![]u8 {
        var client: HttpClient = .{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        var aw = std.Io.Writer.Allocating.init(self.allocator);
        defer aw.deinit();

        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .headers = .{ .user_agent = .{ .override = USER_AGENT } },
            .extra_headers = extra_headers,
            .response_writer = &aw.writer,
        });

        switch (result.status) {
            .ok => {
                std.log.info("Downloaded application icons from {0f}.", .{diagnostics.safe(url)});
                return aw.toOwnedSlice();
            },
            else => {
                std.debug.print("Could not download application icons from {0f}: the server returned HTTP {1d}.\n", .{ diagnostics.safe(url), @intFromEnum(result.status) });
                return error.HttpError;
            },
        }
    }
};

fn unpack(io: Io, dir: Io.Dir, tar_gz: []const u8) !void {
    var src = Io.Reader.fixed(tar_gz);
    var window: [flate.max_window_len]u8 = undefined;
    var dec = flate.Decompress.init(&src, .gzip, &window);
    try std.tar.extract(io, dir, &dec.reader, .{});
}

pub fn downloadIconsInBackground(allocator: std.mem.Allocator, io: Io, icons_enabled: bool) void {
    const thread = std.Thread.spawn(.{}, worker, .{ allocator, io, icons_enabled }) catch |e| {
        std.debug.print("Could not start downloading application icons. {0s}\n\nTechnical details: {1s}\n", .{ diagnostics.cause(e), @errorName(e) });
        return;
    };
    thread.detach();
}

fn worker(allocator: std.mem.Allocator, io: Io, icons_enabled: bool) void {
    var svc = IconDownloadService.init(allocator, io);
    if (!icons_enabled) {
        svc.remove_cached_icons() catch |e| {
            std.debug.print("Could not remove the cached application icons. {0s}\n\nTechnical details: {1s}\n", .{ diagnostics.cause(e), @errorName(e) });
        };
        return;
    }
    _ = svc.download_unpack_icons() catch |e| {
        std.debug.print("Could not download application icons. {0s}\n\nTechnical details: {1s}\n", .{ diagnostics.cause(e), @errorName(e) });
    };
}
