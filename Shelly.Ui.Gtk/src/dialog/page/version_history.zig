const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gdk = bindings.gdk;

const gobject = bindings.gobject;
const support = @import("../../pages/support.zig");

pub const Entry = struct {
    version: [:0]const u8 = "",
    date: [:0]const u8 = "",
    note: [:0]const u8 = "",
};

pub const VersionHistoryDialog = extern struct {
    parent_instance: Parent,
    const Self = @This();
    pub const Parent = gtk.Box;
    const resource_path = "/com/shellyorg/shelly/dialog/ui/version_history.ui";

    pub const CloseFn = *const fn (ctx: ?*anyopaque) void;

    const Private = struct {
        history_frame: *gtk.Frame,
        title_label: *gtk.Label,
        subtitle_label: *gtk.Label,
        history_list: *gtk.ListBox,
        close_button: *gtk.Button,
        surface: ?*gdk.Surface,
        surface_layout_handler: c_ulong,
        on_close: ?CloseFn,
        ctx: ?*anyopaque,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyVersionHistoryDialog",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    fn priv(self: *Self) *Private {
        return gobject.ext.impl_helpers.getPrivate(self, Private, Private.offset);
    }

    pub fn as(self: *Self, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        const p = self.priv();
        p.surface = null;
        p.surface_layout_handler = 0;
        p.on_close = null;
        p.ctx = null;
        support.connectLifecycle(Self, self);
    }

    /// Takes ownership of `entries` and its strings; frees them before returning.
    pub fn new(title: [:0]const u8, subtitle: [:0]const u8, entries: []Entry, on_close_fn: CloseFn, ctx: ?*anyopaque) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const p = self.priv();
        gtk.Label.setLabel(p.title_label, title);
        gtk.Label.setLabel(p.subtitle_label, subtitle);

        p.on_close = on_close_fn;

        std.log.info("Flatpak version history overlay: entries={}", .{entries.len});

        for (entries) |entry| {
            gtk.ListBox.append(p.history_list, make_row(entry));
        }

        for (entries) |entry| {
            std.heap.c_allocator.free(entry.version);
            std.heap.c_allocator.free(entry.note);
        }
        std.heap.c_allocator.free(entries);

        p.ctx = ctx;
        return self;
    }

    pub fn setButtons(self: *Self, close: [:0]const u8) void {
        const p = self.priv();
        gtk.Button.setLabel(p.close_button, close);
    }

    pub fn applyAvailableSize(self: *Self, available_width: c_int, available_height: c_int) void {
        const width = @max(@divTrunc(available_width * 3, 4), 1);
        const height = @max(@divTrunc(available_height * 3, 4), 1);
        gtk.Widget.setSizeRequest(self.priv().history_frame.as(gtk.Widget), width, height);
    }

    pub fn onMap(self: *Self) void {
        const p = self.priv();
        if (p.surface_layout_handler != 0) return;

        const native = gtk.Widget.getNative(self.as(gtk.Widget)) orelse return;
        const surface = gtk.Native.getSurface(native) orelse return;
        p.surface = surface;
        p.surface_layout_handler = gdk.Surface.signals.layout.connect(
            surface,
            *Self,
            &onSurfaceLayout,
            self,
            .{},
        );
        self.applyAvailableSize(gdk.Surface.getWidth(surface), gdk.Surface.getHeight(surface));
    }

    pub fn onUnmap(self: *Self) void {
        const p = self.priv();
        if (p.surface) |surface| {
            if (p.surface_layout_handler != 0) {
                gobject.signalHandlerDisconnect(surface.as(gobject.Object), p.surface_layout_handler);
            }
        }
        p.surface = null;
        p.surface_layout_handler = 0;
    }

    fn onSurfaceLayout(_: *gdk.Surface, width: c_int, height: c_int, self: *Self) callconv(.c) void {
        self.applyAvailableSize(width, height);
    }

    fn make_row(entry: Entry) *gtk.Widget {
        const row = gtk.ListBoxRow.new();
        const box = gtk.Box.new(.horizontal, 12);
        gtk.Widget.setMarginStart(box.as(gtk.Widget), 12);
        gtk.Widget.setMarginEnd(box.as(gtk.Widget), 12);
        gtk.Widget.setMarginTop(box.as(gtk.Widget), 10);
        gtk.Widget.setMarginBottom(box.as(gtk.Widget), 10);

        const text = gtk.Box.new(.vertical, 2);
        gtk.Widget.setHexpand(text.as(gtk.Widget), 1);

        const ver = gtk.Label.new(entry.version);
        gtk.Label.setXalign(ver, 0);
        gtk.Widget.addCssClass(ver.as(gtk.Widget), "heading");
        gtk.Box.append(text, ver.as(gtk.Widget));

        const note_label = gtk.Label.new(entry.note);
        gtk.Label.setXalign(note_label, 0);
        gtk.Label.setWrap(note_label, 1);
        gtk.Widget.addCssClass(note_label.as(gtk.Widget), "dim-label");
        gtk.Box.append(text, note_label.as(gtk.Widget));

        gtk.Box.append(box, text.as(gtk.Widget));

        const date = gtk.Label.new(entry.date);
        gtk.Widget.setValign(date.as(gtk.Widget), .center);
        gtk.Widget.addCssClass(date.as(gtk.Widget), "dim-label");
        gtk.Box.append(box, date.as(gtk.Widget));

        gtk.ListBoxRow.setChild(row, box.as(gtk.Widget));
        return row.as(gtk.Widget);
    }

    fn on_close(self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.on_close) |cb| cb(p.ctx);
    }

    const template_children = .{
        .{ "history_frame", @offsetOf(Private, "history_frame") },
        .{ "title_label", @offsetOf(Private, "title_label") },
        .{ "subtitle_label", @offsetOf(Private, "subtitle_label") },
        .{ "history_list", @offsetOf(Private, "history_list") },
        .{ "close_button", @offsetOf(Private, "close_button") },
    };

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            const wc = gobject.ext.as(gtk.Widget.Class, class);
            gtk.Widget.Class.setTemplateFromResource(wc, resource_path);
            inline for (template_children) |c| {
                support.bindChild(class, Private.offset, c[0], c[1]);
            }

            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_close", @ptrCast(&on_close));
        }
    };
};
