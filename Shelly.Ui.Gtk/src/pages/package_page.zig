const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gio = bindings.gio;
const glib = bindings.glib;
const gobject = bindings.gobject;
const support = @import("support.zig");
const PackageObject = @import("../g_objects/package_object.zig").PackageObject;
const ConfirmDialog = @import("../dialog/page/yn_dialog.zig").ConfirmDialog;
const ShellyWindow = @import("../shelly_window.zig").ShellyWindow;
const ShellyCli = @import("../services/shelly_cli.zig").ShellyCli;
const SizeConverter = @import("../helpers/size_converts.zig").SizeConverter;
const IconResolver = @import("../services/icon_resolver.zig").IconResolver;
const Package = @import("../models/packages.zig").Package;
const runtime = @import("../services/runtime.zig");
const c_string = @import("../helpers/c_string.zig");
const ShellyConfig = @import("../models/shelly_config.zig").ShellyConfig;
const ViewType = @import("../models/shelly_config.zig").ViewType;
const RecommendCategory = @import("../models/recommendation.zig").RecommendCategory;
const sorters = @import("../helpers/sorters.zig");
const recommendations = @import("../services/recommendations.zig");
const translations = @import("../helpers/translations.zig");

const Event = @import("../services/shelly_operation.zig").Event;
const PackageDetail = @import("package_detail.zig").PackageDetail;

pub const PackagePage = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gtk.Box;

    pub const title: [:0]const u8 = "Package";
    pub const icon_name: [:0]const u8 = "package-x-generic-symbolic";
    const resource_path = "/com/shellyorg/shelly/ui/package_page.ui";

    const Private = struct {
        column_view: *gtk.ColumnView,
        name_column: *gtk.ColumnViewColumn,
        version_column: *gtk.ColumnViewColumn,
        size_column: *gtk.ColumnViewColumn,
        repository_column: *gtk.ColumnViewColumn,
        install_date_column: *gtk.ColumnViewColumn,
        check_column: *gtk.ColumnViewColumn,
        no_results_overlay: *gtk.Widget,
        no_results_label: *gtk.Label,
        selection: *gtk.SingleSelection,
        list_store: *gio.ListStore,
        loading_overlay: *gtk.Box,
        filter: *gtk.CustomFilter,
        grouping_selection: *gtk.DropDown,
        loading_spinner: *gtk.Spinner,
        error_label: *gtk.Label,
        search_entry: *gtk.SearchEntry,
        filter_model: *gtk.FilterListModel,
        grid_view: *gtk.GridView,
        detail_hbox: *gtk.Box,
        detail_grid_hbox: *gtk.Box,
        grid_view_button: *gtk.ToggleButton,
        list_view_button: *gtk.ToggleButton,
        install_button: *gtk.Button,
        cart_items_box: *gtk.Box,
        cart_label: *gtk.Label,
        upgrade_check: *gtk.CheckButton,
        show_hidden_check: *gtk.CheckButton,
        show_explicit_only_check: *gtk.CheckButton,
        show_depends_only_check: *gtk.CheckButton,
        show_detail_pane_check: *gtk.CheckButton,
        arena: ?*std.heap.ArenaAllocator,
        selected_group: [64]u8,
        selected_group_len: usize,
        generation: u64,
        show_installed_only: bool,
        show_explicit_only: bool,
        show_depends_only: bool,
        show_hidden: bool,
        show_detail_pane: bool,

        check_map_grid: std.AutoHashMapUnmanaged(*PackageObject, *gtk.CheckButton),
        check_map_column: std.AutoHashMapUnmanaged(*PackageObject, *gtk.CheckButton),
        loaded: bool,
        applying_config: bool,
        resolver: IconResolver,
        search_text: [256]u8,
        search_len: usize,

        detail_revealer: *gtk.Revealer,
        detail: *PackageDetail,

        var offset: c_int = 0;
    };

    const LoadResult = struct {
        page: *Self,
        packages: []Package,
        groups: []const []const u8,
        arena: *std.heap.ArenaAllocator,
        generation: u64,
        index: usize = 0,
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyPackagePage",
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
        p.show_installed_only = false;
        p.show_explicit_only = false;
        p.show_hidden = false;
        p.show_detail_pane = false;
        p.check_map_grid = .empty;
        p.check_map_column = .empty;

        const detail = PackageDetail.new();
        p.detail = detail;
        gtk.Revealer.setChild(p.detail_revealer, detail.as(gtk.Widget));

        p.list_store = gio.ListStore.new(PackageObject.getGObjectType());

        p.filter = gtk.CustomFilter.new(&filter_func, self, null);
        p.filter_model = gtk.FilterListModel.new(p.list_store.as(gio.ListModel), p.filter.as(gtk.Filter));

        const sort_model = gtk.SortListModel.new(p.filter_model.as(gio.ListModel), null);

        p.selection = gtk.SingleSelection.new(sort_model.as(gio.ListModel));
        gtk.SingleSelection.setAutoselect(p.selection, 0);
        gtk.SingleSelection.setCanUnselect(p.selection, 1);

        gtk.ColumnView.setModel(p.column_view, p.selection.as(gtk.SelectionModel));
        gtk.GridView.setModel(p.grid_view, p.selection.as(gtk.SelectionModel));

        gtk.SortListModel.setSorter(sort_model, gtk.ColumnView.getSorter(p.column_view));

        gtk.GridView.setMaxColumns(p.grid_view, 4);
        gtk.GridView.setMinColumns(p.grid_view, 1);

        setup_grid_factory(self, p.grid_view);
        setup_name_column(self, p.name_column);
        setup_signal_text_label_column(p.version_column, &PackageObject.getVersion, gtk.Align.start);
        setup_signal_text_label_column(p.repository_column, &PackageObject.getRepository, gtk.Align.start);

        const check_factory = gtk.SignalListItemFactory.new();
        _ = gtk.SignalListItemFactory.signals.setup.connect(check_factory, *Self, &on_check_setup, self, .{});
        _ = gtk.SignalListItemFactory.signals.bind.connect(check_factory, *Self, &on_check_bind, self, .{});
        _ = gtk.SignalListItemFactory.signals.unbind.connect(check_factory, *Self, &on_check_unbind, self, .{});
        gtk.ColumnViewColumn.setFactory(p.check_column, check_factory.as(gtk.ListItemFactory));

        const size_factory = gtk.SignalListItemFactory.new();
        _ = gtk.SignalListItemFactory.signals.setup.connect(size_factory, ?*anyopaque, &size_setup, null, .{});
        _ = gtk.SignalListItemFactory.signals.bind.connect(size_factory, ?*anyopaque, &size_bind, null, .{});
        gtk.ColumnViewColumn.setFactory(p.size_column, size_factory.as(gtk.ListItemFactory));

        _ = gtk.SearchEntry.signals.search_changed.connect(p.search_entry, *Self, &on_search_changed, self, .{});

        _ = gobject.Object.signals.notify.connect(p.grouping_selection.as(gobject.Object), *Self, &on_group_notify, self, .{ .detail = "selected" });
        _ = gobject.Object.signals.notify.connect(p.selection.as(gobject.Object), *Self, &on_selection_changed, self, .{ .detail = "selected" });

        _ = gtk.GridView.signals.activate.connect(p.grid_view, *Self, &on_grid_activated, self, .{});
        _ = gtk.ColumnView.signals.activate.connect(p.column_view, *Self, &on_column_activated, self, .{});

        p.resolver = IconResolver.init(std.heap.c_allocator);

        _ = gtk.CheckButton.signals.toggled.connect(p.upgrade_check, *Self, &on_upgrade_toggled, self, .{});
        _ = gtk.CheckButton.signals.toggled.connect(p.show_hidden_check, *Self, &on_show_hidden_toggled, self, .{});

        const install_date_factory = gtk.SignalListItemFactory.new();
        _ = gtk.SignalListItemFactory.signals.setup.connect(install_date_factory, ?*anyopaque, &install_date_setup, null, .{});
        _ = gtk.SignalListItemFactory.signals.bind.connect(install_date_factory, ?*anyopaque, &install_date_bind, null, .{});
        gtk.ColumnViewColumn.setFactory(p.install_date_column, install_date_factory.as(gtk.ListItemFactory));

        gtk.ColumnViewColumn.setVisible(p.install_date_column, 0);

        attachSorter(p.check_column, sorters.boolSorter(PackageObject, &PackageObject.isSelected));
        attachSorter(p.install_date_column, sorters.stringSorter(PackageObject, &PackageObject.getInstallDate));
        attachSorter(p.name_column, sorters.stringSorter(PackageObject, &PackageObject.getName));
        attachSorter(p.size_column, sorters.numericSorter(PackageObject, &PackageObject.getInstalledSize));
        attachSorter(p.repository_column, sorters.stringSorter(PackageObject, &PackageObject.getRepository));
        attachSorter(p.version_column, sorters.stringSorter(PackageObject, &PackageObject.getVersion));

        const group = gio.SimpleActionGroup.new();
        const action = gio.SimpleAction.new("focus", null);
        _ = gio.SimpleAction.signals.activate.connect(action, *Self, &onFocusSearch, self, .{});
        gio.ActionMap.addAction(group.as(gio.ActionMap), action.as(gio.Action));
        gtk.Widget.insertActionGroup(self.as(gtk.Widget), "search", group.as(gio.ActionGroup));

        applyOptionsFromConfig(self);
        support.connectLifecycle(Self, self);
    }

    fn onFocusSearch(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        _ = gtk.Widget.grabFocus(self.priv().search_entry.as(gtk.Widget));
    }

    fn attachSorter(column: *gtk.ColumnViewColumn, sorter: *gtk.Sorter) void {
        gtk.ColumnViewColumn.setSorter(column, sorter);
        sorter.as(gobject.Object).unref();
    }

    fn install_date_setup(_: *gtk.SignalListItemFactory, item: *gobject.Object, _: ?*anyopaque) callconv(.c) void {
        const cell = gobject.ext.cast(gtk.ColumnViewCell, item) orelse return;
        const label = gtk.Label.new("");
        gtk.Widget.setHalign(label.as(gtk.Widget), gtk.Align.start);
        gtk.Label.setEllipsize(label, .end);
        gtk.ColumnViewCell.setChild(cell, label.as(gtk.Widget));
    }

    fn install_date_bind(_: *gtk.SignalListItemFactory, item: *gobject.Object, _: ?*anyopaque) callconv(.c) void {
        const cell = gobject.ext.cast(gtk.ColumnViewCell, item) orelse return;
        const obj = gtk.ColumnViewCell.getItem(cell) orelse return;
        const pkg = gobject.ext.cast(PackageObject, obj) orelse return;
        const child = gtk.ColumnViewCell.getChild(cell) orelse return;
        const label = gobject.ext.cast(gtk.Label, child) orelse return;
        gtk.Label.setLabel(label, if (pkg.isInstalled()) pkg.getInstallDate() else "");
    }

    fn setup_signal_text_label_column(column: *gtk.ColumnViewColumn, comptime getter: *const fn (*PackageObject) [:0]const u8, comptime halign: gtk.Align) void {
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
                const pkg = gobject.ext.cast(PackageObject, obj) orelse return;
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

    fn setup_name_column(self: *Self, column: *gtk.ColumnViewColumn) void {
        const c = struct {
            fn setup(_: *gtk.SignalListItemFactory, item: *gobject.Object, _: *Self) callconv(.c) void {
                const cell = gobject.ext.cast(gtk.ColumnViewCell, item) orelse return;
                gtk.ListItem.setActivatable(gobject.ext.as(gtk.ListItem, cell), 1);

                const box = gtk.Box.new(.horizontal, 8);

                const icon = gtk.Image.new();
                gtk.Image.setPixelSize(icon, 32);
                gtk.Widget.setValign(icon.as(gtk.Widget), .center);
                gtk.Box.append(box, icon.as(gtk.Widget));

                const text_box = gtk.Box.new(.vertical, 0);
                gtk.Widget.setValign(text_box.as(gtk.Widget), .center);
                gtk.Widget.setHexpand(text_box.as(gtk.Widget), 1);

                const name_row = gtk.Box.new(.horizontal, 6);

                const label = gtk.Label.new("");
                gtk.Widget.setHalign(label.as(gtk.Widget), .start);
                gtk.Label.setUseMarkup(label, 1);
                gtk.Label.setEllipsize(label, .end);
                gtk.Box.append(name_row, label.as(gtk.Widget));

                const installed_icon = gtk.Image.newFromIconName("object-select-symbolic");
                gtk.Widget.setTooltipText(installed_icon.as(gtk.Widget), translations._("Installed"));
                gtk.Box.append(name_row, installed_icon.as(gtk.Widget));

                gtk.Box.append(text_box, name_row.as(gtk.Widget));

                const desc_label = gtk.Label.new("");
                gtk.Widget.setHalign(desc_label.as(gtk.Widget), .start);
                gtk.Widget.addCssClass(desc_label.as(gtk.Widget), "dim-label");
                gtk.Label.setEllipsize(desc_label, .end);
                gtk.Label.setMaxWidthChars(desc_label, 60);
                gtk.Box.append(text_box, desc_label.as(gtk.Widget));

                gtk.Box.append(box, text_box.as(gtk.Widget));

                gtk.ColumnViewCell.setChild(cell, box.as(gtk.Widget));
            }

            fn bind(_: *gtk.SignalListItemFactory, item: *gobject.Object, page: *Self) callconv(.c) void {
                const cell = gobject.ext.cast(gtk.ColumnViewCell, item) orelse return;
                const obj = gtk.ColumnViewCell.getItem(cell) orelse return;
                const pkg = gobject.ext.cast(PackageObject, obj) orelse return;
                const child = gtk.ColumnViewCell.getChild(cell) orelse return;
                const box = gobject.ext.cast(gtk.Box, child) orelse return;

                const icon_w = gtk.Widget.getFirstChild(box.as(gtk.Widget)) orelse return;
                const icon = gobject.ext.cast(gtk.Image, icon_w) orelse return;
                const text_w = gtk.Widget.getNextSibling(icon_w) orelse return;
                const name_row_w = gtk.Widget.getFirstChild(text_w) orelse return;
                const label_w = gtk.Widget.getFirstChild(name_row_w) orelse return;
                const label = gobject.ext.cast(gtk.Label, label_w) orelse return;
                const installed_w = gtk.Widget.getNextSibling(label_w) orelse return;
                const desc_w = gtk.Widget.getLastChild(text_w) orelse return;
                const desc_label = gobject.ext.cast(gtk.Label, desc_w) orelse return;

                var buf: [512]u8 = undefined;
                const escaped = glib.markupEscapeText(pkg.getName(), -1);
                defer glib.free(escaped);
                const markup = std.fmt.bufPrintZ(&buf, "<b>{s}</b>", .{escaped}) catch pkg.getName();
                gtk.Label.setMarkup(label, markup);
                gtk.Label.setLabel(desc_label, pkg.getDescription());
                gtk.Widget.setVisible(installed_w, @intFromBool(pkg.isInstalled()));

                const p = page.priv();
                if (p.resolver.resolve(pkg.getName())) |path| {
                    gtk.Image.setFromFile(icon, path);
                } else {
                    gtk.Image.setFromIconName(icon, "package-x-generic-symbolic");
                }
            }
        };

        const factory = gtk.SignalListItemFactory.new();
        _ = gtk.SignalListItemFactory.signals.setup.connect(factory, *Self, &c.setup, self, .{});
        _ = gtk.SignalListItemFactory.signals.bind.connect(factory, *Self, &c.bind, self, .{});
        gtk.ColumnViewColumn.setFactory(column, factory.as(gtk.ListItemFactory));
    }

    fn on_check_setup(_: *gtk.SignalListItemFactory, item: *gobject.Object, self: *Self) callconv(.c) void {
        const cell = gobject.ext.cast(gtk.ColumnViewCell, item) orelse return;
        const check = gtk.CheckButton.new();
        gtk.Widget.setMarginStart(check.as(gtk.Widget), 10);
        gtk.Widget.setMarginEnd(check.as(gtk.Widget), 10);
        gobject.Object.setData(check.as(gobject.Object), "cell", cell);
        gobject.Object.setData(check.as(gobject.Object), "page", self);
        _ = gtk.CheckButton.signals.toggled.connect(check, ?*anyopaque, &on_check_toggled, null, .{});

        gtk.ColumnViewCell.setChild(cell, check.as(gtk.Widget));
    }

    fn on_check_bind(_: *gtk.SignalListItemFactory, item: *gobject.Object, page: *Self) callconv(.c) void {
        const cell = gobject.ext.cast(gtk.ColumnViewCell, item) orelse return;
        const obj = gtk.ColumnViewCell.getItem(cell) orelse return;
        const pkg = gobject.ext.cast(PackageObject, obj) orelse return;
        const child = gtk.ColumnViewCell.getChild(cell) orelse return;
        const check = gobject.ext.cast(gtk.CheckButton, child) orelse return;

        page.priv().check_map_column.put(std.heap.c_allocator, pkg, check) catch {};

        gobject.Object.setData(check.as(gobject.Object), "syncing", @ptrFromInt(1));
        gtk.CheckButton.setActive(check, @intFromBool(pkg.isSelected()));
        gobject.Object.setData(check.as(gobject.Object), "syncing", null);
    }

    fn on_check_unbind(_: *gtk.SignalListItemFactory, item: *gobject.Object, page: *Self) callconv(.c) void {
        const cell = gobject.ext.cast(gtk.ColumnViewCell, item) orelse return;
        const obj = gtk.ColumnViewCell.getItem(cell) orelse return;
        const pkg = gobject.ext.cast(PackageObject, obj) orelse return;
        _ = page.priv().check_map_column.remove(pkg);
    }

    fn size_bind(_: *gtk.SignalListItemFactory, item: *gobject.Object, _: ?*anyopaque) callconv(.c) void {
        const cell = gobject.ext.cast(gtk.ColumnViewCell, item) orelse return;
        const obj = gtk.ColumnViewCell.getItem(cell) orelse return;
        const pkg = gobject.ext.cast(PackageObject, obj) orelse return;
        const child = gtk.ColumnViewCell.getChild(cell) orelse return;
        const label = gobject.ext.cast(gtk.Label, child) orelse return;
        var buf: [32]u8 = undefined;
        gtk.Label.setLabel(label, SizeConverter.convert_null_term(&buf, pkg.getInstalledSize()));
    }

    fn size_setup(_: *gtk.SignalListItemFactory, item: *gobject.Object, _: ?*anyopaque) callconv(.c) void {
        const cell = gobject.ext.cast(gtk.ColumnViewCell, item) orelse return;
        const label = gtk.Label.new("");
        gtk.Widget.setHalign(label.as(gtk.Widget), gtk.Align.start);
        gtk.Label.setEllipsize(label, .end);
        gtk.ColumnViewCell.setChild(cell, label.as(gtk.Widget));
    }

    fn on_check_toggled(check: *gtk.CheckButton, _: ?*anyopaque) callconv(.c) void {
        if (gobject.Object.getData(check.as(gobject.Object), "syncing") != null) return;

        const cell_ptr = gobject.Object.getData(check.as(gobject.Object), "cell") orelse return;
        const cell: *gtk.ColumnViewCell = @ptrCast(@alignCast(cell_ptr));
        const obj = gtk.ColumnViewCell.getItem(cell) orelse return;
        const pkg = gobject.ext.cast(PackageObject, obj) orelse return;
        pkg.setSelected(gtk.CheckButton.getActive(check) != 0);

        const page_ptr = gobject.Object.getData(check.as(gobject.Object), "page") orelse return;

        const self: *Self = @ptrCast(@alignCast(page_ptr));
        const p = self.priv();
        const path = p.resolver.resolve(pkg.getName());
        p.detail.showPackage(pkg.getName(), pkg.isInstalled(), path);
        gtk.Revealer.setRevealChild(p.detail_revealer, 1);

        self.update_selection_ui();
    }

    fn setup_grid_factory(self: *Self, view: *gtk.GridView) void {
        const c = struct {
            fn setup(_: *gtk.SignalListItemFactory, item: *gobject.Object, self_setup: *Self) callconv(.c) void {
                const list_item = gobject.ext.cast(gtk.ListItem, item) orelse return;
                gtk.ListItem.setActivatable(list_item, 1);

                const content_grid = gtk.Grid.new();
                gtk.Widget.setMarginStart(content_grid.as(gtk.Widget), 10);
                gtk.Widget.setMarginEnd(content_grid.as(gtk.Widget), 12);
                gtk.Widget.setMarginTop(content_grid.as(gtk.Widget), 12);
                gtk.Widget.setMarginBottom(content_grid.as(gtk.Widget), 10);
                gtk.Grid.setColumnSpacing(content_grid, 6);
                gtk.Grid.setRowSpacing(content_grid, 0);
                gtk.Widget.setHexpand(content_grid.as(gtk.Widget), 1);
                gtk.Widget.setHalign(content_grid.as(gtk.Widget), .fill);
                gtk.Widget.setValign(content_grid.as(gtk.Widget), .center);

                const image = gtk.Image.newFromIconName("package-x-generic");
                gtk.Image.setPixelSize(image, 64);
                gtk.Widget.setValign(image.as(gtk.Widget), .center);
                gtk.Widget.setHalign(image.as(gtk.Widget), .center);
                gtk.Grid.attach(content_grid, image.as(gtk.Widget), 0, 0, 1, 2);

                const right_box = gtk.Box.new(.vertical, 0);
                gtk.Widget.setValign(right_box.as(gtk.Widget), .center);
                gtk.Widget.setHalign(right_box.as(gtk.Widget), .fill);
                gtk.Widget.setHexpand(right_box.as(gtk.Widget), 1);

                const title_label = gtk.Label.new("");
                gtk.Widget.addCssClass(title_label.as(gtk.Widget), "package-title");
                gtk.Widget.setHalign(title_label.as(gtk.Widget), .start);
                gtk.Widget.setValign(title_label.as(gtk.Widget), .center);
                gtk.Widget.setVexpand(title_label.as(gtk.Widget), 0);
                gtk.Widget.setHexpand(title_label.as(gtk.Widget), 0);
                gtk.Label.setUseMarkup(title_label, 1);
                gtk.Label.setEllipsize(title_label, .end);
                gtk.Label.setMaxWidthChars(title_label, 30);

                const installed_check = gtk.Image.newFromIconName("object-select-symbolic");
                gtk.Widget.setValign(installed_check.as(gtk.Widget), .center);
                gtk.Widget.setHalign(installed_check.as(gtk.Widget), .start);
                gtk.Widget.setHexpand(installed_check.as(gtk.Widget), 0);
                gtk.Widget.setTooltipText(installed_check.as(gtk.Widget), translations._("Package is already installed"));

                const title_grid = gtk.Grid.new();
                gtk.Grid.setColumnSpacing(title_grid, 4);
                gtk.Widget.setHalign(title_grid.as(gtk.Widget), .start);
                gtk.Grid.attach(title_grid, title_label.as(gtk.Widget), 0, 0, 1, 1);
                gtk.Grid.attach(title_grid, installed_check.as(gtk.Widget), 1, 0, 1, 1);

                gtk.Box.append(right_box, title_grid.as(gtk.Widget));

                const desc_label = gtk.Label.new("");
                gtk.Widget.setHalign(desc_label.as(gtk.Widget), .start);
                gtk.Widget.setValign(desc_label.as(gtk.Widget), .start);
                gtk.Widget.setVexpand(desc_label.as(gtk.Widget), 0);
                gtk.Widget.setHexpand(desc_label.as(gtk.Widget), 1);
                gtk.Label.setEllipsize(desc_label, .end);
                gtk.Label.setMaxWidthChars(desc_label, 35);
                gtk.Label.setWidthChars(desc_label, -1);
                gtk.Box.append(right_box, desc_label.as(gtk.Widget));

                gtk.Grid.attach(content_grid, right_box.as(gtk.Widget), 1, 0, 1, 2);

                const selection_check = gtk.CheckButton.new();
                gtk.Widget.setValign(selection_check.as(gtk.Widget), .center);
                gtk.Widget.setHalign(selection_check.as(gtk.Widget), .end);
                gtk.Widget.setHexpand(selection_check.as(gtk.Widget), 0);
                gobject.Object.setData(selection_check.as(gobject.Object), "list-item", list_item);
                gobject.Object.setData(selection_check.as(gobject.Object), "page", self_setup);
                _ = gtk.CheckButton.signals.toggled.connect(selection_check, ?*anyopaque, &on_grid_check_toggled, null, .{});
                gtk.Grid.attach(content_grid, selection_check.as(gtk.Widget), 2, 0, 1, 2);

                const frame = gtk.Frame.new(null);
                gtk.Frame.setChild(frame, content_grid.as(gtk.Widget));
                gtk.Widget.setSizeRequest(frame.as(gtk.Widget), 300, -1);
                gtk.Widget.setHexpand(frame.as(gtk.Widget), 0);
                gtk.Widget.setHalign(frame.as(gtk.Widget), .fill);
                gtk.Widget.setMarginStart(frame.as(gtk.Widget), 3);
                gtk.Widget.setMarginEnd(frame.as(gtk.Widget), 3);
                gtk.Widget.setMarginTop(frame.as(gtk.Widget), 3);
                gtk.Widget.setMarginBottom(frame.as(gtk.Widget), 3);
                gtk.Widget.addCssClass(frame.as(gtk.Widget), "card");

                gtk.ListItem.setChild(list_item, frame.as(gtk.Widget));
            }
            fn bind(_: *gtk.SignalListItemFactory, item: *gobject.Object, page: *Self) callconv(.c) void {
                const list_item = gobject.ext.cast(gtk.ListItem, item) orelse return;
                const obj = gtk.ListItem.getItem(list_item) orelse return;
                const pkg = gobject.ext.cast(PackageObject, obj) orelse return;
                const frame_w = gtk.ListItem.getChild(list_item) orelse return;
                const frame = gobject.ext.cast(gtk.Frame, frame_w) orelse return;
                const content_grid = gobject.ext.cast(gtk.Grid, gtk.Frame.getChild(frame) orelse return) orelse return;
                const icon_image = gobject.ext.cast(gtk.Image, gtk.Grid.getChildAt(content_grid, 0, 0) orelse return) orelse return;
                const right_box = gobject.ext.cast(gtk.Box, gtk.Grid.getChildAt(content_grid, 1, 0) orelse return) orelse return;
                const selection_check = gobject.ext.cast(gtk.CheckButton, gtk.Grid.getChildAt(content_grid, 2, 0) orelse return) orelse return;

                page.priv().check_map_grid.put(std.heap.c_allocator, pkg, selection_check) catch {};

                const title_grid_w = gtk.Widget.getFirstChild(right_box.as(gtk.Widget)) orelse return;
                const title_grid = gobject.ext.cast(gtk.Grid, title_grid_w) orelse return;
                const title_label = gobject.ext.cast(gtk.Label, gtk.Grid.getChildAt(title_grid, 0, 0) orelse return) orelse return;
                const installed_check = gtk.Grid.getChildAt(title_grid, 1, 0) orelse return;
                const desc_w = gtk.Widget.getLastChild(right_box.as(gtk.Widget)) orelse return;
                const desc_label = gobject.ext.cast(gtk.Label, desc_w) orelse return;

                gobject.Object.setData(selection_check.as(gobject.Object), "syncing", @ptrFromInt(1));
                gtk.CheckButton.setActive(selection_check, @intFromBool(pkg.isSelected()));
                gobject.Object.setData(selection_check.as(gobject.Object), "syncing", null);

                const p = page.priv();
                if (p.resolver.resolve(pkg.getName())) |path| {
                    gtk.Image.setFromFile(icon_image, path);
                } else {
                    gtk.Image.setFromIconName(icon_image, "package-x-generic");
                }
                var name_buf: [256]u8 = undefined;
                const markup = std.fmt.bufPrintZ(&name_buf, "<b>{s}</b>", .{pkg.getName()}) catch pkg.getName();
                gtk.Label.setMarkup(title_label, markup);
                gtk.Widget.setVisible(installed_check, @intFromBool(pkg.isInstalled()));
                gtk.Label.setLabel(desc_label, pkg.getDescription());
            }
            fn unbind(_: *gtk.SignalListItemFactory, item: *gobject.Object, page: *Self) callconv(.c) void {
                const list_item = gobject.ext.cast(gtk.ListItem, item) orelse return;
                const obj = gtk.ListItem.getItem(list_item) orelse return;
                const pkg = gobject.ext.cast(PackageObject, obj) orelse return;
                _ = page.priv().check_map_grid.remove(pkg);
            }
        };

        const factory = gtk.SignalListItemFactory.new();
        _ = gtk.SignalListItemFactory.signals.unbind.connect(factory, *Self, &c.unbind, self, .{});
        _ = gtk.SignalListItemFactory.signals.setup.connect(factory, *Self, &c.setup, self, .{});
        _ = gtk.SignalListItemFactory.signals.bind.connect(factory, *Self, &c.bind, self, .{});
        gtk.GridView.setFactory(view, factory.as(gtk.ListItemFactory));
    }

    fn on_grid_check_toggled(check: *gtk.CheckButton, _: ?*anyopaque) callconv(.c) void {
        if (gobject.Object.getData(check.as(gobject.Object), "syncing") != null) return;
        const raw = gobject.Object.getData(check.as(gobject.Object), "list-item") orelse return;
        const list_item: *gtk.ListItem = @ptrCast(@alignCast(raw));
        const obj = gtk.ListItem.getItem(list_item) orelse return;
        const pkg = gobject.ext.cast(PackageObject, obj) orelse return;
        pkg.setSelected(gtk.CheckButton.getActive(check) != 0);

        const page_ptr = gobject.Object.getData(check.as(gobject.Object), "page") orelse return;
        const self: *Self = @ptrCast(@alignCast(page_ptr));
        const p = self.priv();
        const path = p.resolver.resolve(pkg.getName());
        p.detail.showPackage(pkg.getName(), pkg.isInstalled(), path);
        gtk.Revealer.setRevealChild(p.detail_revealer, 1);
        self.update_selection_ui();
    }

    fn on_grid_activated(_: *gtk.GridView, position: c_uint, self: *Self) callconv(.c) void {
        toggle_selection_at(self, position);
    }

    fn on_column_activated(_: *gtk.ColumnView, position: c_uint, self: *Self) callconv(.c) void {
        toggle_selection_at(self, position);
    }

    fn toggle_selection_at(self: *Self, position: c_uint) void {
        const p = self.priv();
        const model = p.selection.as(gio.ListModel);
        const obj = gio.ListModel.getObject(model, position) orelse return;
        defer obj.unref();
        const pkg = gobject.ext.cast(PackageObject, obj) orelse return;

        const new_state = !pkg.isSelected();
        pkg.setSelected(new_state);

        if (p.check_map_grid.get(pkg)) |check| {
            set_sync_active(check, new_state);
        }
        if (p.check_map_column.get(pkg)) |check| {
            set_sync_active(check, new_state);
        }

        self.update_selection_ui();
    }

    fn set_sync_active(check: *gtk.CheckButton, active: bool) void {
        gobject.Object.setData(check.as(gobject.Object), "syncing", @ptrFromInt(1));
        gtk.CheckButton.setActive(check, @intFromBool(active));
        gobject.Object.setData(check.as(gobject.Object), "syncing", null);
    }

    fn filter_func(item: *gobject.Object, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data.?));
        const p = self.priv();

        const pkg = gobject.ext.cast(PackageObject, item) orelse return 0;

        if (p.selected_group_len > 0) {
            const group = p.selected_group[0..p.selected_group_len];
            var found = false;
            for (pkg.getGroups()) |g| {
                if (std.mem.eql(u8, g, group)) {
                    found = true;
                    break;
                }
            }
            if (!found) return 0;
        }

        if (p.show_installed_only and !pkg.isInstalled()) return 0;

        if (p.show_depends_only and pkg.isExplicit()) return 0;

        if (p.show_explicit_only and !pkg.isExplicit()) return 0;

        if (p.search_len < 1) return 1;

        const needle = p.search_text[0..p.search_len];

        return @intFromBool(contains_ignore_case(pkg.getName(), needle) or contains_ignore_case(pkg.getDescription(), needle));
    }

    fn update_no_results(self: *Self) void {
        const p = self.priv();
        const selection = p.selection;
        const loaded = gio.ListModel.getNItems(p.list_store.as(gio.ListModel));
        const visible = loaded > 0 and gio.ListModel.getNItems(selection.as(gio.ListModel)) == 0;
        gtk.Widget.setVisible(p.no_results_overlay.as(gtk.Widget), @intFromBool(visible));
    }

    fn contains_ignore_case(haystack: []const u8, needle: []const u8) bool {
        if (needle.len > haystack.len) return false;
        var i: usize = 0;
        outer: while (i + needle.len <= haystack.len) : (i += 1) {
            for (needle, 0..) |n, j| {
                if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(n)) continue :outer;
            }
            return true;
        }
        return false;
    }

    fn on_search_changed(entry: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        const p = self.priv();

        const text = gtk.Editable.getText(entry.as(gtk.Editable));
        const slice = std.mem.span(text);
        const len = @min(slice.len, p.search_text.len);
        @memcpy(p.search_text[0..len], slice[0..len]);
        p.search_len = len;

        gtk.Filter.changed(p.filter.as(gtk.Filter), .different);
        self.update_no_results();
    }

    fn on_selection_changed(_: *gobject.Object, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const p = self.priv();
        const obj = gtk.SingleSelection.getSelectedItem(p.selection) orelse {
            gtk.Revealer.setRevealChild(p.detail_revealer, 0);
            return;
        };
        const pkg = gobject.ext.cast(PackageObject, obj) orelse return;

        const path = p.resolver.resolve(pkg.getName());
        p.detail.showPackage(pkg.getName(), pkg.isInstalled(), path);
        gtk.Revealer.setRevealChild(p.detail_revealer, 1);
    }

    fn on_group_notify(_: *gobject.Object, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const p = self.priv();

        const idx = gtk.DropDown.getSelected(p.grouping_selection);

        if (idx == 0 or idx == std.math.maxInt(u32)) {
            p.selected_group_len = 0;
        } else {
            const model = gtk.DropDown.getModel(p.grouping_selection) orelse return;
            const obj = gio.ListModel.getObject(model, idx) orelse return;
            const so = gobject.ext.cast(gtk.StringObject, obj) orelse return;
            const s = std.mem.span(gtk.StringObject.getString(so));
            const len = @min(s.len, p.selected_group.len);
            @memcpy(p.selected_group[0..len], s[0..len]);
            p.selected_group_len = len;
        }

        gtk.Filter.changed(p.filter.as(gtk.Filter), .different);
    }

    pub fn onMap(self: *Self) void {
        const p = self.priv();
        if (p.loaded) return;
        applyOptionsFromConfig(self);
        p.loaded = true;
        p.generation += 1;
        show_loading(self);
        self.update_selection_ui();
        _ = gtk.Widget.grabFocus(p.search_entry.as(gtk.Widget));
        const thread = std.Thread.spawn(.{}, load_worker, .{ self, p.generation, p.show_hidden }) catch return;
        gtk.Widget.setVisible(p.no_results_overlay.as(gtk.Widget), 0);
        thread.detach();
    }

    fn applyOptionsFromConfig(self: *Self) void {
        const svc = runtime.config orelse return;
        const cfg = svc.get() catch return;
        const p = self.priv();
        p.applying_config = true;
        defer p.applying_config = false;

        p.show_hidden = cfg.PackageInstallShowHidden;
        gtk.CheckButton.setActive(p.upgrade_check, @intFromBool(cfg.PackageInstallUpgrade));
        gtk.CheckButton.setActive(p.show_hidden_check, @intFromBool(cfg.PackageInstallShowHidden));

        p.show_explicit_only = cfg.PackageInstallShowExplicitOnly;
        gtk.CheckButton.setActive(p.show_explicit_only_check, @intFromBool(cfg.PackageInstallShowExplicitOnly));

        p.show_detail_pane = cfg.PackageInstallShowDetailPane;
        gtk.CheckButton.setActive(p.show_detail_pane_check, @intFromBool(cfg.PackageInstallShowDetailPane));
        gtk.Widget.setVisible(p.detail_revealer.as(gtk.Widget), if (cfg.PackageInstallShowDetailPane) 0 else 1);

        const use_grid = cfg.PackageInstallView == .grid;
        gtk.ToggleButton.setActive(p.grid_view_button, @intFromBool(use_grid));
        gtk.ToggleButton.setActive(p.list_view_button, @intFromBool(!use_grid));
        gtk.Widget.setVisible(p.detail_grid_hbox.as(gtk.Widget), @intFromBool(use_grid));
        gtk.Widget.setVisible(p.detail_hbox.as(gtk.Widget), @intFromBool(!use_grid));
    }

    fn updateConfigField(
        comptime field: std.meta.FieldEnum(ShellyConfig),
        value: std.meta.fieldInfo(ShellyConfig, field).type,
    ) void {
        const svc = runtime.config orelse return;
        svc.updateField(field, value) catch |err| {
            std.log.err("package page: failed to update config: {t}", .{err});
        };
    }

    extern fn malloc_trim(pad: usize) c_int;

    //Unmap stuff we owned
    pub fn onUnmap(self: *Self) void {
        const p = self.priv();
        if (!p.loaded) return;
        p.loaded = false;
        p.generation += 1;

        gio.ListStore.removeAll(p.list_store);

        p.check_map_grid.deinit(std.heap.c_allocator);
        p.check_map_grid = .empty;
        p.check_map_column.deinit(std.heap.c_allocator);
        p.check_map_column = .empty;

        if (p.arena) |a| {
            a.deinit();
            std.heap.c_allocator.destroy(a);
            p.arena = null;
        }

        p.resolver.deinit();
        p.resolver = IconResolver.init(std.heap.c_allocator);

        _ = malloc_trim(0);
    }

    fn load_worker(page: *Self, generation: u64, show_hidden: bool) void {
        const arena_ptr = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch return;
        arena_ptr.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        const alloc = arena_ptr.allocator();
        const p = page.priv();
        if (!p.resolver.loaded) {
            p.resolver.load(runtime.io, runtime.environ_map) catch {};
        }
        var threaded: std.Io.Threaded = .init(alloc, .{});
        defer threaded.deinit();

        const cli = ShellyCli{ .allocator = alloc, .io = threaded.io() };
        const parsed = cli.get_packages(show_hidden) catch |err| {
            std.debug.print("get_packages failed: {t}\n", .{err});
            arena_ptr.deinit();
            std.heap.c_allocator.destroy(arena_ptr);
            return;
        };

        const icli = ShellyCli{ .allocator = alloc, .io = threaded.io() };
        const installed = icli.get_installed_packages() catch null;

        var all: std.ArrayListUnmanaged(Package) = .empty;
        all.appendSlice(alloc, parsed.value) catch {};

        if (installed) |inst| {
            var map: std.StringHashMapUnmanaged(*const Package) = .empty;
            for (inst.value) |*pkg| {
                map.put(alloc, pkg.Name, pkg) catch {};
            }

            var matched: std.StringHashMapUnmanaged(void) = .empty;
            for (all.items) |*pkg| {
                if (map.get(pkg.Name)) |ipkg| {
                    pkg.Installed = true;
                    pkg.InstallDate = ipkg.InstallDate;
                    pkg.Explicit = std.mem.eql(u8, ipkg.InstallReason, "Explicit");
                    matched.put(alloc, pkg.Name, {}) catch {};
                } else {
                    pkg.Installed = false;
                }
            }

            for (inst.value) |ipkg| {
                if (!matched.contains(ipkg.Name)) {
                    var extra = ipkg;
                    extra.Installed = true;
                    extra.Explicit = std.mem.eql(u8, ipkg.InstallReason, "Explicit");
                    all.append(alloc, extra) catch {};
                }
            }
        }

        var set: std.StringHashMapUnmanaged(void) = .empty;
        for (all.items) |pkg| {
            for (pkg.Groups) |g| set.put(alloc, g, {}) catch {};
        }
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = set.keyIterator();
        while (it.next()) |k| list.append(alloc, k.*) catch {};

        post_result(page, all.items, list.items, arena_ptr, generation);
    }

    fn post_result(
        page: *Self,
        packages: []Package,
        groups: []const []const u8,
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
            .packages = packages,
            .groups = groups,
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

            p.check_map_grid.clearAndFree(std.heap.c_allocator);
            p.check_map_column.clearAndFree(std.heap.c_allocator);

            const strings = gtk.StringList.new(null);
            gtk.StringList.append(strings, "Any");
            for (result.groups) |g| {
                var buf: [128]u8 = undefined;
                gtk.StringList.append(strings, c_string.cstr(&buf, g));
            }
            gtk.DropDown.setModel(p.grouping_selection, strings.as(gio.ListModel));
            strings.as(gobject.Object).unref();
            gtk.DropDown.setSelected(p.grouping_selection, 0);
        }

        const batch_size = 500;
        const end = @min(result.index + batch_size, result.packages.len);
        const n = end - result.index;
        var batch: [500]*gobject.Object = undefined;
        var i: usize = 0;
        for (result.packages[result.index..end]) |d| {
            const pkg = PackageObject.new(d);
            batch[i] = pkg.as(gobject.Object);
            i += 1;
        }
        const pos = gio.ListModel.getNItems(p.list_store.as(gio.ListModel));
        gio.ListStore.splice(p.list_store, pos, 0, &batch, @intCast(n));
        for (batch[0..n]) |o| o.unref();
        result.index = end;
        if (result.index < result.packages.len) return 1;

        const page = result.page;
        result.arena.deinit();
        std.heap.c_allocator.destroy(result.arena);
        std.heap.c_allocator.destroy(result);

        _ = gtk.SelectionModel.selectItem(p.selection.as(gtk.SelectionModel), 0, 1);

        hide_loading(page);

        return 0;
    }

    fn show_loading(self: *Self) void {
        const p = self.priv();
        gtk.Widget.setVisible(p.error_label.as(gtk.Widget), 0);
        gtk.Spinner.setSpinning(p.loading_spinner, 1);
        gtk.Widget.setVisible(p.loading_spinner.as(gtk.Widget), 1);
        gtk.Widget.setVisible(p.loading_overlay.as(gtk.Widget), 1);
    }

    fn hide_loading(self: *Self) void {
        const p = self.priv();
        gtk.Spinner.setSpinning(p.loading_spinner, 0);
        gtk.Widget.setVisible(p.loading_overlay.as(gtk.Widget), 0);
        self.update_no_results();
    }

    const template_children = .{
        .{ "package_column_view", @offsetOf(Private, "column_view") },
        .{ "name_column", @offsetOf(Private, "name_column") },
        .{ "version_column", @offsetOf(Private, "version_column") },
        .{ "size_column", @offsetOf(Private, "size_column") },
        .{ "repository_column", @offsetOf(Private, "repository_column") },
        .{ "install_date_column", @offsetOf(Private, "install_date_column") },
        .{ "check_column", @offsetOf(Private, "check_column") },
        .{ "loading_spinner", @offsetOf(Private, "loading_spinner") },
        .{ "loading_overlay", @offsetOf(Private, "loading_overlay") },
        .{ "loading_spinner", @offsetOf(Private, "loading_spinner") },
        .{ "error_label", @offsetOf(Private, "error_label") },
        .{ "search_entry", @offsetOf(Private, "search_entry") },
        .{ "list_packages", @offsetOf(Private, "grid_view") },
        .{ "detail_hbox", @offsetOf(Private, "detail_hbox") },
        .{ "detail_grid_hbox", @offsetOf(Private, "detail_grid_hbox") },
        .{ "grid_view_button", @offsetOf(Private, "grid_view_button") },
        .{ "list_view_button", @offsetOf(Private, "list_view_button") },
        .{ "grouping_selection", @offsetOf(Private, "grouping_selection") },
        .{ "detail_revealer", @offsetOf(Private, "detail_revealer") },
        .{ "install_button", @offsetOf(Private, "install_button") },
        .{ "cart_label", @offsetOf(Private, "cart_label") },
        .{ "cart_items_box", @offsetOf(Private, "cart_items_box") },
        .{ "upgrade_check", @offsetOf(Private, "upgrade_check") },
        .{ "show_hidden_check", @offsetOf(Private, "show_hidden_check") },
        .{ "show_explicit_only", @offsetOf(Private, "show_explicit_only_check") },
        .{ "show_detail_pane", @offsetOf(Private, "show_detail_pane_check") },
        .{ "no_results_overlay", @offsetOf(Private, "no_results_overlay") },
        .{ "no_results_label", @offsetOf(Private, "no_results_label") },
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

            gtk.Widget.Class.bindTemplateCallbackFull(wc, "install_selected", @ptrCast(&install_selected));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_grid_view_toggled", @ptrCast(&on_grid_view_toggled));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_list_view_toggled", @ptrCast(&on_list_view_toggled));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_explicit_only", @ptrCast(&on_explicit_only));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_depends_only", @ptrCast(&on_depends_only));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_installed_only_toggled", @ptrCast(&on_installed_only_toggled));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_detail_pane", @ptrCast(&on_detail_pane));
        }
    };

    fn update_selection_ui(self: *Self) void {
        const p = self.priv();
        const model = p.list_store.as(gio.ListModel);
        const n = gio.ListModel.getNItems(model);

        while (gtk.Widget.getFirstChild(p.cart_items_box.as(gtk.Widget))) |child| {
            gtk.Box.remove(p.cart_items_box, child);
        }

        var install_count: u32 = 0;
        var remove_count: u32 = 0;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const obj = gio.ListModel.getObject(model, i) orelse continue;
            const pkg = gobject.ext.cast(PackageObject, obj) orelse continue;
            if (!pkg.isSelected()) continue;

            const installed = pkg.isInstalled();
            if (installed) remove_count += 1 else install_count += 1;

            const row_btn = gtk.Button.new();
            gtk.Widget.addCssClass(row_btn.as(gtk.Widget), "flat");
            gtk.Widget.setHexpand(row_btn.as(gtk.Widget), 1);
            gtk.Widget.setTooltipText(row_btn.as(gtk.Widget), translations._("Remove from selection"));

            const row = gtk.Box.new(.horizontal, 8);
            gtk.Widget.setHexpand(row.as(gtk.Widget), 1);

            const name_label = gtk.Label.new(pkg.getName());
            gtk.Widget.setHalign(name_label.as(gtk.Widget), .start);
            gtk.Widget.setHexpand(name_label.as(gtk.Widget), 1);
            gtk.Label.setXalign(name_label, 0);
            gtk.Label.setEllipsize(name_label, .end);
            gtk.Label.setMaxWidthChars(name_label, 24);
            gtk.Box.append(row, name_label.as(gtk.Widget));

            const tag = gtk.Label.new(if (installed) translations._("remove") else translations._("install"));
            gtk.Widget.addCssClass(tag.as(gtk.Widget), "caption");
            gtk.Widget.addCssClass(tag.as(gtk.Widget), if (installed) "error" else "success");
            gtk.Widget.setHalign(tag.as(gtk.Widget), .end);
            gtk.Box.append(row, tag.as(gtk.Widget));

            const x_icon = gtk.Image.newFromIconName("window-close-symbolic");
            gtk.Image.setPixelSize(x_icon, 12);
            gtk.Widget.setHalign(x_icon.as(gtk.Widget), .end);
            gtk.Box.append(row, x_icon.as(gtk.Widget));

            gtk.Button.setChild(row_btn, row.as(gtk.Widget));

            gobject.Object.setData(row_btn.as(gobject.Object), "pkg", pkg);
            gobject.Object.setData(row_btn.as(gobject.Object), "page", self);
            _ = gtk.Button.signals.clicked.connect(row_btn, ?*anyopaque, &on_cart_item_clicked, null, .{});

            gtk.Box.append(p.cart_items_box, row_btn.as(gtk.Widget));
        }

        if (install_count == 0 and remove_count == 0) {
            const empty = gtk.Label.new(translations._("No packages selected"));
            gtk.Widget.addCssClass(empty.as(gtk.Widget), "dim-label");
            gtk.Widget.setHalign(empty.as(gtk.Widget), .start);
            gtk.Box.append(p.cart_items_box, empty.as(gtk.Widget));
        }

        const total = install_count + remove_count;
        var cart_buf: [32]u8 = undefined;
        gtk.Label.setLabel(p.cart_label, std.fmt.bufPrintZ(&cart_buf, "{d} {s}", .{ total, translations._("Selected") }) catch translations._("0 Selected"));

        const btn = p.install_button.as(gtk.Widget);
        gtk.Widget.removeCssClass(btn, "suggested-action");
        gtk.Widget.removeCssClass(btn, "destructive-action");

        if (total == 0) {
            gtk.Button.setLabel(p.install_button, translations._("Install Selected"));
            gtk.Widget.setSensitive(btn, 0);
            gtk.Widget.setTooltipText(btn, null);
        } else if (install_count > 0 and remove_count > 0) {
            gtk.Button.setLabel(p.install_button, translations._("Mixed selection"));
            gtk.Widget.setSensitive(btn, 0);
            gtk.Widget.setTooltipText(btn, translations._("Select only installed packages to remove, or only available ones to install."));
        } else if (remove_count > 0) {
            gtk.Button.setLabel(p.install_button, translations._("Remove Selected"));
            gtk.Widget.setSensitive(btn, 1);
            gtk.Widget.addCssClass(btn, "destructive-action");
            gtk.Widget.setTooltipText(btn, null);
        } else {
            gtk.Button.setLabel(p.install_button, translations._("Install Selected"));
            gtk.Widget.setSensitive(btn, 1);
            gtk.Widget.addCssClass(btn, "suggested-action");
            gtk.Widget.setTooltipText(btn, null);
        }
    }

    fn on_cart_item_clicked(button: *gtk.Button, _: ?*anyopaque) callconv(.c) void {
        const pkg_ptr = gobject.Object.getData(button.as(gobject.Object), "pkg") orelse return;
        const pkg: *PackageObject = @ptrCast(@alignCast(pkg_ptr));
        const page_ptr = gobject.Object.getData(button.as(gobject.Object), "page") orelse return;
        const self: *Self = @ptrCast(@alignCast(page_ptr));

        pkg.setSelected(false);
        const p = self.priv();

        if (p.check_map_grid.get(pkg)) |check| {
            set_sync_active(check, false);
        }
        if (p.check_map_column.get(pkg)) |check| {
            set_sync_active(check, false);
        }
        self.update_selection_ui();
    }

    fn install_selected(self: *Self) callconv(.c) void {
        const p = self.priv();
        const model = p.list_store.as(gio.ListModel);
        const n = gio.ListModel.getNItems(model);
        var install_count: u32 = 0;
        var remove_count: u32 = 0;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const obj = gio.ListModel.getObject(model, i) orelse continue;
            const pkg = gobject.ext.cast(PackageObject, obj) orelse continue;
            if (!pkg.isSelected()) continue;
            if (pkg.isInstalled()) remove_count += 1 else install_count += 1;
        }

        if (install_count == 0 and remove_count == 0) return;
        if (install_count > 0 and remove_count > 0) return;
        if (remove_count > 0) self.confirm_remove() else self.start_install();
    }

    fn on_grid_view_toggled(self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.applying_config) return;
        if (gtk.ToggleButton.getActive(p.grid_view_button) == 0) return;
        gtk.Widget.setVisible(p.detail_grid_hbox.as(gtk.Widget), 1);
        gtk.Widget.setVisible(p.detail_hbox.as(gtk.Widget), 0);
        updateConfigField(.PackageInstallView, ViewType.grid);
    }

    fn on_list_view_toggled(self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.applying_config) return;
        if (gtk.ToggleButton.getActive(p.list_view_button) == 0) return;
        gtk.Widget.setVisible(p.detail_hbox.as(gtk.Widget), 1);
        gtk.Widget.setVisible(p.detail_grid_hbox.as(gtk.Widget), 0);
        updateConfigField(.PackageInstallView, ViewType.list);
    }

    fn on_upgrade_toggled(check: *gtk.CheckButton, self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.applying_config) return;
        updateConfigField(.PackageInstallUpgrade, gtk.CheckButton.getActive(check) != 0);
    }

    fn on_show_hidden_toggled(check: *gtk.CheckButton, self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.applying_config) return;
        const active = gtk.CheckButton.getActive(check) != 0;
        p.show_hidden = active;
        updateConfigField(.PackageInstallShowHidden, active);
        if (p.loaded) self.reload();
    }

    fn on_installed_only_toggled(check: *gtk.CheckButton, self: *Self) callconv(.c) void {
        const p = self.priv();
        p.show_installed_only = gtk.CheckButton.getActive(check) != 0;
        gtk.ColumnViewColumn.setVisible(p.install_date_column, @intFromBool(p.show_installed_only));
        gtk.Filter.changed(p.filter.as(gtk.Filter), .different);
    }

    fn on_explicit_only(check: *gtk.CheckButton, self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.applying_config) return;
        const active = gtk.CheckButton.getActive(check) != 0;
        p.show_explicit_only = active;
        updateConfigField(.PackageInstallShowExplicitOnly, active);
        gtk.Filter.changed(p.filter.as(gtk.Filter), .different);
    }

    fn on_depends_only(check: *gtk.CheckButton, self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.applying_config) return;
        const active = gtk.CheckButton.getActive(check) != 0;
        p.show_depends_only = active;
        updateConfigField(.PackageInstallShowDependsOnly, active);
        gtk.Filter.changed(p.filter.as(gtk.Filter), .different);
    }

    fn on_detail_pane(check: *gtk.CheckButton, self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.applying_config) return;
        const active = gtk.CheckButton.getActive(check) != 0;
        p.show_detail_pane = active;
        gtk.Widget.setVisible(p.detail_revealer.as(gtk.Widget), if (active) 0 else 1);
        updateConfigField(.PackageInstallShowDetailPane, active);
    }

    fn confirm_remove(self: *Self) void {
        const dialog = ConfirmDialog.new(
            translations._("Remove Packages"),
            translations._("Remove the selected packages?"),
            &on_remove_response,
            self,
        );
        dialog.setButtons(translations._("Remove"), translations._("Cancel"));
        if (support.getWindow(ShellyWindow, self)) |win| {
            win.showLockout(dialog.as(gtk.Widget));
        }
    }

    fn on_remove_response(ctx: ?*anyopaque, confirmed: bool) void {
        const self: *PackagePage = @ptrCast(@alignCast(ctx.?));
        if (support.getWindow(ShellyWindow, self)) |win| win.hideLockout();
        if (!confirmed) return;

        const p = self.priv();

        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer names.deinit(std.heap.c_allocator);

        const n = gio.ListModel.getNItems(p.list_store.as(gio.ListModel));
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const obj = gio.ListModel.getObject(p.list_store.as(gio.ListModel), i) orelse continue;
            const pkg = gobject.ext.cast(PackageObject, obj) orelse continue;
            if (pkg.isSelected()) {
                names.append(std.heap.c_allocator, pkg.getName()) catch continue;
            }
        }
        if (names.items.len == 0) return;

        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(std.heap.c_allocator);
        argv.append(std.heap.c_allocator, "remove") catch return;
        argv.append(std.heap.c_allocator, "standard") catch return;
        for (names.items) |name| argv.append(std.heap.c_allocator, name) catch return;

        if (runtime.config) |cfg_service| {
            if (cfg_service.get()) |cfg| {
                if (!cfg.PackageManagementCascadeDelete) {
                    argv.append(std.heap.c_allocator, "--no-cascade") catch return;
                }
                if (cfg.PackageManagementRemoveOptionalDeps) {
                    argv.append(std.heap.c_allocator, "--opt-deps") catch return;
                }
                if (cfg.PackageManagementRemoveConfigs) {
                    argv.append(std.heap.c_allocator, "--remove-config") catch return;
                }
            } else |_| {}
        }

        if (support.getWindow(ShellyWindow, self)) |win| {
            win.startTransaction(.{
                .title = translations._("Removing packages"),
                .argv = argv.items,
                .packages = names.items,
                .on_complete = &on_transaction_complete,
                .privileged = true,
                .ctx = self,
            });
        }
    }

    fn start_install(self: *Self) void {
        const p = self.priv();

        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer names.deinit(std.heap.c_allocator);

        const n = gio.ListModel.getNItems(p.list_store.as(gio.ListModel));
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const obj = gio.ListModel.getObject(p.list_store.as(gio.ListModel), i) orelse continue;
            const pkg = gobject.ext.cast(PackageObject, obj) orelse continue;
            if (pkg.isSelected()) {
                names.append(std.heap.c_allocator, pkg.getName()) catch continue;
            }
        }
        if (names.items.len == 0) return;

        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(std.heap.c_allocator);
        argv.append(std.heap.c_allocator, "install") catch return;
        argv.append(std.heap.c_allocator, "standard") catch return;
        for (names.items) |name| argv.append(std.heap.c_allocator, name) catch return;
        if (gtk.CheckButton.getActive(p.upgrade_check) != 0) {
            argv.append(std.heap.c_allocator, "--upgrade") catch return;
        }

        if (support.getWindow(ShellyWindow, self)) |win| {
            win.startTransaction(.{
                .title = translations._("Installing packages"),
                .argv = argv.items,
                .packages = names.items,
                .on_complete = &on_transaction_complete,
                .privileged = true,
                .ctx = self,
            });
        }
    }

    fn on_transaction_complete(ctx: *anyopaque, success: bool) void {
        const self: *PackagePage = @ptrCast(@alignCast(ctx));
        if (!success) return;

        const p = self.priv();
        const model = p.list_store.as(gio.ListModel);
        const n = gio.ListModel.getNItems(model);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const obj = gio.ListModel.getObject(model, i) orelse continue;
            const pkg = gobject.ext.cast(PackageObject, obj) orelse continue;
            pkg.setSelected(false);
        }

        self.update_selection_ui();
        self.reload();
    }

    fn reload(self: *Self) void {
        const p = self.priv();
        p.generation += 1;
        show_loading(self);
        const thread = std.Thread.spawn(.{}, load_worker, .{ self, p.generation, p.show_hidden }) catch return;
        thread.detach();
    }
};
