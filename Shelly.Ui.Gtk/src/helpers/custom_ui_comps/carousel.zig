const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gobject = bindings.gobject;
const gio = bindings.gio;

pub const Carousel = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gtk.Box;

    const Private = struct {
        stack: *gtk.Stack,
        previous_button: *gtk.Button,
        next_button: *gtk.Button,
        disposed: bool,
        var offset: c_int = 0;
    };

    pub const PageChangedHandler = struct {
        id: c_ulong,

        pub fn disconnect(self: *PageChangedHandler, carousel: *Carousel) void {
            if (self.id == 0) return;
            gobject.signalHandlerDisconnect(carousel.priv().stack.as(gobject.Object), self.id);
            self.id = 0;
        }
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{ .name = "ShellyCarousel", .instanceInit = &init, .classInit = &Class.init, .parent_class = &Class.parent, .private = .{ .Type = Private, .offset = &Private.offset } });

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    pub fn as(self: *Self, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    fn priv(self: *Self) *Private {
        return gobject.ext.impl_helpers.getPrivate(self, Private, Private.offset);
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const p = self.priv();
        p.disposed = false;

        gtk.Orientable.setOrientation(self.as(gtk.Orientable), .horizontal);
        gtk.Box.setSpacing(self.as(gtk.Box), 8);

        p.stack = gtk.Stack.new();
        gtk.Stack.setTransitionType(p.stack, .slide_left_right);
        gtk.Widget.setHexpand(p.stack.as(gtk.Widget), 1);
        gtk.Widget.setVexpand(p.stack.as(gtk.Widget), 1);

        p.previous_button = gtk.Button.newFromIconName("go-previous-symbolic");
        gtk.Widget.setValign(p.previous_button.as(gtk.Widget), .center);
        _ = gtk.Button.signals.clicked.connect(p.previous_button, *Self, &onPreviousClicked, self, .{});

        p.next_button = gtk.Button.newFromIconName("go-next-symbolic");
        gtk.Widget.setValign(p.next_button.as(gtk.Widget), .center);
        _ = gtk.Button.signals.clicked.connect(p.next_button, *Self, &onNextClicked, self, .{});

        gtk.Box.append(self.as(gtk.Box), p.previous_button.as(gtk.Widget));
        gtk.Box.append(self.as(gtk.Box), p.stack.as(gtk.Widget));
        gtk.Box.append(self.as(gtk.Box), p.next_button.as(gtk.Widget));

        _ = gobject.Object.signals.notify.connect(p.stack.as(gobject.Object), *Self, &onVisibleChildChanged, self, .{ .detail = "visible-child" });
        self.updateButtons();
    }

    pub fn addWidget(self: *Self, widget: *gtk.Widget) void {
        const p = self.priv();
        if (p.disposed) return;

        _ = gtk.Stack.addChild(p.stack, widget);
        if (gtk.Stack.getVisibleChild(p.stack) == null) gtk.Stack.setVisibleChild(p.stack, widget);
        self.updateButtons();
    }

    pub fn removeAll(self: *Self) void {
        const p = self.priv();
        while (gtk.Widget.getFirstChild(p.stack.as(gtk.Widget))) |child| {
            gtk.Stack.remove(p.stack, child);
        }
        if (!p.disposed) self.updateButtons();
    }

    pub fn next(self: *Self) void {
        const p = self.priv();
        const current = gtk.Stack.getVisibleChild(p.stack) orelse return;
        const next_widget = gtk.Widget.getNextSibling(current) orelse return;
        gtk.Stack.setVisibleChild(p.stack, next_widget);
    }

    pub fn previous(self: *Self) void {
        const p = self.priv();
        const current = gtk.Stack.getVisibleChild(p.stack) orelse return;
        const previous_widget = gtk.Widget.getPrevSibling(current) orelse return;
        gtk.Stack.setVisibleChild(p.stack, previous_widget);
    }

    pub fn getVisibleChild(self: *Self) ?*gtk.Widget {
        return gtk.Stack.getVisibleChild(self.priv().stack);
    }

    pub fn getFirstChild(self: *Self) ?*gtk.Widget {
        return gtk.Widget.getFirstChild(self.priv().stack.as(gtk.Widget));
    }

    pub fn getChildCount(self: *Self) usize {
        var count: usize = 0;
        var child = self.getFirstChild();
        while (child) |widget| : (child = gtk.Widget.getNextSibling(widget)) count += 1;
        return count;
    }

    pub fn connectPageChanged(self: *Self, comptime P_Data: type, callback: *const fn (*gobject.Object, *gobject.ParamSpec, P_Data) callconv(.c) void, data: P_Data) PageChangedHandler {
        return .{
            .id = gobject.Object.signals.notify.connect(self.priv().stack.as(gobject.Object), P_Data, callback, data, .{ .detail = "visible-child" }),
        };
    }

    pub fn connectItemsChanged(self: *Self, comptime P_Data: type, callback: *const fn (*gio.ListModel, c_uint, c_uint, c_uint, P_Data) callconv(.c) void, data: P_Data) c_ulong {
        return gio.ListModel.signals.items_changed.connect(gtk.Stack.getPages(self.priv().stack).as(gio.ListModel), P_Data, callback, data, .{});
    }

    pub fn disconnectItemsChanged(self: *Self, handler_id: c_ulong) void {
        if (handler_id == 0) return;
        gobject.signalHandlerDisconnect(gtk.Stack.getPages(self.priv().stack).as(gobject.Object), handler_id);
    }

    fn onPreviousClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.previous();
    }

    fn onNextClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.next();
    }

    fn onVisibleChildChanged(_: *gobject.Object, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        if (!self.priv().disposed) self.updateButtons();
    }

    fn updateButtons(self: *Self) void {
        const p = self.priv();
        const current = gtk.Stack.getVisibleChild(p.stack);
        gtk.Widget.setSensitive(p.previous_button.as(gtk.Widget), @intFromBool(if (current) |widget| gtk.Widget.getPrevSibling(widget) != null else false));
        gtk.Widget.setSensitive(p.next_button.as(gtk.Widget), @intFromBool(if (current) |widget| gtk.Widget.getNextSibling(widget) != null else false));
    }

    fn dispose(object: *gobject.Object) callconv(.c) void {
        const self = gobject.ext.cast(Self, object) orelse {
            gobject.ext.as(gobject.Object.Class, Class.parent).f_dispose.?(object);
            return;
        };
        const p = self.priv();
        if (!p.disposed) {
            p.disposed = true;
            self.removeAll();
            gtk.Box.remove(self.as(gtk.Box), p.previous_button.as(gtk.Widget));
            gtk.Box.remove(self.as(gtk.Box), p.stack.as(gtk.Widget));
            gtk.Box.remove(self.as(gtk.Box), p.next_button.as(gtk.Widget));
        }
        gobject.ext.as(gobject.Object.Class, Class.parent).f_dispose.?(object);
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            const object_class = gobject.ext.as(gobject.Object.Class, class);
            object_class.f_dispose = &dispose;
        }
    };
};

test "carousel navigates between every page and clears its children" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;

    const carousel = Carousel.new();
    _ = carousel.as(gobject.Object).refSink();
    defer carousel.as(gobject.Object).unref();

    const first = gtk.Label.new("First");
    const second = gtk.Label.new("Second");
    const third = gtk.Label.new("Third");
    carousel.addWidget(first.as(gtk.Widget));
    carousel.addWidget(second.as(gtk.Widget));
    carousel.addWidget(third.as(gtk.Widget));

    try std.testing.expectEqual(@as(usize, 3), carousel.getChildCount());
    try std.testing.expectEqual(first.as(gtk.Widget), carousel.getVisibleChild().?);

    carousel.next();
    try std.testing.expectEqual(second.as(gtk.Widget), carousel.getVisibleChild().?);
    carousel.next();
    try std.testing.expectEqual(third.as(gtk.Widget), carousel.getVisibleChild().?);
    carousel.next();
    try std.testing.expectEqual(third.as(gtk.Widget), carousel.getVisibleChild().?);

    carousel.previous();
    try std.testing.expectEqual(second.as(gtk.Widget), carousel.getVisibleChild().?);

    carousel.removeAll();
    try std.testing.expectEqual(@as(usize, 0), carousel.getChildCount());
    try std.testing.expect(carousel.getVisibleChild() == null);
    carousel.next();
    carousel.previous();
}
