//! Explicit privileged integration target. Never part of the ordinary test step.
const std = @import("std");
const rlpm = @import("Shelly_Rlpm");
const worker_fixture = @import("worker_fixture");
const HttpFixture = @import("http_download_fixture.zig");

test "root download sandbox drops credentials and preserves the parent across all switches" {
    if (std.c.getuid() != 0) return error.RootSandboxIntegrationUnavailable;
    const a = std.testing.allocator;
    const io = std.testing.io;
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(io, worker_fixture.path, a);
    defer a.free(executable);
    const base = try rlpm.Downloads.uniquePath(a, io, "/tmp", "rlpm-sandbox-test");
    defer a.free(base);
    try std.Io.Dir.cwd().createDir(io, base, .fromMode(0o755));
    defer std.Io.Dir.cwd().deleteTree(io, base) catch unreachable;
    for (0..8) |bits| {
        const path = try std.fmt.allocPrint(a, "{s}/case-{d}", .{ base, bits });
        defer a.free(path);
        try std.Io.Dir.cwd().createDir(io, path, .fromMode(0o755));
        const cache = try std.fmt.allocPrint(a, "{s}/cache", .{path});
        defer a.free(cache);
        const source = try std.fmt.allocPrint(a, "{s}/private.pkg", .{path});
        defer a.free(source);
        const input = try std.Io.Dir.cwd().createFile(io, source, .{ .permissions = .fromMode(0o600) });
        try input.writeStreamingAll(io, "private");
        try input.setTimestamps(
            io,
            .{
                .modify_timestamp = .{ .new = .{ .nanoseconds = 1600000000000000000 } },
            },
        );
        input.close(io);
        var owner = try rlpm.Owner.init(io, a, .{
            .root = path,
            .database_path = path,
            .cache_directories = &.{cache},
            .sandbox_user = "nobody",
            .worker_executable = executable,
            .sandbox = .{
                .disable_filesystem = bits & 1 != 0,
                .disable_syscalls = bits & 2 != 0,
                .disable_network = bits & 4 != 0,
            },
        }, &.{});
        defer owner.deinit() catch unreachable;
        const url = try std.fmt.allocPrint(a, "file://{s}", .{source});
        defer a.free(url);
        if (bits == 7) {
            var result = try owner.fetchPackage(io, url);
            defer result.deinit();
            const st = try std.Io.Dir.cwd().statFile(io, result.path, .{});
            try std.testing.expectEqual(0o644, st.permissions.toMode() & 0o777);
            try std.testing.expectEqual(1600000000000000000, st.mtime.nanoseconds);
        } else {
            try std.testing.expectError(error.FileError, owner.fetchPackage(io, url));
            const public_input = try std.Io.Dir.cwd().openFile(io, source, .{});
            defer public_input.close(io);
            try public_input.setPermissions(io, .fromMode(0o644));
            var result = try owner.fetchPackage(io, url);
            defer result.deinit();
            const st = try std.Io.Dir.cwd().statFile(io, result.path, .{});
            try std.testing.expectEqual(0o644, st.permissions.toMode() & 0o777);
            try std.testing.expectEqual(1600000000000000000, st.mtime.nanoseconds);
        }
        try std.testing.expectEqual(0, std.c.getuid());
    }
}

test "sandboxed workers overlap downloads and report fast transfers before slow workers finish" {
    if (std.c.getuid() != 0) return error.RootSandboxIntegrationUnavailable;
    const a = std.testing.allocator;
    const io = std.testing.io;
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(io, worker_fixture.path, a);
    defer a.free(executable);
    const base = try rlpm.Downloads.uniquePath(a, io, "/tmp", "rlpm-sandbox-queue");
    defer a.free(base);
    try std.Io.Dir.cwd().createDir(io, base, .fromMode(0o755));
    defer std.Io.Dir.cwd().deleteTree(io, base) catch unreachable;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server: HttpFixture = .{
        .server = try address.listen(io, .{ .reuse_address = true }),
        .body = "sandboxed concurrent payload",
        .gate_slow = true,
        .unknown_length = true,
    };
    defer server.server.deinit(io);
    var serving = try io.concurrent(HttpFixture.serve, .{&server});
    defer _ = serving.cancel(io) catch {};
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{server.server.socket.address.getPort()});
    defer a.free(url);
    var owner = try rlpm.Owner.init(io, a, .{
        .root = base,
        .database_path = base,
        .cache_directories = &.{base},
        .parallel_downloads = 2,
        .sandbox_user = "nobody",
        .worker_executable = executable,
    }, &.{});
    defer owner.deinit() catch unreachable;
    const Capture = struct {
        fn receive(data: ?*anyopaque, event: rlpm.Callbacks.Download) void {
            const http: *HttpFixture = @ptrCast(@alignCast(data.?));
            if (event == .transferred and std.mem.eql(u8, event.transferred.name, "fast.pkg"))
                http.fast_reported.store(true, .release);
        }
    };
    try owner.setCallbacks(.{ .download = Capture.receive, .download_context = &server });
    const files = try rlpm.Downloads.acquire(&owner, io, &.{
        .{ .name = "slow.pkg", .servers = &.{url}, .policy = rlpm.OwnerConfiguration.disabled_signatures },
        .{ .name = "fast.pkg", .servers = &.{url}, .policy = rlpm.OwnerConfiguration.disabled_signatures },
    });
    defer a.free(files);
    defer for (files) |*file| file.deinit();
    try std.testing.expectEqual(2, server.peak.load(.acquire));
    try std.testing.expectEqual(2, server.requests.load(.acquire));
    try std.testing.expect(server.fast_reported.load(.acquire));
    try std.testing.expect(!server.timed_out.load(.acquire) and !server.failed.load(.acquire));
    for (files) |file| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, file.path, a, .limited(1024));
        defer a.free(bytes);
        try std.testing.expectEqualStrings(server.body, bytes);
    }
    try std.testing.expectEqual(0, std.c.getuid());
}
