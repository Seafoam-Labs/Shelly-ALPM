const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gobject = bindings.gobject;
const support = @import("../../pages/support.zig");

pub const AurWarningDialog = extern struct {
    parent_instance: Parent,
    const Self = @This();
    pub const Parent = gtk.Box;
    const resource_path = "/com/shellyorg/shelly/dialog/ui/aur_warning.ui";
    pub const ResponseFn = *const fn (ctx: ?*anyopaque, confirmed: bool) void;

    const Private = struct {
        title_label: *gtk.Label,
        message_label: *gtk.Label,
        link_label: *gtk.Label,
        enable_button: *gtk.Button,
        cancel_button: *gtk.Button,
        on_response: ?ResponseFn,
        ctx: ?*anyopaque,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyAurWarningDialog",
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
        p.on_response = null;
        p.ctx = null;
        _ = gobject.signalConnectData(
            p.link_label.as(gobject.Object),
            "activate-link",
            @ptrCast(&on_activate_link),
            null,
            null,
            .{},
        );
    }

    pub fn new(on_response: ResponseFn, ctx: ?*anyopaque) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const p = self.priv();
        p.on_response = on_response;
        p.ctx = ctx;
        return self;
    }

    pub fn focusCancel(self: *Self) void {
        const p = self.priv();
        _ = gtk.Widget.grabFocus(p.cancel_button.as(gtk.Widget));
    }

    fn on_enable(self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.on_response) |cb| cb(p.ctx, true);
    }

    fn on_cancel(self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.on_response) |cb| cb(p.ctx, false);
    }

    fn on_activate_link(label: *gtk.Label, uri: [*:0]const u8, _: ?*anyopaque) callconv(.c) c_int {
        const root = gtk.Widget.getRoot(label.as(gtk.Widget));
        const parent: ?*gtk.Window = if (root) |r| gobject.ext.cast(gtk.Window, r) else null;
        const launcher = gtk.UriLauncher.new(uri);
        launcher.launch(parent, null, null, null);
        return 1;
    }

    const template_children = .{
        .{ "title_label", @offsetOf(Private, "title_label") },
        .{ "message_label", @offsetOf(Private, "message_label") },
        .{ "link_label", @offsetOf(Private, "link_label") },
        .{ "enable_button", @offsetOf(Private, "enable_button") },
        .{ "cancel_button", @offsetOf(Private, "cancel_button") },
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
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_enable", @ptrCast(&on_enable));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_cancel", @ptrCast(&on_cancel));
        }
    };
};
