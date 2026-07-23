const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const glib = bindings.glib;
const gio = bindings.gio;
const gobject = bindings.gobject;
const support = @import("support.zig");
const size_helper = @import("../helpers/size_converts.zig").SizeConverter;

const ShellyCli = @import("../services/shelly_cli.zig").ShellyCli;
const ShellyCommands = @import("../services/shelly_operation.zig").ShellyCommands;
const ShellyOperation = @import("../services/shelly_operation.zig").ShellyOperation;
const CheckUpdates = @import("../models/sync.zig").CheckUpdates;
const UpdateObject = @import("../g_objects/update_object.zig").UpdateObject;
const UpdateSource = @import("../g_objects/update_object.zig").UpdateSource;
const ShellyWindow = @import("../shelly_window.zig").ShellyWindow;

pub const UpdatePage = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gtk.Box;

    pub const title: [:0]const u8 = "Update";
    pub const icon_name: [:0]const u8 = "software-update-available-symbolic";
    const resource_path = "/com/shellyorg/shelly/ui/update_page.ui";

    const Private = struct {
        content_list: *gtk.ListView,
        selected_label: *gtk.Label,
        refresh_button: *gtk.Button,
        native_toggle: *gtk.ToggleButton,
        aur_toggle: *gtk.ToggleButton,
        flatpak_toggle: *gtk.ToggleButton,
        updates_stack: *gtk.Stack,
        loading_page: *gtk.Box,
        list_page: *gtk.ScrolledWindow,
        empty_page: *gtk.Box,
        error_page: *gtk.Box,
        loading_spinner: *gtk.Spinner,
        error_label: *gtk.Label,
        list_store: *gio.ListStore,
        filter: *gtk.CustomFilter,
        filter_model: *gtk.FilterListModel,
        selection: *gtk.NoSelection,
        arena: ?*std.heap.ArenaAllocator,
        generation: u64,
        loaded: bool,
        var offset: c_int = 0;
    };

    const UpdateItem = struct {
        source: UpdateSource,
        name: []const u8,
        description: []const u8,
        old_version: []const u8,
        new_version: []const u8,
        size: i64,
    };

    const LoadResult = struct {
        page: *Self,
        updates: []UpdateItem,
        arena: *std.heap.ArenaAllocator,
        generation: u64,
        failed: bool,
        index: usize = 0,
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyUpdatePage",
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
        p.arena = null;
        p.generation = 0;

        p.list_store = gio.ListStore.new(UpdateObject.getGObjectType());
        p.filter = gtk.CustomFilter.new(&filter_update, self, null);
        p.filter_model = gtk.FilterListModel.new(p.list_store.as(gio.ListModel), p.filter.as(gtk.Filter));
        p.selection = gtk.NoSelection.new(p.filter_model.as(gio.ListModel));
        gtk.ListView.setModel(p.content_list, p.selection.as(gtk.SelectionModel));
        const factory = gtk.SignalListItemFactory.new();
        _ = gtk.SignalListItemFactory.signals.setup.connect(factory, *Self, &on_row_setup, self, .{});
        _ = gtk.SignalListItemFactory.signals.bind.connect(factory, *Self, &on_row_bind, self, .{});
        gtk.ListView.setFactory(p.content_list, factory.as(gtk.ListItemFactory));

        _ = gtk.ToggleButton.signals.toggled.connect(p.native_toggle, *Self, &on_source_toggled, self, .{});
        _ = gtk.ToggleButton.signals.toggled.connect(p.aur_toggle, *Self, &on_source_toggled, self, .{});
        _ = gtk.ToggleButton.signals.toggled.connect(p.flatpak_toggle, *Self, &on_source_toggled, self, .{});
        support.connectLifecycle(Self, self);
    }

    fn source_is_active(source: UpdateSource, native: bool, aur: bool, flatpak: bool) bool {
        return switch (source) {
            .package => native,
            .aur => aur,
            .flatpak => flatpak,
        };
    }

    fn is_source_active(self: *Self, source: UpdateSource) bool {
        const p = self.priv();
        return source_is_active(
            source,
            gtk.ToggleButton.getActive(p.native_toggle) != 0,
            gtk.ToggleButton.getActive(p.aur_toggle) != 0,
            gtk.ToggleButton.getActive(p.flatpak_toggle) != 0,
        );
    }

    fn filter_update(item: *gobject.Object, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data.?));
        const update = gobject.ext.cast(UpdateObject, item) orelse return 0;
        return @intFromBool(self.is_source_active(update.getSource()));
    }

    pub fn onMap(self: *Self) void {
        const p = self.priv();
        if (p.loaded) return;
        p.loaded = true;
        start_load(self);
    }

    pub fn onUnmap(self: *Self) void {
        const p = self.priv();
        if (!p.loaded) return;
        p.loaded = false;
        p.generation += 1;
        clear_data(self);
    }

    fn clear_data(self: *Self) void {
        const p = self.priv();
        gio.ListStore.removeAll(p.list_store);
        if (p.arena) |arena| {
            arena.deinit();
            std.heap.c_allocator.destroy(arena);
            p.arena = null;
        }
    }

    fn start_load(self: *Self) void {
        const p = self.priv();
        p.generation += 1;
        clear_data(self);
        gtk.Spinner.start(p.loading_spinner);
        gtk.Label.setLabel(p.selected_label, "Checking for updates…");
        gtk.Widget.setSensitive(p.refresh_button.as(gtk.Widget), 0);
        gtk.Widget.setSensitive(p.native_toggle.as(gtk.Widget), 0);
        gtk.Widget.setSensitive(p.aur_toggle.as(gtk.Widget), 0);
        gtk.Widget.setSensitive(p.flatpak_toggle.as(gtk.Widget), 0);

        const thread = std.Thread.spawn(.{}, load_worker, .{ self, p.generation }) catch {
            show_error(self);
            return;
        };
        thread.detach();
    }

    fn load_worker(page: *Self, generation: u64) void {
        const arena = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch return;
        arena.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        const alloc = arena.allocator();
        var threaded: std.Io.Threaded = .init(alloc, .{});
        defer threaded.deinit();

        const cli = ShellyCli{ .allocator = alloc, .io = threaded.io() };
        const parsed = cli.check_updates() catch {
            post_result(page, &.{}, arena, generation, true);
            return;
        };
        const updates = flatten_updates(alloc, parsed.value) catch {
            post_result(page, &.{}, arena, generation, true);
            return;
        };
        post_result(page, updates, arena, generation, false);
    }

    fn flatten_updates(allocator: std.mem.Allocator, response: CheckUpdates) ![]UpdateItem {
        const updates = try allocator.alloc(UpdateItem, response.count());
        var index: usize = 0;

        for (response.Packages) |package| {
            updates[index] = .{ .source = .package, .name = package.Name, .description = "System package update", .old_version = package.CurrentVersion, .new_version = package.NewVersion, .size = package.DownloadSize };
            index += 1;
        }
        for (response.Aur) |package| {
            updates[index] = .{ .source = .aur, .name = package.Name, .description = "AUR package update", .old_version = package.Version, .new_version = package.NewVersion, .size = package.DownloadSize };
            index += 1;
        }
        for (response.Flatpak) |package| {
            updates[index] = .{ .source = .flatpak, .name = package.Name, .description = package.Id, .old_version = package.Version, .new_version = "Installed", .size = 0 };
            index += 1;
        }
        return updates;
    }

    fn post_result(page: *Self, updates: []UpdateItem, arena: *std.heap.ArenaAllocator, generation: u64, failed: bool) void {
        const result = std.heap.c_allocator.create(LoadResult) catch {
            arena.deinit();
            std.heap.c_allocator.destroy(arena);
            return;
        };
        result.* = .{ .page = page, .updates = updates, .arena = arena, .generation = generation, .failed = failed };
        _ = glib.idleAdd(&on_load_complete, result);
    }

    fn discard_result(result: *LoadResult) void {
        result.arena.deinit();
        std.heap.c_allocator.destroy(result.arena);
        std.heap.c_allocator.destroy(result);
    }

    fn on_load_complete(data: ?*anyopaque) callconv(.c) c_int {
        const result: *LoadResult = @ptrCast(@alignCast(data.?));
        const page = result.page;
        const p = page.priv();
        if (result.generation != p.generation) {
            discard_result(result);
            return 0;
        }
        if (result.failed) {
            discard_result(result);
            show_error(page);
            return 0;
        }
        if (result.updates.len == 0) {
            discard_result(result);
            update_source_labels(page);
            finish_load(page, .empty);
            return 0;
        }

        const end = @min(result.index + 100, result.updates.len);
        const allocator = result.arena.allocator();
        var buf: [32]u8 = undefined;
        for (result.updates[result.index..end]) |update| {
            const object = UpdateObject.new(allocator, update.source, update.name, update.description, update.old_version, update.new_version, size_helper.convert_null_term(&buf, update.size));
            gio.ListStore.append(p.list_store, object.as(gobject.Object));
            object.as(gobject.Object).unref();
        }
        result.index = end;
        if (result.index < result.updates.len) return 1;

        p.arena = result.arena;
        std.heap.c_allocator.destroy(result);
        update_source_labels(page);
        finish_load(page, .list);
        update_summary(page);
        return 0;
    }

    const LoadView = enum { list, empty };

    fn finish_load(self: *Self, view: LoadView) void {
        const p = self.priv();
        gtk.Spinner.stop(p.loading_spinner);
        gtk.Stack.setVisibleChild(p.updates_stack, switch (view) {
            .list => p.list_page.as(gtk.Widget),
            .empty => p.empty_page.as(gtk.Widget),
        });
        gtk.Widget.setSensitive(p.refresh_button.as(gtk.Widget), 1);
        gtk.Widget.setSensitive(p.native_toggle.as(gtk.Widget), 1);
        gtk.Widget.setSensitive(p.aur_toggle.as(gtk.Widget), 1);
        gtk.Widget.setSensitive(p.flatpak_toggle.as(gtk.Widget), 1);
        if (view == .empty) gtk.Label.setLabel(p.selected_label, "No updates available");
    }

    fn show_error(self: *Self) void {
        const p = self.priv();
        gtk.Spinner.stop(p.loading_spinner);
        gtk.Label.setLabel(p.error_label, "Could not run shelly check-updates. Check the CLI output and try again.");
        gtk.Stack.setVisibleChild(p.updates_stack, p.error_page.as(gtk.Widget));
        gtk.Label.setLabel(p.selected_label, "Update check failed");
        gtk.Widget.setSensitive(p.refresh_button.as(gtk.Widget), 1);
    }

    fn update_source_labels(self: *Self) void {
        const p = self.priv();
        var system_count: usize = 0;
        var aur_count: usize = 0;
        var flatpak_count: usize = 0;
        const model = p.list_store.as(gio.ListModel);
        const count = gio.ListModel.getNItems(model);
        for (0..count) |index| {
            const item: *gobject.Object = @ptrCast(@alignCast(gio.ListModel.getItem(model, @intCast(index)) orelse continue));
            const update = gobject.ext.cast(UpdateObject, item) orelse {
                item.unref();
                continue;
            };
            switch (update.getSource()) {
                .package => system_count += 1,
                .aur => aur_count += 1,
                .flatpak => flatpak_count += 1,
            }
            item.unref();
        }
        var system_buffer: [64]u8 = undefined;
        var aur_buffer: [64]u8 = undefined;
        var flatpak_buffer: [64]u8 = undefined;
        gtk.Button.setLabel(p.native_toggle.as(gtk.Button), std.fmt.bufPrintZ(&system_buffer, "System · {d}", .{system_count}) catch "System");
        gtk.Button.setLabel(p.aur_toggle.as(gtk.Button), std.fmt.bufPrintZ(&aur_buffer, "AUR · {d}", .{aur_count}) catch "AUR");
        gtk.Button.setLabel(p.flatpak_toggle.as(gtk.Button), std.fmt.bufPrintZ(&flatpak_buffer, "Flatpak · {d}", .{flatpak_count}) catch "Flatpak");
    }

    fn on_row_setup(_: *gtk.SignalListItemFactory, item: *gobject.Object, _: *Self) callconv(.c) void {
        const list_item = gobject.ext.cast(gtk.ListItem, item) orelse return;
        const grid = gtk.Grid.new();
        gtk.Widget.setMarginStart(grid.as(gtk.Widget), 12);
        gtk.Widget.setMarginEnd(grid.as(gtk.Widget), 12);
        gtk.Widget.setMarginTop(grid.as(gtk.Widget), 10);
        gtk.Widget.setMarginBottom(grid.as(gtk.Widget), 10);
        gtk.Grid.setColumnSpacing(grid, 12);
        gtk.Grid.setRowSpacing(grid, 2);
        gtk.Widget.setHexpand(grid.as(gtk.Widget), 1);

        const icon = gtk.Image.new();
        gtk.Image.setPixelSize(icon, 32);
        gtk.Widget.setValign(icon.as(gtk.Widget), .center);
        gtk.Grid.attach(grid, icon.as(gtk.Widget), 0, 0, 1, 2);

        const name = gtk.Label.new("");
        gtk.Label.setXalign(name, 0);
        gtk.Label.setEllipsize(name, .end);
        gtk.Widget.setHexpand(name.as(gtk.Widget), 1);
        gtk.Widget.addCssClass(name.as(gtk.Widget), "heading");
        gtk.Grid.attach(grid, name.as(gtk.Widget), 1, 0, 2, 1);

        const description = gtk.Label.new("");
        gtk.Label.setXalign(description, 0);
        gtk.Label.setEllipsize(description, .end);
        gtk.Label.setMaxWidthChars(description, 64);
        gtk.Widget.addCssClass(description.as(gtk.Widget), "caption");
        gtk.Widget.addCssClass(description.as(gtk.Widget), "dim-label");
        gtk.Grid.attach(grid, description.as(gtk.Widget), 1, 1, 2, 1);

        const version = gtk.Box.new(.horizontal, 6);
        gtk.Widget.setValign(version.as(gtk.Widget), .center);
        const old_version = gtk.Label.new("");
        gtk.Widget.addCssClass(old_version.as(gtk.Widget), "dim-label");
        gtk.Box.append(version, old_version.as(gtk.Widget));
        const arrow = gtk.Image.newFromIconName("go-next-symbolic");
        gtk.Box.append(version, arrow.as(gtk.Widget));
        const new_version = gtk.Label.new("");
        gtk.Widget.addCssClass(new_version.as(gtk.Widget), "heading");
        gtk.Box.append(version, new_version.as(gtk.Widget));
        gtk.Grid.attach(grid, version.as(gtk.Widget), 3, 0, 1, 2);

        const size = gtk.Label.new("");
        gtk.Label.setWidthChars(size, 10);
        gtk.Label.setXalign(size, 1);
        gtk.Widget.setValign(size.as(gtk.Widget), .center);
        gtk.Widget.addCssClass(size.as(gtk.Widget), "dim-label");
        gtk.Grid.attach(grid, size.as(gtk.Widget), 4, 0, 1, 2);

        gtk.ListItem.setChild(list_item, grid.as(gtk.Widget));
    }

    fn on_row_bind(_: *gtk.SignalListItemFactory, item: *gobject.Object, _: *Self) callconv(.c) void {
        const list_item = gobject.ext.cast(gtk.ListItem, item) orelse return;
        const object = gtk.ListItem.getItem(list_item) orelse return;
        const update = gobject.ext.cast(UpdateObject, object) orelse return;
        const child = gtk.ListItem.getChild(list_item) orelse return;
        const grid = gobject.ext.cast(gtk.Grid, child) orelse return;

        const icon = gobject.ext.cast(gtk.Image, gtk.Grid.getChildAt(grid, 0, 0) orelse return) orelse return;
        const name = gobject.ext.cast(gtk.Label, gtk.Grid.getChildAt(grid, 1, 0) orelse return) orelse return;
        const description = gobject.ext.cast(gtk.Label, gtk.Grid.getChildAt(grid, 1, 1) orelse return) orelse return;
        const version = gobject.ext.cast(gtk.Box, gtk.Grid.getChildAt(grid, 3, 0) orelse return) orelse return;
        const size = gobject.ext.cast(gtk.Label, gtk.Grid.getChildAt(grid, 4, 0) orelse return) orelse return;
        const old_version = gobject.ext.cast(gtk.Label, gtk.Widget.getFirstChild(version.as(gtk.Widget)) orelse return) orelse return;
        const arrow = gtk.Widget.getNextSibling(old_version.as(gtk.Widget)) orelse return;
        const new_version = gobject.ext.cast(gtk.Label, gtk.Widget.getNextSibling(arrow) orelse return) orelse return;

        gtk.Image.setFromIconName(icon, update.getSource().icon());
        gtk.Label.setLabel(name, update.getName());
        gtk.Label.setLabel(description, update.getDescription());
        gtk.Label.setLabel(old_version, update.getOldVersion());
        gtk.Label.setLabel(new_version, update.getNewVersion());
        gtk.Label.setLabel(size, update.getSize());
    }

    fn on_source_toggled(_: *gtk.ToggleButton, self: *Self) callconv(.c) void {
        const p = self.priv();
        gtk.Filter.changed(p.filter.as(gtk.Filter), .different);
        update_summary(self);
    }

    fn update_summary(self: *Self) void {
        const p = self.priv();
        var included: usize = 0;
        const model = p.list_store.as(gio.ListModel);
        const count = gio.ListModel.getNItems(model);
        for (0..count) |index| {
            const item: *gobject.Object = @ptrCast(@alignCast(gio.ListModel.getItem(model, @intCast(index)) orelse continue));
            if (gobject.ext.cast(UpdateObject, item)) |update| {
                if (self.is_source_active(update.getSource())) included += 1;
            }
            item.unref();
        }

        var buffer: [96]u8 = undefined;
        const text = std.fmt.bufPrintZ(&buffer, "{d} of {d} updates included", .{ included, count }) catch "Updates included";
        gtk.Label.setLabel(p.selected_label, text);
    }

    fn refresh_updates(self: *Self) callconv(.c) void {
        if (self.priv().loaded) start_load(self);
    }

    fn upgrade(self: *Self) callconv(.c) void {
        const p = self.priv();
        const flatpak = gtk.ToggleButton.getActive(p.flatpak_toggle) != 0;
        const aur = gtk.ToggleButton.getActive(p.aur_toggle) != 0;
        const standard = gtk.ToggleButton.getActive(p.native_toggle) != 0;

        const argv = ShellyCommands.upgrade(std.heap.c_allocator, flatpak, aur, standard) catch return;
        defer std.mem.Allocator.free(std.heap.c_allocator, argv);

        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer names.deinit(std.heap.c_allocator);

        const n = gio.ListModel.getNItems(p.list_store.as(gio.ListModel));
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const obj = gio.ListModel.getObject(p.list_store.as(gio.ListModel), i) orelse continue;
            const pkg = gobject.ext.cast(UpdateObject, obj) orelse continue;
            if (standard) {
                names.append(std.heap.c_allocator, pkg.getName()) catch continue;
                continue;
            }

            if (flatpak) {
                names.append(std.heap.c_allocator, pkg.getName()) catch continue;
                continue;
            }
            if (aur) {
                names.append(std.heap.c_allocator, pkg.getName()) catch continue;
                continue;
            }
        }
        if (names.items.len == 0) return;

        if (support.getWindow(ShellyWindow, self)) |win| {
            win.startTransaction(.{
                .title = "Upgrading packages",
                .argv = argv,
                .packages = names.items,
                .on_complete = &on_transaction_complete,
                .privileged = true,
                .ctx = self,
            });
        }
    }

    fn on_transaction_complete(ctx: *anyopaque, success: bool) void {
        const self: *UpdatePage = @ptrCast(@alignCast(ctx));
        if (!success) return;
        self.reload();
    }

    fn reload(self: *Self) void {
        const p = self.priv();
        p.generation += 1;

        const thread = std.Thread.spawn(.{}, load_worker, .{ self, p.generation }) catch return;
        self.update_source_labels();
        thread.detach();
    }

    const template_children = .{
        .{ "content_list", @offsetOf(Private, "content_list") },
        .{ "selected_label", @offsetOf(Private, "selected_label") },
        .{ "refresh_button", @offsetOf(Private, "refresh_button") },
        .{ "native_toggle", @offsetOf(Private, "native_toggle") },
        .{ "aur_toggle", @offsetOf(Private, "aur_toggle") },
        .{ "flatpak_toggle", @offsetOf(Private, "flatpak_toggle") },
        .{ "updates_stack", @offsetOf(Private, "updates_stack") },
        .{ "loading_page", @offsetOf(Private, "loading_page") },
        .{ "list_page", @offsetOf(Private, "list_page") },
        .{ "empty_page", @offsetOf(Private, "empty_page") },
        .{ "error_page", @offsetOf(Private, "error_page") },
        .{ "loading_spinner", @offsetOf(Private, "loading_spinner") },
        .{ "error_label", @offsetOf(Private, "error_label") },
    };

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            const wc = gobject.ext.as(gtk.Widget.Class, class);
            gtk.Widget.Class.setTemplateFromResource(wc, resource_path);
            inline for (template_children) |child| {
                support.bindChild(class, Private.offset, child[0], child[1]);
            }
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "refresh_updates", @ptrCast(&refresh_updates));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "upgrade_button", @ptrCast(&upgrade));
        }
    };
};
