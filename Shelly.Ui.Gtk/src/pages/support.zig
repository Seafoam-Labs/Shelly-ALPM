const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gobject = bindings.gobject;

pub fn bindChild(class: anytype, private_offset: c_int, name: [:0]const u8, field_offset: usize) void {
    gtk.Widget.Class.bindTemplateChildFull(
        gobject.ext.as(gtk.Widget.Class, class),
        name,
        @intFromBool(false),
        @as(c_long, @intCast(private_offset)) + @as(c_long, @intCast(field_offset)),
    );
}

/// `Page` must expose `fn onMap(*Page) void` and `fn onUnmap(*Page) void`.
pub fn connectLifecycle(comptime Page: type, self: *Page) void {
    const H = struct {
        fn mapCb(w: *Page, _: ?*anyopaque) callconv(.c) void {
            w.onMap();
        }
        fn unmapCb(w: *Page, _: ?*anyopaque) callconv(.c) void {
            w.onUnmap();
        }
    };
    _ = gtk.Widget.signals.map.connect(self, ?*anyopaque, &H.mapCb, null, .{});
    _ = gtk.Widget.signals.unmap.connect(self, ?*anyopaque, &H.unmapCb, null, .{});
}

pub fn getWindow(comptime W: type, widget: anytype) ?*W {
    const root = gtk.Widget.getRoot(widget.as(gtk.Widget)) orelse return null;
    return gobject.ext.cast(W, root);
}
