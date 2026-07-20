const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gobject = bindings.gobject;
const support = @import("support.zig");

pub const SettingsPage = ShellySettingsPage;

pub const ShellySettingsPage = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gtk.Box;

    pub const title: [:0]const u8 = "Settings";
    pub const icon_name: [:0]const u8 = "emblem-system-symbolic";
    const resource_path = "/com/shellyorg/shelly/ui/settings_page.ui";

    const Private = struct {
        settings_stack: *gtk.Stack,

        // General
        aur_switch: *gtk.Switch,
        language_drop: *gtk.DropDown,
        flatpak_switch: *gtk.Switch,
        recommended_switch: *gtk.Switch,
        appimage_switch: *gtk.Switch,
        tray_switch: *gtk.Switch,
        tray_auto_switch: *gtk.Switch,
        tray_auto_switch_box: *gtk.Box,
        daily_schedule: *gtk.Switch,
        weekly_schedule_switch_box: *gtk.Box,
        tray_interval_box: *gtk.Box,
        tray_interval_spin: *gtk.SpinButton,
        weekly_schedule_box: *gtk.Box,
        day_sun_check: *gtk.CheckButton,
        day_mon_check: *gtk.CheckButton,
        day_tue_check: *gtk.CheckButton,
        day_wed_check: *gtk.CheckButton,
        day_thu_check: *gtk.CheckButton,
        day_fri_check: *gtk.CheckButton,
        day_sat_check: *gtk.CheckButton,
        update_hour_spin: *gtk.SpinButton,
        update_minute_spin: *gtk.SpinButton,

        // Look & Feel
        shelly_icons_switch: *gtk.Switch,
        use_old_menu_switch: *gtk.Switch,
        symbolic_tray_box: *gtk.Box,
        symbolic_tray_switch: *gtk.Switch,
        tray_icon_button: *gtk.Button,
        tray_icon_clear_button: *gtk.Button,
        tray_updates_icon_button: *gtk.Button,
        tray_updates_icon_clear_button: *gtk.Button,
        default_page_box: *gtk.Box,
        default_page_drop: *gtk.DropDown,

        // Advanced
        remove_cache_switch: *gtk.Switch,
        no_confirm_switch: *gtk.Switch,
        shelly_search_switch: *gtk.Switch,
        package_downgrade_switch: *gtk.Switch,
        webview_switch: *gtk.Switch,
        appimage_install_path_box: *gtk.Box,
        appimage_install_path_button: *gtk.Button,
        parallel_downloads_spin: *gtk.SpinButton,
        sync_button: *gtk.Button,
        rm_db_lock_button: *gtk.Button,
        view_pacfiles_button: *gtk.Button,
        fix_permissions_button: *gtk.Button,
        purify_button: *gtk.Button,

        // Bottom action bar
        save_button: *gtk.Button,
        changelog_button: *gtk.Button,
        version_label: *gtk.Label,
        github_link: *gtk.LinkButton,
        fluxer_link: *gtk.LinkButton,
        sponsor_link: *gtk.LinkButton,

        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellySettingsPage",
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

        _ = gtk.Button.signals.clicked.connect(p.save_button, *Self, &on_save_clicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(p.changelog_button, *Self, &on_changelog_clicked, self, .{});

        _ = gtk.Button.signals.clicked.connect(p.tray_icon_button, *Self, &on_pick_tray_icon, self, .{});
        _ = gtk.Button.signals.clicked.connect(p.tray_icon_clear_button, *Self, &on_clear_tray_icon, self, .{});
        _ = gtk.Button.signals.clicked.connect(p.tray_updates_icon_button, *Self, &on_pick_tray_updates_icon, self, .{});
        _ = gtk.Button.signals.clicked.connect(p.tray_updates_icon_clear_button, *Self, &on_clear_tray_updates_icon, self, .{});

        _ = gtk.Button.signals.clicked.connect(p.appimage_install_path_button, *Self, &on_pick_appimage_install_path, self, .{});

        _ = gtk.Button.signals.clicked.connect(p.sync_button, *Self, &on_sync_db, self, .{});
        _ = gtk.Button.signals.clicked.connect(p.rm_db_lock_button, *Self, &on_remove_db_lock, self, .{});
        _ = gtk.Button.signals.clicked.connect(p.view_pacfiles_button, *Self, &on_view_pacfiles, self, .{});
        _ = gtk.Button.signals.clicked.connect(p.fix_permissions_button, *Self, &on_fix_permissions, self, .{});
        _ = gtk.Button.signals.clicked.connect(p.purify_button, *Self, &on_purify, self, .{});

        support.connectLifecycle(Self, self);
    }

    pub fn onMap(self: *Self) void {
        _ = self;
        // Config load will be wired in a later phase.
    }

    pub fn onUnmap(self: *Self) void {
        _ = self;
        // Nothing to tear down yet; added for parity with other pages.
    }

    fn on_save_clicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        _ = self;
        std.debug.print("settings: save (not implemented yet)\n", .{});
    }

    fn on_changelog_clicked(_: *gtk.Button, _: *Self) callconv(.c) void {
        std.debug.print("settings: view changelog (not implemented yet)\n", .{});
    }

    fn on_pick_tray_icon(_: *gtk.Button, _: *Self) callconv(.c) void {
        std.debug.print("settings: pick tray icon (not implemented yet)\n", .{});
    }

    fn on_clear_tray_icon(_: *gtk.Button, _: *Self) callconv(.c) void {
        std.debug.print("settings: clear tray icon (not implemented yet)\n", .{});
    }

    fn on_pick_tray_updates_icon(_: *gtk.Button, _: *Self) callconv(.c) void {
        std.debug.print("settings: pick tray updates icon (not implemented yet)\n", .{});
    }

    fn on_clear_tray_updates_icon(_: *gtk.Button, _: *Self) callconv(.c) void {
        std.debug.print("settings: clear tray updates icon (not implemented yet)\n", .{});
    }

    fn on_pick_appimage_install_path(_: *gtk.Button, _: *Self) callconv(.c) void {
        std.debug.print("settings: pick appimage install path (not implemented yet)\n", .{});
    }

    fn on_sync_db(_: *gtk.Button, _: *Self) callconv(.c) void {
        std.debug.print("settings: force database update (not implemented yet)\n", .{});
    }

    fn on_remove_db_lock(_: *gtk.Button, _: *Self) callconv(.c) void {
        std.debug.print("settings: remove db.lck (not implemented yet)\n", .{});
    }

    fn on_view_pacfiles(_: *gtk.Button, _: *Self) callconv(.c) void {
        std.debug.print("settings: view pacfiles (not implemented yet)\n", .{});
    }

    fn on_fix_permissions(_: *gtk.Button, _: *Self) callconv(.c) void {
        std.debug.print("settings: fix permissions (not implemented yet)\n", .{});
    }

    fn on_purify(_: *gtk.Button, _: *Self) callconv(.c) void {
        std.debug.print("settings: purify packages (not implemented yet)\n", .{});
    }

    const template_children = .{
        .{ "settings_stack", @offsetOf(Private, "settings_stack") },

        // General
        .{ "aur_switch", @offsetOf(Private, "aur_switch") },
        .{ "language_drop", @offsetOf(Private, "language_drop") },
        .{ "flatpak_switch", @offsetOf(Private, "flatpak_switch") },
        .{ "recommended_switch", @offsetOf(Private, "recommended_switch") },
        .{ "appimage_switch", @offsetOf(Private, "appimage_switch") },
        .{ "tray_switch", @offsetOf(Private, "tray_switch") },
        .{ "tray_auto_switch", @offsetOf(Private, "tray_auto_switch") },
        .{ "tray_auto_switch_box", @offsetOf(Private, "tray_auto_switch_box") },
        .{ "daily_schedule", @offsetOf(Private, "daily_schedule") },
        .{ "weekly_schedule_switch_box", @offsetOf(Private, "weekly_schedule_switch_box") },
        .{ "tray_interval_box", @offsetOf(Private, "tray_interval_box") },
        .{ "tray_interval_spin", @offsetOf(Private, "tray_interval_spin") },
        .{ "weekly_schedule_box", @offsetOf(Private, "weekly_schedule_box") },
        .{ "day_sun_check", @offsetOf(Private, "day_sun_check") },
        .{ "day_mon_check", @offsetOf(Private, "day_mon_check") },
        .{ "day_tue_check", @offsetOf(Private, "day_tue_check") },
        .{ "day_wed_check", @offsetOf(Private, "day_wed_check") },
        .{ "day_thu_check", @offsetOf(Private, "day_thu_check") },
        .{ "day_fri_check", @offsetOf(Private, "day_fri_check") },
        .{ "day_sat_check", @offsetOf(Private, "day_sat_check") },
        .{ "update_hour_spin", @offsetOf(Private, "update_hour_spin") },
        .{ "update_minute_spin", @offsetOf(Private, "update_minute_spin") },

        // Look & Feel
        .{ "shelly_icons_switch", @offsetOf(Private, "shelly_icons_switch") },
        .{ "use_old_menu_switch", @offsetOf(Private, "use_old_menu_switch") },
        .{ "symbolic_tray_box", @offsetOf(Private, "symbolic_tray_box") },
        .{ "symbolic_tray_switch", @offsetOf(Private, "symbolic_tray_switch") },
        .{ "tray_icon_button", @offsetOf(Private, "tray_icon_button") },
        .{ "tray_icon_clear_button", @offsetOf(Private, "tray_icon_clear_button") },
        .{ "tray_updates_icon_button", @offsetOf(Private, "tray_updates_icon_button") },
        .{ "tray_updates_icon_clear_button", @offsetOf(Private, "tray_updates_icon_clear_button") },
        .{ "default_page_box", @offsetOf(Private, "default_page_box") },
        .{ "default_page_drop", @offsetOf(Private, "default_page_drop") },

        // Advanced
        .{ "remove_cache_switch", @offsetOf(Private, "remove_cache_switch") },
        .{ "no_confirm_switch", @offsetOf(Private, "no_confirm_switch") },
        .{ "shelly_search_switch", @offsetOf(Private, "shelly_search_switch") },
        .{ "package_downgrade_switch", @offsetOf(Private, "package_downgrade_switch") },
        .{ "webview_switch", @offsetOf(Private, "webview_switch") },
        .{ "appimage_install_path_box", @offsetOf(Private, "appimage_install_path_box") },
        .{ "appimage_install_path_button", @offsetOf(Private, "appimage_install_path_button") },
        .{ "parallel_downloads_spin", @offsetOf(Private, "parallel_downloads_spin") },
        .{ "sync_button", @offsetOf(Private, "sync_button") },
        .{ "rm_db_lock_button", @offsetOf(Private, "rm_db_lock_button") },
        .{ "view_pacfiles_button", @offsetOf(Private, "view_pacfiles_button") },
        .{ "fix_permissions_button", @offsetOf(Private, "fix_permissions_button") },
        .{ "purify_button", @offsetOf(Private, "purify_button") },

        // Bottom action bar
        .{ "save_button", @offsetOf(Private, "save_button") },
        .{ "changelog_button", @offsetOf(Private, "changelog_button") },
        .{ "version_label", @offsetOf(Private, "version_label") },
        .{ "github_link", @offsetOf(Private, "github_link") },
        .{ "fluxer_link", @offsetOf(Private, "fluxer_link") },
        .{ "sponsor_link", @offsetOf(Private, "sponsor_link") },
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
        }

        pub fn as(class: *Class, comptime T: type) *T {
            return gobject.ext.as(T, class);
        }
    };
};
