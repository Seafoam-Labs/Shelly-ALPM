//! Parent side of the download worker protocol; no parent credential changes.
const std = @import("std");
const transport = @import("Shelly_Download");
const Owner = @import("Owner.zig");
const Publication = @import("Publication.zig");
const Downloads = @import("Downloads.zig");
const Workers = @import("workers");
const ImmutableFile = @import("ImmutableFile.zig");

const protocol = transport.WorkerProtocol;
extern "c" fn rlpm_worker_directory([*:0]const u8, [*:0]const u8) c_int;
extern "c" fn rlpm_worker_read(c_int, [*]u8, usize) c_int;

pub fn applicable(owner: *const Owner) bool {
    const config = owner.configuration;
    return std.c.getuid() == 0 and config.sandbox_user != null and
        (!config.sandbox.disable_filesystem or !config.sandbox.disable_syscalls or
            !config.sandbox.disable_network);
}

pub fn fetch(
    owner: *Owner,
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    path: []const u8,
    force: bool,
    maximum: ?u64,
    mtime: ?i128,
    allow_resume: bool,
    progress: *std.atomic.Value(u64),
    effective_url: ?*?[]u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const directory = try Downloads.uniquePath(a, io, "/tmp", "rlpm-download");
    try Publication.privateDirectory(directory);
    defer std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    const directory_z = try a.dupeZ(u8, directory);
    const user = try a.dupeZ(u8, owner.configuration.sandbox_user.?);
    if (rlpm_worker_directory(directory_z, user) != 0) return error.DownloadSandboxFailed;
    // Payload basenames cannot collide with worker protocol metadata.
    const payload_directory = try std.fs.path.join(a, &.{ directory, "payload" });
    try Publication.privateDirectory(payload_directory);
    if (rlpm_worker_directory(try a.dupeZ(u8, payload_directory), user) != 0)
        return error.DownloadSandboxFailed;
    const output = try std.fs.path.join(a, &.{ payload_directory, std.fs.path.basename(path) });
    const partial = try std.fmt.allocPrint(a, "{s}.part", .{output});
    const parent_partial = try std.fmt.allocPrint(a, "{s}.part", .{path});
    // Restore a prior partial into the sandbox with the worker's credentials.
    if (allow_resume) {
        if (Publication.copy(io, parent_partial, partial)) {
            if (rlpm_worker_directory(try a.dupeZ(u8, partial), user) != 0) return error.DownloadSandboxFailed;
        } else |err| if (err != error.FileNotFound) return err;
    }
    if (mtime != null) {
        if (Publication.copy(io, path, output)) {
            if (rlpm_worker_directory(try a.dupeZ(u8, output), user) != 0) return error.DownloadSandboxFailed;
        } else |err| if (err != error.FileNotFound) return err;
    }
    const request: protocol.Request = .{
        .url = url,
        .path = output,
        .directory = directory,
        .user = user,
        .filesystem = !owner.configuration.sandbox.disable_filesystem,
        .syscalls = !owner.configuration.sandbox.disable_syscalls,
        .force = force or mtime == null,
        .timeout = if (owner.configuration.disable_download_timeout) 0 else 30,
        .maximum = maximum,
        .mtime = mtime,
        .partial = if (allow_resume) partial else null,
    };
    const payload = try std.json.Stringify.valueAlloc(a, request, .{});
    var child = try std.process.spawn(
        io,
        .{
            .argv = &.{ owner.configuration.worker_executable orelse Workers.self_executable, Workers.download_argument },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        },
    );
    var completed = false;
    defer {
        child.kill(io);
        if (!completed and allow_resume) {
            if (ImmutableFile.copyRegular(io, partial, maximum)) |value| {
                var snapshot = value;
                defer snapshot.deinit();
                Publication.copy(io, snapshot.path(), parent_partial) catch {};
            } else |_| {}
        }
    }
    try child.stdin.?.writeStreamingAll(io, payload);
    child.stdin.?.close(io);
    child.stdin = null;
    var packet: [17]u8 = undefined;
    var count: usize = 0;
    var result: ?protocol.Result = null;
    while (result == null) {
        try owner.checkCancelled();
        const n = rlpm_worker_read(child.stdout.?.handle, packet[count..].ptr, packet.len - count);
        if (n == -2) continue;
        if (n <= 0) return error.DownloadWorkerFailed;
        count += @intCast(n);
        if (count != packet.len) continue;
        count = 0;
        if (packet[0] == 0) progress.store(std.mem.readInt(u64, packet[1..9], .little), .release) else {
            result = std.enums.fromInt(protocol.Result, packet[0] - 1) orelse
                return error.DownloadWorkerFailed;
        }
    }
    child.stdout.?.close(io);
    child.stdout = null;
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.DownloadWorkerFailed;
    if (result == .success or result == .unchanged) {
        if (effective_url) |output_url| {
            const metadata = try std.fs.path.join(a, &.{ directory, ".rlpm-effective-url" });
            const value = ImmutableFile.copyRegular(io, metadata, 16384) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            if (value) |file| {
                var snapshot = file;
                defer snapshot.deinit();
                output_url.* = try std.Io.Dir.cwd().readFileAlloc(
                    io,
                    snapshot.path(),
                    allocator,
                    .limited(16385),
                );
            }
        }
    }
    if (result == .success) {
        var snapshot = try ImmutableFile.copyRegular(io, output, maximum);
        defer snapshot.deinit();
        try Publication.copy(io, snapshot.path(), path);
        completed = true;
    } else {
        return switch (result.?) {
            .unchanged => error.NotModified,
            .not_found => error.NotFound,
            .host_not_found => error.HostNotFound,
            .cancelled => error.Cancelled,
            .size => error.SizeExceeded,
            .file => error.FileError,
            .timeout => error.Timeout,
            .url => error.InvalidUrl,
            .tls => error.SslError,
            .network => error.NetworkError,
            .sandbox => error.DownloadSandboxFailed,
            .success => unreachable,
        };
    }
}
