const std = @import("std");
const linux = std.os.linux;
const ConfigResolver = @import("config.zig").ConfigResolver;
const runtime = @import("../runtime.zig");

const log = std.log.scoped(.watcher);

pub const ConfigWatcher = struct {
    resolver: *ConfigResolver,
    allocator: std.mem.Allocator,
    dir_z: [:0]const u8,
    filename: []const u8,
    last_hash: u64 = 0,
    inotify_fd: i32 = -1,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(
        allocator: std.mem.Allocator,
        resolver: *ConfigResolver,
        filename: []const u8,
    ) !ConfigWatcher {
        const dir = resolver.settings_dir_abs orelse return error.NoSettingsDir;
        const dir_z = try allocator.dupeZ(u8, dir);
        return .{
            .resolver = resolver,
            .allocator = allocator,
            .dir_z = dir_z,
            .filename = filename,
        };
    }

    pub fn deinit(self: *ConfigWatcher) void {
        self.allocator.free(self.dir_z);
    }

    pub fn start(self: *ConfigWatcher) !void {
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
            linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO,
        );
        if (std.posix.errno(wd_r) != .SUCCESS) return error.InotifyAddWatch;

        self.running.store(true, .seq_cst);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn stop(self: *ConfigWatcher) void {
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

    fn run(self: *ConfigWatcher) void {
        var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
        while (self.running.load(.seq_cst)) {
            const n = std.posix.read(self.inotify_fd, &buf) catch |err| switch (err) {
                error.WouldBlock => {
                    self.resolver.io.sleep(.fromMilliseconds(150), .awake) catch {};
                    continue;
                },
                else => return,
            };
            if (n == 0) continue;

            var relevant = false;
            var off: usize = 0;
            while (off + @sizeOf(linux.inotify_event) <= n) {
                const ev: *align(1) const linux.inotify_event = @ptrCast(&buf[off]);
                if (ev.len > 0) {
                    const name_start = off + @sizeOf(linux.inotify_event);
                    const name_ptr: [*:0]const u8 = @ptrCast(&buf[name_start]);
                    const name = std.mem.span(name_ptr);
                    if (std.mem.eql(u8, name, self.filename)) relevant = true;
                }
                off += @sizeOf(linux.inotify_event) + ev.len;
            }

            if (!relevant) continue;

            self.resolver.io.sleep(.fromMilliseconds(150), .awake) catch {};

            if (self.changedSinceLast()) {
                self.resolver.reload() catch |e| {
                    log.warn("reload failed: {any}", .{e});
                    continue;
                };
                log.info("config reloaded from disk", .{});
                runtime.wakeWorker();
            }
        }
    }

    pub fn changedSinceLast(self: *ConfigWatcher) bool {
        const h = self.resolver.fileHash() orelse return true;
        if (h == self.last_hash) return false;
        self.last_hash = h;
        return true;
    }
};
