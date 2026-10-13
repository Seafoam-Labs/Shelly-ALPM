const std = @import("std");
const diagnostics = @import("diagnostics");

const zsn = @import("zsn");
const Service = zsn.Service;
const MenuController = zsn.MenuController;
const MenuState = zsn.MenuState;
const Notifier = zsn.Notifier;
const Tray = zsn.Tray;

const runtime = @import("runtime.zig");
const translations = @import("services/translations.zig");

const AppRunner = @import("services/app_runner.zig").AppRunner;
const ConfigWatcher = @import("services/config-watcher.zig").ConfigWatcher;
const ConfigResolver = @import("services/config.zig").ConfigResolver;
const ShellyCli = @import("services/shelly-cli.zig").ShellyCli;
const update_store = @import("services/update_store.zig");
const Updates = update_store.Updates;
const NotifText = update_store.NotifText;
const Worker = @import("services/update_worker.zig").Worker;
const tray_icons = @import("services/tray_icons.zig");
const tray_menu = @import("services/tray_menu.zig");

const log_main = std.log.scoped(.main);
const log_tray = std.log.scoped(.tray);
const log_loop = std.log.scoped(.loop);
const log_menu = std.log.scoped(.menu);

const SINGLETON_NAME = "org.shellyorg.Notifications";

var launch_requested = std.atomic.Value(bool).init(false);
var quit_requested = std.atomic.Value(bool).init(false);

const Session = struct {
    service: *Service,
    tray: *Tray,
    notifier: *Notifier,
    runner: *AppRunner,
    updates: *Updates,
    menu: *MenuController,
};

pub fn main(init: std.process.Init) !void {
    runtime.allocator = init.gpa;
    runtime.io = init.io;
    runtime.environ_map = init.environ_map;

    _ = translations.init();

    // A lost D-Bus connection ends the session but not the process: wait, then
    // build a whole new session rather than trying to resume the old one.
    while (true) {
        runSession(init) catch |err| {
            failMain("The tray session ended unexpectedly. Reconnecting in 5 seconds.", err);
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
    try acquireSingleton(&service);

    var runner = AppRunner.init(allocator, init.io, init.environ_map);
    defer runner.deinit();

    var config = try ConfigResolver.init(allocator, runtime.io, runtime.environ_map);
    defer config.deinit();
    try config.load();

    if (!tray_icons.loadFromConfig(&config)) {
        log_main.warn("The configured tray icon name exceeds the configured size limit. Keeping the previous icons; choose a shorter name.", .{});
    }
    log_main.info("icon_name={s} attention_icon_name={s}", .{ tray_icons.normal(), tray_icons.attention() });

    var tray = try Tray.init(&service, .{
        .id = "shelly.shellyorg.Notifications",
        .title = "Shelly Notifications",
        .icon_name = tray_icons.normal(),
        .icon_pixmap = &.{},
        .attention_icon_name = tray_icons.attention(),
        .on_activate = &onTrayActivate,
        .user_ctx = &runner,
    });
    defer tray.deinit();
    _ = try tray.register();

    var notifier = Notifier.init(&service);
    defer notifier.deinit();

    var updates = Updates.init(allocator, init.io, &runner, &config);
    defer updates.deinit();

    try service.onExternalSignal("com.shellyorg.shelly", "Refresh", onUiRefresh, &updates);

    var menu_state = MenuState.init(allocator, tray_menu.build);
    defer menu_state.deinit();
    menu_state.ctx = &updates;
    menu_state.on_event = onEvent;

    var menu_ctrl = MenuController.init(&service, &menu_state, tray.name, "/MenuBar");
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

    var session: Session = .{
        .service = &service,
        .tray = &tray,
        .notifier = &notifier,
        .runner = &runner,
        .updates = &updates,
        .menu = &menu_ctrl,
    };
    try pumpLoop(&session);
}

fn acquireSingleton(service: *Service) !void {
    if (try service.nameHasOwner(SINGLETON_NAME)) {
        log_tray.info("another instance running, exiting", .{});
        std.process.exit(0);
    }
    try service.requestName(SINGLETON_NAME);
    log_tray.info("acquired singleton name", .{});
}

fn pumpLoop(s: *Session) !void {
    while (true) {
        _ = s.service.tickTimeout(.{
            .duration = .{ .raw = .fromMilliseconds(250), .clock = .awake },
        }) catch |e| {
            failLoop("The tray lost its D-Bus connection. Reconnecting.", e);
            return e;
        };

        if (s.updates.takeRefresh()) {
            s.menu.invalidate() catch |e| failLoop("Could not refresh the tray menu.", e);
            refreshTrayIcon(s);
        }

        if (s.updates.takeNotif()) |n| {
            defer s.updates.freeNotif(n);
            log_loop.info("notify: {s} {s}", .{ n.summary, n.body });
            showUpdateNotification(s, n);
        }

        if (s.updates.takeConfigChange()) refreshTrayIcon(s);

        if (launch_requested.swap(false, .seq_cst)) {
            s.runner.activateOrLaunch(s.service) catch |e| failLoop("Could not open Shelly from the tray.", e);
        }

        if (quit_requested.swap(false, .seq_cst)) {
            s.runner.quitUi(s.service) catch |e| failLoop("Could not close the Shelly window from the tray.", e);
            std.process.exit(0);
        }
    }
}

fn refreshTrayIcon(s: *Session) void {
    s.tray.emitNewIcon(tray_icons.forCount(s.updates.count())) catch |e|
        failLoop("Could not update the tray icon over D-Bus.", e);
}

fn showUpdateNotification(s: *Session, n: NotifText) void {
    _ = s.notifier.notify(.{
        .app_name = "Shelly",
        .icon = "shelly",
        .summary = n.summary,
        .body = n.body,
        .on_activate = &openShelly,
        .ctx = s.runner,
    }) catch |e| failLoop("Could not display the update notification.", e);
}

fn onEvent(ctx: ?*anyopaque, id: i32) void {
    const updates: *Updates = @ptrCast(@alignCast(ctx.?));
    log_menu.debug("id: {}", .{id});

    if (id == tray_menu.ids.quit) {
        quit_requested.store(true, .seq_cst);
    }

    if (id == tray_menu.ids.run_updates) {
        updates.runner.spawnFixedUpdate(updates.config.get() catch |e| {
            failMenu("Could not start the update command from the tray.", e);
            return;
        }) catch |e| failMenu("Could not start the update command from the tray.", e);
    }

    log_menu.debug("check_update_index: {}", .{tray_menu.ids.check_updates});
    if (id == tray_menu.ids.check_updates) {
        runtime.wakeWorker();
    }

    if (id == tray_menu.ids.open_shelly) {
        launch_requested.store(true, .seq_cst);
    }
}

fn openShelly(ctx: ?*anyopaque, id: u32) void {
    _ = id;
    _ = ctx;
    launch_requested.store(true, .seq_cst);
}

fn onTrayActivate(ctx: ?*anyopaque, x: i32, y: i32) void {
    _ = ctx;
    _ = x;
    _ = y;
    launch_requested.store(true, .seq_cst);
}

fn onUiRefresh(ctx: ?*anyopaque, msg: zsn.Message) void {
    _ = msg;
    _ = ctx;
    runtime.wakeWorker();
}

fn failMain(comptime msg: []const u8, e: anyerror) void {
    log_main.err(msg ++ " {0s}\n\nTechnical details: {1s}", .{ diagnostics.cause(e), @errorName(e) });
}

fn failLoop(comptime msg: []const u8, e: anyerror) void {
    log_loop.err(msg ++ " {0s}\n\nTechnical details: {1s}", .{ diagnostics.cause(e), @errorName(e) });
}

fn failMenu(comptime msg: []const u8, e: anyerror) void {
    log_menu.err(msg ++ " {0s}\n\nTechnical details: {1s}", .{ diagnostics.cause(e), @errorName(e) });
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("services/next_notification.zig");
    _ = @import("services/update_store.zig");
    _ = @import("services/tray_icons.zig");
    _ = @import("services/tray_menu.zig");
    _ = @import("services/update_worker.zig");
}
