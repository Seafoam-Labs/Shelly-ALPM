const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gobject = bindings.gobject;
const support = @import("../../pages/support.zig");

pub const ConfirmDialog = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gtk.Box;
    const resource_path = "/com/shellyorg/shelly/dialog/ui/yn.ui";

    pub const ResponseFn = *const fn (ctx: ?*anyopaque, confirmed: bool) void;

    const Private = struct {
        title_label: *gtk.Label,
        message_label: *gtk.Label,
        confirm_button: *gtk.Button,
        cancel_button: *gtk.Button,
        on_response: ?ResponseFn,
        ctx: ?*anyopaque,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyConfirmDialog",
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
    }

    pub fn new(title: [:0]const u8, message: [:0]const u8, on_response: ResponseFn, ctx: ?*anyopaque) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const p = self.priv();
        gtk.Label.setLabel(p.title_label, title);
        gtk.Label.setLabel(p.message_label, message);
        p.on_response = on_response;
        p.ctx = ctx;
        return self;
    }

    pub fn setButtons(self: *Self, confirm: [:0]const u8, cancel: [:0]const u8) void {
        const p = self.priv();
        gtk.Button.setLabel(p.confirm_button, confirm);
        gtk.Button.setLabel(p.cancel_button, cancel);
    }

    fn on_confirm(self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.on_response) |cb| cb(p.ctx, true);
    }

    fn on_cancel(self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.on_response) |cb| cb(p.ctx, false);
    }

    const template_children = .{
        .{ "title_label", @offsetOf(Private, "title_label") },
        .{ "message_label", @offsetOf(Private, "message_label") },
        .{ "confirm_button", @offsetOf(Private, "confirm_button") },
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
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_confirm", @ptrCast(&on_confirm));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_cancel", @ptrCast(&on_cancel));
        }
    };
};
