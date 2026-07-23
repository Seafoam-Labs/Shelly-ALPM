const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gio = bindings.gio;
const gdk = bindings.gdk;
const glib = bindings.glib;
const gobject = bindings.gobject;
const ShellyWindow = @import("shelly_window.zig").ShellyWindow;
const runtime = @import("services/runtime.zig");

extern fn bindtextdomain(domainname: [*:0]const u8, dirname: [*:0]const u8) ?[*:0]const u8;
extern fn bind_textdomain_codeset(domainname: [*:0]const u8, codeset: [*:0]const u8) ?[*:0]const u8;
extern fn textdomain(domainname: [*:0]const u8) ?[*:0]const u8;

pub fn main(init: std.process.Init) void {
    runtime.io = init.io;
    runtime.environ_map = init.environ_map;

    //hook up translations
    _ = bindtextdomain("shelly-ui", "/usr/share/locale");
    _ = bind_textdomain_codeset("shelly-ui", "UTF-8");
    _ = textdomain("shelly-ui");

    const app = gtk.Application.new("com.shellyorg.shelly", .{});
    defer app.unref();

    _ = gio.Application.signals.activate.connect(app, ?*anyopaque, &activate, null, .{});

    const status = gio.Application.run(gobject.ext.as(gio.Application, app), 0, null);
    runtime.teardownConfig(std.heap.c_allocator);
    std.process.exit(@intCast(status));
}

fn activate(app: *gtk.Application, _: ?*anyopaque) callconv(.c) void {
    //load custom css
    const provider = gtk.CssProvider.new();
    gtk.CssProvider.loadFromResource(provider, "/com/shellyorg/shelly/style.css");
    gtk.StyleContext.addProviderForDisplay(
        gdk.Display.getDefault().?,
        provider.as(gtk.StyleProvider),
        gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
    );

    _ = runtime.setupConfig(std.heap.c_allocator) catch |err| {
        std.log.warn("settings: failed to load config service: {t}", .{err});
    };

    const window = ShellyWindow.new(app);
    gtk.Window.present(gobject.ext.as(gtk.Window, window));
}

test {
    // _ = @import("services/icon_resolver.zig");
    _ = @import("services/config_resolver.zig");
    _ = @import("services/shelly_cli.zig");
    _ = @import("g_objects/appstream_app_object.zig");
    _ = @import("helpers/custom_ui_comps/carousel.zig");
    _ = @import("helpers/custom_ui_comps/carousel_indicator_dots.zig");
    _ = @import("pages/flatpak/flatpak_install_view.zig");
    _ = @import("helpers/ui_decode.zig");
    _ = @import("helpers/datetime.zig");
    _ = @import("services/flathub_api.zig");
}
