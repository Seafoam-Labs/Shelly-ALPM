const std = @import("std");
const linux = std.os.linux;

const bindings = @import("Shelly_Ui_Gtk");
const glib = bindings.glib;

const runtime = @import("runtime.zig");

const APP_NAME = "shelly-notifications";
const APP_PATH: [:0]const u8 = "/usr/bin/shelly-notifications";
const TERM_GRACE_MS = 500;

const log = std.log.scoped(.tray_service);

pub fn start(io: std.Io, alloc: std.mem.Allocator) void {
    std.Io.Dir.cwd().access(io, APP_PATH, .{}) catch {
        log.warn("tray executable not found at {s}", .{APP_PATH});
        return;
    };

    var pids: std.ArrayList(linux.pid_t) = .empty;
    defer pids.deinit(alloc);
    findPids(io, alloc, &pids) catch |err| {
        log.warn("failed to find pids: {s}", .{@errorName(err)});
    };
    if (pids.items.len > 0) {
        log.info("tray already running (pid {d})", .{pids.items[0]});
        return;
    }

    var argv_storage = [_]?[*:0]u8{ @constCast(APP_PATH.ptr), null };
    const argv: [*:null]?[*:0]u8 = @ptrCast(&argv_storage);

    const flags: glib.SpawnFlags = .{
        .do_not_reap_child = true,
        .stdin_from_dev_null = true,
        .stdout_to_dev_null = true,
        .stderr_to_dev_null = true,
    };

    var err: ?*glib.Error = null;
    const ok = glib.spawnAsync(
        null, // inherit working directory
        argv,
        null, // inherit environment
        flags,
        &detachChild,
        null, // no user data
        null, // don't need the child pid
        &err,
    );

    if (ok == 0) {
        if (err) |e| {
            const msg: []const u8 = if (e.f_message) |m| std.mem.sliceTo(m, 0) else "unknown error";
            log.warn("failed to start tray: {s}", .{msg});
            glib.Error.free(e);
        } else {
            log.warn("failed to start tray", .{});
        }
        return;
    }
    log.info("tray started", .{});
}

pub fn end(io: std.Io, alloc: std.mem.Allocator) bool {
    var pids: std.ArrayList(linux.pid_t) = .empty;
    defer pids.deinit(alloc);
    findPids(io, alloc, &pids) catch |err| {
        log.warn("failed to find pids: {s}", .{@errorName(err)});
        return false;
    };

    if (pids.items.len == 0) {
        log.info("no running tray process found", .{});
        return false;
    }

    for (pids.items) |pid| signalPid(pid, .TERM);

    // Give the GLib main loop a moment to unwind, then force-kill survivors.
    runtime.io.sleep(.fromMilliseconds(TERM_GRACE_MS), .awake) catch {};

    var survivors: std.ArrayList(linux.pid_t) = .empty;
    defer survivors.deinit(alloc);
    findPids(io, alloc, &survivors) catch |err| {
        log.warn("failed to find survivors: {s}", .{@errorName(err)});
    };
    for (survivors.items) |pid| {
        log.warn("pid {d} ignored SIGTERM; sending SIGKILL", .{pid});
        signalPid(pid, .KILL);
    }
    log.info("tray ended", .{});

    return true;
}

fn findPids(io: std.Io, alloc: std.mem.Allocator, out: *std.ArrayList(linux.pid_t)) !void {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "pidof", APP_NAME },
        .stdout = .pipe,
    });
    defer _ = child.wait(io) catch |err| {
        log.err("failed to wait for pidof: {s}", .{@errorName(err)});
    };

    const cap = 6 << 7; // 768 bytes
    var buf: [cap]u8 = undefined;
    var file_reader = child.stdout.?.reader(io, &buf);
    const stdout = try file_reader.interface.allocRemaining(alloc, .limited(cap));
    defer alloc.free(stdout);

    var it = std.mem.splitAny(u8, stdout, " \n\r\t");
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        const pid = try std.fmt.parseInt(linux.pid_t, tok, 10);
        try out.append(alloc, pid);
    }
}

fn signalPid(pid: linux.pid_t, sig: linux.SIG) void {
    switch (linux.errno(linux.kill(pid, sig))) {
        .SUCCESS, .SRCH => {},
        .PERM => log.warn("no permission to signal pid {d}", .{pid}),
        else => |e| log.warn("kill({d}) failed: {s}", .{ pid, @tagName(e) }),
    }
}

/// `glib.SpawnChildSetupFunc` run in the child after fork, before exec.
/// `setsid()` detaches the tray into its own session so it isn't killed by
/// SIGHUP when the GUI exits.
fn detachChild(_: ?*anyopaque) callconv(.c) void {
    _ = linux.setsid();
}
