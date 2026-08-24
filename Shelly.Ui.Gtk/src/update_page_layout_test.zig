const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gdk = bindings.gdk;
const gobject = bindings.gobject;
const UpdatePage = @import("pages/update_page.zig").UpdatePage;

pub fn main() !void {
    if (gtk.initCheck() == 0) return error.GtkUnavailable;
    const display = gdk.Display.getDefault() orelse return error.GtkUnavailable;

    const base_provider = gtk.CssProvider.new();
    defer base_provider.unref();
    gtk.CssProvider.loadFromString(base_provider, @embedFile("themes/style.css"));
    gtk.StyleContext.addProviderForDisplay(
        display,
        base_provider.as(gtk.StyleProvider),
        gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
    defer gtk.StyleContext.removeProviderForDisplay(display, base_provider.as(gtk.StyleProvider));

    const reference_provider = gtk.CssProvider.new();
    defer reference_provider.unref();
    gtk.CssProvider.loadFromString(reference_provider,
        \\.update-row-action-reference { min-width: 3em; min-height: 3em; padding: 0; }
        \\.update-row-action-reference > image { -gtk-icon-size: 1.25em; }
    );
    gtk.StyleContext.addProviderForDisplay(
        display,
        reference_provider.as(gtk.StyleProvider),
        gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1,
    );
    defer gtk.StyleContext.removeProviderForDisplay(display, reference_provider.as(gtk.StyleProvider));

    const page = UpdatePage.new();
    _ = page.as(gobject.Object).refSink();
    defer page.as(gobject.Object).unref();

    const item = gobject.ext.newInstance(gtk.ListItem, .{});
    _ = item.as(gobject.Object).refSink();
    defer item.as(gobject.Object).unref();
    page.buildUpdateRow(item);

    const grid = gobject.ext.cast(gtk.Grid, gtk.ListItem.getChild(item) orelse return error.UpdateRowMissing) orelse
        return error.UpdateRowHasWrongType;
    const action = gtk.Grid.getChildAt(grid, 5, 0) orelse return error.UpdateActionMissing;
    const action_icon = gtk.Widget.getFirstChild(action) orelse return error.UpdateActionIconMissing;

    const reference = gtk.Button.newFromIconName("software-update-available-symbolic");
    _ = reference.as(gobject.Object).refSink();
    defer reference.as(gobject.Object).unref();
    gtk.Widget.addCssClass(reference.as(gtk.Widget), "flat");
    gtk.Widget.addCssClass(reference.as(gtk.Widget), "circular");
    gtk.Widget.addCssClass(reference.as(gtk.Widget), "update-row-action-reference");
    const reference_icon = gtk.Widget.getFirstChild(reference.as(gtk.Widget)) orelse
        return error.UpdateReferenceIconMissing;

    var action_width: c_int = 0;
    var action_height: c_int = 0;
    var reference_width: c_int = 0;
    var reference_height: c_int = 0;
    gtk.Widget.measure(action, .horizontal, -1, &action_width, null, null, null);
    gtk.Widget.measure(action, .vertical, -1, &action_height, null, null, null);
    gtk.Widget.measure(reference.as(gtk.Widget), .horizontal, -1, &reference_width, null, null, null);
    gtk.Widget.measure(reference.as(gtk.Widget), .vertical, -1, &reference_height, null, null, null);
    try std.testing.expect(action_width >= reference_width);
    try std.testing.expect(action_height >= reference_height);

    var action_icon_width: c_int = 0;
    var reference_icon_width: c_int = 0;
    gtk.Widget.measure(action_icon, .horizontal, -1, &action_icon_width, null, null, null);
    gtk.Widget.measure(reference_icon, .horizontal, -1, &reference_icon_width, null, null, null);
    try std.testing.expect(action_icon_width >= reference_icon_width);
}
