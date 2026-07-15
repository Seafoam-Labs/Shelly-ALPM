const ui = @import("Shelly_Ui_Gtk");
const gio = ui.gio;
const gtk = ui.gtk;

pub fn main() void {
    const application = gtk.Application.new("io.github.shelly", .{});
    defer application.unref();

    _ = gio.Application.signals.activate.connect(
        application,
        ?*anyopaque,
        &activate,
        null,
        .{},
    );

    _ = gio.Application.run(application.as(gio.Application), 0, null);
}

fn activate(application: *gtk.Application, _: ?*anyopaque) callconv(.c) void {
    const application_window = gtk.ApplicationWindow.new(application);
    const window = application_window.as(gtk.Window);

    gtk.Window.setTitle(window, "Shelly");
    gtk.Window.setDefaultSize(window, 960, 640);
    gtk.Window.present(window);
}
