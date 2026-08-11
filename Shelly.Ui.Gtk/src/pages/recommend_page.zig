const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const glib = bindings.glib;
const gobject = bindings.gobject;
const support = @import("support.zig");
const c_string = @import("../helpers/c_string.zig");
const ShellyWindow = @import("../shelly_window.zig").ShellyWindow;
const ShellyCli = @import("../services/shelly_cli.zig").ShellyCli;
const IconResolver = @import("../services/icon_resolver.zig").IconResolver;
const Package = @import("../models/packages.zig").Package;
const RecommendCategory = @import("../models/recommendation.zig").RecommendCategory;
const recommendations = @import("../services/recommendations.zig");
const runtime = @import("../services/runtime.zig");

pub const RecommendPage = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gtk.Box;

    pub const title: [:0]const u8 = "Recommended";
    pub const icon_name: [:0]const u8 = "star-filled-rounded-symbolic";
    const resource_path = "/com/shellyorg/shelly/ui/recommend_page.ui";

    const Private = struct {
        header_box: *gtk.Box,
        refresh_button: *gtk.Button,
        recommend_stack: *gtk.Stack,
        loading_page: *gtk.Box,
        loading_spinner: *gtk.Spinner,
        list_page: *gtk.ScrolledWindow,
        content_box: *gtk.Box,
        empty_page: *gtk.Box,

        resolver: IconResolver,
        arena: ?*std.heap.ArenaAllocator,
        generation: u64,
        loaded: bool,
        loading: bool,

        var offset: c_int = 0;
    };

    const CategorySection = struct {
        name: []const u8,
        packages: []Package,
    };

    const LoadResult = struct {
        page: *Self,
        categories: []CategorySection,
        arena: *std.heap.ArenaAllocator,
        generation: u64,
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyRecommendPage",
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
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        const p = self.priv();
        p.loaded = false;
        p.loading = false;
        p.arena = null;
        p.generation = 0;
        p.resolver = IconResolver.init(std.heap.c_allocator);

        support.connectLifecycle(Self, self);
    }

    pub fn onMap(self: *Self) void {
        const p = self.priv();
        if (p.loaded) return;
        p.loaded = true;
        triggerReload(self, false);
    }

    pub fn onUnmap(self: *Self) void {
        const p = self.priv();
        if (!p.loaded) return;
        p.loaded = false;
        p.generation += 1;

        while (gtk.Widget.getFirstChild(p.content_box.as(gtk.Widget))) |c| {
            gtk.Box.remove(p.content_box, c);
        }

        if (p.arena) |a| {
            a.deinit();
            std.heap.c_allocator.destroy(a);
            p.arena = null;
        }

        p.resolver.deinit();
        p.resolver = IconResolver.init(std.heap.c_allocator);
    }

    fn load_worker(page: *Self, generation: u64, force: bool) void {
        const arena_ptr = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch return;
        arena_ptr.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        const alloc = arena_ptr.allocator();

        const p = page.priv();
        if (!p.resolver.loaded) {
            p.resolver.load(runtime.io, runtime.environ_map) catch {};
        }

        var threaded: std.Io.Threaded = .init(alloc, .{});
        defer threaded.deinit();

        const categories = if (force)
            recommendations.reload(alloc, threaded.io(), runtime.environ_map)
        else
            recommendations.load(alloc, threaded.io(), runtime.environ_map);

        const cli = ShellyCli{ .allocator = alloc, .io = threaded.io() };
        const parsed = cli.get_packages(false) catch {
            post_result(page, &.{}, arena_ptr, generation);
            return;
        };

        var installed_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer installed_arena.deinit();
        const ialloc = installed_arena.allocator();
        var ithreaded: std.Io.Threaded = .init(ialloc, .{});
        defer ithreaded.deinit();
        const icli = ShellyCli{ .allocator = ialloc, .io = ithreaded.io() };

        const installed = icli.get_installed_packages() catch null;
        var installed_names: std.StringHashMapUnmanaged(void) = .empty;
        if (installed) |inst| {
            for (inst.value) |pkg| {
                installed_names.put(ialloc, pkg.Name, {}) catch {};
            }
        }

        var avail: std.StringHashMapUnmanaged(*const Package) = .empty;
        for (parsed.value) |*pkg| {
            avail.put(alloc, pkg.Name, pkg) catch {};
        }

        var sections: std.ArrayListUnmanaged(CategorySection) = .empty;
        for (categories) |cat| {
            var pkgs: std.ArrayListUnmanaged(Package) = .empty;
            for (cat.packages) |name| {
                const pkg = avail.get(name) orelse continue;
                var copy = pkg.*;
                copy.Installed = installed_names.contains(name);
                pkgs.append(alloc, copy) catch {};
            }
            if (pkgs.items.len == 0) continue;
            sections.append(alloc, .{ .name = cat.name, .packages = pkgs.items }) catch {};
        }

        post_result(page, sections.items, arena_ptr, generation);
    }

    fn post_result(
        page: *Self,
        categories: []CategorySection,
        arena: *std.heap.ArenaAllocator,
        generation: u64,
    ) void {
        const result = std.heap.c_allocator.create(LoadResult) catch {
            arena.deinit();
            std.heap.c_allocator.destroy(arena);
            return;
        };
        result.* = .{
            .page = page,
            .categories = categories,
            .arena = arena,
            .generation = generation,
        };
        _ = glib.idleAdd(&onLoadComplete, result);
    }

    fn onLoadComplete(data: ?*anyopaque) callconv(.c) c_int {
        const result: *LoadResult = @ptrCast(@alignCast(data.?));
        const page = result.page;
        const p = page.priv();

        p.loading = false;
        gtk.Widget.setSensitive(p.refresh_button.as(gtk.Widget), 1);

        if (result.generation != p.generation) {
            result.arena.deinit();
            std.heap.c_allocator.destroy(result.arena);
            std.heap.c_allocator.destroy(result);
            return 0;
        }

        if (p.arena) |a| {
            a.deinit();
            std.heap.c_allocator.destroy(a);
        }
        p.arena = result.arena;

        if (result.categories.len == 0) {
            std.heap.c_allocator.destroy(result);
            show_empty(page);
            return 0;
        }

        buildSections(page, result.categories);
        std.heap.c_allocator.destroy(result);

        hide_loading(page);
        return 0;
    }

    fn buildSections(self: *Self, categories: []const CategorySection) void {
        const p = self.priv();
        const sizeGroup = gtk.SizeGroup.new(.horizontal);

        for (categories) |cat| {
            const section = gtk.Box.new(.vertical, 6);

            var nbuf: [256]u8 = undefined;
            const header = gtk.Label.new(c_string.cstr(&nbuf, cat.name));
            gtk.Widget.setHalign(header.as(gtk.Widget), .start);
            gtk.Widget.addCssClass(header.as(gtk.Widget), "title-4");
            gtk.Box.append(section, header.as(gtk.Widget));

            const flow = gtk.FlowBox.new();
            gtk.FlowBox.setSelectionMode(flow, .none);
            gtk.FlowBox.setColumnSpacing(flow, 8);
            gtk.FlowBox.setRowSpacing(flow, 8);
            gtk.FlowBox.setHomogeneous(flow, 1);
            gtk.FlowBox.setMinChildrenPerLine(flow, 1);
            gtk.FlowBox.setMaxChildrenPerLine(flow, 6);

            for (cat.packages) |*pkg| {
                const card = makeCard(self, pkg);
                gtk.SizeGroup.addWidget(sizeGroup, card.as(gtk.Widget));
                gtk.FlowBox.append(flow, card.as(gtk.Widget));
            }

            gtk.Box.append(section, flow.as(gtk.Widget));
            gtk.Box.append(p.content_box, section.as(gtk.Widget));
        }
    }

    fn makeCard(self: *Self, pkg: *const Package) *gtk.Widget {
        const p = self.priv();

        const content = gtk.Box.new(.horizontal, 10);
        gtk.Widget.setMarginTop(content.as(gtk.Widget), 8);
        gtk.Widget.setMarginBottom(content.as(gtk.Widget), 8);
        gtk.Widget.setMarginStart(content.as(gtk.Widget), 10);
        gtk.Widget.setMarginEnd(content.as(gtk.Widget), 10);
        gtk.Widget.setHexpand(content.as(gtk.Widget), 1);

        const image = gtk.Image.new();
        if (p.resolver.resolve(pkg.Name)) |path| {
            gtk.Image.setFromFile(image, path);
        } else {
            gtk.Image.setFromIconName(image, "package-x-generic");
        }
        gtk.Image.setPixelSize(image, 48);
        gtk.Widget.setValign(image.as(gtk.Widget), .center);
        gtk.Widget.addCssClass(image.as(gtk.Widget), "icon-dropshadow");
        gtk.Box.append(content, image.as(gtk.Widget));

        const text_box = gtk.Box.new(.vertical, 0);
        gtk.Widget.setHalign(text_box.as(gtk.Widget), .start);
        gtk.Widget.setValign(text_box.as(gtk.Widget), .center);
        gtk.Widget.setHexpand(text_box.as(gtk.Widget), 1);

        const title_box = gtk.Box.new(.horizontal, 6);
        gtk.Widget.setHalign(title_box.as(gtk.Widget), .start);

        var buf: [256]u8 = undefined;
        const title_label = gtk.Label.new(c_string.cstr(&buf, pkg.Name));
        gtk.Widget.setHalign(title_label.as(gtk.Widget), .start);
        gtk.Widget.addCssClass(title_label.as(gtk.Widget), "title-4");
        gtk.Box.append(title_box, title_label.as(gtk.Widget));

        var vbuf: [128]u8 = undefined;
        const version_label = gtk.Label.new(c_string.cstr(&vbuf, pkg.Version));
        gtk.Widget.setHalign(version_label.as(gtk.Widget), .start);
        gtk.Widget.setValign(version_label.as(gtk.Widget), .center);
        gtk.Widget.addCssClass(version_label.as(gtk.Widget), "caption");
        gtk.Box.append(title_box, version_label.as(gtk.Widget));

        const installed_check = gtk.Image.newFromIconName("object-select-symbolic");
        gtk.Widget.setVisible(installed_check.as(gtk.Widget), @intFromBool(pkg.Installed));
        gtk.Widget.setValign(installed_check.as(gtk.Widget), .center);
        gtk.Widget.setTooltipText(installed_check.as(gtk.Widget), "Package is already installed");
        gtk.Box.append(title_box, installed_check.as(gtk.Widget));

        gtk.Box.append(text_box, title_box.as(gtk.Widget));

        if (pkg.Description.len > 0) {
            var dbuf: [512]u8 = undefined;
            const desc_label = gtk.Label.new(c_string.cstr(&dbuf, pkg.Description));
            gtk.Widget.setHalign(desc_label.as(gtk.Widget), .start);
            gtk.Widget.addCssClass(desc_label.as(gtk.Widget), "dim-label");
            gtk.Label.setWrap(desc_label, 1);
            gtk.Label.setLines(desc_label, 2);
            gtk.Label.setEllipsize(desc_label, .end);
            gtk.Label.setMaxWidthChars(desc_label, 40);
            gtk.Box.append(text_box, desc_label.as(gtk.Widget));
        }

        gtk.Box.append(content, text_box.as(gtk.Widget));

        const name: [:0]const u8 = if (p.arena) |a|
            a.allocator().dupeSentinel(u8, pkg.Name, 0) catch ""
        else
            "";

        const remove_button = gtk.Button.newFromIconName("edit-delete-symbolic");
        gtk.Widget.setVisible(remove_button.as(gtk.Widget), @intFromBool(pkg.Installed));
        gtk.Widget.addCssClass(remove_button.as(gtk.Widget), "destructive-action");
        gtk.Widget.setValign(remove_button.as(gtk.Widget), .center);
        gtk.Widget.setTooltipText(remove_button.as(gtk.Widget), "Remove package");
        gobject.Object.setData(remove_button.as(gobject.Object), "pkg-name", @ptrCast(@constCast(name.ptr)));
        gobject.Object.setData(remove_button.as(gobject.Object), "page", self);
        _ = gtk.Button.signals.clicked.connect(remove_button, ?*anyopaque, &on_remove_clicked, null, .{});
        gtk.Box.append(content, remove_button.as(gtk.Widget));

        const install_button = gtk.Button.newFromIconName("folder-download-symbolic");
        gtk.Widget.setVisible(install_button.as(gtk.Widget), @intFromBool(!pkg.Installed));
        gtk.Widget.addCssClass(install_button.as(gtk.Widget), "suggested-action");
        gtk.Widget.setValign(install_button.as(gtk.Widget), .center);
        gtk.Widget.setTooltipText(install_button.as(gtk.Widget), "Install package");
        gobject.Object.setData(install_button.as(gobject.Object), "pkg-name", @ptrCast(@constCast(name.ptr)));
        gobject.Object.setData(install_button.as(gobject.Object), "page", self);
        _ = gtk.Button.signals.clicked.connect(install_button, ?*anyopaque, &on_install_clicked, null, .{});
        gtk.Box.append(content, install_button.as(gtk.Widget));

        const frame = gtk.Frame.new(null);
        gtk.Frame.setChild(frame, content.as(gtk.Widget));
        gtk.Widget.setHexpand(frame.as(gtk.Widget), 1);
        gtk.Widget.setHalign(frame.as(gtk.Widget), .fill);
        gtk.Widget.addCssClass(frame.as(gtk.Widget), "card");

        return frame.as(gtk.Widget);
    }

    fn on_install_clicked(button: *gtk.Button, _: ?*anyopaque) callconv(.c) void {
        const page_ptr = gobject.Object.getData(button.as(gobject.Object), "page") orelse return;
        const self: *Self = @ptrCast(@alignCast(page_ptr));
        const name_ptr = gobject.Object.getData(button.as(gobject.Object), "pkg-name") orelse return;
        const name: []const u8 = std.mem.span(@as([*:0]const u8, @ptrCast(name_ptr)));

        const names = [_][]const u8{name};
        const argv = [_][]const u8{ "install", "standard", name };

        if (support.getWindow(ShellyWindow, self)) |win| {
            win.startTransaction(.{
                .title = "Installing package",
                .argv = &argv,
                .packages = &names,
                .on_complete = &on_transaction_complete,
                .privileged = true,
                .ctx = self,
            });
        }
    }

    fn on_remove_clicked(button: *gtk.Button, _: ?*anyopaque) callconv(.c) void {
        const page_ptr = gobject.Object.getData(button.as(gobject.Object), "page") orelse return;
        const self: *Self = @ptrCast(@alignCast(page_ptr));
        const name_ptr = gobject.Object.getData(button.as(gobject.Object), "pkg-name") orelse return;
        const name: []const u8 = std.mem.span(@as([*:0]const u8, @ptrCast(name_ptr)));

        const names = [_][]const u8{name};
        const argv = [_][]const u8{ "remove", "standard", name };

        if (support.getWindow(ShellyWindow, self)) |win| {
            win.startTransaction(.{
                .title = "Removing package",
                .argv = &argv,
                .packages = &names,
                .on_complete = &on_transaction_complete,
                .privileged = true,
                .ctx = self,
            });
        }
    }

    fn on_transaction_complete(ctx: *anyopaque, success: bool) void {
        if (!success) return;
        const self: *Self = @ptrCast(@alignCast(ctx));
        const p = self.priv();
        if (!p.loaded) return;
        triggerReload(self, false);
    }

    fn triggerReload(self: *Self, force: bool) void {
        const p = self.priv();
        if (p.loading) return;
        p.loading = true;
        p.generation += 1;
        gtk.Widget.setSensitive(p.refresh_button.as(gtk.Widget), 0);

        while (gtk.Widget.getFirstChild(p.content_box.as(gtk.Widget))) |c| {
            gtk.Box.remove(p.content_box, c);
        }
        if (p.arena) |a| {
            a.deinit();
            std.heap.c_allocator.destroy(a);
            p.arena = null;
        }

        show_loading(self);
        const thread = std.Thread.spawn(.{}, load_worker, .{ self, p.generation, force }) catch {
            p.loading = false;
            gtk.Widget.setSensitive(p.refresh_button.as(gtk.Widget), 1);
            return;
        };
        thread.detach();
    }

    fn on_refresh_clicked(self: *Self) callconv(.c) void {
        triggerReload(self, true);
    }

    fn show_loading(self: *Self) void {
        const p = self.priv();
        gtk.Spinner.start(p.loading_spinner);
        gtk.Stack.setVisibleChild(p.recommend_stack, p.loading_page.as(gtk.Widget));
    }

    fn hide_loading(self: *Self) void {
        const p = self.priv();
        gtk.Spinner.stop(p.loading_spinner);
        gtk.Stack.setVisibleChild(p.recommend_stack, p.list_page.as(gtk.Widget));
    }

    fn show_empty(self: *Self) void {
        const p = self.priv();
        gtk.Spinner.stop(p.loading_spinner);
        gtk.Stack.setVisibleChild(p.recommend_stack, p.empty_page.as(gtk.Widget));
    }

    const template_children = .{
        .{ "header_box", @offsetOf(Private, "header_box") },
        .{ "refresh_button", @offsetOf(Private, "refresh_button") },
        .{ "recommend_stack", @offsetOf(Private, "recommend_stack") },
        .{ "loading_page", @offsetOf(Private, "loading_page") },
        .{ "loading_spinner", @offsetOf(Private, "loading_spinner") },
        .{ "list_page", @offsetOf(Private, "list_page") },
        .{ "content_box", @offsetOf(Private, "content_box") },
        .{ "empty_page", @offsetOf(Private, "empty_page") },
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
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_refresh_clicked", @ptrCast(&on_refresh_clicked));
        }

        pub fn as(class: *Class, comptime T: type) *T {
            return gobject.ext.as(T, class);
        }
    };
};
