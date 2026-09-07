const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gio = bindings.gio;
const glib = bindings.glib;
const gobject = bindings.gobject;
const support = @import("../support.zig");

const FlatpakInstallView = @import("flatpak_install_view.zig").FlatpakInstallView;
const FlatpakRemoveView = @import("flatpak_remove_view.zig").FlatpakRemoveView;
const FlatpakRemotesView = @import("flatpak_remotes_view.zig").FlatpakRemotesView;
const FlatpakInstallLocalView = @import("flatpak_install_local_view.zig").FlatpakInstallLocalView;
const Category = @import("../../models/flatpak.zig").Category;
const translations = @import("../../helpers/translations.zig");

pub const FlatpakPage = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gtk.Box;

    pub const title: [:0]const u8 = "Flatpak";
    pub const icon_name: [:0]const u8 = "flatpak-symbolic";

    pub const Section = enum {
        install,
        remove,
        remotes,
        local,
    };

    const resource_path = "/com/shellyorg/shelly/ui/flatpak/flatpak_page.ui";

    const Private = struct {
        main_content_stack: *gtk.Stack,
        section_nav_list: *gtk.ListBox,
        nav_install_row: *gtk.ListBoxRow,
        nav_remove_row: *gtk.ListBoxRow,
        nav_remote_row: *gtk.ListBoxRow,
        nav_install_local: *gtk.ListBoxRow,
        category_list: *gtk.ListBox,
        search_entry: *gtk.SearchEntry,
        install_view: *FlatpakInstallView,
        remove_view: *FlatpakRemoveView,
        loaded: bool,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyFlatpakPage",
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

    pub fn navigateTo(self: *Self, section: Section) void {
        const p = self.priv();
        const row: *gtk.ListBoxRow = switch (section) {
            .install => p.nav_install_row,
            .remove => p.nav_remove_row,
            .remotes => p.nav_remote_row,
            .local => p.nav_install_local,
        };
        const name: [:0]const u8 = switch (section) {
            .install => "install",
            .remove => "remove",
            .remotes => "remotes",
            .local => "local",
        };
        gtk.ListBox.selectRow(p.section_nav_list, row);
        gtk.Stack.setVisibleChildName(p.main_content_stack, name);
    }

    pub fn openApp(self: *Self, app_id: [:0]const u8) void {
        const p = self.priv();
        gtk.Editable.setText(p.search_entry.as(gtk.Editable), "");
        if (gtk.ListBox.getRowAtIndex(p.category_list, 0)) |row| {
            gtk.ListBox.selectRow(p.category_list, row);
        }
        p.install_view.openAppById(app_id);
        self.navigateTo(.install);
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        const p = self.priv();
        p.loaded = false;

        populateStack(self);

        _ = gtk.SearchEntry.signals.search_changed.connect(p.search_entry, *Self, &onSearchChanged, self, .{});
        _ = gtk.SearchEntry.signals.activate.connect(p.search_entry, *Self, &onSearchActivate, self, .{});

        _ = gtk.ListBox.signals.row_selected.connect(
            p.section_nav_list,
            *Self,
            &onNavRowSelected,
            self,
            .{},
        );

        _ = gtk.ListBox.signals.row_selected.connect(
            p.category_list,
            *Self,
            &onCategoryRowSelected,
            self,
            .{},
        );

        // start on Install
        gtk.ListBox.selectRow(p.section_nav_list, p.nav_install_row);
        gtk.Stack.setVisibleChildName(p.main_content_stack, "install");

        gtk.ListBox.setHeaderFunc(p.category_list, &getCategoryHeader, null, null);

        const group = gio.SimpleActionGroup.new();
        const action = gio.SimpleAction.new("focus", null);
        _ = gio.SimpleAction.signals.activate.connect(action, *Self, &onFocusSearch, self, .{});
        gio.ActionMap.addAction(group.as(gio.ActionMap), action.as(gio.Action));
        gtk.Widget.insertActionGroup(self.as(gtk.Widget), "search", group.as(gio.ActionGroup));

        support.connectLifecycle(Self, self);
    }

    fn onFocusSearch(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        _ = gtk.Widget.grabFocus(self.priv().search_entry.as(gtk.Widget));
    }

    fn populateStack(self: *Self) void {
        const p = self.priv();

        const install = FlatpakInstallView.new();
        p.install_view = install;
        _ = gtk.Stack.addNamed(p.main_content_stack, install.as(gtk.Widget), "install");

        const remove = FlatpakRemoveView.new();
        p.remove_view = remove;
        _ = gtk.Stack.addNamed(p.main_content_stack, remove.as(gtk.Widget), "remove");

        const remotes = FlatpakRemotesView.new();
        _ = gtk.Stack.addNamed(p.main_content_stack, remotes.as(gtk.Widget), "remotes");

        const local = FlatpakInstallLocalView.new();
        _ = gtk.Stack.addNamed(p.main_content_stack, local.as(gtk.Widget), "local");
    }

    fn onNavRowSelected(_: *gtk.ListBox, row: ?*gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const p = self.priv();
        const r = row orelse return;

        const name: [:0]const u8 =
            if (r == p.nav_install_row) "install" else if (r == p.nav_remove_row) "remove" else if (r == p.nav_remote_row) "remotes" else if (r == p.nav_install_local) "local" else return;

        gtk.Stack.setVisibleChildName(p.main_content_stack, name);
    }

    fn getCategoryHeader(row: *gtk.ListBoxRow, before: ?*gtk.ListBoxRow, _: ?*anyopaque) callconv(.c) void {
        const raw = gobject.Object.getData(row.as(gobject.Object), "category-index");
        if (raw == null) return;
        const index = @intFromPtr(raw) - 1;
        const category: Category = @enumFromInt(index);

        const header_text: ?[:0]const u8 = switch (category) {
            .@"All Applications" => translations._("Discover"),
            .@"Audio & Video" => translations._("Categories"),
            else => null,
        };

        if (header_text) |text| {
            const label = gtk.Label.new(text);
            gtk.Widget.setHalign(label.as(gtk.Widget), .start);
            gtk.Label.setXalign(label, 0);
            gtk.Widget.setMarginStart(label.as(gtk.Widget), 6);
            gtk.Widget.setMarginTop(label.as(gtk.Widget), if (before == null) 2 else 10);
            gtk.Widget.setMarginBottom(label.as(gtk.Widget), 4);
            gtk.Widget.addCssClass(label.as(gtk.Widget), "dim-label");
            gtk.Widget.addCssClass(label.as(gtk.Widget), "caption-heading");
            gtk.ListBoxRow.setHeader(row, label.as(gtk.Widget));
        } else {
            gtk.ListBoxRow.setHeader(row, null);
        }
    }

    fn onCategoryRowSelected(_: *gtk.ListBox, row: ?*gtk.ListBoxRow, self: *Self) callconv(.c) void {
        if (row) |r| {
            const raw = gobject.Object.getData(r.as(gobject.Object), "category-index");
            if (raw == null) return;
            const index = @intFromPtr(raw) - 1;

            std.debug.print("index: {d}\n", .{index});

            const app: Category = @enumFromInt(index);
            const p = self.priv();
            p.install_view.applyCategory(app);
        }
    }

    fn onSearchChanged(entry: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        const text = std.mem.span(gtk.Editable.getText(entry.as(gtk.Editable)));
        const p = self.priv();
        p.install_view.applySearch(text);
        p.remove_view.applySearch(text);
    }

    fn onSearchActivate(entry: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        const text = std.mem.span(gtk.Editable.getText(entry.as(gtk.Editable)));
        const p = self.priv();
        p.install_view.applySearch(text);
        p.remove_view.applySearch(text);
        p.install_view.showList();
    }

    pub fn onMap(self: *Self) void {
        const p = self.priv();
        if (p.loaded) return;

        p.category_list.removeAll();

        for (std.enums.values(Category)) |app| {
            const row = gtk.ListBoxRow.new();
            const enum_num: usize = @intFromEnum(app);
            gobject.Object.setData(
                row.as(gobject.Object),
                "category-index",
                @ptrFromInt(enum_num + 1),
            );

            const box = gtk.Box.new(.horizontal, 10);
            gtk.Widget.setMarginStart(box.as(gtk.Widget), 6);
            gtk.Widget.setMarginEnd(box.as(gtk.Widget), 6);
            gtk.Widget.setMarginTop(box.as(gtk.Widget), 2);
            gtk.Widget.setMarginBottom(box.as(gtk.Widget), 2);

            const icon = gtk.Image.newFromIconName(getIconForCategory(app));
            gtk.Image.setPixelSize(icon, 16);
            gtk.Widget.setValign(icon.as(gtk.Widget), .center);
            gtk.Box.append(box, icon.as(gtk.Widget));

            const label = gtk.Label.new(getCategoryLabel(app));
            gtk.Widget.setHalign(label.as(gtk.Widget), .start);
            gtk.Widget.setHexpand(label.as(gtk.Widget), 1);
            gtk.Label.setXalign(label, 0);
            gtk.Box.append(box, label.as(gtk.Widget));

            gtk.ListBoxRow.setChild(row, box.as(gtk.Widget));
            gtk.ListBox.append(p.category_list, row.as(gtk.Widget));
        }

        p.loaded = true;
    }

    fn getIconForCategory(category: Category) [:0]const u8 {
        return switch (category) {
            .@"All Applications" => "view-grid-symbolic",
            .Recommended => "starred-symbolic",
            .Verified => "security-high-symbolic",
            .@"Most Wanted" => "user-bookmarks-symbolic",
            .@"Recently Added" => "list-add-symbolic",
            .@"Recently Updated" => "view-refresh-symbolic",
            .@"Audio & Video" => "applications-multimedia-symbolic",
            .Development => "applications-engineering-symbolic",
            .Education => "applications-science-symbolic",
            .Game => "applications-games-symbolic",
            .Graphics => "applications-graphics-symbolic",
            .Network => "network-workgroup-symbolic",
            .Office => "x-office-document-symbolic",
            .Science => "applications-science-symbolic",
            .System => "applications-system-symbolic",
            .Utility => "applications-utilities-symbolic",
        };
    }

    fn getCategoryLabel(category: Category) [:0]const u8 {
        return switch (category) {
            .@"All Applications" => translations._("All Applications"),
            .Recommended => translations._("Recommended"),
            .Verified => translations._("Verified"),
            .@"Most Wanted" => translations._("Most Wanted"),
            .@"Recently Added" => translations._("Recently Added"),
            .@"Recently Updated" => translations._("Recently Updated"),
            .@"Audio & Video" => translations._("Audio & Video"),
            .Development => translations._("Development"),
            .Education => translations._("Education"),
            .Game => translations._("Game"),
            .Graphics => translations._("Graphics"),
            .Network => translations._("Network"),
            .Office => translations._("Office"),
            .Science => translations._("Science"),
            .System => translations._("System"),
            .Utility => translations._("Utility"),
        };
    }

    pub fn onUnmap(self: *Self) void {
        const p = self.priv();
        if (!p.loaded) return;
        p.loaded = false;
    }

    const template_children = .{
        .{ "main_content_stack", @offsetOf(Private, "main_content_stack") },
        .{ "section_nav_list", @offsetOf(Private, "section_nav_list") },
        .{ "nav_install_row", @offsetOf(Private, "nav_install_row") },
        .{ "nav_remove_row", @offsetOf(Private, "nav_remove_row") },
        .{ "nav_remote_row", @offsetOf(Private, "nav_remote_row") },
        .{ "nav_install_local", @offsetOf(Private, "nav_install_local") },
        .{ "search_entry", @offsetOf(Private, "search_entry") },
        .{ "category_list", @offsetOf(Private, "category_list") },
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
        }
    };
};
