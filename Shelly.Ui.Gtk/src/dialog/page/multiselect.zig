const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gobject = bindings.gobject;
const c_string = @import("../../helpers/c_string.zig");
const support = @import("../../pages/support.zig");
const ShellyOperation = @import("../../services/shelly_operation.zig").ShellyOperation;
const Option = @import("../../services/shelly_operation.zig").Option;

pub const MultiSelectDialog = extern struct {
    parent_instance: Parent,
    const Self = @This();
    pub const Parent = gtk.Box;
    const resource_path = "/com/shellyorg/shelly/dialog/ui/multiselect.ui";

    pub const ResponseFn = *const fn (ctx: ?*anyopaque, confirmed: bool, selected: []const usize) void;

    const Private = struct {
        title_label: *gtk.Label,
        options_box: *gtk.Box,
        confirm_button: *gtk.Button,
        cancel_button: *gtk.Button,
        on_response: ?ResponseFn,
        ctx: ?*anyopaque,
        checks: []*gtk.CheckButton,
        indices: []usize,
        checks_len: usize,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyMultiSelectDialog",
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
        p.checks = &.{};
        p.indices = &.{};
        p.checks_len = 0;
    }

    pub fn new(
        alloc: std.mem.Allocator,
        title: []const u8,
        options: []const Option,
        on_response: ResponseFn,
        ctx: ?*anyopaque,
    ) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const p = self.priv();

        var tbuf: [512]u8 = undefined;
        gtk.Label.setLabel(p.title_label, c_string.cstr(&tbuf, title));

        p.on_response = on_response;
        p.ctx = ctx;
        
        p.checks = alloc.alloc(*gtk.CheckButton, options.len) catch &.{};
        p.indices = alloc.alloc(usize, options.len) catch &.{};
        p.checks_len = if (p.checks.len == options.len and p.indices.len == options.len) options.len else 0;

        for (options, 0..) |opt, i| {
            const row = gtk.Box.new(.horizontal, 8);

            const check = gtk.CheckButton.new();
            gtk.CheckButton.setActive(check, @intFromBool(opt.is_selected or opt.is_installed));
            gtk.Widget.setValign(check.as(gtk.Widget), .start);
            gtk.Box.append(row, check.as(gtk.Widget));

            // name + description stacked
            const textbox = gtk.Box.new(.vertical, 2);
            gtk.Widget.setHexpand(textbox.as(gtk.Widget), 1);

            var nbuf: [256]u8 = undefined;
            const name = gtk.Label.new(c_string.cstr(&nbuf, opt.name));
            gtk.Widget.setHalign(name.as(gtk.Widget), .start);
            gtk.Label.setXalign(name, 0);
            gtk.Widget.addCssClass(name.as(gtk.Widget), "spec-value");
            gtk.Box.append(textbox, name.as(gtk.Widget));

            if (opt.description.len > 0) {
                var dbuf: [512]u8 = undefined;
                const desc = gtk.Label.new(c_string.cstr(&dbuf, opt.description));
                gtk.Widget.setHalign(desc.as(gtk.Widget), .start);
                gtk.Label.setXalign(desc, 0);
                gtk.Label.setWrap(desc, 1);
                gtk.Widget.addCssClass(desc.as(gtk.Widget), "dim-label");
                gtk.Box.append(textbox, desc.as(gtk.Widget));
            }

            gtk.Box.append(row, textbox.as(gtk.Widget));
            gtk.Box.append(p.options_box, row.as(gtk.Widget));

            if (p.checks_len > 0) {
                p.checks[i] = check;
                p.indices[i] = opt.index;
            }
        }

        return self;
    }

    fn on_confirm(self: *Self) callconv(.c) void {
        const p = self.priv();
        var selected: [256]usize = undefined;
        var count: usize = 0;
        var i: usize = 0;
        while (i < p.checks_len and count < selected.len) : (i += 1) {
            if (gtk.CheckButton.getActive(p.checks[i]) != 0) {
                selected[count] = p.indices[i];
                count += 1;
            }
        }
        if (p.on_response) |cb| cb(p.ctx, true, selected[0..count]);
    }

    fn on_cancel(self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.on_response) |cb| cb(p.ctx, false, &.{});
    }

    const template_children = .{
        .{ "title_label", @offsetOf(Private, "title_label") },
        .{ "options_box", @offsetOf(Private, "options_box") },
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
