const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gio = bindings.gio;
const glib = bindings.glib;
const gobject = bindings.gobject;
const support = @import("support.zig");
const SearchResultObject = @import("../g_objects/search_result_object.zig").SearchResultObject;
const search_model = @import("../models/search_result.zig");
const SearchResult = search_model.SearchResult;
const Source = search_model.Source;
const FlatpakPackageDetail = @import("flatpak_package_detail.zig").FlatpakPackageDetail;
const StandardPackageDetail = @import("package_detail.zig").PackageDetail;
const AurPackageDetail = @import("aur_package_detail.zig").PackageDetail;
const ConfirmDialog = @import("../dialog/page/yn_dialog.zig").ConfirmDialog;
const ShellyWindow = @import("../shelly_window.zig").ShellyWindow;
const ShellyCli = @import("../services/shelly_cli.zig").ShellyCli;
const ShellyCommands = @import("../services/shelly_operation.zig").ShellyCommands;
const ShellyConfig = @import("../models/shelly_config.zig").ShellyConfig;
const runtime = @import("../services/runtime.zig");
const translations = @import("../helpers/translations.zig");
const sorters = @import("../helpers/sorters.zig");

pub const ShellySearchPage = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gtk.Box;

    pub const title: [:0]const u8 = "Shelly Search";
    pub const icon_name: [:0]const u8 = "system-search-symbolic";
    const resource_path = "/com/shellyorg/shelly/ui/search_page.ui";

    const Private = struct {
        list_store: *gio.ListStore,
        selection: *gtk.SingleSelection,
        search_entry: *gtk.SearchEntry,
        install_button: *gtk.Button,
        grid_overlay: *gtk.Overlay,
        loading_box: *gtk.Box,
        loading_spinner: *gtk.Spinner,
        placeholder_box: *gtk.Box,
        placeholder_icon: *gtk.Image,
        placeholder_title: *gtk.Label,
        placeholder_subtitle: *gtk.Label,
        package_grid: *gtk.ColumnView,
        check_column: *gtk.ColumnViewColumn,
        name_column: *gtk.ColumnViewColumn,
        source_column: *gtk.ColumnViewColumn,
        version_column: *gtk.ColumnViewColumn,
        standard_toggle: *gtk.ToggleButton,
        aur_toggle: *gtk.ToggleButton,
        flatpak_toggle: *gtk.ToggleButton,
        show_detail_pane_check: *gtk.CheckButton,
        source_filter: *gtk.CustomFilter,
        detail_revealer: *gtk.Revealer,
        detail_stack: *gtk.Stack,
        standard_detail: *StandardPackageDetail,
        aur_detail: *AurPackageDetail,
        flatpak_detail: *FlatpakPackageDetail,
        generation: u64,
        loaded: bool,
        applying_config: bool,
        show_detail_pane: bool,
        install_running: bool,
        last_query: [256]u8,
        last_query_len: usize,
        check_map: std.AutoHashMapUnmanaged(*SearchResultObject, *gtk.CheckButton),
        pending_installs: std.ArrayListUnmanaged(PendingInstall),
        var offset: c_int = 0;
    };

    const SourceSlot = struct {
        enabled: bool = false,
        ok: bool = false,
        items: []SearchResult = &.{},
        arena: ?*std.heap.ArenaAllocator = null,
    };

    const LoadResult = struct {
        page: *Self,
        items: []SearchResult,
        arena: *std.heap.ArenaAllocator,
        generation: u64,
        index: usize = 0,
        failed: bool = false,
    };

    const PendingInstall = struct {
        source: Source,
        names: []const []const u8 = &.{},
        remote: []const u8 = "",
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellySearchPage",
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
        p.applying_config = false;
        p.show_detail_pane = false;
        p.install_running = false;
        p.generation = 0;
        p.last_query_len = 0;
        p.check_map = .empty;
        p.pending_installs = .empty;

        p.list_store = gio.ListStore.new(SearchResultObject.getGObjectType());

        p.source_filter = gtk.CustomFilter.new(&source_filter_match, self, null);
        const filter_model = gtk.FilterListModel.new(p.list_store.as(gio.ListModel), p.source_filter.as(gtk.Filter));

        const sort_model = gtk.SortListModel.new(filter_model.as(gio.ListModel), null);

        p.selection = gtk.SingleSelection.new(sort_model.as(gio.ListModel));
        gtk.SingleSelection.setAutoselect(p.selection, 0);
        gtk.SingleSelection.setCanUnselect(p.selection, 1);

        gtk.ColumnView.setModel(p.package_grid, p.selection.as(gtk.SelectionModel));

        gtk.SortListModel.setSorter(sort_model, gtk.ColumnView.getSorter(p.package_grid));

        setup_name_column(p.name_column);
        setup_text_column(p.source_column, &source_label, .start);
        setup_text_column(p.version_column, &SearchResultObject.getVersion, .start);

        const check_factory = gtk.SignalListItemFactory.new();
        _ = gtk.SignalListItemFactory.signals.setup.connect(check_factory, *Self, &on_check_setup, self, .{});
        _ = gtk.SignalListItemFactory.signals.bind.connect(check_factory, *Self, &on_check_bind, self, .{});
        _ = gtk.SignalListItemFactory.signals.unbind.connect(check_factory, *Self, &on_check_unbind, self, .{});
        gtk.ColumnViewColumn.setFactory(p.check_column, check_factory.as(gtk.ListItemFactory));

        _ = gtk.ColumnView.signals.activate.connect(p.package_grid, *Self, &on_row_activated, self, .{});
        _ = gobject.Object.signals.notify.connect(p.selection.as(gobject.Object), *Self, &on_selection_changed, self, .{ .detail = "selected" });

        _ = gtk.ToggleButton.signals.toggled.connect(p.standard_toggle, *Self, &on_source_filter_toggled, self, .{});
        _ = gtk.ToggleButton.signals.toggled.connect(p.aur_toggle, *Self, &on_source_filter_toggled, self, .{});
        _ = gtk.ToggleButton.signals.toggled.connect(p.flatpak_toggle, *Self, &on_source_filter_toggled, self, .{});

        const standard_detail = StandardPackageDetail.new();
        p.standard_detail = standard_detail;
        _ = gtk.Stack.addNamed(p.detail_stack, standard_detail.as(gtk.Widget), "standard");

        const aur_detail = AurPackageDetail.new();
        p.aur_detail = aur_detail;
        _ = gtk.Stack.addNamed(p.detail_stack, aur_detail.as(gtk.Widget), "aur");

        const flatpak_detail = FlatpakPackageDetail.new();
        p.flatpak_detail = flatpak_detail;
        _ = gtk.Stack.addNamed(p.detail_stack, flatpak_detail.as(gtk.Widget), "flatpak");

        attachSorter(p.check_column, sorters.boolSorter(SearchResultObject, &SearchResultObject.isSelected));
        attachSorter(p.name_column, sorters.stringSorter(SearchResultObject, &SearchResultObject.getName));
        attachSorter(p.source_column, sorters.stringSorter(SearchResultObject, &source_label));
        attachSorter(p.version_column, sorters.stringSorter(SearchResultObject, &SearchResultObject.getVersion));

        const group = gio.SimpleActionGroup.new();
        const action = gio.SimpleAction.new("focus", null);
        _ = gio.SimpleAction.signals.activate.connect(action, *Self, &onFocusSearch, self, .{});
        gio.ActionMap.addAction(group.as(gio.ActionMap), action.as(gio.Action));
        gtk.Widget.insertActionGroup(self.as(gtk.Widget), "search", group.as(gio.ActionGroup));

        self.update_selection_ui();
        support.connectLifecycle(Self, self);
    }

    fn onFocusSearch(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        _ = gtk.Widget.grabFocus(self.priv().search_entry.as(gtk.Widget));
    }

    fn dispose(self: *Self) callconv(.c) void {
        const p = self.priv();
        p.check_map.deinit(std.heap.c_allocator);
        self.drainPendingInstalls();
        p.pending_installs.deinit(std.heap.c_allocator);
        gtk.Widget.disposeTemplate(self.as(gtk.Widget), getGObjectType());
        Class.parent.as(gobject.Object.Class).f_dispose.?(self.as(gobject.Object));
    }

    fn attachSorter(column: *gtk.ColumnViewColumn, sorter: *gtk.Sorter) void {
        gtk.ColumnViewColumn.setSorter(column, sorter);
        sorter.as(gobject.Object).unref();
    }

    const State = enum {
        prompt,
        loading,
        results,
        empty,
        err,
    };

    fn set_state(self: *Self, state: State) void {
        const p = self.priv();
        switch (state) {
            .loading => {
                gtk.Widget.setVisible(p.loading_box.as(gtk.Widget), 1);
                gtk.Widget.setVisible(p.placeholder_box.as(gtk.Widget), 0);
                gtk.Spinner.start(p.loading_spinner);
            },
            .results => {
                gtk.Widget.setVisible(p.loading_box.as(gtk.Widget), 0);
                gtk.Widget.setVisible(p.placeholder_box.as(gtk.Widget), 0);
                gtk.Spinner.stop(p.loading_spinner);
            },
            .prompt => self.show_placeholder("system-search-symbolic", translations._("Search everywhere"), translations._("Search standard repositories, the AUR and Flatpak at once. Type a name to begin.")),
            .empty => self.show_placeholder("edit-find-symbolic", translations._("No packages found"), translations._("Try a shorter or more general keyword.")),
            .err => self.show_placeholder("dialog-error-symbolic", translations._("Search failed"), translations._("Check your connection and try again.")),
        }
    }

    fn show_placeholder(self: *Self, icon: [:0]const u8, titles: [:0]const u8, subtitle: [:0]const u8) void {
        const p = self.priv();
        gtk.Spinner.stop(p.loading_spinner);
        gtk.Widget.setVisible(p.loading_box.as(gtk.Widget), 0);
        gtk.Image.setFromIconName(p.placeholder_icon, icon);
        gtk.Label.setLabel(p.placeholder_title, titles);
        gtk.Label.setLabel(p.placeholder_subtitle, subtitle);
        gtk.Widget.setVisible(p.placeholder_box.as(gtk.Widget), 1);
    }

    fn source_label(pkg: *const SearchResultObject) [:0]const u8 {
        return switch (pkg.getSource()) {
            .standard => translations._("Standard"),
            .aur => translations._("AUR"),
            .flatpak => translations._("Flatpak"),
        };
    }

    fn on_selection_changed(_: *gobject.Object, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const p = self.priv();
        const obj = gtk.SingleSelection.getSelectedItem(p.selection) orelse {
            gtk.Revealer.setRevealChild(p.detail_revealer, 0);
            return;
        };
        const pkg_obj = gobject.ext.cast(SearchResultObject, obj) orelse return;
        self.showDetail(pkg_obj);
    }

    fn showDetail(self: *Self, pkg_obj: *SearchResultObject) void {
        const p = self.priv();
        switch (pkg_obj.getSource()) {
            .standard => {
                p.standard_detail.showPackage(pkg_obj.getName(), pkg_obj.isInstalled(), null);
                gtk.Stack.setVisibleChildName(p.detail_stack, "standard");
            },
            .aur => {
                const aur = pkg_obj.getAurPackage() orelse return;
                p.aur_detail.showPackage(aur);
                gtk.Stack.setVisibleChildName(p.detail_stack, "aur");
            },
            .flatpak => {
                const hit = pkg_obj.getFlatpakHit() orelse return;
                p.flatpak_detail.showHit(hit);
                gtk.Stack.setVisibleChildName(p.detail_stack, "flatpak");
            },
        }
        gtk.Revealer.setRevealChild(p.detail_revealer, 1);
    }

    fn setup_text_column(
        column: *gtk.ColumnViewColumn,
        comptime getter: *const fn (*const SearchResultObject) [:0]const u8,
        comptime halign: gtk.Align,
    ) void {
        const c = struct {
            fn setup(_: *gtk.SignalListItemFactory, item: *gobject.Object, _: ?*anyopaque) callconv(.c) void {
                const cell = gobject.ext.cast(gtk.ColumnViewCell, item) orelse return;
                const label = gtk.Label.new("");
                gtk.Widget.setHalign(label.as(gtk.Widget), halign);
                gtk.Label.setEllipsize(label, .end);
                gtk.ColumnViewCell.setChild(cell, label.as(gtk.Widget));
            }
            fn bind(_: *gtk.SignalListItemFactory, item: *gobject.Object, _: ?*anyopaque) callconv(.c) void {
                const cell = gobject.ext.cast(gtk.ColumnViewCell, item) orelse return;
                const obj = gtk.ColumnViewCell.getItem(cell) orelse return;
                const pkg = gobject.ext.cast(SearchResultObject, obj) orelse return;
                const child = gtk.ColumnViewCell.getChild(cell) orelse return;
                const label = gobject.ext.cast(gtk.Label, child) orelse return;
                gtk.Label.setLabel(label, getter(pkg));
            }
        };
        const factory = gtk.SignalListItemFactory.new();
        _ = gtk.SignalListItemFactory.signals.setup.connect(factory, ?*anyopaque, &c.setup, null, .{});
        _ = gtk.SignalListItemFactory.signals.bind.connect(factory, ?*anyopaque, &c.bind, null, .{});
        gtk.ColumnViewColumn.setFactory(column, factory.as(gtk.ListItemFactory));
    }

    fn setup_name_column(column: *gtk.ColumnViewColumn) void {
        const c = struct {
            fn setup(_: *gtk.SignalListItemFactory, item: *gobject.Object, _: ?*anyopaque) callconv(.c) void {
                const cell = gobject.ext.cast(gtk.ColumnViewCell, item) orelse return;
                gtk.ListItem.setActivatable(gobject.ext.as(gtk.ListItem, cell), 1);

                const box = gtk.Box.new(.vertical, 0);
                gtk.Widget.setValign(box.as(gtk.Widget), .center);

                const title_box = gtk.Box.new(.horizontal, 6);

                const name_label = gtk.Label.new("");
                gtk.Widget.setHalign(name_label.as(gtk.Widget), .start);
                gtk.Label.setUseMarkup(name_label, 1);
                gtk.Label.setEllipsize(name_label, .end);
                gtk.Box.append(title_box, name_label.as(gtk.Widget));

                const ood_icon = gtk.Image.newFromIconName("dialog-warning-symbolic");
                gtk.Widget.setTooltipText(ood_icon.as(gtk.Widget), translations._("Flagged out of date"));
                gtk.Box.append(title_box, ood_icon.as(gtk.Widget));

                const installed_icon = gtk.Image.newFromIconName("object-select-symbolic");
                gtk.Widget.setTooltipText(installed_icon.as(gtk.Widget), translations._("Installed"));
                gtk.Box.append(title_box, installed_icon.as(gtk.Widget));

                const verified_icon = gtk.Image.newFromIconName("security-high-symbolic");
                gtk.Widget.setTooltipText(verified_icon.as(gtk.Widget), translations._("Verified"));
                gtk.Box.append(title_box, verified_icon.as(gtk.Widget));

                gtk.Box.append(box, title_box.as(gtk.Widget));

                const desc_label = gtk.Label.new("");
                gtk.Widget.setHalign(desc_label.as(gtk.Widget), .start);
                gtk.Widget.addCssClass(desc_label.as(gtk.Widget), "dim-label");
                gtk.Label.setEllipsize(desc_label, .end);
                gtk.Label.setMaxWidthChars(desc_label, 60);
                gtk.Box.append(box, desc_label.as(gtk.Widget));

                gtk.ColumnViewCell.setChild(cell, box.as(gtk.Widget));
            }

            fn bind(_: *gtk.SignalListItemFactory, item: *gobject.Object, _: ?*anyopaque) callconv(.c) void {
                const cell = gobject.ext.cast(gtk.ColumnViewCell, item) orelse return;
                const obj = gtk.ColumnViewCell.getItem(cell) orelse return;
                const pkg = gobject.ext.cast(SearchResultObject, obj) orelse return;
                const child = gtk.ColumnViewCell.getChild(cell) orelse return;
                const box = gobject.ext.cast(gtk.Box, child) orelse return;

                const title_box_w = gtk.Widget.getFirstChild(box.as(gtk.Widget)) orelse return;
                const title_box = gobject.ext.cast(gtk.Box, title_box_w) orelse return;
                const name_w = gtk.Widget.getFirstChild(title_box.as(gtk.Widget)) orelse return;
                const name_label = gobject.ext.cast(gtk.Label, name_w) orelse return;
                const ood_w = gtk.Widget.getNextSibling(name_w) orelse return;
                const installed_w = gtk.Widget.getNextSibling(ood_w) orelse return;
                const verified_w = gtk.Widget.getNextSibling(installed_w) orelse return;
                const desc_w = gtk.Widget.getLastChild(box.as(gtk.Widget)) orelse return;
                const desc_label = gobject.ext.cast(gtk.Label, desc_w) orelse return;

                var buf: [512]u8 = undefined;
                const escaped = glib.markupEscapeText(pkg.getName(), -1);
                defer glib.free(escaped);
                const markup = std.fmt.bufPrintZ(&buf, "<b>{s}</b>", .{escaped}) catch pkg.getName();
                gtk.Label.setMarkup(name_label, markup);
                gtk.Widget.setVisible(ood_w, @intFromBool(pkg.isOutOfDate()));
                gtk.Widget.setVisible(installed_w, @intFromBool(pkg.isInstalled()));
                gtk.Widget.setVisible(verified_w, @intFromBool(pkg.isVerified()));
                gtk.Label.setLabel(desc_label, pkg.getDescription());
            }
        };
        const factory = gtk.SignalListItemFactory.new();
        _ = gtk.SignalListItemFactory.signals.setup.connect(factory, ?*anyopaque, &c.setup, null, .{});
        _ = gtk.SignalListItemFactory.signals.bind.connect(factory, ?*anyopaque, &c.bind, null, .{});
        gtk.ColumnViewColumn.setFactory(column, factory.as(gtk.ListItemFactory));
    }

    fn on_check_setup(_: *gtk.SignalListItemFactory, item: *gobject.Object, self: *Self) callconv(.c) void {
        const cell = gobject.ext.cast(gtk.ColumnViewCell, item) orelse return;
        const check = gtk.CheckButton.new();
        gtk.Widget.setMarginStart(check.as(gtk.Widget), 10);
        gtk.Widget.setMarginEnd(check.as(gtk.Widget), 10);
        gtk.Widget.setValign(check.as(gtk.Widget), .center);
        gobject.Object.setData(check.as(gobject.Object), "cell", cell);
        gobject.Object.setData(check.as(gobject.Object), "page", self);
        _ = gtk.CheckButton.signals.toggled.connect(check, ?*anyopaque, &on_check_toggled, null, .{});
        gtk.ColumnViewCell.setChild(cell, check.as(gtk.Widget));
    }

    fn on_check_bind(_: *gtk.SignalListItemFactory, item: *gobject.Object, page: *Self) callconv(.c) void {
        const cell = gobject.ext.cast(gtk.ColumnViewCell, item) orelse return;
        const obj = gtk.ColumnViewCell.getItem(cell) orelse return;
        const pkg = gobject.ext.cast(SearchResultObject, obj) orelse return;
        const child = gtk.ColumnViewCell.getChild(cell) orelse return;
        const check = gobject.ext.cast(gtk.CheckButton, child) orelse return;

        page.priv().check_map.put(std.heap.c_allocator, pkg, check) catch {};
        set_sync_active(check, pkg.isSelected());
    }

    fn on_check_unbind(_: *gtk.SignalListItemFactory, item: *gobject.Object, page: *Self) callconv(.c) void {
        const cell = gobject.ext.cast(gtk.ColumnViewCell, item) orelse return;
        const obj = gtk.ColumnViewCell.getItem(cell) orelse return;
        const pkg = gobject.ext.cast(SearchResultObject, obj) orelse return;
        _ = page.priv().check_map.remove(pkg);
    }

    fn set_sync_active(check: *gtk.CheckButton, active: bool) void {
        gobject.Object.setData(check.as(gobject.Object), "syncing", @ptrFromInt(1));
        gtk.CheckButton.setActive(check, @intFromBool(active));
        gobject.Object.setData(check.as(gobject.Object), "syncing", null);
    }

    fn on_check_toggled(check: *gtk.CheckButton, _: ?*anyopaque) callconv(.c) void {
        if (gobject.Object.getData(check.as(gobject.Object), "syncing") != null) return;

        const cell_ptr = gobject.Object.getData(check.as(gobject.Object), "cell") orelse return;
        const cell: *gtk.ColumnViewCell = @ptrCast(@alignCast(cell_ptr));
        const obj = gtk.ColumnViewCell.getItem(cell) orelse return;
        const pkg = gobject.ext.cast(SearchResultObject, obj) orelse return;
        pkg.setSelected(gtk.CheckButton.getActive(check) != 0);

        const page_ptr = gobject.Object.getData(check.as(gobject.Object), "page") orelse return;
        const self: *Self = @ptrCast(@alignCast(page_ptr));

        self.showDetail(pkg);
        self.update_selection_ui();
    }

    fn on_row_activated(_: *gtk.ColumnView, position: c_uint, self: *Self) callconv(.c) void {
        const p = self.priv();
        const obj = gio.ListModel.getObject(p.selection.as(gio.ListModel), position) orelse return;
        defer obj.unref();
        const pkg = gobject.ext.cast(SearchResultObject, obj) orelse return;

        const new_state = !pkg.isSelected();
        pkg.setSelected(new_state);
        if (p.check_map.get(pkg)) |check| set_sync_active(check, new_state);

        self.showDetail(pkg);
        self.update_selection_ui();
    }

    fn selection_count(self: *Self) u32 {
        const p = self.priv();
        const model = p.list_store.as(gio.ListModel);
        const n = gio.ListModel.getNItems(model);
        var count: u32 = 0;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const obj = gio.ListModel.getObject(model, i) orelse continue;
            defer obj.unref();
            const pkg = gobject.ext.cast(SearchResultObject, obj) orelse continue;
            if (pkg.isSelected()) count += 1;
        }
        return count;
    }

    fn clear_selection(self: *Self) void {
        const p = self.priv();
        const model = p.list_store.as(gio.ListModel);
        const n = gio.ListModel.getNItems(model);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const obj = gio.ListModel.getObject(model, i) orelse continue;
            defer obj.unref();
            const pkg = gobject.ext.cast(SearchResultObject, obj) orelse continue;
            pkg.setSelected(false);
            if (p.check_map.get(pkg)) |check| set_sync_active(check, false);
        }
        self.update_selection_ui();
    }

    fn update_selection_ui(self: *Self) void {
        const p = self.priv();
        const count = self.selection_count();
        const btn = p.install_button.as(gtk.Widget);

        gtk.Widget.removeCssClass(btn, "suggested-action");

        if (count == 0 or p.install_running) {
            gtk.Button.setLabel(p.install_button, translations._("Install Selected"));
            gtk.Widget.setSensitive(btn, 0);
            gtk.Widget.setTooltipText(
                btn,
                if (p.install_running) translations._("Installation in progress") else translations._("Select one or more packages"),
            );
            return;
        }

        var buf: [64]u8 = undefined;
        gtk.Button.setLabel(
            p.install_button,
            std.fmt.bufPrintZ(&buf, "{s} {d} {s}", .{ translations._("Install"), count, translations._("Package(s)") }) catch translations._("Install Selected"),
        );
        gtk.Widget.setSensitive(btn, 1);
        gtk.Widget.addCssClass(btn, "suggested-action");
        gtk.Widget.setTooltipText(btn, null);
    }

    fn update_source_labels(self: *Self, standard_count: u32, aur_count: u32, flatpak_count: u32) void {
        const p = self.priv();
        var buf: [64]u8 = undefined;
        gtk.Button.setLabel(p.standard_toggle.as(gtk.Button), std.fmt.bufPrintZ(&buf, "{s} \u{00b7} {d}", .{ translations._("Standard"), standard_count }) catch translations._("Standard"));
        gtk.Button.setLabel(p.aur_toggle.as(gtk.Button), std.fmt.bufPrintZ(&buf, "{s} \u{00b7} {d}", .{ translations._("AUR"), aur_count }) catch translations._("AUR"));
        gtk.Button.setLabel(p.flatpak_toggle.as(gtk.Button), std.fmt.bufPrintZ(&buf, "{s} \u{00b7} {d}", .{ translations._("Flatpak"), flatpak_count }) catch translations._("Flatpak"));
    }

    fn reset_source_labels(self: *Self) void {
        const p = self.priv();
        gtk.Button.setLabel(p.standard_toggle.as(gtk.Button), translations._("Standard"));
        gtk.Button.setLabel(p.aur_toggle.as(gtk.Button), translations._("AUR"));
        gtk.Button.setLabel(p.flatpak_toggle.as(gtk.Button), translations._("Flatpak"));
    }

    pub fn onMap(self: *Self) void {
        const p = self.priv();
        if (p.loaded) return;
        p.loaded = true;

        const sources = enabledSources();

        gtk.ToggleButton.setActive(p.standard_toggle, 1);
        // Disabled sources are neither queried nor offered in the filter.
        gtk.Widget.setVisible(p.aur_toggle.as(gtk.Widget), @intFromBool(sources.aur));
        gtk.ToggleButton.setActive(p.aur_toggle, @intFromBool(sources.aur));
        gtk.Widget.setVisible(p.flatpak_toggle.as(gtk.Widget), @intFromBool(sources.flatpak));
        gtk.ToggleButton.setActive(p.flatpak_toggle, @intFromBool(sources.flatpak));

        self.applyOptionsFromConfig();
        self.update_selection_ui();
        _ = gtk.Widget.grabFocus(p.search_entry.as(gtk.Widget));
    }

    extern fn malloc_trim(pad: usize) c_int;

    pub fn onUnmap(self: *Self) void {
        const p = self.priv();
        if (!p.loaded) return;
        p.loaded = false;

        p.generation += 1;
        gio.ListStore.removeAll(p.list_store);
        self.drainPendingInstalls();
        p.install_running = false;
        self.reset_source_labels();

        _ = malloc_trim(0);
    }

    fn source_filter_match(item: *gobject.Object, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data.?));
        const pkg = gobject.ext.cast(SearchResultObject, item) orelse return 0;
        const p = self.priv();
        return switch (pkg.getSource()) {
            .standard => gtk.ToggleButton.getActive(p.standard_toggle),
            .aur => gtk.ToggleButton.getActive(p.aur_toggle),
            .flatpak => gtk.ToggleButton.getActive(p.flatpak_toggle),
        };
    }

    fn on_source_filter_toggled(_: *gtk.ToggleButton, self: *Self) callconv(.c) void {
        const p = self.priv();
        gtk.Filter.changed(p.source_filter.as(gtk.Filter), .different);

        // Results stay loaded; explain the grid if every source is filtered out.
        if (gio.ListModel.getNItems(p.list_store.as(gio.ListModel)) == 0) return;
        const any_enabled =
            gtk.ToggleButton.getActive(p.standard_toggle) != 0 or
            gtk.ToggleButton.getActive(p.aur_toggle) != 0 or
            gtk.ToggleButton.getActive(p.flatpak_toggle) != 0;
        if (!any_enabled) {
            self.show_placeholder(
                "dialog-warning-symbolic",
                translations._("No sources selected"),
                translations._("Enable at least one source filter above."),
            );
        } else {
            self.set_state(.results);
        }
    }

    fn applyOptionsFromConfig(self: *Self) void {
        const svc = runtime.config orelse return;
        const cfg = svc.get() catch return;
        const p = self.priv();
        p.applying_config = true;
        defer p.applying_config = false;
        p.show_detail_pane = cfg.SearchShowDetailPane;
        gtk.CheckButton.setActive(p.show_detail_pane_check, @intFromBool(cfg.SearchShowDetailPane));
        gtk.Widget.setVisible(p.detail_revealer.as(gtk.Widget), if (cfg.SearchShowDetailPane) 0 else 1);
    }

    fn on_detail_pane(check: *gtk.CheckButton, self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.applying_config) return;
        const active = gtk.CheckButton.getActive(check) != 0;
        p.show_detail_pane = active;
        gtk.Widget.setVisible(p.detail_revealer.as(gtk.Widget), if (active) 0 else 1);
        updateConfigField(.SearchShowDetailPane, active);
    }

    fn updateConfigField(
        comptime field: std.meta.FieldEnum(ShellyConfig),
        value: std.meta.fieldInfo(ShellyConfig, field).type,
    ) void {
        const svc = runtime.config orelse return;
        svc.updateField(field, value) catch |err| {
            std.log.err("search page: failed to update config: {t}", .{err});
        };
    }

    const Sources = struct {
        standard: bool = true,
        aur: bool = false,
        flatpak: bool = false,
    };

    fn enabledSources() Sources {
        var sources = Sources{};
        if (runtime.config) |svc| {
            if (svc.get()) |cfg| {
                sources.aur = cfg.AurEnabled;
                sources.flatpak = cfg.FlatPackEnabled;
            } else |_| {}
        }
        return sources;
    }

    fn start_load(self: *Self, sources: Sources) void {
        const p = self.priv();
        p.generation += 1;
        gio.ListStore.removeAll(p.list_store);
        self.update_selection_ui();
        self.reset_source_labels();
        self.set_state(.loading);

        const thread = std.Thread.spawn(.{}, load_worker, .{ self, p.generation, sources }) catch {
            self.set_state(.err);
            return;
        };
        thread.detach();
    }

    fn load_worker(page: *Self, generation: u64, sources: Sources) void {
        const p = page.priv();
        const query_buf: *[256]u8 = &p.last_query;
        const query_len = p.last_query_len;

        var slots = [3]SourceSlot{ .{}, .{}, .{} };
        slots[0].enabled = sources.standard;
        slots[1].enabled = sources.aur;
        slots[2].enabled = sources.flatpak;

        const tags = [3]Source{ .standard, .aur, .flatpak };
        var threads: [3]?std.Thread = .{ null, null, null };

        for (0..3) |i| {
            if (!slots[i].enabled) continue;
            threads[i] = std.Thread.spawn(.{}, source_worker, .{ &slots[i], query_buf, query_len, tags[i] }) catch null;
        }
        for (threads) |maybe_thread| {
            if (maybe_thread) |thread| thread.join();
        }

        var any_ok = false;
        for (slots) |slot| {
            if (slot.ok) any_ok = true;
        }

        if (!any_ok) {
            for (slots) |slot| freeSourceArena(slot.arena);
            post_failure(page, generation);
            return;
        }

        const arena_ptr = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch {
            for (slots) |slot| freeSourceArena(slot.arena);
            post_failure(page, generation);
            return;
        };
        arena_ptr.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        const alloc = arena_ptr.allocator();

        var merged: std.ArrayListUnmanaged(SearchResult) = .empty;
        for (slots) |slot| {
            if (!slot.ok) {
                freeSourceArena(slot.arena);
                continue;
            }
            for (slot.items) |item| {
                const copy = dupeResult(alloc, item) catch continue;
                merged.append(alloc, copy) catch continue;
            }
            freeSourceArena(slot.arena);
        }

        post_result(page, merged.items, arena_ptr, generation);
    }

    fn source_worker(slot: *SourceSlot, query_buf: *[256]u8, query_len: usize, source: Source) void {
        const query: []const u8 = query_buf[0..query_len];

        const arena_ptr = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch return;
        arena_ptr.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        slot.arena = arena_ptr;
        const alloc = arena_ptr.allocator();

        var threaded: std.Io.Threaded = .init(alloc, .{});
        defer threaded.deinit();

        const cli = ShellyCli{ .allocator = alloc, .io = threaded.io() };
        var items: std.ArrayListUnmanaged(SearchResult) = .empty;

        switch (source) {
            .standard => {
                const parsed = cli.search_standard(query) catch |err| {
                    std.debug.print("search standard failed: {t}\n", .{err});
                    return;
                };
                var seen = std.StringHashMap(void).init(alloc);
                for (parsed.value) |pkg| {
                    if (seen.contains(pkg.Name)) continue;
                    seen.put(pkg.Name, {}) catch continue;
                    items.append(alloc, .{
                        .source = .standard,
                        .name = alloc.dupeZ(u8, pkg.Name) catch continue,
                        .install_target = alloc.dupeZ(u8, pkg.Name) catch continue,
                        .version = alloc.dupeZ(u8, pkg.Version) catch continue,
                        .description = alloc.dupeZ(u8, pkg.Description) catch continue,
                        .repository = alloc.dupeZ(u8, pkg.Repository) catch continue,
                        .installed = std.mem.eql(u8, pkg.Repository, "local"),
                    }) catch continue;
                }
            },
            .aur => {
                const parsed = cli.search_aur(query) catch |err| {
                    std.debug.print("search aur failed: {t}\n", .{err});
                    return;
                };
                for (parsed.value) |pkg| {
                    items.append(alloc, .{
                        .source = .aur,
                        .name = alloc.dupeZ(u8, pkg.Name) catch continue,
                        .install_target = alloc.dupeZ(u8, pkg.Name) catch continue,
                        .version = alloc.dupeZ(u8, pkg.Version) catch continue,
                        .description = if (pkg.Description) |value| alloc.dupeZ(u8, value) catch "" else "",
                        .repository = alloc.dupeZ(u8, "AUR") catch continue,
                        .out_of_date = pkg.OutOfDate != null,
                        .aur = pkg,
                    }) catch continue;
                }
            },
            .flatpak => {
                const parsed = cli.search_flatpak(query) catch |err| {
                    std.debug.print("search flatpak failed: {t}\n", .{err});
                    return;
                };
                for (parsed.value.hits) |hit| {
                    const display = if (hit.name.len > 0) hit.name else hit.id;
                    items.append(alloc, .{
                        .source = .flatpak,
                        .name = alloc.dupeZ(u8, display) catch continue,
                        .install_target = alloc.dupeZ(u8, hit.id) catch continue,
                        .description = alloc.dupeZ(u8, hit.summary) catch continue,
                        .repository = alloc.dupeZ(u8, hit.remote) catch continue,
                        .verified = hit.verification_verified,
                        .flatpak = hit,
                    }) catch continue;
                }
            },
        }

        slot.items = items.items;
        slot.ok = true;
    }

    fn dupeResult(alloc: std.mem.Allocator, item: SearchResult) !SearchResult {
        return search_model.clone(alloc, item);
    }

    fn freeSourceArena(arena: ?*std.heap.ArenaAllocator) void {
        const value = arena orelse return;
        value.deinit();
        std.heap.c_allocator.destroy(value);
    }

    fn post_result(page: *Self, items: []SearchResult, arena: *std.heap.ArenaAllocator, generation: u64) void {
        const result = std.heap.c_allocator.create(LoadResult) catch return;
        result.* = .{
            .page = page,
            .items = items,
            .arena = arena,
            .generation = generation,
        };
        _ = glib.idleAdd(&onLoadComplete, result);
    }

    fn post_failure(page: *Self, generation: u64) void {
        const arena = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch return;
        arena.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        const result = std.heap.c_allocator.create(LoadResult) catch {
            arena.deinit();
            std.heap.c_allocator.destroy(arena);
            return;
        };
        result.* = .{
            .page = page,
            .items = &.{},
            .arena = arena,
            .generation = generation,
            .failed = true,
        };
        _ = glib.idleAdd(&onLoadComplete, result);
    }

    fn finish(result: *LoadResult) void {
        result.arena.deinit();
        std.heap.c_allocator.destroy(result.arena);
        std.heap.c_allocator.destroy(result);
    }

    fn onLoadComplete(data: ?*anyopaque) callconv(.c) c_int {
        const result: *LoadResult = @ptrCast(@alignCast(data.?));
        const page = result.page;
        const p = page.priv();

        if (result.generation != p.generation) {
            finish(result);
            return 0;
        }

        if (result.failed) {
            page.set_state(.err);
            page.update_selection_ui();
            finish(result);
            return 0;
        }

        if (result.items.len == 0) {
            page.set_state(.empty);
            page.update_selection_ui();
            finish(result);
            return 0;
        }

        const batch_size = 200;
        const end = @min(result.index + batch_size, result.items.len);

        var batch: [batch_size]*gobject.Object = undefined;
        var i: usize = 0;
        for (result.items[result.index..end]) |item| {
            const pkg = SearchResultObject.new(item) catch continue;
            batch[i] = pkg.as(gobject.Object);
            i += 1;
        }
        const pos = gio.ListModel.getNItems(p.list_store.as(gio.ListModel));
        gio.ListStore.splice(p.list_store, pos, 0, &batch, @intCast(i));
        for (batch[0..i]) |o| o.unref();

        result.index = end;
        if (result.index < result.items.len) return 1;

        page.set_state(.results);
        page.update_selection_ui();

        var standard_count: u32 = 0;
        var aur_count: u32 = 0;
        var flatpak_count: u32 = 0;
        for (result.items) |item| {
            switch (item.source) {
                .standard => standard_count += 1,
                .aur => aur_count += 1,
                .flatpak => flatpak_count += 1,
            }
        }
        page.update_source_labels(standard_count, aur_count, flatpak_count);

        finish(result);
        return 0;
    }

    fn search_text(self: *Self) [:0]const u8 {
        const p = self.priv();
        return std.mem.span(gtk.Editable.getText(p.search_entry.as(gtk.Editable)));
    }

    fn on_search_activate(self: *Self) callconv(.c) void {
        const p = self.priv();

        const text = self.search_text();
        if (text.len == 0) {
            p.last_query_len = 0;
            gio.ListStore.removeAll(p.list_store);
            self.update_selection_ui();
            self.reset_source_labels();
            self.set_state(.prompt);
            return;
        }

        const len = @min(text.len, p.last_query.len);
        @memcpy(p.last_query[0..len], text[0..len]);
        p.last_query_len = len;

        self.start_load(enabledSources());
    }

    fn on_install_clicked(self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.install_running) return;
        if (self.selection_count() == 0) return;

        const dialog = ConfirmDialog.new(
            translations._("Install Packages"),
            translations._("Install the selected packages?"),
            &on_install_response,
            self,
        );
        dialog.setButtons(translations._("Install"), translations._("Cancel"));
        if (support.getWindow(ShellyWindow, self)) |win| win.showLockout(dialog.as(gtk.Widget));
    }

    fn on_install_response(ctx: ?*anyopaque, confirmed: bool) void {
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        if (support.getWindow(ShellyWindow, self)) |win| win.hideLockout();
        if (!confirmed) return;

        const p = self.priv();
        if (p.install_running) return;

        var standard: std.ArrayListUnmanaged([]const u8) = .empty;
        var aur_list: std.ArrayListUnmanaged([]const u8) = .empty;
        var flatpaks: std.ArrayListUnmanaged(PendingInstall) = .empty;

        const model = p.list_store.as(gio.ListModel);
        const n = gio.ListModel.getNItems(model);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const obj = gio.ListModel.getObject(model, i) orelse continue;
            defer obj.unref();
            const pkg = gobject.ext.cast(SearchResultObject, obj) orelse continue;
            if (!pkg.isSelected()) continue;

            const target = std.heap.c_allocator.dupeZ(u8, pkg.getInstallTarget()) catch continue;
            switch (pkg.getSource()) {
                .standard => standard.append(std.heap.c_allocator, target) catch {
                    std.heap.c_allocator.free(target);
                    continue;
                },
                .aur => aur_list.append(std.heap.c_allocator, target) catch {
                    std.heap.c_allocator.free(target);
                    continue;
                },
                .flatpak => {
                    const single = std.heap.c_allocator.alloc([]const u8, 1) catch {
                        std.heap.c_allocator.free(target);
                        continue;
                    };
                    single[0] = target;
                    const remote = std.heap.c_allocator.dupe(u8, pkg.getRepository()) catch "";
                    flatpaks.append(std.heap.c_allocator, .{ .source = .flatpak, .names = single, .remote = remote }) catch {
                        std.heap.c_allocator.free(single);
                        if (remote.len > 0) std.heap.c_allocator.free(remote);
                        continue;
                    };
                },
            }
        }

        const queued_standard = self.enqueueGroup(.standard, &standard);
        const queued_aur = self.enqueueGroup(.aur, &aur_list);
        var queued_flatpak = false;
        for (flatpaks.items) |pending| {
            p.pending_installs.append(std.heap.c_allocator, pending) catch {
                freePending(pending);
                continue;
            };
            queued_flatpak = true;
        }
        flatpaks.deinit(std.heap.c_allocator);

        if (!queued_standard and !queued_aur and !queued_flatpak) return;

        p.install_running = true;
        self.update_selection_ui();
        self.runNextInstall();
    }

    fn enqueueGroup(self: *Self, source: Source, list: *std.ArrayListUnmanaged([]const u8)) bool {
        if (list.items.len == 0) {
            list.deinit(std.heap.c_allocator);
            return false;
        }
        const names = list.toOwnedSlice(std.heap.c_allocator) catch {
            for (list.items) |name| std.heap.c_allocator.free(name);
            list.deinit(std.heap.c_allocator);
            return false;
        };
        self.priv().pending_installs.append(std.heap.c_allocator, .{ .source = source, .names = names }) catch {
            for (names) |name| std.heap.c_allocator.free(name);
            std.heap.c_allocator.free(names);
            return false;
        };
        return true;
    }

    fn runNextInstall(self: *Self) void {
        const p = self.priv();

        if (p.pending_installs.items.len == 0) {
            p.install_running = false;
            self.clear_selection();
            if (p.last_query_len > 0) {
                self.start_load(enabledSources());
            }
            return;
        }

        const win = support.getWindow(ShellyWindow, self) orelse {
            self.drainPendingInstalls();
            p.install_running = false;
            self.update_selection_ui();
            return;
        };

        const next = p.pending_installs.orderedRemove(0);
        defer freePending(next);

        const step_title: [:0]const u8 = switch (next.source) {
            .standard => translations._("Installing packages"),
            .aur => translations._("Installing AUR packages"),
            .flatpak => translations._("Installing flatpak"),
        };
        const privileged = next.source != .flatpak;

        const argv = switch (next.source) {
            .standard => ShellyCommands.install(std.heap.c_allocator, next.names),
            .aur => ShellyCommands.install_aur(std.heap.c_allocator, next.names),
            .flatpak => ShellyCommands.installFlatpak(std.heap.c_allocator, next.names[0], .system, next.remote),
        } catch {
            self.drainPendingInstalls();
            p.install_running = false;
            self.update_selection_ui();
            return;
        };
        defer std.heap.c_allocator.free(argv);

        win.startTransaction(.{
            .title = step_title,
            .argv = argv,
            .packages = next.names,
            .on_complete = &on_install_step_complete,
            .privileged = privileged,
            .ctx = self,
        });
    }

    fn on_install_step_complete(ctx: *anyopaque, success: bool) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (!success) {
            self.drainPendingInstalls();
            self.priv().install_running = false;
            self.update_selection_ui();
            return;
        }
        self.runNextInstall();
    }

    fn drainPendingInstalls(self: *Self) void {
        const p = self.priv();
        for (p.pending_installs.items) |pending| freePending(pending);
        p.pending_installs.clearRetainingCapacity();
    }

    fn freePending(pending: PendingInstall) void {
        for (pending.names) |name| std.heap.c_allocator.free(name);
        std.heap.c_allocator.free(pending.names);
        if (pending.remote.len > 0) std.heap.c_allocator.free(pending.remote);
    }

    const template_children = .{
        .{ "search_entry", @offsetOf(Private, "search_entry") },
        .{ "install_button", @offsetOf(Private, "install_button") },
        .{ "grid_overlay", @offsetOf(Private, "grid_overlay") },
        .{ "loading_box", @offsetOf(Private, "loading_box") },
        .{ "loading_spinner", @offsetOf(Private, "loading_spinner") },
        .{ "placeholder_box", @offsetOf(Private, "placeholder_box") },
        .{ "placeholder_icon", @offsetOf(Private, "placeholder_icon") },
        .{ "placeholder_title", @offsetOf(Private, "placeholder_title") },
        .{ "placeholder_subtitle", @offsetOf(Private, "placeholder_subtitle") },
        .{ "package_grid", @offsetOf(Private, "package_grid") },
        .{ "check_column", @offsetOf(Private, "check_column") },
        .{ "name_column", @offsetOf(Private, "name_column") },
        .{ "source_column", @offsetOf(Private, "source_column") },
        .{ "version_column", @offsetOf(Private, "version_column") },
        .{ "standard_toggle", @offsetOf(Private, "standard_toggle") },
        .{ "aur_toggle", @offsetOf(Private, "aur_toggle") },
        .{ "flatpak_toggle", @offsetOf(Private, "flatpak_toggle") },
        .{ "show_detail_pane_check", @offsetOf(Private, "show_detail_pane_check") },
        .{ "detail_revealer", @offsetOf(Private, "detail_revealer") },
        .{ "detail_stack", @offsetOf(Private, "detail_stack") },
    };

    const template_callbacks = .{
        .{ "on_search_activate", &on_search_activate },
        .{ "on_install_clicked", &on_install_clicked },
        .{ "on_detail_pane", &on_detail_pane },
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
            inline for (template_callbacks) |cb| {
                gtk.Widget.Class.bindTemplateCallbackFull(wc, cb[0], @ptrCast(cb[1]));
            }
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }
    };
};
