const std = @import("std");
const HttpClient = @import("ShellyHttp");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gio = bindings.gio;
const gdk = bindings.gdk;
const glib = bindings.glib;
const gobject = bindings.gobject;
const ShellyWindow = @import("shelly_window.zig").ShellyWindow;
const runtime = @import("services/runtime.zig");
const translations = @import("helpers/translations.zig");
const deep_link = @import("helpers/deep_link.zig");
const tray_service = @import("services/tray_service.zig");
const options = @import("options");
const IconDownloadService = @import("services/icon_fetcher.zig").downloadIconsInBackground;

var did_activate: bool = false;

pub fn main(init: std.process.Init) void {
    runtime.io = init.io;
    runtime.environ_map = init.environ_map;
    HttpClient.setDefaultProxyEnvironment(init.environ_map);

    if (!translations.init()) {
        std.log.warn("translations: failed to initialize gettext", .{});
    }
    if (!options.skip_background_services) {
        IconDownloadService(std.heap.c_allocator, runtime.io);
    }

    const app = gtk.Application.new("com.shellyorg.shelly", .{
        .handles_command_line = true,
    });
    defer app.unref();
    const gapp = gobject.ext.as(gio.Application, app);

    _ = gio.Application.signals.startup.connect(app, ?*anyopaque, &startup, null, .{});
    _ = gio.Application.signals.activate.connect(app, ?*anyopaque, &activate, null, .{});
    _ = gio.Application.signals.command_line.connect(app, ?*anyopaque, &commandLine, null, .{});

    const argv_vector = init.minimal.args.vector;
    const status = gio.Application.run(
        gapp,
        @intCast(argv_vector.len),
        @ptrCast(@constCast(argv_vector.ptr)),
    );

    if (did_activate) {
        tryStopTray(runtime.io, std.heap.c_allocator);
    }
    runtime.teardownConfig(std.heap.c_allocator);
    std.process.exit(@intCast(status));
}

fn commandLine(
    app: *gtk.Application,
    cmdline: *gio.ApplicationCommandLine,
    _: ?*anyopaque,
) callconv(.c) c_int {
    var argc: c_int = 0;
    const argv = gio.ApplicationCommandLine.getArguments(cmdline, &argc);
   const argc_usize = @as(usize, @intCast(argc));
    defer glib.strfreev(@ptrCast(argv));

    var requested_page: ?deep_link.PageTarget = null;
    var app_id_buffer: [deep_link.max_app_id_len + 1]u8 = undefined;
    var requested_app_id: ?[:0]const u8 = null;

    var i: usize = 1;
    while (i < argc_usize) : (i += 1) {
        const arg = std.mem.span(argv[i]);
    
        if (std.mem.eql(u8, arg, "--tray-updates")) {
            requested_page = .updates;
            continue;
        }
    
        if (std.mem.eql(u8, arg, "--page")) {
            if (i + 1 < argc_usize) {
                i += 1;
                requested_page =
                    deep_link.parsePageTarget(std.mem.span(argv[i]));
            } else {
                std.log.warn("--page requires a value", .{});
            }
            continue;
        }
    
        if (deep_link.extractFlatpakAppId(arg, &app_id_buffer)) |id| {
            requested_app_id = id;
        }
    }

    if (requested_app_id) |id| {
        runtime.queueFlatpakApp(id);
    } else if (requested_page) |page| {
        runtime.queuePage(page);
    }
 
    gio.Application.activate(app.as(gio.Application));
    gio.ApplicationCommandLine.setExitStatus(cmdline, 0);
    return 0;
}

fn dispatchPendingNavigation(window: *ShellyWindow) void {
    const request = runtime.takePendingNavigation() orelse return;

    const navigated = switch (request) {
        .page => |target| window.navigateTo(target),
        .flatpak_app => |app| window.openFlatpakApp(app.id()),
    };

    if (!navigated) {
        std.log.warn("requested page is disabled or unavailable", .{});
    }
}

fn tryStopTray(io: std.Io, alloc: std.mem.Allocator) void {
    var should_stop = true;
    if (runtime.config) |svc| {
        if (svc.get() catch null) |cfg| should_stop = !cfg.TrayEnabled;
    }
    if (should_stop) _ = tray_service.end(io, alloc);
}

fn quitActivated(_: *gio.SimpleAction, _: ?*glib.Variant, app: *gtk.Application) callconv(.c) void {
    app.as(gio.Application).quit();
}

fn startup(app: *gtk.Application, _: ?*anyopaque) callconv(.c) void {
    const quit_action = gio.SimpleAction.new("quit", null);
    defer quit_action.unref();
    _ = gio.SimpleAction.signals.activate.connect(
        quit_action,
        *gtk.Application,
        &quitActivated,
        app,
        .{},
    );
    app.as(gio.ActionMap).addAction(quit_action.as(gio.Action));
    const accels = [_:null]?[*:0]const u8{ "<Control>q", "<Control>w", null };
    gtk.Application.setAccelsForAction(app, "app.quit", &accels);
}

fn activate(app: *gtk.Application, _: ?*anyopaque) callconv(.c) void {
    did_activate = true;

    if (gtk.Application.getActiveWindow(app)) |gtk_window| {
        if (gobject.ext.cast(ShellyWindow, gtk_window)) |window| {
            dispatchPendingNavigation(window);
        }
        gtk.Window.present(gtk_window);
        if (runtime.pending_navigate_updates) {
            runtime.pending_navigate_updates = false;
            if (gobject.ext.cast(ShellyWindow, gtk_window)) |shelly_window| {
                shelly_window.navigateToUpdates();
            }
        }
        return;
    }
    const provider = gtk.CssProvider.new();
    gtk.CssProvider.loadFromResource(provider, "/com/shellyorg/shelly/style.css");
    gtk.StyleContext.addProviderForDisplay(
        gdk.Display.getDefault().?,
        provider.as(gtk.StyleProvider),
        gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
    );

    if (gdk.Display.getDefault()) |display| {
        const icon_theme = gtk.IconTheme.getForDisplay(display);
        gtk.IconTheme.addResourcePath(icon_theme, "/com/shellyorg/shelly/icons");
    }

    _ = runtime.setupConfig(std.heap.c_allocator) catch |err| {
        std.log.warn("settings: failed to load config service: {t}", .{err});
    };

    if (runtime.config) |svc| {
        const cfg = svc.get() catch |err| {
            std.log.warn("settings: failed to get config: {t}", .{err});
            return;
        };

        if (cfg.Culture.len > 0) {
            var cul_buf: [256:0]u8 = undefined;
            @memcpy(cul_buf[0..cfg.Culture.len], cfg.Culture);
            cul_buf[cfg.Culture.len] = 0;
            const cul = cul_buf[0..cfg.Culture.len :0];
            const ok = translations.initWithLocale(cul);
            std.log.info("[i18n] init ok={}, culture={s}\n", .{ ok, cul });
        }
    }

    if (!options.skip_background_services) tryStartTray(runtime.io, std.heap.c_allocator);

    setupGnomeThemePreference();

    const window = ShellyWindow.new(app);
    dispatchPendingNavigation(window);
    gtk.Window.present(window.as(gtk.Window));

    if (runtime.pending_navigate_updates) {
        runtime.pending_navigate_updates = false;
        window.navigateToUpdates();
    }

    gtk.Window.present(gobject.ext.as(gtk.Window, window));
}

fn tryStartTray(io: std.Io, alloc: std.mem.Allocator) void {
    if (runtime.config) |svc| {
        const cfg = svc.get() catch return;
        if (!cfg.TrayEnabled) return;
    }
    tray_service.start(io, alloc);
}

fn setupGnomeThemePreference() void {
    const desktop = runtime.environ_map.get("XDG_CURRENT_DESKTOP") orelse return;

    std.debug.print("desktop = {s}\n", .{desktop});

    if (!std.mem.containsAtLeast(u8, desktop, 1, "GNOME")) {
        return;
    }

    const settings = gio.Settings.new("org.gnome.desktop.interface");

    const scheme = settings.getString("color-scheme");

    const prefer_dark = std.mem.eql(u8, std.mem.span(scheme), "prefer-dark");

    std.debug.print("prefer_dark = {}\n", .{prefer_dark});

    if (prefer_dark) {
        const gtk_settings = gtk.Settings.getDefault() orelse {
            std.debug.print("Failed to fetch GtkSettings layout.\n", .{});
            return;
        };
        const base_object = @as(*gobject.Object, @ptrCast(@alignCast(gtk_settings)));
        var value = std.mem.zeroes(gobject.Value);
        const bool_type = gobject.typeFromName("gboolean");
        _ = value.init(bool_type);
        value.setBoolean(1);
        base_object.setProperty("gtk-application-prefer-dark-theme", &value);
    }

    _ = glib.setenv(
        "GTK_APPLICATION_PREFER_DARK_THEME",
        if (prefer_dark) "1" else "0",
        1,
    );
}

test {
    _ = @import("services/icon_resolver.zig");
    _ = @import("services/ui_config_resolver.zig");
    _ = @import("services/shelly_cli.zig");
    _ = @import("services/tray_service.zig");
    _ = @import("g_objects/appstream_app_object.zig");
    _ = @import("helpers/custom_ui_comps/carousel.zig");
    _ = @import("helpers/custom_ui_comps/carousel_indicator_dots.zig");
    _ = @import("pages/flatpak/flatpak_install_view.zig");
    _ = @import("helpers/ui_decode.zig");
    _ = @import("helpers/datetime.zig");
    _ = @import("helpers/deep_link.zig");
    _ = @import("services/flathub_api.zig");
    _ = @import("models/aur_package.zig");
    _ = @import("g_objects/aur_package_object.zig");
    _ = @import("models/search_result.zig");
    _ = @import("g_objects/search_result_object.zig");
    _ = @import("pages/transaction_page.zig");
}
