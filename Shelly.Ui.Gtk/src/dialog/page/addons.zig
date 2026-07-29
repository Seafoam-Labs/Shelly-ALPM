const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gobject = bindings.gobject;
const support = @import("../../pages/support.zig");
const translations = @import("../../helpers/translations.zig");
const flatpak = @import("../../models/flatpak.zig");

pub const AddonInstallFn = *const fn (ctx: ?*anyopaque, addon: *const flatpak.AppstreamApp, button: *gtk.Button) void;

pub const AddonsDialog = extern struct {
    parent_instance: Parent,
    const Self = @This();
    pub const Parent = gtk.Box;
    const resource_path = "/com/shellyorg/shelly/dialog/ui/addons.ui";

    pub const CloseFn = *const fn (ctx: ?*anyopaque) void;

    const Private = struct {
        title_label: *gtk.Label,
        subtitle_label: *gtk.Label,
        addons_stack: *gtk.Stack,
        addons_list: *gtk.ListBox,
        close_button: *gtk.Button,
        on_close: ?CloseFn,
        ctx: ?*anyopaque,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyAddonsDialog",
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
        p.on_close = null;
        p.ctx = null;
    }

    /// Borrows `addons`; strings are copied into labels before returning.
    /// The caller must keep `addons` alive while `on_install` may still fire
    /// (in practice the selected app object owns this memory).
    pub fn new(title: [:0]const u8, subtitle: [:0]const u8, addons: []const flatpak.AppstreamApp, on_install: AddonInstallFn, on_close_fn: CloseFn, ctx: ?*anyopaque) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const p = self.priv();
        gtk.Label.setLabel(p.title_label, title);
        gtk.Label.setLabel(p.subtitle_label, subtitle);
        p.on_close = on_close_fn;
        p.ctx = ctx;

        var shown: usize = 0;
        for (addons) |*addon| {
            if (addon.Id.len == 0) continue;
            gtk.ListBox.append(p.addons_list, make_row(addon, on_install, ctx));
            shown += 1;
        }

        gtk.Stack.setVisibleChildName(p.addons_stack, if (shown == 0) "empty" else "list");
        return self;
    }

    fn make_row(addon: *const flatpak.AppstreamApp, on_install: AddonInstallFn, ctx: ?*anyopaque) *gtk.Widget {
        const row = gtk.ListBoxRow.new();
        const box = gtk.Box.new(.horizontal, 12);
        gtk.Widget.setMarginStart(box.as(gtk.Widget), 12);
        gtk.Widget.setMarginEnd(box.as(gtk.Widget), 12);
        gtk.Widget.setMarginTop(box.as(gtk.Widget), 10);
        gtk.Widget.setMarginBottom(box.as(gtk.Widget), 10);

        const text = gtk.Box.new(.vertical, 2);
        gtk.Widget.setHexpand(text.as(gtk.Widget), 1);

        var name_buffer: [512]u8 = undefined;
        const name_z = std.fmt.bufPrintZ(&name_buffer, "{s}", .{if (addon.Name.len > 0) addon.Name else addon.Id}) catch "";
        const name_label = gtk.Label.new(name_z);
        gtk.Label.setXalign(name_label, 0);
        gtk.Label.setWrap(name_label, 1);
        gtk.Widget.addCssClass(name_label.as(gtk.Widget), "heading");
        gtk.Box.append(text, name_label.as(gtk.Widget));

        if (addon.Summary.len > 0) {
            var summary_buffer: [1024]u8 = undefined;
            const summary_z = std.fmt.bufPrintZ(&summary_buffer, "{s}", .{addon.Summary}) catch "";
            const summary_label = gtk.Label.new(summary_z);
            gtk.Label.setXalign(summary_label, 0);
            gtk.Label.setWrap(summary_label, 1);
            gtk.Widget.addCssClass(summary_label.as(gtk.Widget), "dim-label");
            gtk.Box.append(text, summary_label.as(gtk.Widget));
        }

        if (addon.Name.len > 0) {
            var id_buffer: [512]u8 = undefined;
            const id_z = std.fmt.bufPrintZ(&id_buffer, "{s}", .{addon.Id}) catch "";
            const id_label = gtk.Label.new(id_z);
            gtk.Label.setXalign(id_label, 0);
            gtk.Label.setWrap(id_label, 1);
            gtk.Widget.addCssClass(id_label.as(gtk.Widget), "dim-label");
            gtk.Widget.addCssClass(id_label.as(gtk.Widget), "caption");
            gtk.Box.append(text, id_label.as(gtk.Widget));
        }

        gtk.Box.append(box, text.as(gtk.Widget));

        const install_button = gtk.Button.new();
        gtk.Button.setLabel(install_button, translations._("Install"));
        gtk.Widget.setValign(install_button.as(gtk.Widget), .center);
        gtk.Widget.addCssClass(install_button.as(gtk.Widget), "suggested-action");

        const ctx_box = std.heap.c_allocator.create(InstallCtx) catch return row.as(gtk.Widget);
        ctx_box.* = .{ .addon = addon, .handler = on_install, .ctx = ctx };
        _ = gtk.Button.signals.clicked.connect(install_button, *InstallCtx, &on_install_clicked, ctx_box, .{ .destroyData = &destroy_install_ctx });

        gtk.Box.append(box, install_button.as(gtk.Widget));
        gtk.ListBoxRow.setChild(row, box.as(gtk.Widget));
        return row.as(gtk.Widget);
    }

    const InstallCtx = struct {
        addon: *const flatpak.AppstreamApp,
        handler: AddonInstallFn,
        ctx: ?*anyopaque,
    };

    fn on_install_clicked(button: *gtk.Button, data: *InstallCtx) callconv(.c) void {
        gtk.Widget.setSensitive(button.as(gtk.Widget), 0);
        data.handler(data.ctx, data.addon, button);
    }

    fn destroy_install_ctx(data: *InstallCtx) callconv(.c) void {
        std.heap.c_allocator.destroy(data);
    }

    fn on_close(self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.on_close) |cb| cb(p.ctx);
    }

    const template_children = .{
        .{ "title_label", @offsetOf(Private, "title_label") },
        .{ "subtitle_label", @offsetOf(Private, "subtitle_label") },
        .{ "addons_stack", @offsetOf(Private, "addons_stack") },
        .{ "addons_list", @offsetOf(Private, "addons_list") },
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
