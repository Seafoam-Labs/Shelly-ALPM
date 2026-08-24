const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gio = bindings.gio;
const glib = bindings.glib;
const gobject = bindings.gobject;
const gdk = bindings.gdk;
const c_string = @import("../helpers/c_string.zig");
const support = @import("support.zig");
const ShellyCli = @import("../services/shelly_cli.zig").ShellyCli;
const Package = @import("../models/packages.zig").Package;
const SizeConverter = @import("../helpers/size_converts.zig").SizeConverter;
const ShellyWindow = @import("../shelly_window.zig").ShellyWindow;
const ShellyOperation = @import("../services/shelly_operation.zig").ShellyOperation;
const translations = @import("../helpers/translations.zig");

pub const PackageDetail = extern struct {
    parent_instance: Parent,
    const Self = @This();
    pub const Parent = gtk.Box;
    const resource_path = "/com/shellyorg/shelly/ui/package_detail.ui";

    const Private = struct {
        content_box: *gtk.Box,
        icon: *gtk.Image,
        name_label: *gtk.Label,
        description_label: *gtk.Label,
        spec_box: *gtk.Box,
        sections_box: *gtk.Box,

        reinstall_action: *gio.SimpleAction,
        add_ignore_action: *gio.SimpleAction,
        add_hold_action: *gio.SimpleAction,
        add_explicit_action: *gio.SimpleAction,
        mark_dependency_action: *gio.SimpleAction,

        back_button: *gtk.Button,
        actions_button: *gtk.MenuButton,

        debounce_source: c_uint,
        base_installed: bool,
        nav_stack: std.ArrayListUnmanaged([]const u8),
        pending_name: [256]u8,
        pending_len: usize,
        generation: u64,
        arena: ?*std.heap.ArenaAllocator,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyPackageDetail",
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
        p.generation = 0;
        p.arena = null;
        p.debounce_source = 0;
        p.pending_len = 0;

        const group = gio.SimpleActionGroup.new();

        p.reinstall_action = addAction(self, group, "reinstall", &on_reinstall);
        p.add_ignore_action = addAction(self, group, "addignore", &on_add_ignore);
        p.add_hold_action = addAction(self, group, "addhold", &on_add_hold);
        p.add_explicit_action = addAction(self, group, "addexplicit", &on_add_explicit);
        p.mark_dependency_action = addAction(self, group, "dependency", &on_mark_dependency);

        gtk.Widget.insertActionGroup(self.as(gtk.Widget), "detail", group.as(gio.ActionGroup));
        _ = gtk.Button.signals.clicked.connect(p.back_button, *Self, &on_back_clicked, self, .{});
        group.as(gobject.Object).unref();
    }

    fn addAction(
        self: *Self,
        group: *gio.SimpleActionGroup,
        name: [:0]const u8,
        handler: *const fn (*gio.SimpleAction, ?*glib.Variant, *Self) callconv(.c) void,
    ) *gio.SimpleAction {
        const action = gio.SimpleAction.new(name, null);
        _ = gio.SimpleAction.signals.activate.connect(action, *Self, handler, self, .{});
        gio.ActionMap.addAction(group.as(gio.ActionMap), action.as(gio.Action));
        action.as(gobject.Object).unref(); // group holds the ref now
        return action;
    }

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    pub fn showPackage(self: *Self, name: []const u8, is_installed: bool, icon_path: ?[:0]const u8) void {
        const p = self.priv();
        clear_nav_stack(self);
        p.base_installed = is_installed;
        self.show_package_internal(name, is_installed, icon_path);
        update_nav(self);
    }

    fn show_package_internal(self: *Self, name: []const u8, is_installed: bool, icon_path: ?[:0]const u8) void {
        const p = self.priv();
        const len = @min(name.len, p.pending_name.len);
        @memset(&p.pending_name, 0);
        @memcpy(p.pending_name[0..len], name[0..len]);
        p.pending_len = len;
        if (icon_path) |path| {
            gtk.Image.setFromFile(p.icon, path);
        } else {
            gtk.Image.setFromIconName(p.icon, "package-x-generic");
        }
        var buf: [256]u8 = undefined;
        gtk.Label.setLabel(p.name_label, c_string.cstr(&buf, name));
        gtk.Label.setLabel(p.description_label, translations._("Loading..."));
        clear_box(p.spec_box);
        clear_box(p.sections_box);
        gio.SimpleAction.setEnabled(p.reinstall_action, @intFromBool(is_installed));
        gio.SimpleAction.setEnabled(p.add_explicit_action, @intFromBool(is_installed));
        gio.SimpleAction.setEnabled(p.mark_dependency_action, @intFromBool(is_installed));
        gio.SimpleAction.setEnabled(p.add_hold_action, @intFromBool(is_installed));
        if (p.debounce_source != 0) {
            _ = glib.Source.remove(p.debounce_source);
            p.debounce_source = 0;
        }
        p.debounce_source = glib.timeoutAdd(150, &on_debounce, self);
    }

    fn on_debounce(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data.?));
        const p = self.priv();
        p.debounce_source = 0;

        const name = p.pending_name[0..p.pending_len];

        p.generation += 1;
        const gen = p.generation;

        const name_copy = std.heap.c_allocator.dupe(u8, name) catch return 0;
        const thread = std.Thread.spawn(.{}, worker, .{ self, name_copy, gen }) catch {
            std.heap.c_allocator.free(name_copy);
            return 0;
        };
        thread.detach();

        return 0;
    }

    fn worker(page: *Self, name: []const u8, gen: u64) void {
        defer std.heap.c_allocator.free(name);

        const arena_ptr = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch return;
        arena_ptr.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        const alloc = arena_ptr.allocator();

        var threaded: std.Io.Threaded = .init(alloc, .{});
        defer threaded.deinit();
        const cli = ShellyCli{ .allocator = alloc, .io = threaded.io() };

        const parsed = cli.get_package_details(name) catch {
            arena_ptr.deinit();
            std.heap.c_allocator.destroy(arena_ptr);
            return;
        };

        post_result(page, parsed.value, arena_ptr, gen);
    }

    const Result = struct { page: *Self, package: Package, arena: *std.heap.ArenaAllocator, generation: u64 };

    fn post_result(page: *Self, package: Package, arena: *std.heap.ArenaAllocator, gen: u64) void {
        const r = std.heap.c_allocator.create(Result) catch {
            arena.deinit();
            std.heap.c_allocator.destroy(arena);
            return;
        };
        r.* = .{ .page = page, .package = package, .arena = arena, .generation = gen };
        _ = glib.idleAdd(&on_complete, r);
    }

    fn on_complete(data: ?*anyopaque) callconv(.c) c_int {
        const r: *Result = @ptrCast(@alignCast(data.?));
        defer std.heap.c_allocator.destroy(r);
        const p = r.page.priv();

        if (r.generation != p.generation) {
            r.arena.deinit();
            std.heap.c_allocator.destroy(r.arena);
            return 0;
        }

        if (p.arena) |old| {
            old.deinit();
            std.heap.c_allocator.destroy(old);
        }
        p.arena = r.arena;

        populate(r.page, r.package);
        return 0;
    }

    fn populate(self: *Self, package: Package) void {
        const p = self.priv();
        var buf: [512]u8 = undefined;

        gtk.Label.setLabel(p.name_label, c_string.cstr(&buf, package.Name));
        p.name_label.setSelectable(1);
        gtk.Label.setLabel(p.description_label, c_string.cstr(&buf, package.Description));

        var sbuf: [32]u8 = undefined;

        clear_box(p.spec_box);
        add_spec_row(p.spec_box, translations._("Version"), package.Version);
        add_spec_row(p.spec_box, translations._("Repository"), package.Repository);
        add_spec_row(p.spec_box, translations._("Installed Size"), SizeConverter.convert_null_term(&sbuf, package.InstalledSize));
        if (package.DownloadSize > 0) add_spec_size(p.spec_box, translations._("Download Size"), package.DownloadSize);
        if (package.BuildDate.len > 0) add_spec_row(p.spec_box, translations._("Build Date"), package.BuildDate);
        if (package.InstallReason.len > 0) add_spec_row(p.spec_box, translations._("Install Reason"), package.InstallReason);

        if (package.Url) |u| if (u.len > 0) add_url_spec_row(p.spec_box, translations._("URL"), u);

        clear_box(p.sections_box);
        const alloc = (p.arena orelse return).allocator();

        add_spec_list(p.spec_box, alloc, translations._("Licenses"), package.Licenses);
        add_spec_list(p.spec_box, alloc, translations._("Provides"), package.Provides);
        add_spec_list(p.spec_box, alloc, translations._("Conflicts"), package.Conflicts);

        add_list_section(p.sections_box, self, translations._("Depends"), package.Depends, null);
        add_list_section(
            p.sections_box,
            self,
            translations._("Optional Depends"),
            package.OptDepends,
            package.OptDependsInstalled,
        );
        add_list_section(p.sections_box, self, translations._("Required By"), package.RequiredBy, null);
    }

    fn add_spec_row(box: *gtk.Box, label: []const u8, value: []const u8) void {
        var lbuf: [64]u8 = undefined;
        var vbuf: [512]u8 = undefined;
        const row = gtk.Box.new(.horizontal, 8);
        gtk.Widget.setMarginTop(row.as(gtk.Widget), 10);
        gtk.Widget.setMarginBottom(row.as(gtk.Widget), 10);
        gtk.Widget.addCssClass(row.as(gtk.Widget), "spec-row");
        const key = gtk.Label.new(c_string.cstr(&lbuf, label));
        gtk.Widget.setHalign(key.as(gtk.Widget), .start);
        gtk.Label.setXalign(key, 0);
        gtk.Widget.addCssClass(key.as(gtk.Widget), "dim-label");
        gtk.Box.append(row, key.as(gtk.Widget));
        const val = gtk.Label.new(c_string.cstr(&vbuf, value));
        gtk.Widget.setHalign(val.as(gtk.Widget), .end);
        gtk.Widget.setHexpand(val.as(gtk.Widget), 1);
        gtk.Label.setXalign(val, 1);
        gtk.Label.setEllipsize(val, .end);
        gtk.Widget.addCssClass(val.as(gtk.Widget), "spec-value");
        gtk.Box.append(row, val.as(gtk.Widget));
        gtk.Box.append(box, row.as(gtk.Widget));
    }

    fn add_url_spec_row(box: *gtk.Box, label: []const u8, value: []const u8) void {
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
        const markup = std.fmt.bufPrintZ(&mbuf, "<a href=\"{s}\">{s}</a>", .{ value, value }) catch return;
        const val = gtk.Label.new(null);
        gtk.Label.setMarkup(val, markup);
        gtk.Widget.setHalign(val.as(gtk.Widget), .end);
        gtk.Widget.setHexpand(val.as(gtk.Widget), 1);
        gtk.Label.setXalign(val, 1);
        gtk.Label.setEllipsize(val, .end);
        gtk.Box.append(row, val.as(gtk.Widget));
        gtk.Box.append(box, row.as(gtk.Widget));
    }

    fn add_spec_list(box: *gtk.Box, allocator: std.mem.Allocator, label: []const u8, items: []const []const u8) void {
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

    fn add_list_section(
        box: *gtk.Box,
        page: *PackageDetail,
        title: []const u8,
        items: []const []const u8,
        installed_states: ?[]const bool,
    ) void {
        if (items.len == 0) return;

        var buf: [64]u8 = undefined;
        const header = std.fmt.bufPrintZ(&buf, "{s} ({d})", .{ title, items.len }) catch translations._("Section");
        const expander = gtk.Expander.new(header);
        gtk.Expander.setExpanded(expander, 0);
        gtk.Widget.addCssClass(expander.as(gtk.Widget), "spec-expander");

        const list = gtk.Box.new(.vertical, 0);
        gtk.Widget.setMarginStart(list.as(gtk.Widget), 8);

        for (items, 0..) |item, index| {
            const dep_name = strip_version(item);
            const is_installed = if (installed_states) |states|
                index < states.len and states[index]
            else
                false;

            const navigable = std.mem.indexOf(u8, dep_name, ".so") == null and dep_name.len > 0;

            if (navigable) {
                const row_btn = gtk.Button.new();
                gtk.Widget.addCssClass(row_btn.as(gtk.Widget), "flat");
                gtk.Widget.addCssClass(row_btn.as(gtk.Widget), "dep-row");
                gtk.Widget.setHalign(row_btn.as(gtk.Widget), .fill);
                var ibuf: [256]u8 = undefined;
                const lbl = gtk.Label.new(c_string.cstr(&ibuf, item));
                gtk.Widget.setHalign(lbl.as(gtk.Widget), .start);
                gtk.Widget.setHexpand(lbl.as(gtk.Widget), 1);
                gtk.Label.setXalign(lbl, 0);
                gtk.Label.setEllipsize(lbl, .end);
                gtk.Widget.addCssClass(lbl.as(gtk.Widget), "spec-value");
                const row_content = gtk.Box.new(.horizontal, 8);
                gtk.Box.append(row_content, lbl.as(gtk.Widget));
                append_installed_indicator(row_content, is_installed);
                gtk.Button.setChild(row_btn, row_content.as(gtk.Widget));
                const name_owned = std.heap.c_allocator.dupeZ(u8, dep_name) catch continue;
                gobject.Object.setDataFull(row_btn.as(gobject.Object), "dep-name", name_owned.ptr, &free_dep_name);
                gobject.Object.setData(row_btn.as(gobject.Object), "page", page);
                _ = gtk.Button.signals.clicked.connect(row_btn, ?*anyopaque, &on_dep_clicked, null, .{});
                gtk.Box.append(list, row_btn.as(gtk.Widget));
            } else {
                const row = gtk.Box.new(.horizontal, 8);
                var ibuf: [256]u8 = undefined;
                const lbl = gtk.Label.new(c_string.cstr(&ibuf, item));
                gtk.Widget.setHalign(lbl.as(gtk.Widget), .start);
                gtk.Widget.setHexpand(lbl.as(gtk.Widget), 1);
                gtk.Label.setXalign(lbl, 0);
                gtk.Label.setEllipsize(lbl, .end);
                gtk.Widget.addCssClass(lbl.as(gtk.Widget), "spec-value");
                gtk.Widget.addCssClass(lbl.as(gtk.Widget), "dim-label");
                gtk.Widget.addCssClass(lbl.as(gtk.Widget), "dep-row-static");
                gtk.Box.append(row, lbl.as(gtk.Widget));
                append_installed_indicator(row, is_installed);
                gtk.Box.append(list, row.as(gtk.Widget));
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

    fn append_installed_indicator(row: *gtk.Box, installed: bool) void {
        if (!installed) return;
        const icon = gtk.Image.newFromIconName("object-select-symbolic");
        gtk.Widget.setTooltipText(icon.as(gtk.Widget), translations._("Installed"));
        gtk.Box.append(row, icon.as(gtk.Widget));
    }

    fn free_dep_name(ptr: ?*anyopaque) callconv(.c) void {
        const p: [*:0]u8 = @ptrCast(ptr orelse return);
        std.heap.c_allocator.free(std.mem.span(p));
    }

    fn on_dep_clicked(button: *gtk.Button, _: ?*anyopaque) callconv(.c) void {
        const name_ptr = gobject.Object.getData(button.as(gobject.Object), "dep-name") orelse return;
        const name: [*:0]const u8 = @ptrCast(name_ptr);
        const page_ptr = gobject.Object.getData(button.as(gobject.Object), "page") orelse return;
        const self: *PackageDetail = @ptrCast(@alignCast(page_ptr));
        self.navigate_to_dep(std.mem.span(name));
    }

    fn navigate_to_dep(self: *Self, name: []const u8) void {
        const p = self.priv();

        const current = p.pending_name[0..p.pending_len];
        const owned = std.heap.c_allocator.dupe(u8, current) catch return;
        p.nav_stack.append(std.heap.c_allocator, owned) catch {
            std.heap.c_allocator.free(owned);
            return;
        };
        self.show_package_internal(name, false, null);
        update_nav(self);
    }

    fn on_back_clicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const p = self.priv();
        const prev = p.nav_stack.pop() orelse return;
        defer std.heap.c_allocator.free(prev);

        const at_root_after = p.nav_stack.items.len == 0;
        const installed = if (at_root_after) p.base_installed else false;
        self.show_package_internal(prev, installed, null);
        update_nav(self);
    }

    fn update_nav(self: *Self) void {
        const p = self.priv();
        const at_root = p.nav_stack.items.len == 0;
        gtk.Widget.setVisible(p.back_button.as(gtk.Widget), @intFromBool(!at_root));
        gtk.Widget.setVisible(p.actions_button.as(gtk.Widget), @intFromBool(at_root));
    }

    fn clear_nav_stack(self: *Self) void {
        const p = self.priv();
        for (p.nav_stack.items) |name| std.heap.c_allocator.free(name);
        p.nav_stack.clearRetainingCapacity();
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

    fn add_spec_size(box: *gtk.Box, label: []const u8, bytes: i64) void {
        var buf: [32]u8 = undefined;
        const formatted = SizeConverter.convert_null_term(&buf, bytes);
        add_spec_row(box, label, formatted);
    }

    fn on_reinstall(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        const p = self.priv();

        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(std.heap.c_allocator);
        argv.append(std.heap.c_allocator, "install") catch return;
        argv.append(std.heap.c_allocator, "standard") catch return;
        argv.append(std.heap.c_allocator, p.pending_name[0..p.pending_len]) catch return;

        if (support.getWindow(ShellyWindow, self)) |win| {
            win.startTransaction(.{
                .title = translations._("Reinstalling package"),
                .argv = argv.items,
                .packages = &.{&p.pending_name},
                .on_complete = &on_reinstall_complete,
                .privileged = true,
                .ctx = self,
            });
        }
    }

    fn on_add_ignore(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        const p = self.priv();

        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(std.heap.c_allocator);
        argv.append(std.heap.c_allocator, "mark") catch return;
        argv.append(std.heap.c_allocator, "ignore") catch return;
        argv.append(std.heap.c_allocator, "--add") catch return;
        argv.append(std.heap.c_allocator, p.pending_name[0..p.pending_len]) catch return;

        if (support.getWindow(ShellyWindow, self)) |win| {
            win.startTransaction(.{
                .title = translations._("Adding to package ignore"),
                .argv = argv.items,
                .packages = &.{&p.pending_name},
                .on_complete = &on_reinstall_complete,
                .privileged = true,
                .ctx = self,
            });
        }
    }

    fn on_add_hold(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        const p = self.priv();

        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(std.heap.c_allocator);
        argv.append(std.heap.c_allocator, "mark") catch return;
        argv.append(std.heap.c_allocator, "hold") catch return;
        argv.append(std.heap.c_allocator, "--add") catch return;
        argv.append(std.heap.c_allocator, p.pending_name[0..p.pending_len]) catch return;

        if (support.getWindow(ShellyWindow, self)) |win| {
            win.startTransaction(.{
                .title = translations._("Adding to package to hold"),
                .argv = argv.items,
                .packages = &.{&p.pending_name},
                .on_complete = &on_reinstall_complete,
                .privileged = true,
                .ctx = self,
            });
        }
    }
    fn on_add_explicit(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        const p = self.priv();

        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(std.heap.c_allocator);
        argv.append(std.heap.c_allocator, "mark") catch return;
        argv.append(std.heap.c_allocator, "explicit") catch return;
        argv.append(std.heap.c_allocator, p.pending_name[0..p.pending_len]) catch return;

        if (support.getWindow(ShellyWindow, self)) |win| {
            win.startTransaction(.{
                .title = translations._("Making Package Explicit"),
                .argv = argv.items,
                .packages = &.{&p.pending_name},
                .on_complete = &on_reinstall_complete,
                .privileged = true,
                .ctx = self,
            });
        }
    }
    fn on_mark_dependency(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        const p = self.priv();

        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(std.heap.c_allocator);
        argv.append(std.heap.c_allocator, "mark") catch return;
        argv.append(std.heap.c_allocator, "dependency") catch return;
        argv.append(std.heap.c_allocator, p.pending_name[0..p.pending_len]) catch return;

        if (support.getWindow(ShellyWindow, self)) |win| {
            win.startTransaction(.{
                .title = translations._("Making Package Dependency"),
                .argv = argv.items,
                .packages = &.{&p.pending_name},
                .on_complete = &on_reinstall_complete,
                .privileged = true,
                .ctx = self,
            });
        }
    }

    fn on_reinstall_complete(ctx: *anyopaque, success: bool) void {
        _ = success;
        _ = ctx;
    }

    fn clear_box(box: *gtk.Box) void {
        while (gtk.Widget.getFirstChild(box.as(gtk.Widget))) |child| {
            gtk.Box.remove(box, child);
        }
    }

    fn finalize(self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.debounce_source != 0) {
            _ = glib.Source.remove(p.debounce_source);
            p.debounce_source = 0;
        }
        if (p.arena) |a| {
            a.deinit();
            std.heap.c_allocator.destroy(a);
            p.arena = null;
        }
        const parent_class: *gobject.Object.Class = @ptrCast(Class.parent);
        gobject.Object.virtual_methods.finalize.call(parent_class, self.as(gobject.Object));
    }

    const template_children = .{
        .{ "icon", @offsetOf(Private, "icon") },
        .{ "name_label", @offsetOf(Private, "name_label") },
        .{ "description_label", @offsetOf(Private, "description_label") },
        .{ "spec_box", @offsetOf(Private, "spec_box") },
        .{ "sections_box", @offsetOf(Private, "sections_box") },
        .{ "content_box", @offsetOf(Private, "content_box") },
        .{ "back_button", @offsetOf(Private, "back_button") },
        .{ "actions_button", @offsetOf(Private, "actions_button") },
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
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
    };
};
