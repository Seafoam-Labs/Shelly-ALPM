const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gio = bindings.gio;
const glib = bindings.glib;
const runtime = @import("../../services/runtime.zig");
const gobject = bindings.gobject;
const support = @import("../support.zig");
const sizeconverter = @import("../../helpers/size_converts.zig");
const search = @import("../../helpers/search.zig");

const Flatpak = @import("../../models/flatpak.zig").Flatpak;
const ShellyCli = @import("../../services/shelly_cli.zig").ShellyCli;
const FlatpakObject = @import("../../g_objects/flatpak_object.zig").FlatpakObject;
const ShellyWindow = @import("../../shelly_window.zig").ShellyWindow;
const ShellyCommands = @import("../../services/shelly_operation.zig").ShellyCommands;
const FlatpakRemoveDialog = @import("../../dialog/page/flatpak_remove_dialog.zig").FlatpakRemoveDialog;
const translations = @import("../../helpers/translations.zig");

pub const FlatpakRemoveView = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gtk.Box;

    const resource_path = "/com/shellyorg/shelly/ui/flatpak/flatpak_remove_view.ui";

    const Private = struct {
        installed_flatpaks: *gtk.ListView,
        selection: *gtk.SingleSelection,
        list_store: *gio.ListStore,
        filter_model: *gtk.FilterListModel,
        arena: ?*std.heap.ArenaAllocator,
        filter: *gtk.CustomFilter,
        runtime_check: *gtk.CheckButton,
        show_runtimes: bool,
        generation: u64,
        loaded: bool,
        pending_pkg: ?*FlatpakObject,
        search_text: [256]u8,
        search_len: usize,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyFlatpakRemoveView",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const LoadResult = struct {
        page: *Self,
        packages: []Flatpak,
        arena: *std.heap.ArenaAllocator,
        generation: u64,
        index: usize = 0,
    };

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
        p.arena = null;
        p.generation = 0;
        p.show_runtimes = false;
        p.pending_pkg = null;
        p.search_len = 0;

        p.list_store = gio.ListStore.new(FlatpakObject.getGObjectType());

        p.filter = gtk.CustomFilter.new(&filterFunc, self, null);
        p.filter_model = gtk.FilterListModel.new(
            p.list_store.as(gio.ListModel),
            p.filter.as(gtk.Filter),
        );

        p.selection = gtk.SingleSelection.new(p.filter_model.as(gio.ListModel));

        gtk.ListView.setModel(p.installed_flatpaks, p.selection.as(gtk.SelectionModel));

        const factory = gtk.SignalListItemFactory.new();
        _ = gtk.SignalListItemFactory.signals.setup.connect(factory, *FlatpakRemoveView, &onSetup, self, .{});
        _ = gtk.SignalListItemFactory.signals.bind.connect(factory, ?*anyopaque, &onBind, null, .{});
        gtk.ListView.setFactory(p.installed_flatpaks, factory.as(gtk.ListItemFactory));

        support.connectLifecycle(Self, self);
    }

    fn filterFunc(item: *gobject.Object, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data.?));
        const p = self.priv();

        const pkg = gobject.ext.cast(FlatpakObject, item) orelse return 0;

        if (!p.show_runtimes and pkg.getKind() == .runtime) return 0;

        const query = p.search_text[0..p.search_len];
        if (!search.matchesAnyIgnoreCase(query, &.{ pkg.getName(), pkg.getId() })) return 0;

        return 1;
    }

    pub fn applySearch(self: *Self, text: []const u8) void {
        const p = self.priv();
        const len = @min(text.len, p.search_text.len);
        @memcpy(p.search_text[0..len], text[0..len]);
        p.search_len = len;
        gtk.Filter.changed(p.filter.as(gtk.Filter), .different);
    }

    fn onSetup(_: *gtk.SignalListItemFactory, item: *gobject.Object, self: *FlatpakRemoveView) callconv(.c) void {
        const list_item = gobject.ext.cast(gtk.ListItem, item) orelse return;

        const grid = gtk.Grid.new();
        gtk.Widget.setMarginStart(grid.as(gtk.Widget), 12);
        gtk.Widget.setMarginEnd(grid.as(gtk.Widget), 12);
        gtk.Widget.setMarginTop(grid.as(gtk.Widget), 6);
        gtk.Widget.setMarginBottom(grid.as(gtk.Widget), 6);
        gtk.Grid.setColumnSpacing(grid, 12);
        gtk.Grid.setRowSpacing(grid, 2);
        gtk.Widget.setHexpand(grid.as(gtk.Widget), 1);
        gtk.Widget.setValign(grid.as(gtk.Widget), .center);

        const icon = gtk.Image.new();
        gtk.Image.setPixelSize(icon, 48);
        gtk.Widget.setValign(icon.as(gtk.Widget), .center);
        gtk.Grid.attach(grid, icon.as(gtk.Widget), 0, 0, 1, 2);

        const name_label = gtk.Label.new("");
        gtk.Widget.setHalign(name_label.as(gtk.Widget), .start);
        gtk.Widget.setHexpand(name_label.as(gtk.Widget), 1);
        gtk.Grid.attach(grid, name_label.as(gtk.Widget), 1, 0, 2, 1);

        const info_label = gtk.Label.new("");
        gtk.Widget.setHalign(info_label.as(gtk.Widget), .start);
        gtk.Widget.addCssClass(info_label.as(gtk.Widget), "dim-label");
        gtk.Grid.attach(grid, info_label.as(gtk.Widget), 1, 1, 2, 1);

        const remove_button = gtk.Button.newFromIconName("user-trash-symbolic");
        gtk.Widget.setValign(remove_button.as(gtk.Widget), .center);
        gtk.Widget.addCssClass(remove_button.as(gtk.Widget), "flat");
        gtk.Widget.addCssClass(remove_button.as(gtk.Widget), "destructive-action");

        // stash the list item so the handler can find the current package
        gobject.Object.setData(remove_button.as(gobject.Object), "list-item", list_item);
        _ = gtk.Button.signals.clicked.connect(remove_button, *FlatpakRemoveView, &onRemoveClicked, self, .{});

        gtk.Grid.attach(grid, remove_button.as(gtk.Widget), 3, 0, 1, 2);

        gtk.ListItem.setChild(list_item, grid.as(gtk.Widget));
    }

    fn onBind(_: *gtk.SignalListItemFactory, item: *gobject.Object, _: ?*anyopaque) callconv(.c) void {
        const list_item = gobject.ext.cast(gtk.ListItem, item) orelse return;
        const obj = gtk.ListItem.getItem(list_item) orelse return;
        const pkg = gobject.ext.cast(FlatpakObject, obj) orelse return;
        const child = gtk.ListItem.getChild(list_item) orelse return;
        const grid = gobject.ext.cast(gtk.Grid, child) orelse return;

        const icon = gobject.ext.cast(gtk.Image, gtk.Grid.getChildAt(grid, 0, 0) orelse return) orelse return;
        const name_label = gobject.ext.cast(gtk.Label, gtk.Grid.getChildAt(grid, 1, 0) orelse return) orelse return;
        const info_label = gobject.ext.cast(gtk.Label, gtk.Grid.getChildAt(grid, 1, 1) orelse return) orelse return;

        gtk.Label.setLabel(name_label, pkg.getName());

        var buf: [64]u8 = undefined;
        const size_text = sizeconverter.SizeConverter.convert_null_term(&buf, pkg.getInstalledSize());

        var info_buf: [128]u8 = undefined;
        const version = pkg.getVersion();
        const info = if (version.len == 0)
            size_text
        else
            std.fmt.bufPrintZ(&info_buf, "{s} • {s}", .{ version, size_text }) catch size_text;
        gtk.Label.setLabel(info_label, info);

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path: ?[:0]const u8 = blk: {
            const p = if (pkg.getInstallLevel() == .user) blk2: {
                const data_home = runtime.data_home; // cached at startup
                break :blk2 std.fmt.bufPrintZ(&path_buf, "{s}/flatpak/appstream/{s}/x86_64/active/icons/64x64/{s}.png", .{ data_home, pkg.getRemotes(), pkg.getId() }) catch break :blk null;
            } else std.fmt.bufPrintZ(&path_buf, "/var/lib/flatpak/appstream/{s}/x86_64/active/icons/64x64/{s}.png", .{ pkg.getRemotes(), pkg.getId() }) catch break :blk null;

            std.Io.Dir.cwd().access(runtime.io, p, .{}) catch break :blk null;
            break :blk p;
        };

        if (path) |pp| {
            gtk.Image.setFromFile(icon, pp);
        } else {
            gtk.Image.setFromIconName(icon, "package-x-generic");
        }
    }

    fn onRemoveClicked(button: *gtk.Button, self: *FlatpakRemoveView) callconv(.c) void {
        const raw = gobject.Object.getData(button.as(gobject.Object), "list-item") orelse return;
        const list_item: *gtk.ListItem = @ptrCast(@alignCast(raw));
        const obj = gtk.ListItem.getItem(list_item) orelse return;
        const pkg = gobject.ext.cast(FlatpakObject, obj) orelse return;

        const p = self.priv();
        if (p.pending_pkg != null) return;
        p.pending_pkg = pkg;
        _ = pkg.as(gobject.Object).ref();

        var remove_config = false;
        if (runtime.config) |cfg_service| {
            if (cfg_service.get()) |cfg| {
                remove_config = cfg.PackageManagementRemoveConfigs;
            } else |_| {}
        }

        var buf: [512]u8 = undefined;
        const message = std.fmt.bufPrintSentinel(
            &buf,
            "{s} {s}?",
            .{ translations._("Remove"), pkg.getName() },
            0,
        ) catch translations._("Remove this Flatpak?");

        const dialog = FlatpakRemoveDialog.new(translations._("Remove Flatpak"), message, &onRemoveResponse, self);
        dialog.setButtons(translations._("Remove"), translations._("Cancel"));
        dialog.setDefaultRemoveConfig(remove_config);

        if (support.getWindow(ShellyWindow, self)) |win| {
            win.showLockout(dialog.as(gtk.Widget));
            dialog.focusConfirm();
        } else {
            self.clearPending();
        }
    }

    fn onRemoveResponse(ctx: ?*anyopaque, confirmed: bool, remove_config: bool) void {
        const self: *FlatpakRemoveView = @ptrCast(@alignCast(ctx.?));
        if (support.getWindow(ShellyWindow, self)) |win| win.hideLockout();

        const p = self.priv();
        const pkg = p.pending_pkg orelse return;

        if (!confirmed) {
            self.clearPending();
            return;
        }

        const argv = ShellyCommands.removeFlatpak(std.heap.c_allocator, pkg.getId(), remove_config) catch {
            self.clearPending();
            return;
        };
        defer std.heap.c_allocator.free(argv);

        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer names.deinit(std.heap.c_allocator);
        names.append(std.heap.c_allocator, pkg.getName()) catch {};

        if (support.getWindow(ShellyWindow, self)) |win| {
            win.startTransaction(.{
                .title = translations._("Removing Flatpak"),
                .argv = argv,
                .packages = names.items,
                .on_complete = &onTransactionComplete,
                .privileged = false,
                .ctx = self,
            });
        }

        self.clearPending();
    }

    fn clearPending(self: *Self) void {
        const p = self.priv();
        if (p.pending_pkg) |pkg| {
            pkg.as(gobject.Object).unref();
            p.pending_pkg = null;
        }
    }

    fn onTransactionComplete(ctx: *anyopaque, success: bool) void {
        const self: *FlatpakRemoveView = @ptrCast(@alignCast(ctx));
        if (!success) return;
        self.reload();
    }

    fn reload(self: *Self) void {
        const p = self.priv();
        p.generation += 1;
        const thread = std.Thread.spawn(.{}, loadWorker, .{ self, p.generation }) catch return;
        thread.detach();
    }

    pub fn onMap(self: *Self) void {
        const p = self.priv();
        if (p.loaded) return;
        p.loaded = true;
        p.generation += 1;

        const arena_ptr = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch return;
        arena_ptr.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        p.arena = arena_ptr;

        const thread = std.Thread.spawn(.{}, loadWorker, .{ self, p.generation }) catch return;
        thread.detach();
    }

    pub fn onUnmap(self: *Self) void {
        const p = self.priv();
        if (!p.loaded) return;
        p.loaded = false;

        self.clearPending();

        gio.ListStore.removeAll(p.list_store);
        p.generation += 1;

        if (p.arena) |a| {
            a.deinit();
            std.heap.c_allocator.destroy(a);
            p.arena = null;
        }
    }

    fn loadWorker(page: *Self, generation: u64) void {
        const arena_ptr = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch return;
        arena_ptr.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);

        const alloc = arena_ptr.allocator();

        var threaded: std.Io.Threaded = .init(alloc, .{});
        defer threaded.deinit();

        const cli = ShellyCli{ .allocator = alloc, .io = threaded.io() };
        const parsed = cli.getInstalledFlatpaks() catch |err| {
            std.debug.print("get_installed_flatpaks failed: {t}\n", .{err});
            postResult(page, &.{}, arena_ptr, generation);
            return;
        };
        postResult(page, parsed.value, arena_ptr, generation);
    }

    fn postResult(page: *Self, packages: []Flatpak, arena: *std.heap.ArenaAllocator, generation: u64) void {
        const result = std.heap.c_allocator.create(LoadResult) catch {
            arena.deinit();
            std.heap.c_allocator.destroy(arena);
            return;
        };
        result.* = .{
            .page = page,
            .packages = packages,
            .arena = arena,
            .generation = generation,
        };
        _ = glib.idleAdd(&onLoadComplete, result);
    }

    fn onLoadComplete(data: ?*anyopaque) callconv(.c) c_int {
        const result: *LoadResult = @ptrCast(@alignCast(data.?));
        const p = result.page.priv();
        if (result.generation != p.generation) {
            result.arena.deinit();
            std.heap.c_allocator.destroy(result.arena);
            std.heap.c_allocator.destroy(result);
            return 0;
        }

        if (result.index == 0) {
            gio.ListStore.removeAll(p.list_store);
            if (p.arena) |old| {
                old.deinit();
                std.heap.c_allocator.destroy(old);
            }
            const na = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch {
                p.arena = null;
                result.arena.deinit();
                std.heap.c_allocator.destroy(result.arena);
                std.heap.c_allocator.destroy(result);
                return 0;
            };
            na.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            p.arena = na;
        }

        const page_alloc = (p.arena orelse {
            result.arena.deinit();
            std.heap.c_allocator.destroy(result.arena);
            std.heap.c_allocator.destroy(result);
            return 0;
        }).allocator();

        const batch_size = 250;
        const end = @min(result.index + batch_size, result.packages.len);
        for (result.packages[result.index..end]) |d| {
            const pkg = FlatpakObject.new(page_alloc, d);
            gio.ListStore.append(p.list_store, pkg.as(gobject.Object));
            pkg.as(gobject.Object).unref();
        }
        result.index = end;
        if (result.index < result.packages.len) return 1;

        result.arena.deinit();
        std.heap.c_allocator.destroy(result.arena);
        std.heap.c_allocator.destroy(result);
        return 0;
    }

    const template_children = .{
        .{ "installed_flatpaks", @offsetOf(Private, "installed_flatpaks") },
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
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "show_runtimes", @ptrCast(&showRuntimes));
        }
    };

    fn showRuntimes(self: *Self, check: *gtk.CheckButton) callconv(.c) void {
        const p = self.priv();
        p.show_runtimes = gtk.CheckButton.getActive(check) != 0;
        gtk.Filter.changed(p.filter.as(gtk.Filter), .different);
    }
};
