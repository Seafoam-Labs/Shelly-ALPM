const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gobject = bindings.gobject;
const support = @import("../../pages/support.zig");
const shelly_operation = @import("../../services/shelly_operation.zig");
const TransactionQuestion = shelly_operation.TransactionQuestion;
const TransactionPackage = shelly_operation.TransactionPackage;
const SizeConverter = @import("../../helpers/size_converts.zig").SizeConverter;
const translations = @import("../../helpers/translations.zig");

pub const PlanDialog = extern struct {
    parent_instance: Parent,
    const Self = @This();
    pub const Parent = gtk.Box;
    const resource_path = "/com/shellyorg/shelly/dialog/ui/plan_dialog.ui";

    pub const ResponseFn = *const fn (ctx: ?*anyopaque, confirmed: bool) void;

    const Private = struct {
        title_label: *gtk.Label,
        summary_label: *gtk.Label,
        plan_list: *gtk.Box,
        cancel_button: *gtk.Button,
        confirm_button: *gtk.Button,
        on_response: ?ResponseFn,
        ctx: ?*anyopaque,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyPlanDialog",
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

    /// Borrows `question`; everything is copied into widgets before returning,
    /// so the caller may free the question immediately after.
    pub fn new(
        question: TransactionQuestion,
        on_response: ResponseFn,
        ctx: ?*anyopaque,
    ) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const p = self.priv();
        p.on_response = on_response;
        p.ctx = ctx;

        var title_buf: [256]u8 = undefined;
        const title = std.fmt.bufPrintZ(&title_buf, "{s}", .{question.question_text}) catch "";
        gtk.Label.setLabel(p.title_label, title);

        set_summary(p, question);
        add_plan_rows(p, question.packages);
        return self;
    }

    fn set_summary(p: *Private, q: TransactionQuestion) void {
        var dl_buf: [32]u8 = undefined;
        var net_buf: [32]u8 = undefined;
        var buf: [256]u8 = undefined;

        if (std.mem.eql(u8, q.action, "remove")) {
            const removed = if (q.total_installed_size) |size|
                SizeConverter.convert_null_term(&dl_buf, @intCast(size))
            else
                translations._("Unknown");
            const text = std.fmt.bufPrintZ(&buf, "{d} {s} {s} {s} — {s} {s}", .{
                q.packages.len,
                translations._("package(s)"),
                translations._("to"),
                q.action,
                removed,
                translations._("removed size"),
            }) catch "";
            gtk.Label.setLabel(p.summary_label, text);
            return;
        }

        const dl = SizeConverter.convert_null_term(&dl_buf, @intCast(q.total_download_size orelse 0));
        const net = SizeConverter.convert_null_term(&net_buf, q.net_installed_size orelse 0);

        const text = std.fmt.bufPrintZ(
            &buf,
            "{d} {s} {s} {s} — {s} {s}, {s} {s}",
            .{
                q.packages.len,
                translations._("package(s)"),
                translations._("to"),
                q.action,
                dl,
                translations._("download"),
                net,
                translations._("net"),
            },
        ) catch "";
        gtk.Label.setLabel(p.summary_label, text);
    }

    fn add_plan_rows(p: *Private, packages: []TransactionPackage) void {
        for (packages) |pkg| {
            gtk.Box.append(p.plan_list, make_row(pkg));
        }
    }

    fn make_row(pkg: TransactionPackage) *gtk.Widget {
        const row = gtk.Box.new(.horizontal, 8);
        gtk.Widget.setMarginStart(row.as(gtk.Widget), 8);
        gtk.Widget.setMarginTop(row.as(gtk.Widget), 2);
        gtk.Widget.setMarginBottom(row.as(gtk.Widget), 2);

        var name_buf: [160]u8 = undefined;
        const name_z = if (pkg.version) |v|
            std.fmt.bufPrintZ(&name_buf, "{s}  {s}", .{ pkg.name, v }) catch pkg_name_fallback(&name_buf, pkg.name)
        else
            pkg_name_fallback(&name_buf, pkg.name);
        const name = gtk.Label.new(name_z);
        gtk.Label.setXalign(name, 0);
        gtk.Widget.setHexpand(name.as(gtk.Widget), 1);
        gtk.Box.append(row, name.as(gtk.Widget));

        if (pkg.repository) |repo| {
            var repo_buf: [64]u8 = undefined;
            const repo_z = std.fmt.bufPrintZ(&repo_buf, "{s}", .{repo}) catch "";
            const repo_label = gtk.Label.new(repo_z);
            gtk.Widget.addCssClass(repo_label.as(gtk.Widget), "dim-label");
            gtk.Box.append(row, repo_label.as(gtk.Widget));
        }

        const size = pkg.download_size orelse pkg.installed_size;
        if (size) |s| {
            var size_buf: [32]u8 = undefined;
            const size_z = SizeConverter.convert_null_term(&size_buf, @intCast(s));
            const size_label = gtk.Label.new(size_z);
            gtk.Widget.addCssClass(size_label.as(gtk.Widget), "dim-label");
            gtk.Box.append(row, size_label.as(gtk.Widget));
        }

        return row.as(gtk.Widget);
    }

    fn pkg_name_fallback(buf: []u8, name: []const u8) [:0]const u8 {
        return std.fmt.bufPrintZ(buf, "{s}", .{name}) catch "";
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
        .{ "summary_label", @offsetOf(Private, "summary_label") },
        .{ "plan_list", @offsetOf(Private, "plan_list") },
        .{ "cancel_button", @offsetOf(Private, "cancel_button") },
        .{ "confirm_button", @offsetOf(Private, "confirm_button") },
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
