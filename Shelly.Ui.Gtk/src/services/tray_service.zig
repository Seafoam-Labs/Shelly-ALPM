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
        log.warn("Could not start the tray because its executable is missing at {0f}. Check the Shelly installation.", .{@import("diagnostics").safe(APP_PATH)});
        return;
    };

    var pids: std.ArrayList(linux.pid_t) = .empty;
    defer pids.deinit(alloc);
    findPids(io, alloc, &pids) catch |err| {
        log.warn("Could not identify running Shelly tray processes. {0s}\n\nTechnical details: {1s}", .{ @import("diagnostics").cause(err), @errorName(err) });
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
            log.warn("Could not start the Shelly tray. {0f}", .{@import("diagnostics").safe(msg)});
            glib.Error.free(e);
        } else {
            log.warn("Could not start the Shelly tray.", .{});
        }
        return;
    }
    log.info("tray started", .{});
}

pub fn end(io: std.Io, alloc: std.mem.Allocator) bool {
    var pids: std.ArrayList(linux.pid_t) = .empty;
    defer pids.deinit(alloc);
    findPids(io, alloc, &pids) catch |err| {
        log.warn("Could not identify running Shelly tray processes. {0s}\n\nTechnical details: {1s}", .{ @import("diagnostics").cause(err), @errorName(err) });
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
        log.warn("Could not confirm whether the Shelly tray stopped. {0s}\n\nTechnical details: {1s}", .{ @import("diagnostics").cause(err), @errorName(err) });
    };
    for (survivors.items) |pid| {
        log.warn("Tray process {0d} did not stop after SIGTERM; sending SIGKILL.", .{pid});
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
        log.err("Could not collect the result of the tray-process lookup. {0s}\n\nTechnical details: {1s}", .{ @import("diagnostics").cause(err), @errorName(err) });
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
        .PERM => log.warn("Could not stop tray process {0d} because permission was denied. Run the action as the user who owns the tray process.", .{pid}),
        else => |e| log.warn("Could not stop tray process {0d}. The operating system rejected the request. Review the technical details.\n\nTechnical details: {1f}", .{ pid, @import("diagnostics").safe(@tagName(e)) }),
    }
}

/// `glib.SpawnChildSetupFunc` run in the child after fork, before exec.
/// `setsid()` detaches the tray into its own session so it isn't killed by
/// SIGHUP when the GUI exits.
fn detachChild(_: ?*anyopaque) callconv(.c) void {
    _ = linux.setsid();
}
