const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gio = bindings.gio;
const glib = bindings.glib;
const gobject = bindings.gobject;
const support = @import("support.zig");
const AurPackageObject = @import("../g_objects/aur_package_object.zig").AurPackageObject;
const ConfirmDialog = @import("../dialog/page/yn_dialog.zig").ConfirmDialog;
const ShellyWindow = @import("../shelly_window.zig").ShellyWindow;
const ShellyCli = @import("../services/shelly_cli.zig").ShellyCli;
const AurPackage = @import("../models/aur_package.zig").AurPackage;
const runtime = @import("../services/runtime.zig");
const ShellyConfig = @import("../models/shelly_config.zig").ShellyConfig;
const AurPackageDetail = @import("aur_package_detail.zig").PackageDetail;
const translations = @import("../helpers/translations.zig");
const sorters = @import("../helpers/sorters.zig");

pub const AurPage = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gtk.Box;

    pub const title: [:0]const u8 = "AUR";
    pub const icon_name: [:0]const u8 = "arch-symbolic";
    const resource_path = "/com/shellyorg/shelly/ui/aur_page.ui";

    const Private = struct {
        list_store: *gio.ListStore,
        selection: *gtk.SingleSelection,
        search_entry: *gtk.SearchEntry,
        installed_toggle: *gtk.CheckButton,
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
        votes_column: *gtk.ColumnViewColumn,
        popularity_column: *gtk.ColumnViewColumn,
        version_column: *gtk.ColumnViewColumn,
        run_checks_check: *gtk.CheckButton,
        views_and_detail_hbox: *gtk.Box,
        detail_revealer: *gtk.Revealer,
        aur_detail: *AurPackageDetail,
        show_detail_pane_check: *gtk.CheckButton,
        show_detail_pane: bool,
        arena: ?*std.heap.ArenaAllocator,
        generation: u64,
        loaded: bool,
        applying_config: bool,
        installed_mode: bool,
        last_query: [256]u8,
        last_query_len: usize,
        check_map: std.AutoHashMapUnmanaged(*AurPackageObject, *gtk.CheckButton),
        var offset: c_int = 0;
    };

    const Mode = enum { search, installed };

    const LoadResult = struct {
        page: *Self,
        packages: []AurPackage,
        arena: *std.heap.ArenaAllocator,
        generation: u64,
        index: usize = 0,
        failed: bool = false,
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyAurPage",
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
        p.arena = null;
        p.generation = 0;
        p.installed_mode = false;
        p.last_query_len = 0;
        p.check_map = .empty;
        p.show_detail_pane = false;

        p.list_store = gio.ListStore.new(AurPackageObject.getGObjectType());

        const sort_model = gtk.SortListModel.new(p.list_store.as(gio.ListModel), null);

        p.selection = gtk.SingleSelection.new(sort_model.as(gio.ListModel));
        gtk.SingleSelection.setAutoselect(p.selection, 0);
        gtk.SingleSelection.setCanUnselect(p.selection, 1);

        gtk.ColumnView.setModel(p.package_grid, p.selection.as(gtk.SelectionModel));

        gtk.SortListModel.setSorter(sort_model, gtk.ColumnView.getSorter(p.package_grid));

        setup_name_column(p.name_column);
        setup_text_column(p.version_column, &AurPackageObject.getVersion, .start);
        setup_number_column(p.votes_column, &votes_text);
        setup_number_column(p.popularity_column, &popularity_text);

        const check_factory = gtk.SignalListItemFactory.new();
        _ = gtk.SignalListItemFactory.signals.setup.connect(check_factory, *Self, &on_check_setup, self, .{});
        _ = gtk.SignalListItemFactory.signals.bind.connect(check_factory, *Self, &on_check_bind, self, .{});
        _ = gtk.SignalListItemFactory.signals.unbind.connect(check_factory, *Self, &on_check_unbind, self, .{});
        gtk.ColumnViewColumn.setFactory(p.check_column, check_factory.as(gtk.ListItemFactory));

        _ = gtk.ColumnView.signals.activate.connect(p.package_grid, *Self, &on_row_activated, self, .{});
        _ = gobject.Object.signals.notify.connect(p.selection.as(gobject.Object), *Self, &on_selection_changed, self, .{ .detail = "selected" });
        _ = gtk.CheckButton.signals.toggled.connect(p.run_checks_check, *Self, &on_run_checks_toggled, self, .{});

        const detail = AurPackageDetail.new();
        p.aur_detail = detail;
        gtk.Revealer.setChild(p.detail_revealer, detail.as(gtk.Widget));

        attachSorter(p.check_column, sorters.boolSorter(AurPackageObject, &AurPackageObject.isSelected));
        attachSorter(p.name_column, sorters.stringSorter(AurPackageObject, &AurPackageObject.getName));
        attachSorter(p.version_column, sorters.stringSorter(AurPackageObject, &AurPackageObject.getVersion));
        attachSorter(p.votes_column, sorters.numericSorter(AurPackageObject, &AurPackageObject.getNumVotes));
        attachSorter(p.popularity_column, sorters.numericSorter(AurPackageObject, &AurPackageObject.getPopularity));

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
        if (p.arena) |a| {
            a.deinit();
            std.heap.c_allocator.destroy(a);
            p.arena = null;
        }
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

        fn name(self: State) [:0]const u8 {
            return switch (self) {
                .prompt => "prompt",
                .loading => "loading",
                .results => "results",
                .empty => "empty",
                .err => "error",
            };
        }
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
            .prompt => self.show_placeholder("system-search-symbolic", translations._("Search the AUR"), translations._("The AUR has no browsable index — type a package name to begin.")),
            .empty => self.show_placeholder("edit-find-symbolic", translations._("No packages found"), translations._("Try a shorter or more general keyword.")),
            .err => self.show_placeholder("dialog-error-symbolic", translations._("Could not reach the AUR"), translations._("Check your connection and try again.")),
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

    fn setup_text_column(
        column: *gtk.ColumnViewColumn,
        comptime getter: *const fn (*const AurPackageObject) [:0]const u8,
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
                const pkg = gobject.ext.cast(AurPackageObject, obj) orelse return;
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

    fn votes_text(buf: []u8, pkg: *const AurPackageObject) [:0]const u8 {
        return std.fmt.bufPrintZ(buf, "{d}", .{pkg.getNumVotes()}) catch "";
    }

    fn popularity_text(buf: []u8, pkg: *const AurPackageObject) [:0]const u8 {
        return std.fmt.bufPrintZ(buf, "{d:.2}", .{pkg.getPopularity()}) catch "";
    }

    fn on_selection_changed(_: *gobject.Object, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const p = self.priv();
        const obj = gtk.SingleSelection.getSelectedItem(p.selection) orelse {
            gtk.Revealer.setRevealChild(p.detail_revealer, 0);
            return;
        };
        const pkg_obj = gobject.ext.cast(AurPackageObject, obj) orelse return;
        p.aur_detail.showPackage(pkg_obj.getPackage());
        gtk.Revealer.setRevealChild(p.detail_revealer, 1);
    }

    fn setup_number_column(
        column: *gtk.ColumnViewColumn,
        comptime formatter: *const fn ([]u8, *const AurPackageObject) [:0]const u8,
    ) void {
        const c = struct {
            fn setup(_: *gtk.SignalListItemFactory, item: *gobject.Object, _: ?*anyopaque) callconv(.c) void {
                const cell = gobject.ext.cast(gtk.ColumnViewCell, item) orelse return;
                const label = gtk.Label.new("");
                gtk.Widget.setHalign(label.as(gtk.Widget), .start);
                gtk.ColumnViewCell.setChild(cell, label.as(gtk.Widget));
            }
            fn bind(_: *gtk.SignalListItemFactory, item: *gobject.Object, _: ?*anyopaque) callconv(.c) void {
                const cell = gobject.ext.cast(gtk.ColumnViewCell, item) orelse return;
                const obj = gtk.ColumnViewCell.getItem(cell) orelse return;
                const pkg = gobject.ext.cast(AurPackageObject, obj) orelse return;
                const child = gtk.ColumnViewCell.getChild(cell) orelse return;
                const label = gobject.ext.cast(gtk.Label, child) orelse return;
                var buf: [32]u8 = undefined;
                gtk.Label.setLabel(label, formatter(&buf, pkg));
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
                const pkg = gobject.ext.cast(AurPackageObject, obj) orelse return;
                const child = gtk.ColumnViewCell.getChild(cell) orelse return;
                const box = gobject.ext.cast(gtk.Box, child) orelse return;

                const title_box_w = gtk.Widget.getFirstChild(box.as(gtk.Widget)) orelse return;
                const title_box = gobject.ext.cast(gtk.Box, title_box_w) orelse return;
                const name_w = gtk.Widget.getFirstChild(title_box.as(gtk.Widget)) orelse return;
                const name_label = gobject.ext.cast(gtk.Label, name_w) orelse return;
                const ood_w = gtk.Widget.getNextSibling(name_w) orelse return;
                const installed_w = gtk.Widget.getNextSibling(ood_w) orelse return;
                const desc_w = gtk.Widget.getLastChild(box.as(gtk.Widget)) orelse return;
                const desc_label = gobject.ext.cast(gtk.Label, desc_w) orelse return;

                var buf: [256]u8 = undefined;
                const markup = std.fmt.bufPrintZ(&buf, "<b>{s}</b>", .{pkg.getName()}) catch pkg.getName();
                gtk.Label.setMarkup(name_label, markup);
                gtk.Widget.setVisible(ood_w, @intFromBool(pkg.isOutOfDate()));
                gtk.Widget.setVisible(installed_w, @intFromBool(pkg.isInstalled()));
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
        const pkg = gobject.ext.cast(AurPackageObject, obj) orelse return;
        const child = gtk.ColumnViewCell.getChild(cell) orelse return;
        const check = gobject.ext.cast(gtk.CheckButton, child) orelse return;

        page.priv().check_map.put(std.heap.c_allocator, pkg, check) catch {};
        set_sync_active(check, pkg.isSelected());
    }

    fn on_check_unbind(_: *gtk.SignalListItemFactory, item: *gobject.Object, page: *Self) callconv(.c) void {
        const cell = gobject.ext.cast(gtk.ColumnViewCell, item) orelse return;
        const obj = gtk.ColumnViewCell.getItem(cell) orelse return;
        const pkg = gobject.ext.cast(AurPackageObject, obj) orelse return;
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
        const pkg = gobject.ext.cast(AurPackageObject, obj) orelse return;
        pkg.setSelected(gtk.CheckButton.getActive(check) != 0);

        const page_ptr = gobject.Object.getData(check.as(gobject.Object), "page") orelse return;
        const self: *Self = @ptrCast(@alignCast(page_ptr));
        const p = self.priv();

        p.aur_detail.showPackage(pkg.getPackage());
        gtk.Revealer.setRevealChild(p.detail_revealer, 1);

        self.update_selection_ui();
    }

    fn on_row_activated(_: *gtk.ColumnView, position: c_uint, self: *Self) callconv(.c) void {
        const p = self.priv();
        const obj = gio.ListModel.getObject(p.selection.as(gio.ListModel), position) orelse return;
        defer obj.unref();
        const pkg = gobject.ext.cast(AurPackageObject, obj) orelse return;

        const new_state = !pkg.isSelected();
        pkg.setSelected(new_state);
        if (p.check_map.get(pkg)) |check| set_sync_active(check, new_state);

        p.aur_detail.showPackage(pkg.getPackage());
        gtk.Revealer.setRevealChild(p.detail_revealer, 1);

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
            const pkg = gobject.ext.cast(AurPackageObject, obj) orelse continue;
            if (pkg.isSelected()) count += 1;
        }
        return count;
    }

    fn collect_selected(self: *Self, list: *std.ArrayListUnmanaged([]const u8)) void {
        const p = self.priv();
        const model = p.list_store.as(gio.ListModel);
        const n = gio.ListModel.getNItems(model);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const obj = gio.ListModel.getObject(model, i) orelse continue;
            defer obj.unref();
            const pkg = gobject.ext.cast(AurPackageObject, obj) orelse continue;
            if (!pkg.isSelected()) continue;
            list.append(std.heap.c_allocator, pkg.getName()) catch continue;
        }
    }

    fn clear_selection(self: *Self) void {
        const p = self.priv();
        const model = p.list_store.as(gio.ListModel);
        const n = gio.ListModel.getNItems(model);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const obj = gio.ListModel.getObject(model, i) orelse continue;
            defer obj.unref();
            const pkg = gobject.ext.cast(AurPackageObject, obj) orelse continue;
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
        gtk.Widget.removeCssClass(btn, "destructive-action");

        var buf: [64]u8 = undefined;
        if (count == 0) {
            gtk.Button.setLabel(p.install_button, if (p.installed_mode) translations._("Remove Selected") else translations._("Install Selected"));
            gtk.Widget.setSensitive(btn, 0);
            gtk.Widget.setTooltipText(btn, translations._("Select one or more packages"));
        } else if (p.installed_mode) {
            gtk.Button.setLabel(
                p.install_button,
                std.fmt.bufPrintZ(&buf, "{s} {d} {s}", .{ translations._("Remove"), count, translations._("Package(s)") }) catch translations._("Remove Selected"),
            );
            gtk.Widget.setSensitive(btn, 1);
            gtk.Widget.addCssClass(btn, "destructive-action");
            gtk.Widget.setTooltipText(btn, null);
        } else {
            gtk.Button.setLabel(
                p.install_button,
                std.fmt.bufPrintZ(&buf, "{s} {d} {s}", .{ translations._("Install"), count, translations._("Package(s)") }) catch translations._("Install Selected"),
            );
            gtk.Widget.setSensitive(btn, 1);
            gtk.Widget.addCssClass(btn, "suggested-action");
            gtk.Widget.setTooltipText(btn, null);
        }
    }

    pub fn onMap(self: *Self) void {
        const p = self.priv();
        if (p.loaded) return;
        p.loaded = true;
        applyOptionsFromConfig(self);
        self.update_selection_ui();
        _ = gtk.Widget.grabFocus(p.search_entry.as(gtk.Widget));
        restore_current_view(self);
    }

    fn applyOptionsFromConfig(self: *Self) void {
        const svc = runtime.config orelse return;
        const cfg = svc.get() catch return;
        const p = self.priv();
        p.applying_config = true;
        defer p.applying_config = false;
        gtk.CheckButton.setActive(p.run_checks_check, @intFromBool(cfg.AurInstallRunChecks));
        p.show_detail_pane = cfg.AurInstallShowDetailPane;
        gtk.CheckButton.setActive(p.show_detail_pane_check, @intFromBool(cfg.AurInstallShowDetailPane));
        gtk.Widget.setVisible(p.detail_revealer.as(gtk.Widget), if (cfg.AurInstallShowDetailPane) 0 else 1);
    }

    fn on_run_checks_toggled(check: *gtk.CheckButton, self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.applying_config) return;
        updateConfigField(.AurInstallRunChecks, gtk.CheckButton.getActive(check) != 0);
    }

    fn updateConfigField(
        comptime field: std.meta.FieldEnum(ShellyConfig),
        value: std.meta.fieldInfo(ShellyConfig, field).type,
    ) void {
        const svc = runtime.config orelse return;
        svc.updateField(field, value) catch |err| {
            std.log.err("aur page: failed to update config: {t}", .{err});
        };
    }

    extern fn malloc_trim(pad: usize) c_int;

    pub fn onUnmap(self: *Self) void {
        const p = self.priv();
        if (!p.loaded) return;
        p.loaded = false;

        p.generation += 1;
        gio.ListStore.removeAll(p.list_store);

        if (p.arena) |a| {
            a.deinit();
            std.heap.c_allocator.destroy(a);
            p.arena = null;
        }

        _ = malloc_trim(0);
    }

    fn start_load(self: *Self, mode: Mode) void {
        const p = self.priv();
        p.generation += 1;
        gio.ListStore.removeAll(p.list_store);
        self.update_selection_ui();
        self.set_state(.loading);

        const thread = std.Thread.spawn(.{}, load_worker, .{ self, p.generation, mode }) catch {
            self.set_state(.err);
            return;
        };
        thread.detach();
    }

    fn load_worker(page: *Self, generation: u64, mode: Mode) void {
        const arena_ptr = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch return;
        arena_ptr.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        const alloc = arena_ptr.allocator();

        var threaded: std.Io.Threaded = .init(alloc, .{});
        defer threaded.deinit();

        const cli = ShellyCli{ .allocator = alloc, .io = threaded.io() };

        const parsed = switch (mode) {
            .search => blk: {
                const p = page.priv();
                const query = alloc.dupe(u8, p.last_query[0..p.last_query_len]) catch {
                    post_failure(page, arena_ptr, generation);
                    return;
                };
                break :blk cli.search_aur(query) catch |err| {
                    std.debug.print("aur_search failed: {t}\n", .{err});
                    post_failure(page, arena_ptr, generation);
                    return;
                };
            },
            .installed => cli.list_aur_installed() catch |err| {
                std.debug.print("aur_installed failed: {t}\n", .{err});
                post_failure(page, arena_ptr, generation);
                return;
            },
        };

        post_result(page, parsed.value, arena_ptr, generation);
    }

    fn post_result(page: *Self, packages: []AurPackage, arena: *std.heap.ArenaAllocator, generation: u64) void {
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

    fn post_failure(page: *Self, arena: *std.heap.ArenaAllocator, generation: u64) void {
        const result = std.heap.c_allocator.create(LoadResult) catch {
            arena.deinit();
            std.heap.c_allocator.destroy(arena);
            return;
        };
        result.* = .{
            .page = page,
            .packages = &.{},
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

        if (result.packages.len == 0) {
            page.set_state(.empty);
            page.update_selection_ui();
            finish(result);
            return 0;
        }

        const batch_size = 200;
        const end = @min(result.index + batch_size, result.packages.len);

        var batch: [batch_size]*gobject.Object = undefined;
        var i: usize = 0;
        for (result.packages[result.index..end]) |d| {
            const pkg = AurPackageObject.new(d) catch continue;
            batch[i] = pkg.as(gobject.Object);
            i += 1;
        }
        const pos = gio.ListModel.getNItems(p.list_store.as(gio.ListModel));
        gio.ListStore.splice(p.list_store, pos, 0, &batch, @intCast(i));
        for (batch[0..i]) |o| o.unref();

        result.index = end;
        if (result.index < result.packages.len) return 1;

        page.set_state(.results);
        page.update_selection_ui();

        page.set_state(.results);
        page.update_selection_ui();
        page.set_state(.results);
        page.update_selection_ui();

        if (result.packages.len > 0) {
            _ = gtk.SelectionModel.selectItem(p.selection.as(gtk.SelectionModel), 0, 1);
        }

        finish(result);
        return 0;
    }

    fn search_text(self: *Self) [:0]const u8 {
        const p = self.priv();
        return std.mem.span(gtk.Editable.getText(p.search_entry.as(gtk.Editable)));
    }

    fn on_search_activate(self: *Self) callconv(.c) void {
        const p = self.priv();

        if (p.installed_mode) {
            gtk.CheckButton.setActive(p.installed_toggle, 0);
        }

        const text = self.search_text();
        if (text.len == 0) {
            p.last_query_len = 0;
            gio.ListStore.removeAll(p.list_store);
            self.update_selection_ui();
            self.set_state(.prompt);
            return;
        }

        const len = @min(text.len, p.last_query.len);
        @memcpy(p.last_query[0..len], text[0..len]);
        p.last_query_len = len;

        self.start_load(.search);
    }

    fn restore_current_view(self: *Self) void {
        const p = self.priv();
        
        if (p.installed_mode) {
            self.start_load(.installed);
        } else if (p.last_query_len > 0) {
            self.start_load(.search);
        } else {
            gio.ListStore.removeAll(p.list_store);
            self.update_selection_ui();
            self.set_state(.prompt);
        }
    }
    
    fn on_installed_toggled(self: *Self) callconv(.c) void {
        const p = self.priv();
        p.installed_mode = gtk.CheckButton.getActive(p.installed_toggle) != 0;
        restore_current_view(self);
    }

    fn on_install_clicked(self: *Self) callconv(.c) void {
        const p = self.priv();
        if (self.selection_count() == 0) return;

        if (p.installed_mode) {
            const dialog = ConfirmDialog.new(
                translations._("Remove Packages"),
                translations._("Remove the selected AUR packages?"),
                &on_remove_response,
                self,
            );
            dialog.setButtons(translations._("Remove"), translations._("Cancel"));
            if (support.getWindow(ShellyWindow, self)) |win| win.showLockout(dialog.as(gtk.Widget));
        } else {
            const dialog = ConfirmDialog.new(
                translations._("Build from AUR"),
                translations._("Build and install the selected packages? This may take a while."),
                &on_install_response,
                self,
            );
            dialog.setButtons(translations._("Build"), translations._("Cancel"));
            if (support.getWindow(ShellyWindow, self)) |win| win.showLockout(dialog.as(gtk.Widget));
        }
    }

    fn on_detail_pane(check: *gtk.CheckButton, self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.applying_config) return;
        const active = gtk.CheckButton.getActive(check) != 0;
        p.show_detail_pane = active;
        gtk.Widget.setVisible(p.detail_revealer.as(gtk.Widget), if (active) 0 else 1);
        updateConfigField(.AurInstallShowDetailPane, active);
    }

    fn on_install_response(ctx: ?*anyopaque, confirmed: bool) void {
        const self: *AurPage = @ptrCast(@alignCast(ctx.?));
        if (support.getWindow(ShellyWindow, self)) |win| win.hideLockout();
        if (!confirmed) return;

        const p = self.priv();

        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer names.deinit(std.heap.c_allocator);
        self.collect_selected(&names);
        if (names.items.len == 0) return;

        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(std.heap.c_allocator);
        argv.append(std.heap.c_allocator, "install") catch return;
        argv.append(std.heap.c_allocator, "aur") catch return;
        for (names.items) |name| argv.append(std.heap.c_allocator, name) catch return;
        if (gtk.CheckButton.getActive(p.run_checks_check) != 0) {
            argv.append(std.heap.c_allocator, "--check") catch return;
        }

        if (support.getWindow(ShellyWindow, self)) |win| {
            win.startTransaction(.{
                .title = translations._("Installing AUR packages"),
                .argv = argv.items,
                .packages = names.items,
                .on_complete = &on_transaction_complete,
                .privileged = true,
                .ctx = self,
            });
        }
    }

    fn on_remove_response(ctx: ?*anyopaque, confirmed: bool) void {
        const self: *AurPage = @ptrCast(@alignCast(ctx.?));
        if (support.getWindow(ShellyWindow, self)) |win| win.hideLockout();
        if (!confirmed) return;

        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer names.deinit(std.heap.c_allocator);
        self.collect_selected(&names);
        if (names.items.len == 0) return;

        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(std.heap.c_allocator);
        argv.append(std.heap.c_allocator, "remove") catch return;
        argv.append(std.heap.c_allocator, "aur") catch return;
        for (names.items) |name| argv.append(std.heap.c_allocator, name) catch return;

        if (runtime.config) |cfg_service| {
            if (cfg_service.get()) |cfg| {
                if (!cfg.AurRemoveCascadeDelete) {
                    argv.append(std.heap.c_allocator, "--no-cascade") catch return;
                }
            } else |_| {}
        }

        if (support.getWindow(ShellyWindow, self)) |win| {
            win.startTransaction(.{
                .title = translations._("Removing AUR packages"),
                .argv = argv.items,
                .packages = names.items,
                .on_complete = &on_transaction_complete,
                .privileged = true,
                .ctx = self,
            });
        }
    }

    fn on_transaction_complete(ctx: *anyopaque, success: bool) void {
        const self: *AurPage = @ptrCast(@alignCast(ctx));
        if (!success) return;
        self.clear_selection();
        restore_current_view(self);
    }

    const template_children = .{
        .{ "search_entry", @offsetOf(Private, "search_entry") },
        .{ "installed_toggle", @offsetOf(Private, "installed_toggle") },
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
        .{ "votes_column", @offsetOf(Private, "votes_column") },
        .{ "popularity_column", @offsetOf(Private, "popularity_column") },
        .{ "version_column", @offsetOf(Private, "version_column") },
        .{ "run_checks_check", @offsetOf(Private, "run_checks_check") },
        .{ "views_and_detail_hbox", @offsetOf(Private, "views_and_detail_hbox") },
        .{ "detail_revealer", @offsetOf(Private, "detail_revealer") },
        .{ "show_detail_pane_check", @offsetOf(Private, "show_detail_pane_check") },
    };

    const template_callbacks = .{
        .{ "on_search_activate", &on_search_activate },
        .{ "on_installed_toggled", &on_installed_toggled },
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
