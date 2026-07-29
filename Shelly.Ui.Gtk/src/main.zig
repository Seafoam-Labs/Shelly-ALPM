const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gio = bindings.gio;
const gdk = bindings.gdk;
const glib = bindings.glib;
const gobject = bindings.gobject;
const ShellyWindow = @import("shelly_window.zig").ShellyWindow;
const runtime = @import("services/runtime.zig");
const translations = @import("helpers/translations.zig");
const tray_service = @import("services/tray_service.zig");
const IconDownloadService = @import("services/icon_fetcher.zig").downloadIconsInBackground;

pub fn main(init: std.process.Init) void {
    runtime.io = init.io;
    runtime.environ_map = init.environ_map;

    setupGnomeThemePreference();

    if (!translations.init()) {
        std.log.warn("translations: failed to initialize gettext", .{});
    }
    IconDownloadService(std.heap.c_allocator, runtime.io);

    const app = gtk.Application.new("com.shellyorg.shelly", .{});
    defer app.unref();
    const gapp = gobject.ext.as(gio.Application, app);

    _ = gio.Application.signals.startup.connect(
        app,
        ?*anyopaque,
        &startup,
        null,
        .{},
    );
    _ = gio.Application.signals.activate.connect(
        app,
        ?*anyopaque,
        &activate,
        null,
        .{},
    );

    const status = gio.Application.run(gapp, 0, null);
    tryStopTray(runtime.io, std.heap.c_allocator);
    runtime.teardownConfig(std.heap.c_allocator);
    std.process.exit(@intCast(status));
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
    if (gtk.Application.getActiveWindow(app)) |window| {
        gtk.Window.present(window);
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

    tryStartTray(runtime.io, std.heap.c_allocator);

    const window = ShellyWindow.new(app);
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
    const desktop = std.posix.getenv("XDG_CURRENT_DESKTOP") orelse return;

    if (!std.mem.containsAtLeast(u8, desktop, 1, "GNOME")) {
        return;
    }

    const settings = gio.Settings.new("org.gnome.desktop.interface");
    defer settings.unref();

    const scheme = settings.getString("color-scheme");
    defer scheme.free();

    const prefer_dark = std.mem.eql(u8, scheme, "prefer-dark");

    std.posix.setenv(
        "GTK_APPLICATION_PREFER_DARK_THEME",
        if (prefer_dark) "1" else "0",
        true,
    ) catch {};
}

test {
    _ = @import("services/icon_resolver.zig");
    _ = @import("services/config_resolver.zig");
    _ = @import("services/shelly_cli.zig");
    _ = @import("services/tray_service.zig");
    _ = @import("g_objects/appstream_app_object.zig");
    _ = @import("helpers/custom_ui_comps/carousel.zig");
    _ = @import("helpers/custom_ui_comps/carousel_indicator_dots.zig");
    _ = @import("pages/flatpak/flatpak_install_view.zig");
    _ = @import("helpers/ui_decode.zig");
    _ = @import("helpers/datetime.zig");
    _ = @import("services/flathub_api.zig");
    _ = @import("models/aur_package.zig");
    _ = @import("g_objects/aur_package_object.zig");
    _ = @import("pages/transaction_page.zig");
}
