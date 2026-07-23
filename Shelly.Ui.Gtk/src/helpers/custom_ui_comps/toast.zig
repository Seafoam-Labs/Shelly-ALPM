const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gobject = bindings.gobject;
const glib = bindings.glib;

pub const ToastKind = enum {
    info,
    success,
    warning,
    @"error",
};

const toast_timeout_ms: c_uint = 3000;

pub const ToastAction = struct {
    label: [:0]const u8,
    callback: *const fn (?*anyopaque) void,
    user_data: ?*anyopaque = null,
};

const ToastItem = struct {
    kind: ToastKind,
    message: [:0]const u8,
    action: ?ToastAction,
    timeout_ms: c_uint,
};

pub const Toast = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gtk.Box;

    const Private = struct {
        revealer: *gtk.Revealer,
        card: *gtk.Box,
        message_label: *gtk.Label,
        action_button: *gtk.Button,
        close_button: *gtk.Button,

        hide_source: c_uint,
        remaining_ms: c_uint,
        started_monotonic_us: i64,
        timeout_inhibited_count: u32,

        current_action: ?ToastAction,
        showing: bool,
        disposed: bool,

        queue: std.ArrayList(ToastItem),

        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyToast",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

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
        p.hide_source = 0;
        p.remaining_ms = 0;
        p.started_monotonic_us = 0;
        p.timeout_inhibited_count = 0;
        p.current_action = null;
        p.showing = false;
        p.disposed = false;
        p.queue = .empty;

        gtk.Orientable.setOrientation(self.as(gtk.Orientable), .vertical);
        gtk.Widget.setHexpand(self.as(gtk.Widget), 1);
        gtk.Widget.setVexpand(self.as(gtk.Widget), 1);
        gtk.Widget.setMarginBottom(self.as(gtk.Widget), 20);
        gtk.Widget.setHalign(self.as(gtk.Widget), .center);
        gtk.Widget.setValign(self.as(gtk.Widget), .end);

        const revealer = gtk.Revealer.new();
        gtk.Revealer.setTransitionType(revealer, .slide_up);
        gtk.Revealer.setTransitionDuration(revealer, 250);
        gtk.Revealer.setRevealChild(revealer, 0);
        gtk.Widget.setHalign(revealer.as(gtk.Widget), .center);
        gtk.Widget.setValign(revealer.as(gtk.Widget), .end);
        gtk.Widget.addCssClass(revealer.as(gtk.Widget), "toast-revealer");
        p.revealer = revealer;

        const card = gtk.Box.new(.horizontal, 10);
        gtk.Widget.addCssClass(card.as(gtk.Widget), "toast-card");
        gtk.Widget.setMarginStart(card.as(gtk.Widget), 12);
        gtk.Widget.setMarginEnd(card.as(gtk.Widget), 12);
        gtk.Widget.setMarginTop(card.as(gtk.Widget), 8);
        gtk.Widget.setMarginBottom(card.as(gtk.Widget), 8);
        p.card = card;

        const message_label = gtk.Label.new("");
        gtk.Label.setWrap(message_label, 1);
        gtk.Label.setMaxWidthChars(message_label, 60);
        gtk.Widget.setHexpand(message_label.as(gtk.Widget), 1);
        gtk.Box.append(card, message_label.as(gtk.Widget));
        p.message_label = message_label;

        const action_button = gtk.Button.new();
        gtk.Widget.addCssClass(action_button.as(gtk.Widget), "flat");
        gtk.Widget.setVisible(action_button.as(gtk.Widget), 0);
        gtk.Widget.setFocusOnClick(action_button.as(gtk.Widget), 0);
        gtk.Box.append(card, action_button.as(gtk.Widget));
        p.action_button = action_button;

        const close_button = gtk.Button.newFromIconName("window-close-symbolic");
        gtk.Widget.addCssClass(close_button.as(gtk.Widget), "circular");
        gtk.Widget.addCssClass(close_button.as(gtk.Widget), "flat");
        gtk.Widget.setFocusOnClick(close_button.as(gtk.Widget), 0);
        gtk.Widget.setTooltipText(close_button.as(gtk.Widget), "Dismiss");
        gtk.Box.append(card, close_button.as(gtk.Widget));
        p.close_button = close_button;

        gtk.Revealer.setChild(revealer, card.as(gtk.Widget));
        gtk.Box.append(self.as(gtk.Box), revealer.as(gtk.Widget));

        _ = gtk.Button.signals.clicked.connect(action_button, *Self, &onActionClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(close_button, *Self, &onCloseClicked, self, .{});

        const motion = gtk.EventControllerMotion.new();
        _ = gtk.EventControllerMotion.signals.enter.connect(motion, *Self, &onMotionEnter, self, .{});
        _ = gtk.EventControllerMotion.signals.leave.connect(motion, *Self, &onMotionLeave, self, .{});
        gtk.Widget.addController(card.as(gtk.Widget), motion.as(gtk.EventController));

        const focus = gtk.EventControllerFocus.new();
        _ = gtk.EventControllerFocus.signals.enter.connect(focus, *Self, &onFocusEnter, self, .{});
        _ = gtk.EventControllerFocus.signals.leave.connect(focus, *Self, &onFocusLeave, self, .{});
        gtk.Widget.addController(card.as(gtk.Widget), focus.as(gtk.EventController));

        const click = gtk.GestureClick.new();
        _ = gtk.GestureClick.signals.pressed.connect(click, *Self, &onClickPressed, self, .{});
        _ = gtk.GestureClick.signals.released.connect(click, *Self, &onClickReleased, self, .{});
        gtk.Widget.addController(card.as(gtk.Widget), click.as(gtk.EventController));
    }

    pub fn show(self: *Self, kind: ToastKind, message: [:0]const u8) void {
        self.showWithOptions(kind, message, null, toast_timeout_ms);
    }

    pub fn showWithAction(
        self: *Self,
        kind: ToastKind,
        message: [:0]const u8,
        action: ToastAction,
    ) void {
        self.showWithOptions(kind, message, action, toast_timeout_ms);
    }

    pub fn showWithOptions(
        self: *Self,
        kind: ToastKind,
        message: [:0]const u8,
        action: ?ToastAction,
        timeout_ms: c_uint,
    ) void {
        const p = self.priv();
        if (p.disposed) return;

        const owned = std.heap.c_allocator.dupeSentinel(u8, std.mem.sliceTo(message, 0), 0) catch return;

        const item = ToastItem{
            .kind = kind,
            .message = owned,
            .action = action,
            .timeout_ms = timeout_ms,
        };

        if (!p.showing) {
            self.presentItem(item);
        } else {
            p.queue.append(std.heap.c_allocator, item) catch std.heap.c_allocator.free(owned);
        }
    }

    pub fn hide(self: *Self) void {
        self.dismissCurrent();
    }

    pub fn isShowing(self: *Self) bool {
        return self.priv().showing;
    }

    fn presentItem(self: *Self, item: ToastItem) void {
        const p = self.priv();
        p.showing = true;
        p.timeout_inhibited_count = 0;

        gtk.Widget.removeCssClass(p.card.as(gtk.Widget), "info");
        gtk.Widget.removeCssClass(p.card.as(gtk.Widget), "success");
        gtk.Widget.removeCssClass(p.card.as(gtk.Widget), "warning");
        gtk.Widget.removeCssClass(p.card.as(gtk.Widget), "error");
        gtk.Widget.addCssClass(p.card.as(gtk.Widget), @tagName(item.kind));

        gtk.Label.setLabel(p.message_label, item.message.ptr);

        p.current_action = item.action;
        if (item.action) |a| {
            gtk.Button.setLabel(p.action_button, a.label);
            gtk.Widget.setSensitive(p.action_button.as(gtk.Widget), 1);
            gtk.Widget.setVisible(p.action_button.as(gtk.Widget), 1);
        } else {
            gtk.Widget.setVisible(p.action_button.as(gtk.Widget), 0);
        }

        gtk.Revealer.setRevealChild(p.revealer, 1);

        gtk.Accessible.announce(
            p.revealer.as(gtk.Accessible),
            item.message.ptr,
            .medium,
        );

        p.remaining_ms = item.timeout_ms;
        self.startHideTimeoutIfNeeded();

        std.heap.c_allocator.free(item.message);
    }

    fn dismissCurrent(self: *Self) void {
        const p = self.priv();
        self.cancelHideTimeout();
        self.clearCurrentVisuals();

        if (p.queue.items.len == 0) {
            p.showing = false;
            p.current_action = null;
            return;
        }

        const next = p.queue.orderedRemove(0);
        self.presentItem(next);
    }

    fn clearCurrentVisuals(self: *Self) void {
        const p = self.priv();
        gtk.Revealer.setRevealChild(p.revealer, 0);
        gtk.Widget.setVisible(p.action_button.as(gtk.Widget), 0);
        p.current_action = null;
    }

    fn startHideTimeoutIfNeeded(self: *Self) void {
        const p = self.priv();
        if (p.remaining_ms == 0) return;
        if (p.timeout_inhibited_count > 0) return;
        if (p.hide_source != 0) return;

        p.started_monotonic_us = glib.getMonotonicTime();
        p.hide_source = glib.timeoutAdd(p.remaining_ms, &hideCallback, self);
    }

    fn cancelHideTimeout(self: *Self) void {
        const p = self.priv();
        if (p.hide_source != 0) {
            _ = glib.Source.remove(p.hide_source);
            p.hide_source = 0;
        }
    }

    fn inhibitHide(self: *Self) void {
        const p = self.priv();
        p.timeout_inhibited_count += 1;
        if (p.timeout_inhibited_count == 1) {
            if (p.hide_source != 0 and p.started_monotonic_us != 0) {
                const now = glib.getMonotonicTime();
                const elapsed_us = if (now > p.started_monotonic_us) now - p.started_monotonic_us else 0;
                const elapsed_ms: c_uint = @intCast(@min(@divFloor(elapsed_us, 1000), std.math.maxInt(c_uint)));
                if (elapsed_ms >= p.remaining_ms) {
                    p.remaining_ms = 1;
                } else {
                    p.remaining_ms -= elapsed_ms;
                }
            }
            self.cancelHideTimeout();
        }
    }

    fn uninhibitHide(self: *Self) void {
        const p = self.priv();
        if (p.timeout_inhibited_count == 0) return;
        p.timeout_inhibited_count -= 1;
        if (p.timeout_inhibited_count == 0) {
            self.startHideTimeoutIfNeeded();
        }
    }

    fn hideCallback(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data.?));
        const p = self.priv();
        p.hide_source = 0;
        self.dismissCurrent();
        return 0;
    }

    fn onActionClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.current_action) |a| {
            a.callback(a.user_data);
        }
        self.dismissCurrent();
    }

    fn onCloseClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.dismissCurrent();
    }

    fn onMotionEnter(_: *gtk.EventControllerMotion, _: f64, _: f64, self: *Self) callconv(.c) void {
        self.inhibitHide();
    }

    fn onMotionLeave(_: *gtk.EventControllerMotion, self: *Self) callconv(.c) void {
        self.uninhibitHide();
    }

    fn onFocusEnter(_: *gtk.EventControllerFocus, self: *Self) callconv(.c) void {
        self.inhibitHide();
    }

    fn onFocusLeave(_: *gtk.EventControllerFocus, self: *Self) callconv(.c) void {
        self.uninhibitHide();
    }

    fn onClickPressed(_: *gtk.GestureClick, _: c_int, _: f64, _: f64, self: *Self) callconv(.c) void {
        self.inhibitHide();
    }

    fn onClickReleased(_: *gtk.GestureClick, _: c_int, _: f64, _: f64, self: *Self) callconv(.c) void {
        self.uninhibitHide();
    }

    fn dispose(object: *gobject.Object) callconv(.c) void {
        const self = gobject.ext.cast(Self, object) orelse {
            gobject.ext.as(gobject.Object.Class, Class.parent).f_dispose.?(object);
            return;
        };
        const p = self.priv();
        if (!p.disposed) {
            p.disposed = true;
            self.cancelHideTimeout();

            for (p.queue.items) |item| {
                std.heap.c_allocator.free(item.message);
            }
            p.queue.deinit(std.heap.c_allocator);
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

test "toast reveals on show and hides on dismiss" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;

    const toast = Toast.new();
    _ = toast.as(gobject.Object).refSink();
    defer toast.as(gobject.Object).unref();

    try std.testing.expect(!toast.isShowing());

    toast.show(.info, "Test message");
    try std.testing.expect(toast.isShowing());

    const revealer = gtk.Widget.getFirstChild(toast.as(gtk.Widget)).?;
    try std.testing.expectEqual(@as(c_uint, 1), gtk.Revealer.getRevealChild(revealer));

    toast.hide();
    try std.testing.expect(!toast.isShowing());
    try std.testing.expectEqual(@as(c_uint, 0), gtk.Revealer.getRevealChild(revealer));
}
