const std = @import("std");
const diagnostics = @import("diagnostics");

const ShellyCli = @import("shelly-cli.zig").ShellyCli;
const ConfigResolver = @import("config.zig").ConfigResolver;
const Updates = @import("update_store.zig").Updates;
const next_notification = @import("next_notification.zig");
const tray_icons = @import("tray_icons.zig");
const runtime = @import("../runtime.zig");
const translations = @import("translations.zig");
const trans = translations._;

const log_worker = std.log.scoped(.worker);

/// Used when the interval cannot be read or computed.
const fallback_interval_secs: u32 = 36_000; // 10 hours

pub const Worker = struct {
    updates: *Updates,
    cli: ShellyCli,
    io: std.Io,
    gpa: std.mem.Allocator,
    config: *ConfigResolver,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

    pub fn run(self: *Worker) void {
        var initial_check_done = false;

        while (self.running.load(.seq_cst)) {
            const expected = runtime.wake_gen.load(.acquire);

            if (self.config.dirty.swap(false, .seq_cst)) self.applyConfigChange();

            if (self.skipInitialCheck(initial_check_done)) {
                log_worker.info("cron mode: skipping initial check", .{});
            } else {
                self.pollOnce() catch |e| {
                    log_worker.err("Could not check for package updates. {0s}\n\nTechnical details: {1s}", .{ diagnostics.cause(e), @errorName(e) });
                };
            }
            initial_check_done = true;

            const secs = self.nextWaitSeconds();
            log_worker.info("next check in: {d}s (or on request)", .{secs});
            log_worker.debug("waiting {d}s until next check (interruptible)", .{secs});

            if (!self.running.load(.seq_cst)) return;
            if (self.config.dirty.load(.seq_cst)) continue;

            self.io.futexWaitTimeout(
                u32,
                &runtime.wake_gen.raw,
                expected,
                .{ .duration = .{ .raw = .fromSeconds(secs), .clock = .awake } },
            ) catch {};
        }
    }

    fn skipInitialCheck(self: *Worker, initial_check_done: bool) bool {
        if (initial_check_done) return false;

        self.config.mutex.lockUncancelable(self.io);
        defer self.config.mutex.unlock(self.io);
        const cfg = self.config.get() catch return false;
        return next_notification.isCronMode(cfg);
    }

    fn nextWaitSeconds(self: *Worker) u32 {
        self.config.mutex.lockUncancelable(self.io);
        defer self.config.mutex.unlock(self.io);

        const cfg = self.config.get() catch |e| {
            log_worker.warn("Could not read the update-check interval. {0s} Using a 10-hour interval.\n\nTechnical details: {1s}", .{ diagnostics.cause(e), @errorName(e) });
            return fallback_interval_secs;
        };

        return next_notification.getNextSeconds(self.gpa, self.io, cfg) catch |e| {
            log_worker.warn("Could not calculate the next update-check time. {0s} Using a 10-hour interval.\n\nTechnical details: {1s}", .{ diagnostics.cause(e), @errorName(e) });
            return fallback_interval_secs;
        };
    }

    fn applyConfigChange(self: *Worker) void {
        log_worker.info("config changed, updating tray icons", .{});

        self.config.mutex.lockUncancelable(self.io);
        const loaded = tray_icons.loadFromConfig(self.config);
        self.config.mutex.unlock(self.io);

        if (!loaded) {
            log_worker.warn("The configured tray icon name exceeds the configured size limit. Keeping the previous icons; choose a shorter name.", .{});
            return;
        }

        self.updates.signalConfigChange();
    }

    fn pollOnce(self: *Worker) !void {
        const parsed = try self.cli.check_updates();
        defer parsed.deinit();

        const count = try self.updates.replaceAll(parsed.value);
        log_worker.info("{d} updates found", .{count});

        self.updates.signalRefresh();

        if (count == 0) return;

        var buf: [128]u8 = undefined;
        const body = std.fmt.bufPrintZ(&buf, "{d} {s}", .{ count, trans("updates available") }) catch "0 updates";
        self.updates.queueNotif(trans("Updates available"), body);
    }
};
