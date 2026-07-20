const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gobject = bindings.gobject;
const support = @import("../support.zig");

const FlatpakInstallView = @import("flatpak_install_view.zig").FlatpakInstallView;
const FlatpakRemoveView = @import("flatpak_remove_view.zig").FlatpakRemoveView;
const FlatpakRemotesView = @import("flatpak_remotes_view.zig").FlatpakRemotesView;

pub const FlatpakPage = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gtk.Box;

    pub const title: [:0]const u8 = "Flatpak";
    pub const icon_name: [:0]const u8 = "flatpak-symbolic";
    const resource_path = "/com/shellyorg/shelly/ui/flatpak/flatpak_page.ui";

    const Private = struct {
        main_content_stack: *gtk.Stack,
        section_nav_list: *gtk.ListBox,
        nav_install_row: *gtk.ListBoxRow,
        nav_remove_row: *gtk.ListBoxRow,
        nav_remote_row: *gtk.ListBoxRow,
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

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        const p = self.priv();
        p.loaded = false;

        populateStack(self);

        _ = gtk.SearchEntry.signals.search_changed.connect(p.search_entry, *Self, &onSearchChanged, self, .{});

        _ = gtk.ListBox.signals.row_selected.connect(
            p.section_nav_list,
            *Self,
            &onNavRowSelected,
            self,
            .{},
        );

        // start on Install
        gtk.ListBox.selectRow(p.section_nav_list, p.nav_install_row);
        gtk.Stack.setVisibleChildName(p.main_content_stack, "install");

        support.connectLifecycle(Self, self);
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
    }

    fn onNavRowSelected(_: *gtk.ListBox, row: ?*gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const p = self.priv();
        const r = row orelse return;

        const name: [:0]const u8 =
            if (r == p.nav_install_row) "install" else if (r == p.nav_remove_row) "remove" else if (r == p.nav_remote_row) "remotes" else return;

        gtk.Stack.setVisibleChildName(p.main_content_stack, name);
    }

    fn onSearchChanged(entry: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        const text = std.mem.span(gtk.Editable.getText(entry.as(gtk.Editable)));
        const p = self.priv();
        p.install_view.apply_search(text);
        p.remove_view.applySearch(text);
    }

    pub fn onMap(self: *Self) void {
        const p = self.priv();
        if (p.loaded) return;
        p.loaded = true;
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
        .{ "search_entry", @offsetOf(Private, "search_entry") },
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
