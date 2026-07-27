const std = @import("std");
const runtime = @import("runtime.zig");
const xdg_paths = @import("xdg_paths.zig").xdg_paths;

const SERVICE_NAME = "shelly-notifications";
const SERVICE_FILENAME = SERVICE_NAME ++ ".service";

const SERVICE_CONTENT =
    \\[Unit]
    \\Description=Shelly Notifications Tray Service
    \\After=graphical-session.target
    \\
    \\[Service]
    \\Type=simple
    \\ExecStart=/usr/bin/shelly-notifications
    \\Restart=on-failure
    \\
    \\[Install]
    \\WantedBy=default.target
;

fn serviceDir(allocator: std.mem.Allocator) ![]u8 {
    const config_home = try xdg_paths.xdgConfigHome(allocator, runtime.environ_map);
    defer allocator.free(config_home);
    return try std.fs.path.join(allocator, &.{ config_home, "systemd", "user" });
}

fn runSystemctl(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var argv = try allocator.alloc([]const u8, args.len + 1);
    defer allocator.free(argv);
    argv[0] = "systemctl";
    @memcpy(argv[1..], args);

    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .environ_map = runtime.environ_map,
    }) catch |err| {
        std.log.err("systemd_tray: failed to spawn systemctl: {t}", .{err});
        return err;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        std.log.err(
            "systemd_tray: systemctl exited with term={any} stderr='{s}'",
            .{ result.term, result.stderr },
        );
        return error.CommandFailed;
    }
}

pub fn addService(allocator: std.mem.Allocator, io: std.Io) !void {
    const dir_path = try serviceDir(allocator);
    defer allocator.free(dir_path);

    const cwd = std.Io.Dir.cwd();
    var dir = cwd.createDirPathOpen(io, dir_path, .{}) catch |err| switch (err) {
        error.PathAlreadyExists => try cwd.openDir(io, dir_path, .{}),
        else => return err,
    };
    defer dir.close(io);

    const file = try dir.createFile(io, SERVICE_FILENAME, .{});
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    try fw.interface.writeAll(SERVICE_CONTENT);
    try fw.flush();

    try runSystemctl(allocator, io, &.{ "--user", "daemon-reload" });
    try runSystemctl(allocator, io, &.{ "--user", "enable", "--now", SERVICE_NAME });
}

pub fn removeService(allocator: std.mem.Allocator, io: std.Io) !void {
    runSystemctl(allocator, io, &.{ "--user", "disable", "--now", SERVICE_NAME }) catch |err| {
        std.log.warn("systemd_tray: disable --now failed (expected if never installed): {t}", .{err});
    };

    const dir_path = serviceDir(allocator) catch |err| {
        std.log.warn("systemd_tray: could not resolve service dir: {t}", .{err});
        try runSystemctl(allocator, io, &.{ "--user", "daemon-reload" });
        return;
    };
    defer allocator.free(dir_path);

    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, dir_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try runSystemctl(allocator, io, &.{ "--user", "daemon-reload" });
            return;
        },
        else => return err,
    };
    defer dir.close(io);

    dir.deleteFile(io, SERVICE_FILENAME) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    try runSystemctl(allocator, io, &.{ "--user", "daemon-reload" });
}
