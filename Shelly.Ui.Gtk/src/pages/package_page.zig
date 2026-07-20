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
const ShellyOperation = @import("../services/shelly_operation.zig").ShellyOperation;
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
        check_column: *gtk.ColumnViewColumn,
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
        arena: ?*std.heap.ArenaAllocator,
        selected_group: [64]u8,
        selected_group_len: usize,
        generation: u64,
        show_installed_only: bool,
        loaded: bool,
        resolver: IconResolver,
        search_text: [256]u8,
        search_len: usize,
        operation: ?*ShellyOperation,
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
        p.arena = null;
        p.generation = 0;
        p.show_installed_only = false;
        p.operation = null;

        const detail = PackageDetail.new();
        p.detail = detail;
        gtk.Revealer.setChild(p.detail_revealer, detail.as(gtk.Widget));
        // or gtk.Box.append(p.detail_hbox, detail.as(gtk.Widget)) — whatever your slot is

        p.list_store = gio.ListStore.new(PackageObject.getGObjectType());
        p.selection = gtk.SingleSelection.new(p.list_store.as(gio.ListModel));
        gtk.ColumnView.setModel(p.column_view, p.selection.as(gtk.SelectionModel));

        p.filter = gtk.CustomFilter.new(&filter_func, self, null);
        p.filter_model = gtk.FilterListModel.new(p.list_store.as(gio.ListModel), p.filter.as(gtk.Filter));
        p.selection = gtk.SingleSelection.new(p.filter_model.as(gio.ListModel));
        gtk.ColumnView.setModel(p.column_view, p.selection.as(gtk.SelectionModel));

        gtk.GridView.setModel(p.grid_view, p.selection.as(gtk.SelectionModel));
        gtk.GridView.setMaxColumns(p.grid_view, 4);
        gtk.GridView.setMinColumns(p.grid_view, 1);

        setup_grid_factory(self, p.grid_view);

        setup_name_column(self, p.name_column);
        setup_signal_text_label_column(p.version_column, &PackageObject.getVersion, gtk.Align.start);
        setup_signal_text_label_column(p.repository_column, &PackageObject.getRepository, gtk.Align.start);

        const check_factory = gtk.SignalListItemFactory.new();
        _ = gtk.SignalListItemFactory.signals.setup.connect(check_factory, ?*anyopaque, &on_check_setup, null, .{});
        _ = gtk.SignalListItemFactory.signals.bind.connect(check_factory, ?*anyopaque, &on_check_bind, null, .{});
        gtk.ColumnViewColumn.setFactory(p.check_column, check_factory.as(gtk.ListItemFactory));

        const size_factory = gtk.SignalListItemFactory.new();
        _ = gtk.SignalListItemFactory.signals.setup.connect(size_factory, ?*anyopaque, &size_setup, null, .{});
        _ = gtk.SignalListItemFactory.signals.bind.connect(size_factory, ?*anyopaque, &size_bind, null, .{});
        gtk.ColumnViewColumn.setFactory(p.size_column, size_factory.as(gtk.ListItemFactory));

        _ = gtk.SearchEntry.signals.search_changed.connect(p.search_entry, *Self, &on_search_changed, self, .{});

        _ = gobject.Object.signals.notify.connect(p.grouping_selection.as(gobject.Object), *Self, &on_group_notify, self, .{ .detail = "selected" });
        _ = gobject.Object.signals.notify.connect(p.selection.as(gobject.Object), *Self, &on_selection_changed, self, .{ .detail = "selected" });

        p.resolver = IconResolver.init(std.heap.c_allocator);

        const use_grid = true;

        gtk.ToggleButton.setActive(p.grid_view_button, @intFromBool(use_grid));
        gtk.ToggleButton.setActive(p.list_view_button, @intFromBool(!use_grid));
        gtk.Widget.setVisible(p.detail_grid_hbox.as(gtk.Widget), @intFromBool(use_grid));
        gtk.Widget.setVisible(p.detail_hbox.as(gtk.Widget), @intFromBool(!use_grid));

        support.connectLifecycle(Self, self);
    }

    fn setup_signal_text_label_column(column: *gtk.ColumnViewColumn, comptime getter: *const fn (*PackageObject) [:0]const u8, comptime halign: gtk.Align) void {
        const c = struct {
            fn setup(_: *gtk.SignalListItemFactory, item: *gobject.Object, _: ?*anyopaque) callconv(.c) void {
                const cell = gobject.ext.cast(gtk.ColumnViewCell, item) orelse return;
                const label = gtk.Label.new("");
                gtk.Widget.setHalign(label.as(gtk.Widget), halign);
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

                const box = gtk.Box.new(.horizontal, 6);

                const icon = gtk.Image.new();
                gtk.Image.setPixelSize(icon, 24);
                gtk.Box.append(box, icon.as(gtk.Widget));

                const label = gtk.Label.new("");
                gtk.Widget.setHalign(label.as(gtk.Widget), .start);
                gtk.Label.setEllipsize(label, .end);
                gtk.Box.append(box, label.as(gtk.Widget));

                const installed_icon = gtk.Image.newFromIconName("object-select-symbolic");
                gtk.Widget.setTooltipText(installed_icon.as(gtk.Widget), "Installed");
                gtk.Box.append(box, installed_icon.as(gtk.Widget));

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
                const label_w = gtk.Widget.getNextSibling(icon_w) orelse return;
                const label = gobject.ext.cast(gtk.Label, label_w) orelse return;
                const installed_w = gtk.Widget.getNextSibling(label_w) orelse return;

                gtk.Label.setLabel(label, pkg.getName());
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

    fn on_check_setup(_: *gtk.SignalListItemFactory, item: *gobject.Object, _: ?*anyopaque) callconv(.c) void {
        const cell = gobject.ext.cast(gtk.ColumnViewCell, item) orelse return;

        const check = gtk.CheckButton.new();
        gtk.Widget.setMarginStart(check.as(gtk.Widget), 10);
        gtk.Widget.setMarginEnd(check.as(gtk.Widget), 10);

        gobject.Object.setData(check.as(gobject.Object), "cell", cell);
        _ = gtk.CheckButton.signals.toggled.connect(check, ?*anyopaque, &on_check_toggled, null, .{});

        gtk.ColumnViewCell.setChild(cell, check.as(gtk.Widget));
    }

    fn on_check_bind(_: *gtk.SignalListItemFactory, item: *gobject.Object, _: ?*anyopaque) callconv(.c) void {
        const cell = gobject.ext.cast(gtk.ColumnViewCell, item) orelse return;
        const obj = gtk.ColumnViewCell.getItem(cell) orelse return;
        const pkg = gobject.ext.cast(PackageObject, obj) orelse return;
        const child = gtk.ColumnViewCell.getChild(cell) orelse return;
        const check = gobject.ext.cast(gtk.CheckButton, child) orelse return;

        gobject.Object.setData(check.as(gobject.Object), "syncing", @ptrFromInt(1));
        gtk.CheckButton.setActive(check, @intFromBool(pkg.isSelected()));
        gobject.Object.setData(check.as(gobject.Object), "syncing", null);
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
        gtk.ColumnViewCell.setChild(cell, label.as(gtk.Widget));
    }

    fn on_check_toggled(check: *gtk.CheckButton, _: ?*anyopaque) callconv(.c) void {
        if (gobject.Object.getData(check.as(gobject.Object), "syncing") != null) return;

        const cell_ptr = gobject.Object.getData(check.as(gobject.Object), "cell") orelse return;
        const cell: *gtk.ColumnViewCell = @ptrCast(@alignCast(cell_ptr));
        const obj = gtk.ColumnViewCell.getItem(cell) orelse return;
        const pkg = gobject.ext.cast(PackageObject, obj) orelse return;

        pkg.setSelected(gtk.CheckButton.getActive(check) != 0);
        // TODO: update cart / install button sensitivity
    }

    fn setup_grid_factory(self: *Self, view: *gtk.GridView) void {
        const c = struct {
            fn setup(_: *gtk.SignalListItemFactory, item: *gobject.Object, _: *Self) callconv(.c) void {
                const list_item = gobject.ext.cast(gtk.ListItem, item) orelse return;

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
                gtk.Widget.setTooltipText(installed_check.as(gtk.Widget), "Package is already installed");

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

                const title_grid_w = gtk.Widget.getFirstChild(right_box.as(gtk.Widget)) orelse return;
                const title_grid = gobject.ext.cast(gtk.Grid, title_grid_w) orelse return;
                const title_label = gobject.ext.cast(gtk.Label, gtk.Grid.getChildAt(title_grid, 0, 0) orelse return) orelse return;
                const installed_check = gtk.Grid.getChildAt(title_grid, 1, 0) orelse return;
                const desc_w = gtk.Widget.getLastChild(right_box.as(gtk.Widget)) orelse return;
                const desc_label = gobject.ext.cast(gtk.Label, desc_w) orelse return;

                // checkbox state — guarded so the handler ignores this programmatic set
                gobject.Object.setData(selection_check.as(gobject.Object), "syncing", @ptrFromInt(1));
                gtk.CheckButton.setActive(selection_check, @intFromBool(pkg.isSelected()));
                gobject.Object.setData(selection_check.as(gobject.Object), "syncing", null);

                const p = page.priv();
                if (p.resolver.resolve(pkg.getName())) |path| {
                    gtk.Image.setFromFile(icon_image, path);
                } else {
                    gtk.Image.setFromIconName(icon_image, "application-x-executable");
                }

                var name_buf: [256]u8 = undefined;
                const markup = std.fmt.bufPrintZ(&name_buf, "<b>{s}</b>", .{pkg.getName()}) catch pkg.getName();
                gtk.Label.setMarkup(title_label, markup);

                gtk.Widget.setVisible(installed_check, @intFromBool(pkg.isInstalled()));
                gtk.Label.setLabel(desc_label, pkg.getDescription());
            }
        };

        const factory = gtk.SignalListItemFactory.new();
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

        //TODO: Cart logic.
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

        if (p.search_len < 1) return 1;

        const needle = p.search_text[0..p.search_len];

        return @intFromBool(contains_ignore_case(pkg.getName(), needle));
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
    }

    fn on_selection_changed(_: *gobject.Object, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const p = self.priv();
        const obj = gtk.SingleSelection.getSelectedItem(p.selection) orelse {
            gtk.Revealer.setRevealChild(p.detail_revealer, 0);
            return;
        };
        const pkg = gobject.ext.cast(PackageObject, obj) orelse return;

        const path = p.resolver.resolve(pkg.getName());
        p.detail.showPackage(pkg.getName(), path);
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
        p.loaded = true;
        p.generation += 1;

        show_loading(self);

        const arena_ptr = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch return;
        arena_ptr.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        p.arena = arena_ptr;

        const thread = std.Thread.spawn(.{}, load_worker, .{ self, p.generation }) catch return;
        thread.detach();
    }

    extern fn malloc_trim(pad: usize) c_int;

    //Unmap stuff we owned
    pub fn onUnmap(self: *Self) void {
        const p = self.priv();
        if (!p.loaded) return;
        p.loaded = false;

        gio.ListStore.removeAll(p.list_store);

        if (p.arena) |a| {
            a.deinit();
            std.heap.c_allocator.destroy(a);
            p.arena = null;
        }

        _ = malloc_trim(0);
    }

    fn load_worker(page: *Self, generation: u64) void {
        const arena_ptr = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch return;
        arena_ptr.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);

        const alloc = arena_ptr.allocator();

        const p = page.priv();
        if (!p.resolver.loaded) {
            p.resolver.load(runtime.io, runtime.environ_map) catch {};
        }

        var threaded: std.Io.Threaded = .init(alloc, .{});
        defer threaded.deinit();

        //remember arena allocs arnt thread safe so if you are coming back
        //and looking to paralize this please consider
        //done sequentially as load times arnt heavily effected by it and its easier then paralizing atm.
        const cli = ShellyCli{ .allocator = alloc, .io = threaded.io() };
        const parsed = cli.get_packages() catch |err| {
            std.debug.print("get_packages failed: {t}\n", .{err});
            return;
        };

        var installed_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer installed_arena.deinit();
        const ialloc = installed_arena.allocator();

        var ithreaded: std.Io.Threaded = .init(ialloc, .{});
        defer ithreaded.deinit();
        const icli = ShellyCli{ .allocator = ialloc, .io = ithreaded.io() };

        const installed = icli.get_installed_packages() catch null;
        if (installed) |inst| {
            var set: std.StringHashMapUnmanaged(void) = .empty;
            for (inst.value) |pkg| set.put(ialloc, pkg.Name, {}) catch {};
            for (parsed.value) |*pkg| pkg.Installed = set.contains(pkg.Name);
        }

        var set: std.StringHashMapUnmanaged(void) = .empty;
        for (parsed.value) |pkg| {
            for (pkg.Groups) |g| set.put(alloc, g, {}) catch {};
        }

        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = set.keyIterator();
        while (it.next()) |k| list.append(alloc, k.*) catch {};

        post_result(page, parsed.value, list.items, arena_ptr, generation);
    }

    fn post_result(page: *Self, packages: []Package, groups: []const []const u8, arena: *std.heap.ArenaAllocator, generation: u64) void {
        const result = std.heap.c_allocator.create(LoadResult) catch return;
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

        const page_alloc = (p.arena orelse {
            result.arena.deinit();
            std.heap.c_allocator.destroy(result.arena);
            std.heap.c_allocator.destroy(result);
            return 0;
        }).allocator();

        if (result.index == 0) {
            const strings = gtk.StringList.new(null);
            gtk.StringList.append(strings, "Any");
            for (result.groups) |g| {
                var buf: [128]u8 = undefined;
                gtk.StringList.append(strings, c_string.cstr(&buf, g));
            }
            gtk.DropDown.setModel(p.grouping_selection, strings.as(gio.ListModel));
            gtk.DropDown.setSelected(p.grouping_selection, 0);
        }

        const batch_size = 500;
        const end = @min(result.index + batch_size, result.packages.len);
        const n = end - result.index;

        var batch: [500]*gobject.Object = undefined;
        var i: usize = 0;
        for (result.packages[result.index..end]) |d| {
            const pkg = PackageObject.new(page_alloc, d);
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
    }

    const template_children = .{
        .{ "package_column_view", @offsetOf(Private, "column_view") },
        .{ "name_column", @offsetOf(Private, "name_column") },
        .{ "version_column", @offsetOf(Private, "version_column") },
        .{ "size_column", @offsetOf(Private, "size_column") },
        .{ "repository_column", @offsetOf(Private, "repository_column") },
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
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_installed_only_toggled", @ptrCast(&on_installed_only_toggled));
        }
    };

    fn install_selected(self: *Self) callconv(.c) void {
        const dialog = ConfirmDialog.new(
            "Install Packages",
            "Install the selected packages?",
            &on_install_response,
            self,
        );
        dialog.setButtons("Install", "Cancel");

        if (support.getWindow(ShellyWindow, self)) |win| {
            win.showLockout(dialog.as(gtk.Widget));
        }
    }

    fn on_grid_view_toggled(self: *Self) callconv(.c) void {
        const p = self.priv();
        gtk.Widget.setVisible(p.detail_grid_hbox.as(gtk.Widget), 1);
        gtk.Widget.setVisible(p.detail_hbox.as(gtk.Widget), 0);
    }

    fn on_list_view_toggled(self: *Self) callconv(.c) void {
        const p = self.priv();
        gtk.Widget.setVisible(p.detail_hbox.as(gtk.Widget), 1);
        gtk.Widget.setVisible(p.detail_grid_hbox.as(gtk.Widget), 0);
    }

    fn on_installed_only_toggled(check: *gtk.CheckButton, self: *Self) callconv(.c) void {
        const p = self.priv();
        p.show_installed_only = gtk.CheckButton.getActive(check) != 0;
        gtk.Filter.changed(p.filter.as(gtk.Filter), .different);
    }

    fn on_install_response(ctx: ?*anyopaque, confirmed: bool) void {
        const self: *PackagePage = @ptrCast(@alignCast(ctx.?));
        if (support.getWindow(ShellyWindow, self)) |win| win.hideLockout();
        if (!confirmed) return;

        //     const p = self.priv();

        //     var names: std.ArrayListUnmanaged([]const u8) = .empty;
        //     defer names.deinit(std.heap.c_allocator);
        //     const n = gio.ListModel.getNItems(p.list_store.as(gio.ListModel));
        //     var i: u32 = 0;
        //     while (i < n) : (i += 1) {
        //         const obj = gio.ListModel.getObject(p.list_store.as(gio.ListModel), i) orelse continue;
        //         const pkg = gobject.ext.cast(PackageObject, obj) orelse continue;
        //         if (pkg.isSelected()) names.append(std.heap.c_allocator, pkg.getName()) catch continue;
        //     }
        //     if (names.items.len == 0) return;

        //     const op = std.heap.c_allocator.create(ShellyOperation) catch return;
        //     op.* = ShellyOperation.init(std.heap.c_allocator, &on_op_event, &on_op_done, self);
        //     op.io = op.threaded.io();
        //     p.operation = op;

        //     op.install(names.items) catch {
        //         std.debug.print("failed to start install\n", .{});
        //         std.heap.c_allocator.destroy(op);
        //         p.operation = null;
        //     };
    }

    // fn on_op_event(ctx: *anyopaque, events: Event) void {
    //     const self: *PackagePage = @ptrCast(@alignCast(ctx));
    //     self.handleOperationEvent(events);
    // }

    // fn on_op_done(ctx: *anyopaque, exit_code: u8) void {
    //     const self: *PackagePage = @ptrCast(@alignCast(ctx));
    //     self.handleOperationDone(exit_code);
    // }

    // fn handleOperationEvent(self: *Self, events: Event) void {
    //     _ = self;
    //     switch (events) {
    //         .info => |i| {
    //             std.debug.print("[info] {s}: {s}\n", .{ i.event_type, i.message });
    //         },
    //         .err => |e| {
    //             std.debug.print("[error] {s}\n", .{e.message});
    //         },
    //         .unknown => {},
    //     }
    // }

    // fn handleOperationDone(self: *Self, exit_code: u8) void {
    //     const p = self.priv();
    //     std.debug.print("[done] exit={d}\n", .{exit_code});
    //     if (p.operation) |op| {
    //         if (op.reader) |t| t.join(); // wait for reader to fully exit
    //         op.threaded.deinit();
    //         std.heap.c_allocator.destroy(op);
    //         p.operation = null;
    //     }
    // }
};
