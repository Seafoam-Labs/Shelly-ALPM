//! Fresh process: privilege changes never affect the parent or its worker pool.
const std = @import("std");
const download = @import("Shelly_Download");
const protocol = download.WorkerProtocol;
pub fn run(init: std.process.Init) !void {
    const a = init.arena.allocator();
    var input_buffer: [8192]u8 = undefined;
    var input = std.Io.File.stdin().reader(init.io, &input_buffer);
    const bytes = try input.interface.allocRemaining(a, .limited(1024 * 1024));
    const parsed = try std.json.parseFromSlice(protocol.Request, a, bytes, .{});
    const request = parsed.value;
    const user = try a.dupeZ(u8, request.user);
    const directory = try a.dupeZ(u8, request.directory);
    download.Sandbox.apply(user, directory, request.filesystem, request.syscalls) catch return finish(init.io, .sandbox);
    download.HttpClient.setDefaultProxyEnvironment(init.environ_map);
    var core = download.CoreDownloader.init(init.gpa, init.io, .{ .timeout_in_seconds = request.timeout, .response_header_timeout_in_seconds = request.timeout, .response_body_timeout_in_seconds = request.timeout, .max_retries = 1, .retry_delay_secs = 0, .maximum_size = request.maximum, .conditional_mtime = request.mtime, .resume_path = request.partial, .final_permissions = .fromMode(0o644) });
    defer core.deinit();
    core.quiet = true;
    var context = init.io;
    core.setEventCallback(progress, &context);
    const result = core.downloadToFile(request.url, request.path, request.force);
    if (result == .succes or result == .skipped) {
        if (core.effective_url) |url| {
            const metadata = try std.fs.path.join(a, &.{ request.directory, ".rlpm-effective-url" });
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = metadata, .data = url });
        }
    }
    try finish(init.io, switch (result) {
        .succes => .success,
        .skipped => .unchanged,
        .failure => |err| switch (err) {
            error.NotFound => .not_found,
            error.HostNotFound => .host_not_found,
            error.Cancelled => .cancelled,
            error.SizeExceeded => .size,
            error.FileError => .file,
            error.Timeout, error.ConnectTimeout, error.HeaderTimeout, error.BodyTimeout => .timeout,
            error.InvalidUrl => .url,
            error.SslError, error.CertificateBundleError => .tls,
            else => .network,
        },
    });
}
fn progress(ctx: ?*anyopaque, event: download.DownloadEvent) void {
    const io: *std.Io = @ptrCast(@alignCast(ctx.?));
    if (event.progress) |value| {
        var bytes: [17]u8 = undefined;
        bytes[0] = 0;
        std.mem.writeInt(u64, bytes[1..9], value.bytes_downloaded, .little);
        std.mem.writeInt(u64, bytes[9..17], value.bytes_total orelse 0, .little);
        std.Io.File.stdout().writeStreamingAll(io.*, &bytes) catch {};
    }
}
fn finish(io: std.Io, result: protocol.Result) !void {
    var bytes: [17]u8 = @splat(0);
    bytes[0] = @intFromEnum(result) + 1;
    try std.Io.File.stdout().writeStreamingAll(io, &bytes);
}
