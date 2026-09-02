const std = @import("std");

const zeit = @import("zeit");
const zsn = @import("zsn");
const Service = zsn.Service;
const MenuController = zsn.MenuController;
const Notifier = zsn.Notifier;
const MenuState = zsn.MenuState;
const Tree = zsn.Tree;
const Tray = zsn.Tray;
const MenuItem = zsn.MenuItem;
const ItemType = zsn.ItemType;
const Action = zsn.Action;
const Pixmap = zsn.Pixmap;

const CheckUpdatesPackage = @import("models/update.zig").CheckUpdatesPackage;
const CheckUpdatesAur = @import("models/update.zig").CheckUpdatesAur;
const CheckUpdatesFlatpak = @import("models/update.zig").CheckUpdatesFlatpak;
const Repo = @import("models/update.zig").CheckUpdatesPackage;
const Aur = @import("models/update.zig").CheckUpdatesAur;
const Flatpak = @import("models/update.zig").CheckUpdatesFlatpak;
const runtime = @import("runtime.zig");
const AppRunner = @import("services/app_runner.zig").AppRunner;
const ConfigWatcher = @import("services/config-watcher.zig").ConfigWatcher;
const ShellyConfig = @import("services/config.zig").ConfigResolver;
const next_notification = @import("services/next_notification.zig");
const ShellyCli = @import("services/shelly-cli.zig").ShellyCli;

const translations = @import("services/translations.zig");
const trans = translations._;

const log_worker = std.log.scoped(.worker);
const log_tray = std.log.scoped(.tray);
const log_main = std.log.scoped(.main);
const log_loop = std.log.scoped(.loop);
const log_menu = std.log.scoped(.menu);

var quit_index: i32 = 0;
var check_update_index: i32 = 0;
var run_update_index: i32 = 0;
var open_shelly_index: i32 = 0;
var tray_index: i32 = 0;
var menu_generation_seen: u64 = 0;
var menu_generation_start: i32 = 0;

var icon_name: [:0]const u8 = undefined;
var attention_icon_name: [:0]const u8 = undefined;

var icon_buf: [256:0]u8 = undefined;
var updates_buf: [256:0]u8 = undefined;

var launch_requested = std.atomic.Value(bool).init(false);
var quit_requested = std.atomic.Value(bool).init(false);

const NotifText = struct { summary: [:0]u8, body: [:0]u8 };

const IconsToUse = struct {
    icon_name: []const u8,
    attention_icon_name: []const u8,
};

const Updates = struct {
    mutex: std.Io.Mutex = .init,
    io: std.Io,
    runner: *AppRunner,
    config: *ShellyConfig,
    allocator: std.mem.Allocator,
    repo: std.ArrayListUnmanaged(Repo) = .empty,
    aur: std.ArrayListUnmanaged(Aur) = .empty,
    flatpak: std.ArrayListUnmanaged(Flatpak) = .empty,

    needs_refresh: bool = false,
    menu_generation: u64 = 0,
    pending_notif: ?NotifText = null,
    needs_config_change: bool = false,
    last_check: i64 = 0,

    fn init(allocator: std.mem.Allocator, io: std.Io, runner: *AppRunner, config: *ShellyConfig) Updates {
        return .{ .allocator = allocator, .io = io, .runner = runner, .config = config };
    }

    fn deinit(self: *Updates) void {
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

    fn total(self: *Updates) usize {
        return self.repo.items.len + self.aur.items.len + self.flatpak.items.len;
    }

    fn count(self: *Updates) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.total();
    }

    fn signalRefresh(self: *Updates) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.needs_refresh = true;
        self.menu_generation += 1;
    }

    fn signalConfigChange(self: *Updates) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.needs_config_change = true;
    }

    fn queueNotif(self: *Updates, summary: []const u8, body: []const u8) void {
        const s = self.allocator.dupeZ(u8, summary) catch return;
        const b = self.allocator.dupeZ(u8, body) catch {
            self.allocator.free(s);
            return;
        };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.pending_notif) |old| {
            self.allocator.free(old.summary);
            self.allocator.free(old.body);
        }
        self.pending_notif = .{ .summary = s, .body = b };
    }

    fn takeRefresh(self: *Updates) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const r = self.needs_refresh;
        self.needs_refresh = false;
        return r;
    }

    fn takeNotif(self: *Updates) ?NotifText {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const n = self.pending_notif;
        self.pending_notif = null;
        return n;
    }

    fn takeConfigChange(self: *Updates) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const r = self.needs_config_change;
        self.needs_config_change = false;
        return r;
    }

    fn freeNotif(self: *Updates, n: NotifText) void {
        self.allocator.free(n.summary);
        self.allocator.free(n.body);
    }
};

const Worker = struct {
    updates: *Updates,
    cli: ShellyCli,
    io: std.Io,
    gpa: std.mem.Allocator,
    config: *ShellyConfig,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

    fn run(self: *Worker) void {
        var initial_check_done = false;
        while (self.running.load(.seq_cst)) {
            if (self.config.dirty.swap(false, .seq_cst)) {
                self.applyConfigChange();
            }

            const skip_initial_check = blk: {
                self.config.mutex.lockUncancelable(self.io);
                defer self.config.mutex.unlock(self.io);
                const cfg = self.config.get() catch break :blk false;
                break :blk !initial_check_done and next_notification.isCronMode(cfg);
            };
            if (skip_initial_check) {
                log_worker.info("cron mode: skipping initial check", .{});
            } else {
                self.pollOnce() catch |e| {
                    log_worker.err("check failed: {any}", .{e});
                };
            }
            initial_check_done = true;

            const secs: u32 = blk: {
                self.config.mutex.lockUncancelable(self.io);
                defer self.config.mutex.unlock(self.io);
                const cfg = self.config.get() catch |e| {
                    log_worker.warn("config get failed: {any}, using 10h", .{e});
                    break :blk 36000;
                };
                break :blk next_notification.getNextSeconds(self.gpa, self.io, cfg) catch |e| {
                    log_worker.warn("schedule calc failed: {any}, using 10h", .{e});
                    break :blk 36000;
                };
            };

            log_worker.info("next check in: {d}s (or on request)", .{secs});
            log_worker.debug("waiting {d}s until next check (interruptible)", .{secs});

            const expected = runtime.wake_gen.load(.acquire);
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

    fn applyConfigChange(self: *Worker) void {
        log_worker.info("config changed, updating tray icons", .{});
        const icons = blk: {
            self.config.mutex.lockUncancelable(self.io);
            defer self.config.mutex.unlock(self.io);
            break :blk getIconsToUse(self.config);
        };

        if (icons.icon_name.len >= icon_buf.len or icons.attention_icon_name.len >= updates_buf.len) {
            log_worker.warn("configured tray icon name too long, keeping previous icons", .{});
            return;
        }

        @memcpy(icon_buf[0..icons.icon_name.len], icons.icon_name);
        icon_buf[icons.icon_name.len] = 0;
        @memcpy(updates_buf[0..icons.attention_icon_name.len], icons.attention_icon_name);
        updates_buf[icons.attention_icon_name.len] = 0;
        icon_name = icon_buf[0..icons.icon_name.len :0];
        attention_icon_name = updates_buf[0..icons.attention_icon_name.len :0];
        self.updates.signalConfigChange();
    }

    fn pollOnce(self: *Worker) !void {
        const parsed = try self.cli.check_updates();
        defer parsed.deinit();

        const count = blk: {
            self.updates.mutex.lockUncancelable(self.io);
            defer self.updates.mutex.unlock(self.io);

            self.updates.clear();
            const a = self.updates.allocator;

            for (parsed.value.Packages) |pkg| {
                try self.updates.repo.append(a, .{
                    .Name = try a.dupe(u8, pkg.Name),
                    .CurrentVersion = try a.dupe(u8, pkg.CurrentVersion),
                    .NewVersion = try a.dupe(u8, pkg.NewVersion),
                });
            }
            for (parsed.value.Aur) |pkg| {
                try self.updates.aur.append(a, .{
                    .Name = try a.dupe(u8, pkg.Name),
                    .Version = try a.dupe(u8, pkg.Version),
                    .NewVersion = try a.dupe(u8, pkg.NewVersion),
                });
            }
            for (parsed.value.Flatpak) |pkg| {
                try self.updates.flatpak.append(a, .{
                    .Name = try a.dupe(u8, pkg.Name),
                    .Version = try a.dupe(u8, pkg.Version),
                });
            }
            break :blk self.updates.total();
        };

        log_worker.info("{d} updates found", .{count});

        const now_ts = std.Io.Clock.now(.real, self.io);
        const seconds = @divFloor(now_ts.nanoseconds, std.time.ns_per_s);
        self.updates.last_check = @intCast(seconds);

        self.updates.signalRefresh();
        if (count > 0) {
            var buf: [128]u8 = undefined;
            const body = std.fmt.bufPrintZ(&buf, "{d} {s}", .{ count, trans("updates available") }) catch "0 updates";
            self.updates.queueNotif(trans("Updates available"), body);
        }
    }
};

fn getIconsToUse(config: *ShellyConfig) IconsToUse {
    const conf = config.get() catch return .{
        .icon_name = "shelly-tray",
        .attention_icon_name = "shelly-update",
    };

    if (conf.TrayIconPath.len > 0 or conf.TrayUpdatesIconPath.len > 0) {
        return .{
            .icon_name = conf.TrayIconPath,
            .attention_icon_name = conf.TrayUpdatesIconPath,
        };
    }

    if (conf.UseSymbolicTray) {
        return .{
            .icon_name = "shelly-shell-symbolic",
            .attention_icon_name = "shelly-updates-symbolic",
        };
    }

    return .{
        .icon_name = "shelly-tray",
        .attention_icon_name = "shelly-update",
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    runtime.allocator = allocator;
    runtime.io = init.io;
    runtime.environ_map = init.environ_map;

    _ = translations.init();

    while (true) {
        runSession(init) catch |err| {
            log_main.err("session ended: {any}; reconnecting in 5s", .{err});
            init.io.sleep(.fromMilliseconds(5_000), .awake) catch {};
            continue;
        };
        return;
    }
}

fn runSession(init: std.process.Init) !void {
    const allocator = init.gpa;

    var service = try Service.init(allocator, init.io, init.environ_map);
    defer service.deinit();

    const SINGLETON_NAME = "org.shellyorg.Notifications";

    if (try service.nameHasOwner(SINGLETON_NAME)) {
        log_tray.info("another instance running, exiting", .{});
        std.process.exit(0);
    }
    try service.requestName(SINGLETON_NAME);
    log_tray.info("acquired singleton name", .{});

    var runner = AppRunner.init(allocator, init.io, init.environ_map);
    defer runner.deinit();

    var config = try ShellyConfig.init(allocator, runtime.io, runtime.environ_map);
    defer config.deinit();
    try config.load();

    const startIcons = getIconsToUse(&config);

    @memcpy(icon_buf[0..startIcons.icon_name.len], startIcons.icon_name);
    icon_buf[startIcons.icon_name.len] = 0;

    @memcpy(updates_buf[0..startIcons.attention_icon_name.len], startIcons.attention_icon_name);
    updates_buf[startIcons.attention_icon_name.len] = 0;

    icon_name = icon_buf[0..startIcons.icon_name.len :0];
    attention_icon_name = updates_buf[0..startIcons.attention_icon_name.len :0];

    log_main.info("icon_name={s} attention_icon_name={s}", .{ icon_name, attention_icon_name });

    var t = try Tray.init(&service, .{
        .id = "shelly.shellyorg.Notifications",
        .title = "Shelly Notifications",
        .icon_name = icon_name,
        .icon_pixmap = &.{},
        .attention_icon_name = attention_icon_name,
        .on_activate = &onTrayActivate,
        .user_ctx = &runner,
    });
    defer t.deinit();
    _ = try t.register();

    var notifier = Notifier.init(&service);
    defer notifier.deinit();

    var updates = Updates.init(allocator, init.io, &runner, &config);
    defer updates.deinit();

    try service.onExternalSignal("com.shellyorg.shelly", "Refresh", onUiRefresh, &updates);

    var mstate = MenuState.init(allocator, buildMenu);
    defer mstate.deinit();
    mstate.ctx = &updates;
    mstate.on_event = onEvent;

    var menu_ctrl = MenuController.init(&service, &mstate, t.name, "/MenuBar");
    _ = try menu_ctrl.register();

    var watcher = try ConfigWatcher.init(allocator, &config, "settings.json");
    defer watcher.deinit();
    try watcher.start();
    defer watcher.stop();
    _ = watcher.changedSinceLast();

    var worker = Worker{
        .updates = &updates,
        .cli = ShellyCli{ .allocator = allocator, .io = init.io, .environ_map = init.environ_map },
        .io = init.io,
        .gpa = allocator,
        .config = &config,
    };
    const worker_thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    defer {
        worker.running.store(false, .seq_cst);
        runtime.wakeWorker();
        worker_thread.join();
    }

    while (true) {
        _ = service.tickTimeout(.{
            .duration = .{
                .raw = .fromMilliseconds(250),
                .clock = .awake,
            },
        }) catch |e| {
            log_loop.err("tick error: {any}; D-Bus connection lost, reconnecting", .{e});
            return e;
        };

        if (updates.takeRefresh()) {
            menu_ctrl.invalidate() catch |e| log_loop.err("invalidate: {any}", .{e});
            const target_icon = if (updates.count() > 0) attention_icon_name else icon_name;
            t.emitNewIcon(target_icon) catch |e| log_loop.err("emitNewIcon: {any}", .{e});
        }

        if (updates.takeNotif()) |n| {
            defer updates.freeNotif(n);

            log_loop.info("notify: {s} {s}", .{ n.summary, n.body });
            _ = notifier.notify(.{
                .app_name = "Shelly",
                .icon = "shelly",
                .summary = n.summary,
                .body = n.body,
                .on_activate = &openShelly,
                .ctx = &runner,
            }) catch |e| log_loop.err("notify: {any}", .{e});
        }

        if (updates.takeConfigChange()) {
            const target_icon = if (updates.count() > 0) attention_icon_name else icon_name;
            t.emitNewIcon(target_icon) catch |e| log_loop.err("emitNewIcon: {any}", .{e});
        }

        if (launch_requested.swap(false, .seq_cst)) {
            runner.activateOrLaunch(&service) catch |e|
                log_loop.err("activate/launch failed: {any}", .{e});
        }

        if (quit_requested.swap(false, .seq_cst)) {
            runner.quitUi(&service) catch |e| log_loop.err("quit ui: {any}", .{e});
            std.process.exit(0);
        }
    }
}

fn openShelly(ctx: ?*anyopaque, id: u32) void {
    _ = id;
    _ = ctx;
    launch_requested.store(true, .seq_cst);
}

fn buildMenu(ctx: ?*anyopaque, arena: std.mem.Allocator) !Tree {
    const updates: *Updates = @ptrCast(@alignCast(ctx.?));

    updates.mutex.lockUncancelable(updates.io);
    defer updates.mutex.unlock(updates.io);

    // The menu provider can ask for the root and then a submenu in separate
    // GetLayout calls. Reuse the same ID range until the menu data changes;
    // otherwise the submenu's parent ID no longer exists in the rebuilt tree.
    if (menu_generation_seen != updates.menu_generation) {
        menu_generation_seen = updates.menu_generation;
        menu_generation_start = tray_index;
    } else {
        tray_index = menu_generation_start;
    }

    var items = std.ArrayList(MenuItem).empty;

    try addItem(arena, &items, &tray_index, trans("Open Shelly"), true, true, .normal);
    open_shelly_index = tray_index;
    try addItem(arena, &items, &tray_index, trans("Update Packages"), true, true, .normal);
    run_update_index = tray_index;
    try addItem(arena, &items, &tray_index, trans("Check for updates"), true, true, .normal);
    check_update_index = tray_index;
    try addItem(arena, &items, &tray_index, "", false, true, .separator);
    const label = if (updates.last_check == 0)
        try arena.dupe(u8, trans("Last Check: Never"))
    else
        try formatCheckTime(arena, updates.last_check);
    try addItem(arena, &items, &tray_index, label, false, true, .normal);
    try addItem(arena, &items, &tray_index, "", false, true, .separator);

    const count = updates.total();
    if (count == 0) {
        try addItem(arena, &items, &tray_index, trans("No updates"), false, true, .normal);
    } else {
        if (updates.repo.items.len > 0) {
            try addItemWithSubmenu(
                @TypeOf(updates.repo.items[0]),
                arena,
                &items,
                &tray_index,
                updates.repo.items,
                repoLabel,
                "Standard",
                .normal,
            );
        }

        if (updates.aur.items.len > 0) {
            try addItemWithSubmenu(
                @TypeOf(updates.aur.items[0]),
                arena,
                &items,
                &tray_index,
                updates.aur.items,
                aurLabel,
                "AUR",
                .normal,
            );
        }

        if (updates.flatpak.items.len > 0) {
            try addItemWithSubmenu(
                @TypeOf(updates.flatpak.items[0]),
                arena,
                &items,
                &tray_index,
                updates.flatpak.items,
                flatpakLabel,
                "Flatpak",
                .normal,
            );
        }
    }

    try addItem(arena, &items, &tray_index, "", true, true, .separator);
    try addItem(arena, &items, &tray_index, trans("Exit"), true, true, .normal);
    quit_index = tray_index;

    return .{ .root = .{ .id = 0, .children = try items.toOwnedSlice(arena) } };
}

fn nextId(id: *i32) i32 {
    id.* = if (id.* == std.math.maxInt(i32)) 1 else id.* + 1;
    return id.*;
}

fn addItem(arena: std.mem.Allocator, items: *std.ArrayList(MenuItem), id: *i32, label: []const u8, enabled: bool, visible: bool, itype: ItemType) !void {
    const item: MenuItem = .{ .id = nextId(id), .label = label, .enabled = enabled, .visible = visible, .type = itype };
    try items.append(arena, item);
}

fn repoLabel(arena: std.mem.Allocator, pkg: CheckUpdatesPackage) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}  {s} -> {s}", .{
        pkg.Name, pkg.CurrentVersion, pkg.NewVersion,
    });
}

fn aurLabel(arena: std.mem.Allocator, pkg: CheckUpdatesAur) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}  {s} -> {s}", .{
        pkg.Name, pkg.Version, pkg.NewVersion,
    });
}

fn flatpakLabel(arena: std.mem.Allocator, pkg: CheckUpdatesFlatpak) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}  {s}", .{
        pkg.Name, pkg.Version,
    });
}

fn addItemWithSubmenu(
    comptime T: type,
    arena: std.mem.Allocator,
    items: *std.ArrayList(MenuItem),
    id: *i32,
    source: []const T,
    labelFn: fn (std.mem.Allocator, T) anyerror![]const u8,
    label: []const u8,
    itype: ItemType,
) !void {
    var children = std.ArrayList(MenuItem).empty;
    defer children.deinit(arena);

    const parent_id = nextId(id);

    for (source) |pkg| {
        const child_label = try labelFn(arena, pkg);
        try children.append(arena, .{ .id = nextId(id), .label = child_label });
    }

    try items.append(arena, .{
        .id = parent_id,
        .type = itype,
        .children = try children.toOwnedSlice(arena),
        .label = label,
    });
}

fn onEvent(ctx: ?*anyopaque, id: i32) void {
    const updates: *Updates = @ptrCast(@alignCast(ctx.?));
    log_menu.debug("id: {}", .{id});

    if (id == quit_index) {
        quit_requested.store(true, .seq_cst);
    }

    if (id == run_update_index) {
        updates.runner.spawnFixedUpdate(updates.config.get() catch |e| {
            log_menu.err("update spawn failed: {any}", .{e});
            return;
        }) catch |e|
            log_menu.err("update spawn failed: {any}", .{e});
    }

    log_menu.debug("check_update_index: {}", .{check_update_index});
    if (id == check_update_index) {
        runtime.wakeWorker();
    }

    if (id == open_shelly_index) {
        launch_requested.store(true, .seq_cst);
    }
}

fn formatCheckTime(arena: std.mem.Allocator, ts: i64) ![]const u8 {
    if (ts == 0) return arena.dupe(u8, trans("Last Check: never"));

    var local = zeit.local(arena, runtime.io, .{}) catch {
        return arena.dupe(u8, "Last Check: unknown");
    };
    defer local.deinit();

    const inst = zeit.instant(.{ .unix_timestamp = ts }, &local);
    const dt = inst.time();

    return std.fmt.allocPrint(arena, "{s} {d:0>2}:{d:0>2} {d:0>2}/{d:0>2}", .{
        trans("Last Check:"),
        dt.hour,
        dt.minute,
        dt.day,
        dt.month,
    });
}

fn onUiRefresh(ctx: ?*anyopaque, msg: zsn.Message) void {
    _ = msg;
    _ = ctx;
    runtime.wakeWorker();
}

fn onTrayActivate(ctx: ?*anyopaque, x: i32, y: i32) void {
    _ = ctx;
    _ = x;
    _ = y;
    launch_requested.store(true, .seq_cst);
}
test {
    std.testing.refAllDecls(@This());
    _ = @import("services/next_notification.zig");
}
