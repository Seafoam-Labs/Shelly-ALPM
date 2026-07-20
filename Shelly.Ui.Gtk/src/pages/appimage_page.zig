const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gobject = bindings.gobject;
const support = @import("support.zig");

pub const AppImagePage = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gtk.Box;

    pub const title: [:0]const u8 = "AppImage";
    pub const icon_name: [:0]const u8 = "application-x-executable-symbolic";
    const resource_path = "/com/shellyorg/shelly/ui/appimage_page.ui";

    const Private = struct {
        app_list: *gtk.ListBox,
        list_view: *gtk.Widget,
        detail_view: *gtk.Widget,
        detail_title: *gtk.Label,
        detail_version: *gtk.Label,
        detail_description: *gtk.Label,
        detail_icon: *gtk.Image,
        loaded: bool,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyAppImagePage",
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

    const appimage = struct {
        desktop_name: [:0]const u8,
        version: [:0]const u8,
        description: [:0]const u8 = "",
        icon_name: [:0]const u8 = "",
    };

    const dummy_data = [_]appimage{
        .{ .desktop_name = "Blender", .version = "4.2.0" },
        .{ .desktop_name = "Krita", .version = "5.2.3" },
        .{ .desktop_name = "OBS Studio", .version = "30.1.2" },
        .{ .desktop_name = "Inkscape", .version = "1.3.2" },
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        const p = self.priv();
        p.loaded = false;

        gtk.Widget.setVexpand(p.detail_view, 1);
        gtk.Widget.setHexpand(p.detail_view, 1);

        support.connectLifecycle(Self, self);
        _ = gtk.ListBox.signals.row_activated.connect(p.app_list, *Self, &onRowActivated, self, .{});
    }

    pub fn onMap(self: *Self) void {
        const p = self.priv();
        if (p.loaded) return;
        p.loaded = true;

        for (dummy_data, 0..) |app, i| {
            const row = make_app_row(app, i);
            gtk.ListBox.append(p.app_list, row);
        }
    }

    pub fn onUnmap(self: *Self) void {
        const p = self.priv();
        if (!p.loaded) return;
        p.loaded = false;
        gtk.ListBox.removeAll(p.app_list);
    }

    fn make_app_row(app: appimage, index: usize) *gtk.Widget {
        const row = gtk.ListBoxRow.new();
        gtk.ListBoxRow.setActivatable(row, 1);

        gobject.Object.setData(
            row.as(gobject.Object),
            "app-index",
            @ptrFromInt(index + 1),
        );

        const hbox = gtk.Box.new(.horizontal, 12);
        gtk.Widget.setMarginStart(hbox.as(gtk.Widget), 12);
        gtk.Widget.setMarginEnd(hbox.as(gtk.Widget), 12);
        gtk.Widget.setMarginTop(hbox.as(gtk.Widget), 8);
        gtk.Widget.setMarginBottom(hbox.as(gtk.Widget), 8);

        const icon = gtk.Image.new();
        gtk.Image.setPixelSize(icon, 32);
        gtk.Image.setFromIconName(icon, "application-x-executable-symbolic");
        gtk.Box.append(hbox, icon.as(gtk.Widget));

        const vbox = gtk.Box.new(.vertical, 2);
        gtk.Widget.setHexpand(vbox.as(gtk.Widget), 1);

        const name_label = gtk.Label.new(app.desktop_name);
        gtk.Widget.addCssClass(name_label.as(gtk.Widget), "title-4");
        gtk.Label.setXalign(name_label, 0);
        gtk.Box.append(vbox, name_label.as(gtk.Widget));

        const version_hbox = gtk.Box.new(.horizontal, 6);

        const version_label = gtk.Label.new(app.version);
        gtk.Widget.addCssClass(version_label.as(gtk.Widget), "caption");
        gtk.Widget.addCssClass(version_label.as(gtk.Widget), "dim-label");
        gtk.Label.setXalign(version_label, 0);
        gtk.Box.append(version_hbox, version_label.as(gtk.Widget));

        const update_label = gtk.Label.new("");
        gtk.Widget.setVisible(update_label.as(gtk.Widget), 0);
        gtk.Widget.setValign(update_label.as(gtk.Widget), .center);
        gtk.Widget.addCssClass(update_label.as(gtk.Widget), "caption");
        gtk.Widget.addCssClass(update_label.as(gtk.Widget), "dim-label");
        gtk.Box.append(version_hbox, update_label.as(gtk.Widget));

        gtk.Box.append(vbox, version_hbox.as(gtk.Widget));

        if (app.description.len > 0) {
            const desc_label = gtk.Label.new(app.description);
            gtk.Widget.addCssClass(desc_label.as(gtk.Widget), "caption");
            gtk.Widget.addCssClass(desc_label.as(gtk.Widget), "dim-label");
            gtk.Label.setXalign(desc_label, 0);
            gtk.Label.setEllipsize(desc_label, .end);
            gtk.Label.setMaxWidthChars(desc_label, 50);
            gtk.Box.append(vbox, desc_label.as(gtk.Widget));
        }

        gtk.Box.append(hbox, vbox.as(gtk.Widget));
        gtk.ListBoxRow.setChild(row, hbox.as(gtk.Widget));
        return row.as(gtk.Widget);
    }

    fn onRowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const raw = gobject.Object.getData(row.as(gobject.Object), "app-index");
        if (raw == null) return;
        const index = @intFromPtr(raw) - 1;

        if (index < dummy_data.len) {
            show_detail(self, dummy_data[index]);
        }
    }

    fn show_detail(self: *Self, app: appimage) void {
        const p = self.priv();

        gtk.Label.setLabel(p.detail_title, app.desktop_name);
        gtk.Label.setLabel(p.detail_version, app.version);
        gtk.Label.setLabel(p.detail_description, app.description);
        gtk.Image.setFromIconName(p.detail_icon, if (app.icon_name.len == 0) "application-x-executable-symbolic" else app.icon_name);
        gtk.Widget.setVisible(p.list_view, 0);
        gtk.Widget.setVisible(p.detail_view, 1);
    }

    fn show_list(self: *Self) void {
        const p = self.priv();
        gtk.Widget.setVisible(p.detail_view, 0);
        gtk.Widget.setVisible(p.list_view, 1);
    }

    const template_children = .{
        .{ "AppImageListBox", @offsetOf(Private, "app_list") },
        .{ "AppImageOverlay", @offsetOf(Private, "list_view") },
        .{ "AppImageDetailView", @offsetOf(Private, "detail_view") },
        .{ "DetailTitleLabel", @offsetOf(Private, "detail_title") },
        .{ "DetailVersionLabel", @offsetOf(Private, "detail_version") },
        .{ "DetailDescriptionLabel", @offsetOf(Private, "detail_description") },
        .{ "DetailIcon", @offsetOf(Private, "detail_icon") },
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
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "install_appimage", @ptrCast(&install_appimage));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "upgrade_appimage", @ptrCast(&upgrade_appimage));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "sync_all_appimage", @ptrCast(&sync_all_appimage));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "back_to_list", @ptrCast(&back_to_list));
        }
    };

    fn install_appimage() callconv(.c) void {
        std.debug.print("install", .{});
    }

    fn upgrade_appimage() callconv(.c) void {
        std.debug.print("upgrade", .{});
    }

    fn sync_all_appimage() callconv(.c) void {
        std.debug.print("sync", .{});
    }

    fn back_to_list(self: *Self) callconv(.c) void {
        show_list(self);
    }

    //
    // fn onDownloadClicked(_: *gtk.Button, page: *AppImagePage) callconv(.c) void {
    // const root = gtk.Widget.getRoot(page.as(gtk.Widget));
    // const window = gobject.ext.cast(ShellyWindow, root) orelse return;
    // window.showProgress("Downloading AppImage…");
    // // kick off the download; drive window.setProgress(...) as it proceeds;
    // // window.hideProgress() when done.
    // }
};
