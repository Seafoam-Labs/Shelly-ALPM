const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gio = bindings.gio;
const glib = bindings.glib;
const gobject = bindings.gobject;
const gdk = bindings.gdk;
const c_string = @import("../helpers/c_string.zig");
const translations = @import("../helpers/translations.zig");
const support = @import("support.zig");
const ShellyCli = @import("../services/shelly_cli.zig").ShellyCli;
const AurPackage = @import("../models/aur_package.zig").AurPackage;
const SizeConverter = @import("../helpers/size_converts.zig").SizeConverter;
const ShellyWindow = @import("../shelly_window.zig").ShellyWindow;
const ShellyOperation = @import("../services/shelly_operation.zig").ShellyOperation;
const PkgbuildReviewDialog = @import("../dialog/page/preview_pkgbuild.zig").PkgbuildReviewDialog;

pub const PackageDetail = extern struct {
    parent_instance: Parent,
    const Self = @This();
    pub const Parent = gtk.Box;
    const resource_path = "/com/shellyorg/shelly/ui/aur_package_detail.ui";

    const Private = struct {
        content_box: *gtk.Box,
        preview_button: *gtk.Button,
        name_label: *gtk.Label,
        description_label: *gtk.Label,
        spec_box: *gtk.Box,
        sections_box: *gtk.Box,
        base_installed: bool,
        pending_name: [256]u8,
        pending_len: usize,

        arena: ?*std.heap.ArenaAllocator,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyAurPackageDetail",
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

        p.arena = null;

        p.pending_len = 0;

        const group = gio.SimpleActionGroup.new();

        gtk.Widget.insertActionGroup(self.as(gtk.Widget), "detail", group.as(gio.ActionGroup));
        group.as(gobject.Object).unref();
    }

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    pub fn showPackage(self: *Self, package: *const AurPackage) void {
        const p = self.priv();

        if (p.arena) |old| {
            old.deinit();
            std.heap.c_allocator.destroy(old);
        }

        const arena_ptr = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch return;
        arena_ptr.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        p.arena = arena_ptr;

        self.populate(package.*);
    }

    fn populate(self: *Self, package: AurPackage) void {
        const p = self.priv();
        var buf: [512]u8 = undefined;
        var time_buf: [64]u8 = undefined;
        const len = @min(package.Name.len, p.pending_name.len);
        @memcpy(p.pending_name[0..len], package.Name[0..len]);
        p.pending_len = len;

        gtk.Label.setLabel(p.name_label, c_string.cstr(&buf, package.Name));
        p.name_label.setSelectable(1);
        gtk.Label.setLabel(p.description_label, if (package.Description) |desc| c_string.cstr(&buf, desc) else "");

        clear_box(p.spec_box);
        clear_box(p.sections_box);
        add_spec_row(p.spec_box, translations._("Version"), package.Version);
        add_spec_row(p.spec_box, translations._("Votes"), votes_text(&buf, package.NumVotes));
        add_spec_row(p.spec_box, translations._("Popularity"), popularity_text(&buf, package.Popularity));

        add_spec_row(p.spec_box, translations._("Maintainer"), if (package.Maintainer) |maintainer| c_string.cstr(&buf, maintainer) else "");
        add_spec_row(p.spec_box, translations._("Last Modified"), c_string.cstr(&buf, formatIsoDateTime(&time_buf, package.LastModified) catch ""));
        add_spec_row(p.spec_box, translations._("First Submitted"), c_string.cstr(&buf, formatIsoDateTime(&time_buf, package.FirstSubmitted) catch ""));

        add_url_spec_row(p.spec_box, translations._("URL"), if (package.Url) |u| c_string.cstr(&buf, u) else "");

        const allocator = (p.arena orelse return).allocator();

        const combined = std.mem.concat(allocator, u8, &.{ "https://aur.archlinux.org/packages/", package.Name }) catch "";
        add_url_spec_row(p.spec_box, translations._("AUR"), c_string.cstr(&buf, combined));

        const alloc = (p.arena orelse return).allocator();
        add_spec_list(p.spec_box, alloc, translations._("Licenses"), if (package.License) |license| license else &.{});

        add_list_section(p.sections_box, self, translations._("Depends"), if (package.Depends) |deps| deps else &.{});
        add_list_section(p.sections_box, self, translations._("Optional Depends"), if (package.OptDepends) |optDeps| optDeps else &.{});
        add_list_section(p.sections_box, self, translations._("Make Depends"), if (package.MakeDepends) |make| make else &.{});
    }

    fn votes_text(buf: []u8, votes: u32) [:0]const u8 {
        return std.fmt.bufPrintZ(buf, "{d}", .{votes}) catch "";
    }

    fn popularity_text(buf: []u8, popularity: f64) [:0]const u8 {
        return std.fmt.bufPrintZ(buf, "{d:.2}", .{popularity}) catch "";
    }

    fn formatIsoDateTime(buffer: []u8, seconds: i64) ![]const u8 {
        if (seconds < 0) return std.fmt.bufPrint(buffer, "1970-01-01T00:00:00", .{});
        const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
        const year_day = epoch.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_seconds = epoch.getDaySeconds();
        return std.fmt.bufPrint(
            buffer,
            "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}",
            .{
                year_day.year,
                month_day.month.numeric(),
                month_day.day_index + 1,
                day_seconds.getHoursIntoDay(),
                day_seconds.getMinutesIntoHour(),
                day_seconds.getSecondsIntoMinute(),
            },
        );
    }

    fn add_spec_row(box: *gtk.Box, label: []const u8, value: [:0]const u8) void {
        var lbuf: [64]u8 = undefined;
        const row = gtk.Box.new(.horizontal, 8);
        gtk.Widget.setMarginTop(row.as(gtk.Widget), 10);
        gtk.Widget.setMarginBottom(row.as(gtk.Widget), 10);
        gtk.Widget.addCssClass(row.as(gtk.Widget), "spec-row");
        const key = gtk.Label.new(c_string.cstr(&lbuf, label));
        gtk.Widget.setHalign(key.as(gtk.Widget), .start);
        gtk.Label.setXalign(key, 0);
        gtk.Widget.addCssClass(key.as(gtk.Widget), "dim-label");
        gtk.Box.append(row, key.as(gtk.Widget));
        const val = gtk.Label.new(value);
        gtk.Widget.setHalign(val.as(gtk.Widget), .end);
        gtk.Widget.setHexpand(val.as(gtk.Widget), 1);
        gtk.Label.setXalign(val, 1);
        gtk.Label.setEllipsize(val, .end);
        gtk.Widget.addCssClass(val.as(gtk.Widget), "spec-value");
        gtk.Box.append(row, val.as(gtk.Widget));
        gtk.Box.append(box, row.as(gtk.Widget));
    }

    fn add_url_spec_row(box: *gtk.Box, label: []const u8, value: [:0]const u8) void {
        var lbuf: [64]u8 = undefined;
        const row = gtk.Box.new(.horizontal, 8);
        gtk.Widget.setMarginTop(row.as(gtk.Widget), 10);
        gtk.Widget.setMarginBottom(row.as(gtk.Widget), 10);
        gtk.Widget.addCssClass(row.as(gtk.Widget), "spec-row");
        const key = gtk.Label.new(c_string.cstr(&lbuf, label));
        gtk.Widget.setHalign(key.as(gtk.Widget), .start);
        gtk.Label.setXalign(key, 0);
        gtk.Widget.addCssClass(key.as(gtk.Widget), "dim-label");
        gtk.Box.append(row, key.as(gtk.Widget));

        var mbuf: [256]u8 = undefined;
        const markup = std.fmt.bufPrintZ(&mbuf, "<a href=\"{s}\">{s}</a>", .{ value, value }) catch value;
        const val = gtk.Label.new(null);
        gtk.Label.setMarkup(val, markup);
        gtk.Widget.setHalign(val.as(gtk.Widget), .end);
        gtk.Widget.setHexpand(val.as(gtk.Widget), 1);
        gtk.Label.setXalign(val, 1);
        gtk.Label.setEllipsize(val, .end);

        gtk.Box.append(row, val.as(gtk.Widget));

        gtk.Box.append(box, row.as(gtk.Widget));
    }

    fn add_spec_list(box: *gtk.Box, allocator: std.mem.Allocator, label: []const u8, items: []const [:0]const u8) void {
        if (items.len == 0) return;
        var joined: std.ArrayListUnmanaged(u8) = .empty;
        defer joined.deinit(allocator);
        for (items, 0..) |item, i| {
            if (i > 0) joined.appendSlice(allocator, ", ") catch return;
            joined.appendSlice(allocator, item) catch return;
        }
        joined.append(allocator, 0) catch return;
        const value: [:0]const u8 = joined.items[0 .. joined.items.len - 1 :0];
        add_spec_row_raw(box, label, value);
    }

    fn add_spec_row_raw(box: *gtk.Box, label: []const u8, value: [:0]const u8) void {
        var lbuf: [64]u8 = undefined;
        const row = gtk.Box.new(.horizontal, 8);
        gtk.Widget.setMarginTop(row.as(gtk.Widget), 10);
        gtk.Widget.setMarginBottom(row.as(gtk.Widget), 10);
        gtk.Widget.addCssClass(row.as(gtk.Widget), "spec-row");
        const key = gtk.Label.new(c_string.cstr(&lbuf, label));
        gtk.Widget.setHalign(key.as(gtk.Widget), .start);
        gtk.Widget.setValign(key.as(gtk.Widget), .start);
        gtk.Label.setXalign(key, 0);
        gtk.Widget.addCssClass(key.as(gtk.Widget), "dim-label");
        gtk.Box.append(row, key.as(gtk.Widget));
        const val = gtk.Label.new(value);
        gtk.Widget.setHalign(val.as(gtk.Widget), .end);
        gtk.Widget.setHexpand(val.as(gtk.Widget), 1);
        gtk.Label.setXalign(val, 1);
        gtk.Label.setWrap(val, 1);
        gtk.Label.setJustify(val, .right);
        gtk.Widget.addCssClass(val.as(gtk.Widget), "spec-value");
        gtk.Box.append(row, val.as(gtk.Widget));
        gtk.Box.append(box, row.as(gtk.Widget));
    }

    fn add_list_section(box: *gtk.Box, page: *PackageDetail, title: []const u8, items: []const [:0]const u8) void {
        if (items.len == 0) return;

        var buf: [64]u8 = undefined;
        const header = std.fmt.bufPrintZ(&buf, "{s} ({d})", .{ title, items.len }) catch translations._("Section");
        const expander = gtk.Expander.new(header);
        gtk.Expander.setExpanded(expander, 0);
        gtk.Widget.addCssClass(expander.as(gtk.Widget), "spec-expander");

        const list = gtk.Box.new(.vertical, 0);
        gtk.Widget.setMarginStart(list.as(gtk.Widget), 8);

        for (items) |item| {
            const dep_name = strip_version(item);

            const navigable = std.mem.indexOf(u8, dep_name, ".so") == null and dep_name.len > 0;

            if (navigable) {
                const row_btn = gtk.Button.new();
                gtk.Widget.addCssClass(row_btn.as(gtk.Widget), "flat");
                gtk.Widget.addCssClass(row_btn.as(gtk.Widget), "dep-row");
                gtk.Widget.setHalign(row_btn.as(gtk.Widget), .fill);

                const lbl = gtk.Label.new(item);
                gtk.Widget.setHalign(lbl.as(gtk.Widget), .start);
                gtk.Label.setXalign(lbl, 0);
                gtk.Label.setEllipsize(lbl, .end);
                gtk.Widget.addCssClass(lbl.as(gtk.Widget), "spec-value");
                gtk.Button.setChild(row_btn, lbl.as(gtk.Widget));
                const name_owned = std.heap.c_allocator.dupeZ(u8, dep_name) catch continue;
                gobject.Object.setDataFull(row_btn.as(gobject.Object), "dep-name", name_owned.ptr, &free_dep_name);
                gobject.Object.setData(row_btn.as(gobject.Object), "page", page);
                gtk.Box.append(list, row_btn.as(gtk.Widget));
            } else {
                const lbl = gtk.Label.new(item);
                gtk.Widget.setHalign(lbl.as(gtk.Widget), .start);
                gtk.Label.setXalign(lbl, 0);
                gtk.Label.setEllipsize(lbl, .end);
                gtk.Widget.addCssClass(lbl.as(gtk.Widget), "spec-value");
                gtk.Widget.addCssClass(lbl.as(gtk.Widget), "dim-label");
                gtk.Widget.addCssClass(lbl.as(gtk.Widget), "dep-row-static");
                gtk.Box.append(list, lbl.as(gtk.Widget));
            }
        }

        if (items.len > 8) {
            const scroll = gtk.ScrolledWindow.new();
            gtk.ScrolledWindow.setChild(scroll, list.as(gtk.Widget));
            gtk.ScrolledWindow.setPolicy(scroll, .never, .automatic);
            gtk.ScrolledWindow.setMinContentHeight(scroll, 200);
            gtk.ScrolledWindow.setMaxContentHeight(scroll, 300);
            gtk.ScrolledWindow.setPropagateNaturalHeight(scroll, 0);
            gtk.Expander.setChild(expander, scroll.as(gtk.Widget));
        } else {
            gtk.Expander.setChild(expander, list.as(gtk.Widget));
        }

        gtk.Box.append(box, expander.as(gtk.Widget));
    }

    fn free_dep_name(ptr: ?*anyopaque) callconv(.c) void {
        const p: [*:0]u8 = @ptrCast(ptr orelse return);
        std.heap.c_allocator.free(std.mem.span(p));
    }

    fn strip_version(item: []const u8) []const u8 {
        const desc_end = std.mem.indexOfScalar(u8, item, ':') orelse item.len;
        var name = std.mem.trim(u8, item[0..desc_end], " ");

        const ops = [_][]const u8{ ">=", "<=", "=", ">", "<" };
        var cut: usize = name.len;
        for (ops) |op| {
            if (std.mem.indexOf(u8, name, op)) |idx| {
                if (idx < cut) cut = idx;
            }
        }
        return std.mem.trim(u8, name[0..cut], " ");
    }

    fn clear_box(box: *gtk.Box) void {
        while (gtk.Widget.getFirstChild(box.as(gtk.Widget))) |child| {
            gtk.Box.remove(box, child);
        }
    }

    fn on_preview_package_build(self: *Self) callconv(.c) void {
        const dialog = PkgbuildReviewDialog.new();
        if (support.getWindow(ShellyWindow, self)) |win| {
            gtk.Window.setTransientFor(dialog.as(gtk.Window), win.as(gtk.Window));
        }
        dialog.showPreview(self.priv().pending_name[0..self.priv().pending_len]);
        dialog.present();
    }

    fn finalize(self: *Self) callconv(.c) void {
        const p = self.priv();

        if (p.arena) |a| {
            a.deinit();
            std.heap.c_allocator.destroy(a);
            p.arena = null;
        }
        const parent_class: *gobject.Object.Class = @ptrCast(Class.parent);
        gobject.Object.virtual_methods.finalize.call(parent_class, self.as(gobject.Object));
    }

    const template_children = .{
        .{ "name_label", @offsetOf(Private, "name_label") },
        .{ "description_label", @offsetOf(Private, "description_label") },
        .{ "spec_box", @offsetOf(Private, "spec_box") },
        .{ "sections_box", @offsetOf(Private, "sections_box") },
        .{ "content_box", @offsetOf(Private, "content_box") },
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
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "preview_package_build", @ptrCast(&on_preview_package_build));
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
    };
};
