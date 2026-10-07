//! Accessible names and descriptions for widgets whose text a screen reader
//! cannot reach, and the focus move that makes a page change audible.
//!
//! GTK4 exposes no getter for accessible properties, so a name written here
//! cannot be asserted in-process: it is verified by walking the AT-SPI tree
//! over the bus, which needs a display and a session bus.
const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk_test = @import("gtk_test.zig");

const gtk = bindings.gtk;
const glib = bindings.glib;
const gobject = bindings.gobject;

/// Frees the buffer a widget owns for its accessible text.
fn freeOwned(ptr: ?*anyopaque) callconv(.c) void {
    glib.free(ptr);
}

fn updateProperty(widget: *gtk.Widget, property: gtk.AccessibleProperty, text: []const u8) void {
    // GTK borrows the string inside the GValue rather than keeping its own copy:
    // unsetting the value after the update leaves the name empty, and a buffer
    // that dies later makes the AT-SPI bridge marshal dangling bytes and abort
    // the application. So the bytes are handed to the widget, which frees them
    // when it is finalized.
    const owned = glib.malloc(text.len + 1) orelse return;
    const bytes: [*]u8 = @ptrCast(owned);
    @memcpy(bytes[0..text.len], text);
    bytes[text.len] = 0;

    var properties = [_]gtk.AccessibleProperty{property};
    var gvalue = std.mem.zeroes(gobject.Value);
    property.initValue(&gvalue);
    gvalue.setStaticString(@ptrCast(bytes));
    gtk.Accessible.updatePropertyValue(
        widget.as(gtk.Accessible),
        1,
        @ptrCast(&properties),
        @ptrCast(&gvalue),
    );
    // The string is static, so this releases only the GValue, not the buffer.
    gvalue.unset();

    // Installed before the previous buffer is freed, so no reader can point at
    // memory that is already gone.
    const key = if (property == .label) "shelly-a11y-name" else "shelly-a11y-description";
    gobject.Object.setDataFull(widget.as(gobject.Object), key, owned, freeOwned);
}

/// Names a control whose visible text is absent from the accessible tree:
/// icon-only buttons, labels inside a collapsed revealer, placeholder-only
/// entries. A `tooltip-text` also surfaces as a name on some widgets, but the
/// tree cannot tell the two apart, so names are always set explicitly.
///
/// For a row in a `SignalListItemFactory` list this must be called at bind, not
/// setup: the cell widget is reused across rows, so a name written once would
/// describe a different package.
pub fn setName(widget: *gtk.Widget, name: []const u8) void {
    updateProperty(widget, .label, name);
}

/// Text an AT should speak when the object it describes changes but never
/// takes focus: statuses, match counts, empty result sets. Writing it fires an
/// accessible-description property change, which static text alone never does.
pub fn setDescription(widget: *gtk.Widget, text: []const u8) void {
    updateProperty(widget, .description, text);
}

/// Focuses the first focusable descendant, so a page swap hands the keyboard to
/// a control an AT can announce. `grabFocus` on a container does not delegate.
pub fn focusFirst(widget: *gtk.Widget) bool {
    return focusDescendant(widget);
}

fn focusDescendant(widget: *gtk.Widget) bool {
    if (gtk.Widget.getFocusable(widget) != 0 and
        gtk.Widget.getSensitive(widget) != 0 and
        gtk.Widget.getVisible(widget) != 0)
    {
        if (gtk.Widget.grabFocus(widget) != 0) return true;
    }

    var child = gtk.Widget.getFirstChild(widget);
    while (child) |c| {
        if (focusDescendant(c)) return true;
        child = gtk.Widget.getNextSibling(c);
    }
    return false;
}

fn shownWindow(child: *gtk.Widget) *gtk.Window {
    const window = gtk.Window.new();
    gtk.Window.setChild(window, child);
    gtk.Window.setDefaultSize(window, 320, 240);
    gtk.Window.present(window);
    return window;
}

test "focusFirst hands focus to the first focusable descendant" {
    try gtk_test.requireDisplay();

    const button = gtk.Button.new();
    gtk.Button.setLabel(button, "Packages");
    const inner = gtk.Box.new(.vertical, 0);
    gtk.Box.append(inner, button.as(gtk.Widget));
    const outer = gtk.Box.new(.vertical, 0);
    gtk.Box.append(outer, inner.as(gtk.Widget));
    const window = shownWindow(outer.as(gtk.Widget));

    try std.testing.expect(focusFirst(outer.as(gtk.Widget)));
    // hasFocus() additionally requires the toplevel to hold global focus, which
    // a test window does not get on a live desktop.
    const focus = gtk.Window.getFocus(window);
    try std.testing.expectEqual(@as(?*gtk.Widget, button.as(gtk.Widget)), focus);
    gtk.Window.destroy(window);
}

test "focusFirst skips controls that cannot take focus" {
    try gtk_test.requireDisplay();

    const hidden = gtk.Button.new();
    gtk.Button.setLabel(hidden, "Hidden");
    gtk.Widget.setVisible(hidden.as(gtk.Widget), 0);
    const insensitive = gtk.Button.new();
    gtk.Button.setLabel(insensitive, "Insensitive");
    gtk.Widget.setSensitive(insensitive.as(gtk.Widget), 0);
    const active = gtk.Button.new();
    gtk.Button.setLabel(active, "Active");

    const box = gtk.Box.new(.vertical, 0);
    gtk.Box.append(box, hidden.as(gtk.Widget));
    gtk.Box.append(box, insensitive.as(gtk.Widget));
    gtk.Box.append(box, active.as(gtk.Widget));
    const window = shownWindow(box.as(gtk.Widget));

    try std.testing.expect(focusFirst(box.as(gtk.Widget)));
    const focus = gtk.Window.getFocus(window);
    try std.testing.expectEqual(@as(?*gtk.Widget, active.as(gtk.Widget)), focus);
    gtk.Window.destroy(window);
}

test "focusFirst reports failure when a subtree has nothing focusable" {
    try gtk_test.requireDisplay();

    const box = gtk.Box.new(.vertical, 0);
    gtk.Box.append(box, gtk.Label.new("No controls").as(gtk.Widget));
    try std.testing.expectEqual(false, focusFirst(box.as(gtk.Widget)));
}
