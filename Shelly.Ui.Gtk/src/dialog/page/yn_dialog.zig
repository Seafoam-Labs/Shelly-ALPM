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
        check_button: *gtk.CheckButton,
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

    pub fn focusConfirm(self: *Self) void {
        const p = self.priv();
        // A gated confirm button is insensitive and rejects focus; the checkbox
        // is the control the user must act on first.
        if (gtk.Widget.getVisible(p.check_button.as(gtk.Widget)) != 0) {
            _ = gtk.Widget.grabFocus(p.check_button.as(gtk.Widget));
            return;
        }
        _ = gtk.Widget.grabFocus(p.confirm_button.as(gtk.Widget));
    }

    pub fn setButtons(self: *Self, confirm: [:0]const u8, cancel: [:0]const u8) void {
        const p = self.priv();
        gtk.Button.setLabel(p.confirm_button, confirm);
        gtk.Button.setLabel(p.cancel_button, cancel);
    }

    /// Shows an optional checkbox and gates the confirm button on it being
    /// checked (FDE recovery-key gate). Hidden by default, so existing callers
    /// are unaffected.
    pub fn setCheckLabel(self: *Self, label: [:0]const u8) void {
        const p = self.priv();
        gtk.CheckButton.setLabel(p.check_button, label);
        gtk.Widget.setVisible(p.check_button.as(gtk.Widget), 1);
        gtk.Widget.setSensitive(p.confirm_button.as(gtk.Widget), @intFromBool(gtk.CheckButton.getActive(p.check_button) != 0));
    }

    pub fn getChecked(self: *Self) bool {
        return gtk.CheckButton.getActive(self.priv().check_button) != 0;
    }

    pub fn setCancelVisible(self: *Self, visible: bool) void {
        gtk.Widget.setVisible(self.priv().cancel_button.as(gtk.Widget), @intFromBool(visible));
    }

    pub fn setConfirmSensitive(self: *Self, sensitive: bool) void {
        gtk.Widget.setSensitive(self.priv().confirm_button.as(gtk.Widget), @intFromBool(sensitive));
    }

    /// Pango markup message; escape daemon-supplied names with
    /// `glib.markupEscapeText` before interpolating. `new()`/plain label setters
    /// reset use-markup, so callers that never opt in keep plain-text behavior.
    pub fn setMarkupMessage(self: *Self, markup: [:0]const u8) void {
        gtk.Label.setMarkup(self.priv().message_label, markup);
    }

    fn on_check_toggled(self: *Self) callconv(.c) void {
        const p = self.priv();
        gtk.Widget.setSensitive(p.confirm_button.as(gtk.Widget), @intFromBool(gtk.CheckButton.getActive(p.check_button) != 0));
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
        .{ "check_button", @offsetOf(Private, "check_button") },
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
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_check_toggled", @ptrCast(&on_check_toggled));
        }
    };
};

const testing = std.testing;
const gtk_test = @import("../../helpers/gtk_test.zig");

fn noopResponse(_: ?*anyopaque, _: bool) void {}

test "confirm dialog defaults keep the checkbox hidden and cancel visible" {
    try gtk_test.requireDisplay();
    const dialog = ConfirmDialog.new("Title", "Message", &noopResponse, null);
    _ = dialog.as(gobject.Object).refSink();
    defer dialog.as(gobject.Object).unref();
    const p = dialog.priv();
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getVisible(p.check_button.as(gtk.Widget)));
    try testing.expectEqual(@as(c_int, 1), gtk.Widget.getVisible(p.cancel_button.as(gtk.Widget)));
    try testing.expectEqual(@as(c_int, 1), gtk.Widget.getSensitive(p.confirm_button.as(gtk.Widget)));
    try testing.expectEqual(@as(c_int, 0), gtk.Label.getUseMarkup(p.message_label));
    try testing.expect(!dialog.getChecked());
}

test "confirm dialog checkbox gates the confirm button" {
    try gtk_test.requireDisplay();
    const dialog = ConfirmDialog.new("Title", "Message", &noopResponse, null);
    _ = dialog.as(gobject.Object).refSink();
    defer dialog.as(gobject.Object).unref();
    const p = dialog.priv();

    dialog.setCheckLabel("I have recovery keys");
    try testing.expectEqual(@as(c_int, 1), gtk.Widget.getVisible(p.check_button.as(gtk.Widget)));
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getSensitive(p.confirm_button.as(gtk.Widget)));
    try testing.expectEqualStrings("I have recovery keys", std.mem.span(gtk.CheckButton.getLabel(p.check_button).?));

    gtk.CheckButton.setActive(p.check_button, 1);
    try testing.expect(dialog.getChecked());
    try testing.expectEqual(@as(c_int, 1), gtk.Widget.getSensitive(p.confirm_button.as(gtk.Widget)));
    gtk.CheckButton.setActive(p.check_button, 0);
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getSensitive(p.confirm_button.as(gtk.Widget)));
}

test "confirm dialog supports markup messages and info-only mode" {
    try gtk_test.requireDisplay();
    const dialog = ConfirmDialog.new("Title", "Plain", &noopResponse, null);
    _ = dialog.as(gobject.Object).refSink();
    defer dialog.as(gobject.Object).unref();
    const p = dialog.priv();

    dialog.setMarkupMessage("Update <b>Device</b> to version <b>1.2</b>?");
    try testing.expectEqual(@as(c_int, 1), gtk.Label.getUseMarkup(p.message_label));
    // getLabel returns the raw markup; getText returns the rendered text.
    try testing.expectEqualStrings("Update Device to version 1.2?", std.mem.span(gtk.Label.getText(p.message_label)));

    dialog.setCancelVisible(false);
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getVisible(p.cancel_button.as(gtk.Widget)));
    dialog.setConfirmSensitive(false);
    try testing.expectEqual(@as(c_int, 0), gtk.Widget.getSensitive(p.confirm_button.as(gtk.Widget)));
    dialog.setConfirmSensitive(true);
    try testing.expectEqual(@as(c_int, 1), gtk.Widget.getSensitive(p.confirm_button.as(gtk.Widget)));
}
