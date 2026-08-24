const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const glib = bindings.glib;

fn duplicate(value: []const u8) ?[:0]u8 {
    return std.heap.c_allocator.dupeZ(u8, value) catch null;
}

fn createRow(box: *gtk.Box, label: []const u8) ?*gtk.Box {
    const label_z = duplicate(label) orelse return null;
    defer std.heap.c_allocator.free(label_z);

    const row = gtk.Box.new(.vertical, 4);
    gtk.Widget.addCssClass(row.as(gtk.Widget), "spec-row");

    const key = gtk.Label.new(label_z);
    gtk.Widget.setHalign(key.as(gtk.Widget), .start);
    gtk.Label.setXalign(key, 0);
    gtk.Widget.addCssClass(key.as(gtk.Widget), "dim-label");
    gtk.Widget.addCssClass(key.as(gtk.Widget), "spec-key");
    gtk.Box.append(row, key.as(gtk.Widget));
    gtk.Box.append(box, row.as(gtk.Widget));
    return row;
}

fn configureValue(value: *gtk.Label) void {
    gtk.Widget.setHalign(value.as(gtk.Widget), .fill);
    gtk.Widget.setHexpand(value.as(gtk.Widget), 1);
    gtk.Label.setXalign(value, 0);
    gtk.Label.setWrap(value, 1);
    gtk.Label.setWrapMode(value, .word_char);
    gtk.Label.setSelectable(value, 1);
    gtk.Label.setEllipsize(value, .none);
    gtk.Label.setMaxWidthChars(value, 32);
    gtk.Widget.addCssClass(value.as(gtk.Widget), "spec-value");
}

pub fn appendText(box: *gtk.Box, label: []const u8, value: []const u8) void {
    const row = createRow(box, label) orelse return;
    const value_z = duplicate(value) orelse return;
    defer std.heap.c_allocator.free(value_z);

    const value_label = gtk.Label.new(value_z);
    configureValue(value_label);
    gtk.Box.append(row, value_label.as(gtk.Widget));
}

pub fn appendUrl(box: *gtk.Box, label: []const u8, value: []const u8) void {
    const row = createRow(box, label) orelse return;
    const value_z = duplicate(value) orelse return;
    defer std.heap.c_allocator.free(value_z);

    const escaped = glib.markupEscapeText(value_z, -1);
    defer glib.free(escaped);
    const markup = std.fmt.allocPrintSentinel(
        std.heap.c_allocator,
        "<a href=\"{s}\">{s}</a>",
        .{ escaped, escaped },
        0,
    ) catch return;
    defer std.heap.c_allocator.free(markup);

    const value_label = gtk.Label.new(null);
    gtk.Label.setMarkup(value_label, markup);
    configureValue(value_label);
    gtk.Box.append(row, value_label.as(gtk.Widget));
}
