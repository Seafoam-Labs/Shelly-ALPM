const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const log = std.log.scoped(.db_watcher);

/// Callback invoked after the installed-package database has been quiet for
/// `LocalDbWatcher.quiet_ms`. The callback runs on the watcher thread, so it
/// must only do something cheap, like waking the update-check worker.
pub const ChangeHandler = *const fn (ctx: ?*anyopaque) void;

/// A transaction touches `{DBPath}/local` many times in quick succession, so
/// a change only wakes the worker once the writes have settled. The window
/// stays short because the tray icon is what the user is waiting on.
const default_quiet_ms: i64 = 1_500;
const poll_interval_ms: i64 = 150;
const max_config_size: std.Io.Limit = .limited(4 << 20);

/// A distribution configuration and the database root it uses when it does
/// not set `DBPath` itself.
pub const ConfigCandidate = struct {
    config_path: []const u8,
    default_db_path: []const u8,
};

const distribution_candidates = [_]ConfigCandidate{
    .{ .config_path = "/etc/shelly.conf", .default_db_path = "/var/lib/shelly" },
    .{ .config_path = "/etc/pacman.conf", .default_db_path = "/var/lib/pacman" },
};

/// Resolves the installed-package database directory (`{DBPath}/local`) from
/// the distribution configuration. Returns null when no known configuration
/// exists, which means the watcher has nothing reliable to watch.
pub fn installedDatabaseDir(allocator: std.mem.Allocator, io: std.Io) !?[]const u8 {
    return installedDatabaseDirFrom(allocator, io, &distribution_candidates);
}

/// Candidate-driven variant of `installedDatabaseDir` so tests can point it
/// at temporary configurations instead of /etc.
pub fn installedDatabaseDirFrom(
    allocator: std.mem.Allocator,
    io: std.Io,
    candidates: []const ConfigCandidate,
) !?[]const u8 {
    for (candidates) |candidate| {
        const db_root = try databaseRoot(allocator, io, candidate.config_path, candidate.default_db_path);
        const root = db_root orelse continue;
        defer allocator.free(root);
        return try std.fs.path.join(allocator, &.{ root, "local" });
    }
    return null;
}

/// Reads the `DBPath` (honoring `RootDir` for relative values) out of a
/// pacman-style configuration file. Returns null when the file does not
/// exist, or the profile default when it exists without a `DBPath`.
fn databaseRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
    default_db_path: []const u8,
) !?[]const u8 {
    const text = std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, max_config_size) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    defer allocator.free(text);

    var root_dir: []const u8 = "";
    var db_path: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        // Global options end where the first repository section begins.
        if (line[0] == '[') break;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
        if (std.mem.eql(u8, key, "RootDir")) root_dir = value;
        if (std.mem.eql(u8, key, "DBPath")) db_path = value;
    }

    if (db_path.len == 0) return try allocator.dupe(u8, default_db_path);
    if (std.fs.path.isAbsolute(db_path))
        return try allocator.dupe(u8, std.mem.trimEnd(u8, db_path, "/"));

    const root = if (root_dir.len > 0) root_dir else "/";
    const joined = try std.fs.path.resolve(allocator, &.{ root, db_path });
    defer allocator.free(joined);
    return try allocator.dupe(u8, std.mem.trimEnd(u8, joined, "/"));
}

pub const LocalDbWatcher = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_z: [:0]const u8,
    quiet_ms: i64 = default_quiet_ms,
    handler: ChangeHandler,
    ctx: ?*anyopaque,
    inotify_fd: i32 = -1,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        db_dir: []const u8,
        handler: ChangeHandler,
        ctx: ?*anyopaque,
    ) !LocalDbWatcher {
        const dir_z = try allocator.dupeSentinel(u8, db_dir, 0);
        return .{
            .allocator = allocator,
            .io = io,
            .dir_z = dir_z,
            .handler = handler,
            .ctx = ctx,
        };
    }

    pub fn deinit(self: *LocalDbWatcher) void {
        self.allocator.free(self.dir_z);
    }

    pub fn start(self: *LocalDbWatcher) !void {
        const fd_r = linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK);
        if (std.posix.errno(fd_r) != .SUCCESS) return error.InotifyInit;
        self.inotify_fd = @intCast(fd_r);
        errdefer {
            _ = linux.close(self.inotify_fd);
            self.inotify_fd = -1;
        }

        const wd_r = linux.inotify_add_watch(
            self.inotify_fd,
            self.dir_z.ptr,
            linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVED_FROM | linux.IN.MOVED_TO,
        );
        if (std.posix.errno(wd_r) != .SUCCESS) return error.InotifyAddWatch;

        self.running.store(true, .seq_cst);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn stop(self: *LocalDbWatcher) void {
        self.running.store(false, .seq_cst);
        if (self.inotify_fd >= 0) {
            _ = linux.close(self.inotify_fd);
            self.inotify_fd = -1;
        }
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn run(self: *LocalDbWatcher) void {
        var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
        var pending = false;
        var last_event_ms: i64 = 0;
        while (self.running.load(.seq_cst)) {
            // Any read means the transaction produced events; the exact event
            // names do not matter, only the moment of the last one.
            const n = std.posix.read(self.inotify_fd, &buf) catch |err| switch (err) {
                error.WouldBlock => {
                    self.maybeFire(&pending, &last_event_ms);
                    self.io.sleep(.fromMilliseconds(poll_interval_ms), .awake) catch {};
                    continue;
                },
                else => return,
            };
            if (n == 0) continue;
            pending = true;
            last_event_ms = @intCast(@divFloor(std.Io.Clock.now(.awake, self.io).nanoseconds, std.time.ns_per_ms));
        }
    }

    fn maybeFire(self: *LocalDbWatcher, pending: *bool, last_event_ms: *i64) void {
        if (!pending.*) return;
        const now_ms: i64 = @intCast(@divFloor(std.Io.Clock.now(.awake, self.io).nanoseconds, std.time.ns_per_ms));
        if (now_ms - last_event_ms.* < self.quiet_ms) return;
        pending.* = false;
        log.info("installed-package database changed, waking the update check", .{});
        self.handler(self.ctx);
    }
};

const testing = std.testing;

fn writeConfig(tmp: *std.testing.TmpDir, name: []const u8, contents: []const u8) !void {
    const file = try tmp.dir.createFile(testing.io, name, .{ .truncate = true });
    defer file.close(testing.io);

    var buf: [256]u8 = undefined;
    var fw = file.writer(testing.io, &buf);
    try fw.interface.writeAll(contents);
    try fw.flush();
}

/// Absolute path of the temporary directory; candidates must resolve from
/// `std.Io.Dir.cwd()`, like the real /etc paths do.
fn tmpDirPath(tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    const len = try tmp.dir.realPath(testing.io, buf);
    return buf[0..len];
}

test "installedDatabaseDirFrom reads DBPath and stops at the first section" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeConfig(&tmp, "dist.conf",
        \\# distribution configuration
        \\RootDir = /alt
        \\DBPath = /var/lib/custom/
        \\
        // Options after a repository header no longer apply.
        \\[core]
        \\DBPath = /ignored
    );

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try tmpDirPath(&tmp, &path_buf);
    const candidates = [_]ConfigCandidate{
        .{
            .config_path = try std.fs.path.join(testing.allocator, &.{ base, "dist.conf" }),
            .default_db_path = "/unused",
        },
    };
    defer testing.allocator.free(candidates[0].config_path);

    const dir = (try installedDatabaseDirFrom(testing.allocator, testing.io, &candidates)).?;
    defer testing.allocator.free(dir);
    try testing.expectEqualStrings("/var/lib/custom/local", dir);
}

test "installedDatabaseDirFrom resolves a relative DBPath against RootDir" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeConfig(&tmp, "dist.conf",
        \\RootDir = /alt
        \\DBPath = db/
    );

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try tmpDirPath(&tmp, &path_buf);
    const candidates = [_]ConfigCandidate{
        .{
            .config_path = try std.fs.path.join(testing.allocator, &.{ base, "dist.conf" }),
            .default_db_path = "/unused",
        },
    };
    defer testing.allocator.free(candidates[0].config_path);

    const dir = (try installedDatabaseDirFrom(testing.allocator, testing.io, &candidates)).?;
    defer testing.allocator.free(dir);
    try testing.expectEqualStrings("/alt/db/local", dir);
}

test "installedDatabaseDirFrom falls back to defaults and skips absent candidates" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeConfig(&tmp, "empty.conf", "SyncFirst = foo\n");

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try tmpDirPath(&tmp, &path_buf);
    var candidates = std.ArrayList(ConfigCandidate).empty;
    defer candidates.deinit(testing.allocator);
    try candidates.append(testing.allocator, .{
        .config_path = std.fs.path.join(testing.allocator, &.{ base, "missing.conf" }) catch unreachable,
        .default_db_path = "/nonexistent/shelly",
    });
    defer testing.allocator.free(candidates.items[0].config_path);
    try candidates.append(testing.allocator, .{
        .config_path = std.fs.path.join(testing.allocator, &.{ base, "empty.conf" }) catch unreachable,
        .default_db_path = "/var/lib/pacman",
    });
    defer testing.allocator.free(candidates.items[1].config_path);

    const dir = (try installedDatabaseDirFrom(testing.allocator, testing.io, candidates.items)).?;
    defer testing.allocator.free(dir);
    try testing.expectEqualStrings("/var/lib/pacman/local", dir);

    const none = try installedDatabaseDirFrom(testing.allocator, testing.io, candidates.items[0..1]);
    try testing.expect(none == null);
}

fn countChange(ctx: ?*anyopaque) void {
    const counter: *std.atomic.Value(u32) = @ptrCast(@alignCast(ctx.?));
    _ = counter.fetchAdd(1, .seq_cst);
}

test "LocalDbWatcher wakes the handler once after database writes settle" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try tmpDirPath(&tmp, &path_buf);

    var counter = std.atomic.Value(u32).init(0);
    var watcher = try LocalDbWatcher.init(testing.allocator, testing.io, base, &countChange, &counter);
    defer watcher.deinit();
    watcher.quiet_ms = 100;
    try watcher.start();
    defer watcher.stop();

    try tmp.dir.createDirPath(testing.io, "shelly-1.0.0-1");
    var waited_ms: i64 = 0;
    while (counter.load(.seq_cst) == 0 and waited_ms < 5_000) {
        testing.io.sleep(.fromMilliseconds(50), .awake) catch {};
        waited_ms += 50;
    }
    try testing.expectEqual(@as(u32, 1), counter.load(.seq_cst));

    // A quiet database must stay quiet: one burst of events is one wake-up.
    testing.io.sleep(.fromMilliseconds(watcher.quiet_ms * 5), .awake) catch {};
    try testing.expectEqual(@as(u32, 1), counter.load(.seq_cst));
}

test {
    std.testing.refAllDecls(@This());
}

