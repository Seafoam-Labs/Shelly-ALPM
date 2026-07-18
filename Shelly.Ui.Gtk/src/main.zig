const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gio = bindings.gio;
const gobject = bindings.gobject;
const ShellyWindow = @import("shelly_window.zig").ShellyWindow;
const runtime = @import("services/runtime.zig");

pub fn main(init: std.process.Init) void {
    runtime.io = init.io;
    runtime.environ_map = init.environ_map;

    const app = gtk.Application.new("com.shellyorzig.shelly", .{}); //RENAME THIS PLEASE FOR THE LOVE OF GOD LATER BUT LIKE THIS FOR DEVVING
    defer app.unref();

    _ = gio.Application.signals.activate.connect(app, ?*anyopaque, &activate, null, .{});

    const status = gio.Application.run(gobject.ext.as(gio.Application, app), 0, null);
    std.process.exit(@intCast(status));
}

fn activate(app: *gtk.Application, _: ?*anyopaque) callconv(.c) void {
    const window = ShellyWindow.new(app);
    gtk.Window.present(gobject.ext.as(gtk.Window, window));
}

test {
    // _ = @import("services/icon_resolver.zig");
    _ = @import("services/config.zig");
    _ = @import("services/shelly_cli.zig");
    _ = @import("g_objects/appstream_app_object.zig");
    _ = @import("helpers/custom_ui_comps/carousel.zig");
    _ = @import("helpers/custom_ui_comps/carousel_indicator_dots.zig");
    _ = @import("pages/flatpak/flatpak_install_view.zig");
}
