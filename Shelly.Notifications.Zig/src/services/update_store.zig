const std = @import("std");

const update_model = @import("../models/update.zig");
const AppRunner = @import("app_runner.zig").AppRunner;
const ConfigResolver = @import("config.zig").ConfigResolver;

const Repo = update_model.CheckUpdatesPackage;
const Aur = update_model.CheckUpdatesAur;
const Flatpak = update_model.CheckUpdatesFlatpak;

pub const NotifText = struct { summary: [:0]u8, body: [:0]u8 };

pub const Updates = struct {
    mutex: std.Io.Mutex = .init,
    io: std.Io,
    allocator: std.mem.Allocator,

    runner: *AppRunner,
    config: *ConfigResolver,

    repo: std.ArrayListUnmanaged(Repo) = .empty,
    aur: std.ArrayListUnmanaged(Aur) = .empty,
    flatpak: std.ArrayListUnmanaged(Flatpak) = .empty,

    needs_refresh: bool = false,
    menu_generation: u64 = 0,
    pending_notif: ?NotifText = null,
    needs_config_change: bool = false,
    last_check: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, runner: *AppRunner, config: *ConfigResolver) Updates {
        return .{ .allocator = allocator, .io = io, .runner = runner, .config = config };
    }

    pub fn deinit(self: *Updates) void {
        self.mutex.lockUncancelable(self.io);
        self.clear();
        if (self.pending_notif) |n| {
            self.allocator.free(n.summary);
            self.allocator.free(n.body);
            self.pending_notif = null;
        }
        self.mutex.unlock(self.io);
        self.repo.deinit(self.allocator);
        self.aur.deinit(self.allocator);
        self.flatpak.deinit(self.allocator);
    }

    pub fn replaceAll(self: *Updates, found: update_model.CheckUpdates) !usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.clear();

        for (found.Packages) |pkg| {
            try self.repo.append(self.allocator, .{
                .Name = try self.allocator.dupe(u8, pkg.Name),
                .CurrentVersion = try self.allocator.dupe(u8, pkg.CurrentVersion),
                .NewVersion = try self.allocator.dupe(u8, pkg.NewVersion),
            });
        }
        for (found.Aur) |pkg| {
            try self.aur.append(self.allocator, .{
                .Name = try self.allocator.dupe(u8, pkg.Name),
                .Version = try self.allocator.dupe(u8, pkg.Version),
                .NewVersion = try self.allocator.dupe(u8, pkg.NewVersion),
            });
        }
        for (found.Flatpak) |pkg| {
            try self.flatpak.append(self.allocator, .{
                .Name = try self.allocator.dupe(u8, pkg.Name),
                .Version = try self.allocator.dupe(u8, pkg.Version),
            });
        }

        const now = std.Io.Clock.now(.real, self.io);
        self.last_check = @intCast(@divFloor(now.nanoseconds, std.time.ns_per_s));

        return self.totalLocked();
    }

    pub fn totalLocked(self: *Updates) usize {
        return self.repo.items.len + self.aur.items.len + self.flatpak.items.len;
    }

    pub fn count(self: *Updates) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.totalLocked();
    }

    pub fn signalRefresh(self: *Updates) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.needs_refresh = true;
        self.menu_generation += 1;
    }

    pub fn signalConfigChange(self: *Updates) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.needs_config_change = true;
    }

    pub fn queueNotif(self: *Updates, summary: []const u8, body: []const u8) void {
        const s = self.allocator.dupeZ(u8, summary) catch return;
        const b = self.allocator.dupeZ(u8, body) catch {
            self.allocator.free(s);
            return;
        };

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.pending_notif) |old| self.freeNotif(old);
        self.pending_notif = .{ .summary = s, .body = b };
    }

    pub fn takeNotif(self: *Updates) ?NotifText {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const n = self.pending_notif;
        self.pending_notif = null;
        return n;
    }

    pub fn takeRefresh(self: *Updates) bool {
        return self.takeFlag("needs_refresh");
    }

    pub fn takeConfigChange(self: *Updates) bool {
        return self.takeFlag("needs_config_change");
    }

    pub fn freeNotif(self: *Updates, n: NotifText) void {
        self.allocator.free(n.summary);
        self.allocator.free(n.body);
    }

    fn takeFlag(self: *Updates, comptime field: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const was_set: bool = @field(self, field);
        @field(self, field) = false;
        return was_set;
    }

    fn clear(self: *Updates) void {
        for (self.repo.items) |*e| {
            self.allocator.free(e.Name);
            self.allocator.free(e.CurrentVersion);
            self.allocator.free(e.NewVersion);
        }
        for (self.aur.items) |*e| {
            self.allocator.free(e.Name);
            self.allocator.free(e.Version);
            self.allocator.free(e.NewVersion);
        }
        for (self.flatpak.items) |*e| {
            self.allocator.free(e.Name);
            self.allocator.free(e.Version);
        }
        self.repo.clearAndFree(self.allocator);
        self.aur.clearAndFree(self.allocator);
        self.flatpak.clearAndFree(self.allocator);
    }
};
