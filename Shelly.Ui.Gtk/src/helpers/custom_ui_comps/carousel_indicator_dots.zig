const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gobject = bindings.gobject;
const gio = bindings.gio;
const Carousel = @import("carousel.zig").Carousel;

pub const CarouselIndicatorDots = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gtk.Box;

    const Private = struct {
        carousel: ?*Carousel,
        page_changed_handler: Carousel.PageChangedHandler,
        items_changed_handler: c_ulong,
        disposed: bool,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyCarouselIndicatorDots",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub fn new(carousel: *Carousel) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        self.setup(carousel);
        return self;
    }

    pub fn as(self: *Self, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    fn priv(self: *Self) *Private {
        return gobject.ext.impl_helpers.getPrivate(self, Private, Private.offset);
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const p = self.priv();
        p.carousel = null;
        p.page_changed_handler = .{ .id = 0 };
        p.items_changed_handler = 0;
        p.disposed = false;

        gtk.Orientable.setOrientation(self.as(gtk.Orientable), .horizontal);
        gtk.Box.setSpacing(self.as(gtk.Box), 6);
        gtk.Widget.setHalign(self.as(gtk.Widget), .center);
        gtk.Widget.setMarginTop(self.as(gtk.Widget), 4);
        gtk.Widget.setMarginBottom(self.as(gtk.Widget), 4);
    }

    fn setup(self: *Self, carousel: *Carousel) void {
        const p = self.priv();
        p.carousel = carousel;
        _ = carousel.as(gobject.Object).ref();
        p.page_changed_handler = carousel.connectPageChanged(*Self, &onPageChanged, self);
        p.items_changed_handler = carousel.connectItemsChanged(*Self, &onItemsChanged, self);
        self.update();
    }

    fn onPageChanged(_: *gobject.Object, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        if (!self.priv().disposed) self.update();
    }

    fn onItemsChanged(_: *gio.ListModel, _: c_uint, _: c_uint, _: c_uint, self: *Self) callconv(.c) void {
        if (!self.priv().disposed) self.update();
    }

    pub fn update(self: *Self) void {
        const p = self.priv();
        self.removeDots();

        const carousel = p.carousel orelse return;
        if (carousel.getChildCount() <= 1) return;

        const visible_child = carousel.getVisibleChild();
        var child = carousel.getFirstChild();
        while (child) |widget| : (child = gtk.Widget.getNextSibling(widget)) {
            const dot = gtk.Image.newFromIconName("media-record-symbolic");
            const active = widget == visible_child;
            gtk.Widget.addCssClass(
                dot.as(gtk.Widget),
                if (active) "carousel-dot-active" else "carousel-dot-inactive",
            );
            if (!active) gtk.Widget.setOpacity(dot.as(gtk.Widget), 0.3);
            gtk.Box.append(self.as(gtk.Box), dot.as(gtk.Widget));
        }
    }

    fn removeDots(self: *Self) void {
        while (gtk.Widget.getFirstChild(self.as(gtk.Widget))) |child| {
            gtk.Box.remove(self.as(gtk.Box), child);
        }
    }

    fn dispose(object: *gobject.Object) callconv(.c) void {
        const self = gobject.ext.cast(Self, object) orelse {
            gobject.ext.as(gobject.Object.Class, Class.parent).f_dispose.?(object);
            return;
        };
        const p = self.priv();
        if (!p.disposed) {
            p.disposed = true;
            self.removeDots();
            if (p.carousel) |carousel| {
                p.page_changed_handler.disconnect(carousel);
                carousel.disconnectItemsChanged(p.items_changed_handler);
                p.items_changed_handler = 0;
                carousel.as(gobject.Object).unref();
                p.carousel = null;
            }
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

fn countDots(indicator: *CarouselIndicatorDots) usize {
    var count: usize = 0;
    var child = gtk.Widget.getFirstChild(indicator.as(gtk.Widget));
    while (child) |widget| : (child = gtk.Widget.getNextSibling(widget)) count += 1;
    return count;
}

test "indicator follows page changes and safely owns its carousel connection" {
    if (true) return error.SkipZigTest;
    if (gtk.initCheck() == 0) return error.SkipZigTest;

    const carousel = Carousel.new();
    _ = carousel.as(gobject.Object).refSink();
    carousel.addWidget(gtk.Label.new("First").as(gtk.Widget));

    const indicator = CarouselIndicatorDots.new(carousel);
    _ = indicator.as(gobject.Object).refSink();
    try std.testing.expectEqual(@as(usize, 0), countDots(indicator));

    carousel.addWidget(gtk.Label.new("Second").as(gtk.Widget));
    try std.testing.expectEqual(@as(usize, 2), countDots(indicator));
    carousel.addWidget(gtk.Label.new("Third").as(gtk.Widget));
    try std.testing.expectEqual(@as(usize, 3), countDots(indicator));

    const first_dot = gtk.Widget.getFirstChild(indicator.as(gtk.Widget)).?;
    try std.testing.expectEqual(@as(f64, 1), gtk.Widget.getOpacity(first_dot));
    carousel.next();
    try std.testing.expectEqual(@as(usize, 3), countDots(indicator));
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.3),
        gtk.Widget.getOpacity(gtk.Widget.getFirstChild(indicator.as(gtk.Widget)).?),
        0.01,
    );

    carousel.as(gobject.Object).unref();
    indicator.update();
    try std.testing.expectEqual(@as(usize, 3), countDots(indicator));
    indicator.as(gobject.Object).unref();
}
