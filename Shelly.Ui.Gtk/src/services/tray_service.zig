const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const glib = bindings.glib;
const runtime = @import("runtime.zig");
const linux = std.os.linux;

const APP_NAME = "shelly-notifications";
const APP_PATH: [:0]const u8 = "/usr/bin/shelly-notifications";

/// Linux truncates `/proc/<pid>/comm` to 15 visible chars (`TASK_COMM_LEN-1`),
/// so `shelly-notifications` (20 chars) is reported as `shelly-notifica`.
const COMM_READ_LIMIT = 32;

const TERM_GRACE_MS = 500;

const log = std.log.scoped(.tray_service);

fn isAllDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// Kernel-truncated form of `APP_NAME` (at most 15 visible chars).
fn truncatedComm() []const u8 {
    return APP_NAME[0..@min(APP_NAME.len, 15)];
}

fn findPids(io: std.Io, out: *std.ArrayList(linux.pid_t)) void {
    var dir = std.Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true }) catch |err| {
        log.warn("cannot open /proc: {t}", .{err});
        return;
    };
    defer dir.close(io);

    const self_pid = linux.getpid();

    var it = dir.iterate();
    while (true) {
        const entry = it.next(io) catch |err| {
            log.warn("/proc iterate error: {t}", .{err});
            return;
        } orelse break;

        if (!isAllDigits(entry.name)) continue;

        const pid = std.fmt.parseInt(linux.pid_t, entry.name, 10) catch continue;
        if (pid == self_pid) continue; // never match ourselves

        if (procExeMatches(entry.name) or procCommMatches(io, entry.name)) {
            out.append(std.heap.c_allocator, pid) catch return;
        }
    }
}

fn procExeMatches(pid: []const u8) bool {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "/proc/{s}/exe", .{pid}, 0) catch return false;

    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = linux.readlink(path, &target_buf, target_buf.len);
    if (linux.errno(rc) != .SUCCESS) return false;
    const target = target_buf[0..@intCast(rc)];
    return std.mem.eql(u8, target, APP_PATH);
}

fn procCommMatches(io: std.Io, pid: []const u8) bool {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{s}/comm", .{pid}) catch return false;

    const cwd = std.Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, path, std.heap.c_allocator, .limited(COMM_READ_LIMIT)) catch return false;
    defer std.heap.c_allocator.free(data);

    const trimmed = std.mem.trimEnd(u8, data, "\n\r ");
    return std.mem.eql(u8, trimmed, truncatedComm());
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

pub fn start() void {
    std.Io.Dir.cwd().access(runtime.io, APP_PATH, .{}) catch {
        log.warn("tray executable not found at {s}", .{APP_PATH});
        return;
    };

    var pids: std.ArrayList(linux.pid_t) = .empty;
    defer pids.deinit(std.heap.c_allocator);
    findPids(runtime.io, &pids);
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

pub fn end(io: std.Io) bool {
    var pids: std.ArrayList(linux.pid_t) = .empty;
    defer pids.deinit(std.heap.c_allocator);
    findPids(io, &pids);

    if (pids.items.len == 0) {
        log.info("no running tray process found", .{});
        return false;
    }

    for (pids.items) |pid| signalPid(pid, .TERM);

    // Give the GLib main loop a moment to unwind, then force-kill survivors.
    runtime.io.sleep(.fromMilliseconds(TERM_GRACE_MS), .awake) catch {};

    var survivors: std.ArrayList(linux.pid_t) = .empty;
    defer survivors.deinit(std.heap.c_allocator);
    findPids(io, &survivors);
    for (survivors.items) |pid| {
        log.warn("pid {d} ignored SIGTERM; sending SIGKILL", .{pid});
        signalPid(pid, .KILL);
    }

    return true;
}

const testing = std.testing;

test "truncatedComm matches kernel /proc/<pid>/comm limit" {
    try testing.expectEqualStrings("shelly-notifica", truncatedComm());
    try testing.expect(truncatedComm().len == 15);
}

test "isAllDigits rejects non-numeric /proc entries" {
    try testing.expect(isAllDigits("1234"));
    try testing.expect(isAllDigits("1"));
    try testing.expect(!isAllDigits(""));
    try testing.expect(!isAllDigits("self"));
    try testing.expect(!isAllDigits("1234abc"));
    try testing.expect(!isAllDigits("cpuinfo"));
}
