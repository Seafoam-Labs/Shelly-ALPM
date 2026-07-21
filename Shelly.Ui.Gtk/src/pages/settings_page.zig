const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gobject = bindings.gobject;
const gio = bindings.gio;
const glib = bindings.glib;
const ShellyConfig = @import("../models/shelly_config.zig").ShellyConfig;
const ShellyTabs = @import("../models/shelly_config.zig").ShellyTabs;
const DayOfWeek = @import("../models/shelly_config.zig").DayOfWeek;
const ConfigResolver = @import("../services/config_resolver.zig").ConfigResolver;
const runtime = @import("../services/runtime.zig");
const support = @import("support.zig");
const datetime = @import("../helpers/datetime.zig");
const ShellyWindow = @import("../shelly_window.zig").ShellyWindow;

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
        sync_button: *gtk.Button,
        rm_db_lock_button: *gtk.Button,
        fix_permissions_button: *gtk.Button,
        purify_button: *gtk.Button,

        // Bottom action bar
        save_button: *gtk.Button,
        changelog_button: *gtk.Button,
        version_label: *gtk.Label,
        github_link: *gtk.LinkButton,
        fluxer_link: *gtk.LinkButton,
        sponsor_link: *gtk.LinkButton,

        loaded: bool,

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
        p.loaded = false;

        populateDropdowns(p);

        _ = gtk.Button.signals.clicked.connect(p.save_button, *Self, &on_save_clicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(p.changelog_button, *Self, &on_changelog_clicked, self, .{});

        _ = gtk.Button.signals.clicked.connect(p.tray_icon_button, *Self, &on_pick_tray_icon, self, .{});
        _ = gtk.Button.signals.clicked.connect(p.tray_icon_clear_button, *Self, &on_clear_tray_icon, self, .{});
        _ = gtk.Button.signals.clicked.connect(p.tray_updates_icon_button, *Self, &on_pick_tray_updates_icon, self, .{});
        _ = gtk.Button.signals.clicked.connect(p.tray_updates_icon_clear_button, *Self, &on_clear_tray_updates_icon, self, .{});

        _ = gtk.Button.signals.clicked.connect(p.appimage_install_path_button, *Self, &on_pick_appimage_install_path, self, .{});

        _ = gtk.Button.signals.clicked.connect(p.sync_button, *Self, &on_sync_db, self, .{});
        _ = gtk.Button.signals.clicked.connect(p.rm_db_lock_button, *Self, &on_remove_db_lock, self, .{});
        _ = gtk.Button.signals.clicked.connect(p.fix_permissions_button, *Self, &on_fix_permissions, self, .{});
        _ = gtk.Button.signals.clicked.connect(p.purify_button, *Self, &on_purify, self, .{});

        _ = gobject.Object.signals.notify.connect(
            p.daily_schedule.as(gobject.Object),
            *Self,
            &on_schedule_notify,
            self,
            .{ .detail = "active" },
        );
        _ = gobject.Object.signals.notify.connect(
            p.tray_switch.as(gobject.Object),
            *Self,
            &on_tray_notify,
            self,
            .{ .detail = "active" },
        );

        support.connectLifecycle(Self, self);
    }

    pub fn onMap(self: *Self) void {
        const p = self.priv();
        if (p.loaded) return;
        p.loaded = true;

        const svc = obtainConfigService() catch |err| {
            std.log.warn("settings: could not open config service: {t}", .{err});
            return;
        };
        const cfg = svc.get() catch |err| {
            std.log.warn("settings: config not loaded: {t}", .{err});
            return;
        };

        populateFromConfig(p, cfg);
        applyScheduleVisibility(p);
        applyTrayVisibility(p);
    }

    pub fn onUnmap(self: *Self) void {
        self.save() catch |err| {
            std.log.err("settings: save failed: {t}", .{err});
        };
    }

    fn on_save_clicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.save() catch |err| {
            std.log.err("settings: save failed: {t}", .{err});
        };
    }

    fn save(self: *Self) !void {
        const p = self.priv();
        const svc = obtainConfigService() catch return;
        const cfg = svc.get() catch return;

        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();

        var updated = cfg.*;
        collectIntoConfig(p, arena.allocator(), &updated);
        try svc.set(updated);
        try svc.save();

        applyScheduleVisibility(p);
        applyTrayVisibility(p);
    }

    fn on_changelog_clicked(_: *gtk.Button, _: *Self) callconv(.c) void {
        std.debug.print("settings: view changelog (not implemented yet)\n", .{});
    }

    fn on_pick_tray_icon(_: *gtk.Button, self: *Self) callconv(.c) void {
        const dialog = gtk.FileDialog.new();
        gtk.FileDialog.setTitle(dialog, "Select Tray Icon");

        const root = gtk.Widget.getRoot(self.as(gtk.Widget));
        const parent: ?*gtk.Window = if (root) |r| gobject.ext.cast(gtk.Window, r) else null;

        gtk.FileDialog.open(
            dialog,
            parent,
            null,
            &on_tray_icon_selected,
            self,
        );
    }

    fn on_tray_icon_selected(
        source_object: ?*gobject.Object,
        result: *gio.AsyncResult,
        user_data: ?*anyopaque,
    ) callconv(.c) void {
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source_object.?));
        defer gobject.Object.unref(gobject.ext.as(gobject.Object, dialog));

        var err: ?*glib.Error = null;
        const file = gtk.FileDialog.openFinish(dialog, result, &err);
        if (err) |e| {
            if (e.f_code != @intFromEnum(gio.IOErrorEnum.cancelled)) {
                std.log.warn("settings: file selection failed: {s}", .{e.f_message orelse ""});
            }
            glib.Error.free(e);
            return;
        }

        const f = file orelse return;
        defer gobject.Object.unref(gobject.ext.as(gobject.Object, f));

        const path_cstr = gio.File.getPath(f) orelse return;
        defer glib.free(path_cstr);
        const path_slice = std.mem.span(path_cstr);

        const self: *Self = @ptrCast(@alignCast(user_data.?));
        const p = self.priv();
        gtk.Button.setLabel(p.tray_icon_button, path_cstr);

        updateConfigField(.TrayIconPath, path_slice);
    }

    fn on_clear_tray_icon(_: *gtk.Button, self: *Self) callconv(.c) void {
        const p = self.priv();
        gtk.Button.setLabel(p.tray_icon_button, "Select Icon");

        updateConfigField(.TrayIconPath, "");
    }

    fn on_pick_tray_updates_icon(_: *gtk.Button, self: *Self) callconv(.c) void {
        const dialog = gtk.FileDialog.new();
        gtk.FileDialog.setTitle(dialog, "Select Tray Updates Icon");

        const root = gtk.Widget.getRoot(self.as(gtk.Widget));
        const parent: ?*gtk.Window = if (root) |r| gobject.ext.cast(gtk.Window, r) else null;

        gtk.FileDialog.open(
            dialog,
            parent,
            null,
            &on_tray_updates_icon_selected,
            self,
        );
    }

    fn on_tray_updates_icon_selected(
        source_object: ?*gobject.Object,
        result: *gio.AsyncResult,
        user_data: ?*anyopaque,
    ) callconv(.c) void {
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source_object.?));
        defer gobject.Object.unref(gobject.ext.as(gobject.Object, dialog));

        var err: ?*glib.Error = null;
        const file = gtk.FileDialog.openFinish(dialog, result, &err);
        if (err) |e| {
            if (e.f_code != @intFromEnum(gio.IOErrorEnum.cancelled)) {
                std.log.warn("settings: file selection failed: {s}", .{e.f_message orelse ""});
            }
            glib.Error.free(e);
            return;
        }

        const f = file orelse return;
        defer gobject.Object.unref(gobject.ext.as(gobject.Object, f));

        const path_cstr = gio.File.getPath(f) orelse return;
        defer glib.free(path_cstr);
        const path_slice = std.mem.span(path_cstr);

        const self: *Self = @ptrCast(@alignCast(user_data.?));
        const p = self.priv();
        gtk.Button.setLabel(p.tray_updates_icon_button, path_cstr);

        updateConfigField(.TrayUpdatesIconPath, path_slice);
    }

    fn on_clear_tray_updates_icon(_: *gtk.Button, self: *Self) callconv(.c) void {
        const p = self.priv();
        gtk.Button.setLabel(p.tray_updates_icon_button, "Select Icon");

        updateConfigField(.TrayUpdatesIconPath, "");
    }

    fn on_pick_appimage_install_path(_: *gtk.Button, self: *Self) callconv(.c) void {
        const dialog = gtk.FileDialog.new();
        gtk.FileDialog.setTitle(dialog, "Select AppImage Install Directory");

        const root = gtk.Widget.getRoot(self.as(gtk.Widget));
        const parent: ?*gtk.Window = if (root) |r| gobject.ext.cast(gtk.Window, r) else null;

        gtk.FileDialog.selectFolder(
            dialog,
            parent,
            null,
            &on_appimage_folder_selected,
            self,
        );
    }

    fn on_appimage_folder_selected(
        source_object: ?*gobject.Object,
        result: *gio.AsyncResult,
        user_data: ?*anyopaque,
    ) callconv(.c) void {
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source_object.?));
        defer gobject.Object.unref(gobject.ext.as(gobject.Object, dialog));

        var err: ?*glib.Error = null;
        const file = gtk.FileDialog.selectFolderFinish(dialog, result, &err);
        if (err) |e| {
            if (e.f_code != @intFromEnum(gio.IOErrorEnum.cancelled)) {
                std.log.warn("settings: folder selection failed: {s}", .{e.f_message orelse ""});
            }
            glib.Error.free(e);
            return;
        }

        const f = file orelse return;
        defer gobject.Object.unref(gobject.ext.as(gobject.Object, f));

        const path_cstr = gio.File.getPath(f) orelse return;
        defer glib.free(path_cstr);
        const path_slice = std.mem.span(path_cstr);

        const self: *Self = @ptrCast(@alignCast(user_data.?));
        const p = self.priv();
        gtk.Button.setLabel(p.appimage_install_path_button, path_cstr);

        updateConfigField(.AppImageInstallPath, path_slice);
    }

    fn on_sync_db(_: *gtk.Button, _: *Self) callconv(.c) void {
        std.debug.print("settings: force database update (not implemented yet)\n", .{});
    }

    fn on_remove_db_lock(_: *gtk.Button, _: *Self) callconv(.c) void {
        std.debug.print("settings: remove db.lck (not implemented yet)\n", .{});
    }

    fn on_fix_permissions(_: *gtk.Button, _: *Self) callconv(.c) void {
        std.debug.print("settings: fix permissions (not implemented yet)\n", .{});
    }

    fn on_purify(_: *gtk.Button, _: *Self) callconv(.c) void {
        std.debug.print("settings: purify packages (not implemented yet)\n", .{});
    }

    fn on_schedule_notify(_: *gobject.Object, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        applyScheduleVisibility(self.priv());
    }

    fn on_tray_notify(_: *gobject.Object, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        applyTrayVisibility(self.priv());
        applyScheduleVisibility(self.priv());
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
        .{ "sync_button", @offsetOf(Private, "sync_button") },
        .{ "rm_db_lock_button", @offsetOf(Private, "rm_db_lock_button") },
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

const DefaultPageEntry = struct {
    label: [:0]const u8,
    value: ShellyTabs,
};

const default_page_entries = [_]DefaultPageEntry{
    .{ .label = "Packages", .value = .packages },
    .{ .label = "AUR", .value = .aur },
    .{ .label = "Flatpak", .value = .flatpak },
    .{ .label = "AppImage", .value = .app_image },
    .{ .label = "Shelly Search", .value = .shelly_search },
    .{ .label = "Recommend", .value = .recommend },
};

const language_entries = [_]struct {
    label: [:0]const u8,
    value: [:0]const u8,
}{
    .{ .label = "System Default", .value = "" },
    .{ .label = "English", .value = "en" },
    .{ .label = "Bulgarian", .value = "bg_BG" },
    .{ .label = "Català", .value = "ca" },
    .{ .label = "Deutsch", .value = "de_DE" },
    .{ .label = "Español", .value = "es" },
    .{ .label = "Français", .value = "fr_FR" },
    .{ .label = "Magyar", .value = "hu_HU" },
    .{ .label = "日本語", .value = "ja_JP" },
    .{ .label = "Polski", .value = "pl" },
    .{ .label = "Português (Brasil)", .value = "pt_BR" },
    .{ .label = "Português (Portugal)", .value = "pt_PT" },
    .{ .label = "Русский", .value = "ru_RU" },
    .{ .label = "Türkçe", .value = "tr_TR" },
    .{ .label = "中文（简体）", .value = "zh_CN" },
};

fn populateDropdowns(p: *ShellySettingsPage.Private) void {
    const page_strings = gtk.StringList.new(null);
    inline for (default_page_entries) |entry| {
        gtk.StringList.append(page_strings, entry.label);
    }
    gtk.DropDown.setModel(p.default_page_drop, page_strings.as(gio.ListModel));

    const lang_strings = gtk.StringList.new(null);
    inline for (language_entries) |entry| {
        gtk.StringList.append(lang_strings, entry.label);
    }
    gtk.DropDown.setModel(p.language_drop, lang_strings.as(gio.ListModel));
}

fn obtainConfigService() !*ConfigResolver {
    return runtime.config.?;
}

fn updateConfigField(
    comptime field: std.meta.FieldEnum(ShellyConfig),
    value: std.meta.fieldInfo(ShellyConfig, field).type,
) void {
    const svc = obtainConfigService() catch return;
    const cfg = svc.get() catch return;
    var updated = cfg.*;
    @field(updated, @tagName(field)) = value;
    svc.set(updated) catch |set_err| {
        std.log.err("settings: failed to update config: {t}", .{set_err});
        return;
    };
    svc.save() catch |save_err| {
        std.log.err("settings: failed to save config: {t}", .{save_err});
    };
}

fn populateFromConfig(p: *ShellySettingsPage.Private, cfg: *ShellyConfig) void {
    setSwitch(p.aur_switch, cfg.AurEnabled);
    setSwitch(p.flatpak_switch, cfg.FlatPackEnabled);
    setSwitch(p.recommended_switch, cfg.RecommendedEnabled);
    setSwitch(p.appimage_switch, cfg.AppImageEnabled);
    setSwitch(p.tray_switch, cfg.TrayEnabled);
    setSwitch(p.tray_auto_switch, cfg.TrayAutoStart);
    setSwitch(p.daily_schedule, cfg.UseWeeklySchedule);

    gtk.SpinButton.setValue(p.tray_interval_spin, @floatFromInt(cfg.TrayCheckIntervalHours));

    setCheck(p.day_sun_check, daySelected(cfg, .sunday));
    setCheck(p.day_mon_check, daySelected(cfg, .monday));
    setCheck(p.day_tue_check, daySelected(cfg, .tuesday));
    setCheck(p.day_wed_check, daySelected(cfg, .wednesday));
    setCheck(p.day_thu_check, daySelected(cfg, .thursday));
    setCheck(p.day_fri_check, daySelected(cfg, .friday));
    setCheck(p.day_sat_check, daySelected(cfg, .saturday));

    const parsed_time = datetime.parseTime(cfg.Time);
    gtk.SpinButton.setValue(p.update_hour_spin, @floatFromInt(parsed_time.hour));
    gtk.SpinButton.setValue(p.update_minute_spin, @floatFromInt(parsed_time.minute));

    // Look & Feel
    setSwitch(p.shelly_icons_switch, cfg.ShellyIconsEnabled);
    setSwitch(p.use_old_menu_switch, cfg.UseOldMenu);
    setSwitch(p.symbolic_tray_switch, cfg.UseSymbolicTray);

    gtk.DropDown.setSelected(p.default_page_drop, @intFromEnum(cfg.DefaultPageDropDown));
    gtk.DropDown.setSelected(p.language_drop, languageIndex(cfg.Culture));

    setButtonLabel(p.tray_icon_button, std.heap.c_allocator, cfg.TrayIconPath, "Select Icon");
    setButtonLabel(p.tray_updates_icon_button, std.heap.c_allocator, cfg.TrayUpdatesIconPath, "Select Icon");

    // Advanced
    setSwitch(p.no_confirm_switch, cfg.NoConfirm);
    setSwitch(p.shelly_search_switch, cfg.ShellySearchEnabled);
    setSwitch(p.package_downgrade_switch, cfg.PackageDowngradeEnabled);

    setButtonLabel(p.appimage_install_path_button, std.heap.c_allocator, cfg.AppImageInstallPath, "Select Directory");
}

fn setButtonLabel(b: *gtk.Button, allocator: std.mem.Allocator, value: []const u8, default: [:0]const u8) void {
    if (value.len == 0) {
        gtk.Button.setLabel(b, default);
        return;
    }

    const dup = allocator.dupeSentinel(u8, value, 0) catch {
        gtk.Button.setLabel(b, default);
        return;
    };
    defer allocator.free(dup);

    gtk.Button.setLabel(b, dup);
}

fn collectIntoConfig(p: *ShellySettingsPage.Private, allocator: std.mem.Allocator, cfg: *ShellyConfig) void {
    cfg.Culture = language_entries[gtk.DropDown.getSelected(p.language_drop)].value;

    cfg.AurEnabled = getSwitch(p.aur_switch);
    cfg.FlatPackEnabled = getSwitch(p.flatpak_switch);
    cfg.RecommendedEnabled = getSwitch(p.recommended_switch);
    cfg.AppImageEnabled = getSwitch(p.appimage_switch);
    cfg.TrayEnabled = getSwitch(p.tray_switch);
    cfg.TrayAutoStart = getSwitch(p.tray_auto_switch);
    cfg.UseWeeklySchedule = getSwitch(p.daily_schedule);

    cfg.TrayCheckIntervalHours = gtk.SpinButton.getValueAsInt(p.tray_interval_spin);

    cfg.DaysOfWeek = collectDays(p, allocator) catch cfg.DaysOfWeek;

    cfg.Time = datetime.formatTime(
        allocator,
        gtk.SpinButton.getValueAsInt(p.update_hour_spin),
        gtk.SpinButton.getValueAsInt(p.update_minute_spin),
    ) catch cfg.Time;

    // Look & Feel
    cfg.ShellyIconsEnabled = getSwitch(p.shelly_icons_switch);
    cfg.UseOldMenu = getSwitch(p.use_old_menu_switch);
    cfg.UseSymbolicTray = getSwitch(p.symbolic_tray_switch);

    const idx = gtk.DropDown.getSelected(p.default_page_drop);
    if (idx != std.math.maxInt(u32) and idx < default_page_entries.len) {
        cfg.DefaultPageDropDown = default_page_entries[idx].value;
    }

    // Advanced
    cfg.NoConfirm = getSwitch(p.no_confirm_switch);
    cfg.ShellySearchEnabled = getSwitch(p.shelly_search_switch);
    cfg.PackageDowngradeEnabled = getSwitch(p.package_downgrade_switch);
}

fn applyScheduleVisibility(p: *ShellySettingsPage.Private) void {
    const tray_enabled = gtk.Switch.getActive(p.tray_switch) != 0;
    if (!tray_enabled) {
        gtk.Widget.setVisible(p.weekly_schedule_switch_box.as(gtk.Widget), 0);
        gtk.Widget.setVisible(p.weekly_schedule_box.as(gtk.Widget), 0);
        gtk.Widget.setVisible(p.tray_interval_box.as(gtk.Widget), 0);
        return;
    }

    gtk.Widget.setVisible(p.weekly_schedule_switch_box.as(gtk.Widget), 1);
    const daily_enabled = gtk.Switch.getActive(p.daily_schedule) != 0;
    gtk.Widget.setVisible(p.weekly_schedule_box.as(gtk.Widget), @intFromBool(daily_enabled));
    gtk.Widget.setVisible(p.tray_interval_box.as(gtk.Widget), @intFromBool(!daily_enabled));
}

fn applyTrayVisibility(p: *ShellySettingsPage.Private) void {
    const enabled = gtk.Switch.getActive(p.tray_switch) != 0;
    gtk.Widget.setVisible(p.tray_auto_switch_box.as(gtk.Widget), @intFromBool(enabled));
    gtk.Widget.setVisible(p.symbolic_tray_box.as(gtk.Widget), @intFromBool(enabled));
}

fn setSwitch(s: *gtk.Switch, value: bool) void {
    gtk.Switch.setActive(s, @intFromBool(value));
}

fn getSwitch(s: *gtk.Switch) bool {
    return gtk.Switch.getActive(s) != 0;
}

fn setCheck(c: *gtk.CheckButton, value: bool) void {
    gtk.CheckButton.setActive(c, @intFromBool(value));
}

fn getCheck(c: *gtk.CheckButton) bool {
    return gtk.CheckButton.getActive(c) != 0;
}

fn daySelected(cfg: *const ShellyConfig, day: DayOfWeek) bool {
    for (cfg.DaysOfWeek) |d| {
        if (d == day) return true;
    }
    return false;
}

fn collectDays(p: *ShellySettingsPage.Private, allocator: std.mem.Allocator) ![]DayOfWeek {
    var buf: [7]DayOfWeek = undefined;
    var len: usize = 0;

    const checks = .{
        .{ p.day_sun_check, DayOfWeek.sunday },
        .{ p.day_mon_check, DayOfWeek.monday },
        .{ p.day_tue_check, DayOfWeek.tuesday },
        .{ p.day_wed_check, DayOfWeek.wednesday },
        .{ p.day_thu_check, DayOfWeek.thursday },
        .{ p.day_fri_check, DayOfWeek.friday },
        .{ p.day_sat_check, DayOfWeek.saturday },
    };
    inline for (checks) |entry| {
        if (getCheck(entry[0])) {
            buf[len] = entry[1];
            len += 1;
        }
    }

    return allocator.dupe(DayOfWeek, buf[0..len]);
}

fn languageIndex(culture: ?[]const u8) c_uint {
    const value = culture orelse return 0;
    for (language_entries, 0..) |entry, i| {
        if (entry.value.len == 0) {
            if (value.len == 0) return @intCast(i);
            continue;
        }
        if (std.ascii.eqlIgnoreCase(value, entry.value)) return @intCast(i);
    }
    return 0;
}
