const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gobject = bindings.gobject;
const gio = bindings.gio;
const glib = bindings.glib;
const ShellyConfig = @import("../models/shelly_config.zig").ShellyConfig;
const ShellyTabs = @import("../models/shelly_config.zig").ShellyTabs;
const DayOfWeek = @import("../models/shelly_config.zig").DayOfWeek;
const NavMode = @import("../models/shelly_config.zig").NavMode;
const ConfigResolver = @import("../services/ui_config_resolver.zig").ConfigResolver;
const CliConfigResolver = @import("../services/cli_config_resolver.zig").CliConfigResolver;
const ShellyCommands = @import("../services/shelly_operation.zig").ShellyCommands;
const support_packages = @import("../services/support_packages.zig");
const runtime = @import("../services/runtime.zig");
const systemd_tray = @import("../services/systemd_tray.zig");
const tray_service = @import("../services/tray_service.zig");
const support = @import("support.zig");
const datetime = @import("../helpers/datetime.zig");
const ShellyWindow = @import("../shelly_window.zig").ShellyWindow;
const Toast = @import("../helpers/custom_ui_comps/toast.zig").Toast;
const VersionHistoryDialog = @import("../dialog/page/version_history.zig").VersionHistoryDialog;
const HistoryEntry = @import("../dialog/page/version_history.zig").Entry;
const AurWarningDialog = @import("../dialog/page/aur_warning.zig").AurWarningDialog;
const translations = @import("../helpers/translations.zig");
const options = @import("options");

pub const SettingsPage = ShellySettingsPage;

pub const ShellySettingsPage = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gtk.Box;
    const SupportFeature = support_packages.Feature;
    const SupportInstallStage = enum {
        dependencies,
        backend_standard,
        backend_aur,
    };

    pub const title: [:0]const u8 = "Settings";
    pub const icon_name: [:0]const u8 = "settings-symbolic";
    const resource_path = "/com/shellyorg/shelly/ui/settings_page.ui";

    const Private = struct {
        page_overlay: *gtk.Overlay,
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
        tray_cron_switch: *gtk.Switch,
        tray_cron_box: *gtk.Box,
        use_ui: *gtk.Switch,
        use_ui_switch_box: *gtk.Box,
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
        symbolic_tray_box: *gtk.Box,
        symbolic_tray_switch: *gtk.Switch,
        use_ui_for_update_switch: *gtk.Switch,

        tray_icon_button: *gtk.Button,
        tray_icon_clear_button: *gtk.Button,
        tray_updates_icon_button: *gtk.Button,
        tray_updates_icon_clear_button: *gtk.Button,
        default_page_box: *gtk.Box,
        default_page_drop: *gtk.DropDown,
        nav_mode_drop: *gtk.DropDown,

        // Advanced
        remove_cache_switch: *gtk.Switch,
        no_confirm_switch: *gtk.Switch,
        shelly_search_switch: *gtk.Switch,
        webview_switch: *gtk.Switch,
        appimage_install_path_box: *gtk.Box,
        appimage_install_path_button: *gtk.Button,

        // Bottom action bar
        save_button: *gtk.Button,
        changelog_button: *gtk.Button,
        version_label: *gtk.Label,
        github_link: *gtk.LinkButton,
        fluxer_link: *gtk.LinkButton,
        sponsor_link: *gtk.LinkButton,

        toast: *Toast,
        loaded: bool,
        save_guard: bool,
        save_source: c_uint,
        support_install_pending: ?SupportFeature,
        support_install_stage: SupportInstallStage,

        page_filter: PageFilter,

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
        p.save_guard = false;
        p.save_source = 0;
        p.support_install_pending = null;
        p.support_install_stage = .dependencies;
        p.page_filter = .{};

        populateDropdowns(p);

        _ = gtk.Button.signals.clicked.connect(p.save_button, *Self, &onSaveClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(p.changelog_button, *Self, &onChangelogClicked, self, .{});

        _ = gtk.Button.signals.clicked.connect(p.tray_icon_button, *Self, &onPickTrayIcon, self, .{});
        _ = gtk.Button.signals.clicked.connect(p.tray_icon_clear_button, *Self, &onClearTrayIcon, self, .{});
        _ = gtk.Button.signals.clicked.connect(p.tray_updates_icon_button, *Self, &onPickTrayUpdatesIcon, self, .{});
        _ = gtk.Button.signals.clicked.connect(p.tray_updates_icon_clear_button, *Self, &onClearTrayUpdatesIcon, self, .{});

        _ = gtk.Button.signals.clicked.connect(p.appimage_install_path_button, *Self, &onPickAppImageInstallPath, self, .{});

        _ = gobject.Object.signals.notify.connect(
            p.daily_schedule.as(gobject.Object),
            *Self,
            &onScheduleNotify,
            self,
            .{ .detail = "active" },
        );
        _ = gobject.Object.signals.notify.connect(
            p.use_ui.as(gobject.Object),
            *Self,
            &onUseUiNotify,
            self,
            .{ .detail = "active" },
        );
        _ = gobject.Object.signals.notify.connect(
            p.tray_switch.as(gobject.Object),
            *Self,
            &onTrayNotify,
            self,
            .{ .detail = "active" },
        );
        _ = gobject.Object.signals.notify.connect(
            p.tray_auto_switch.as(gobject.Object),
            *Self,
            &onTrayAutoNotify,
            self,
            .{ .detail = "active" },
        );
        _ = gobject.Object.signals.notify.connect(
            p.aur_switch.as(gobject.Object),
            *Self,
            &onAurNotify,
            self,
            .{ .detail = "active" },
        );
        _ = gobject.Object.signals.notify.connect(
            p.nav_mode_drop.as(gobject.Object),
            *Self,
            &onNavModeChanged,
            self,
            .{ .detail = "selected" },
        );
        _ = gobject.Object.signals.notify.connect(
            p.flatpak_switch.as(gobject.Object),
            *Self,
            &onFlatpakNotify,
            self,
            .{ .detail = "active" },
        );
        _ = gobject.Object.signals.notify.connect(
            p.appimage_switch.as(gobject.Object),
            *Self,
            &onAppImageNotify,
            self,
            .{ .detail = "active" },
        );

        const autosave_switches = .{
            p.recommended_switch,
            p.shelly_icons_switch,
            p.symbolic_tray_switch,
            p.tray_cron_switch,
            p.no_confirm_switch,
            p.shelly_search_switch,
            p.remove_cache_switch,
            p.webview_switch,
        };
        inline for (autosave_switches) |s| {
            _ = gobject.Object.signals.notify.connect(
                s.as(gobject.Object),
                *Self,
                &onAutosaveNotify,
                self,
                .{ .detail = "active" },
            );
        }
        _ = gobject.Object.signals.notify.connect(
            p.aur_switch.as(gobject.Object),
            *Self,
            &onAutosaveNotify,
            self,
            .{ .detail = "active", .after = true },
        );

        _ = gobject.Object.signals.notify.connect(
            p.default_page_drop.as(gobject.Object),
            *Self,
            &onAutosaveNotify,
            self,
            .{ .detail = "selected" },
        );
        _ = gobject.Object.signals.notify.connect(
            p.language_drop.as(gobject.Object),
            *Self,
            &onAutosaveNotify,
            self,
            .{ .detail = "selected" },
        );
        _ = gobject.Object.signals.notify.connect(
            p.nav_mode_drop.as(gobject.Object),
            *Self,
            &onAutosaveNotify,
            self,
            .{ .detail = "selected", .after = true },
        );

        const day_checks = .{
            p.day_sun_check,
            p.day_mon_check,
            p.day_tue_check,
            p.day_wed_check,
            p.day_thu_check,
            p.day_fri_check,
            p.day_sat_check,
        };
        inline for (day_checks) |c| {
            _ = gtk.CheckButton.signals.toggled.connect(c, *Self, &onAutosaveToggled, self, .{});
        }

        const spins = .{ p.tray_interval_spin, p.update_hour_spin, p.update_minute_spin };
        inline for (spins) |s| {
            _ = gtk.SpinButton.signals.value_changed.connect(s, *Self, &onAutosaveValueChanged, self, .{});
        }

        support.connectLifecycle(Self, self);

        const toast = Toast.new();
        gtk.Overlay.addOverlay(p.page_overlay, toast.as(gtk.Widget));
        p.toast = toast;
    }

    pub fn onMap(self: *Self) void {
        const p = self.priv();
        if (p.loaded) return;
        p.loaded = true;

        const version = std.fmt.allocPrintSentinel(std.heap.c_allocator, "v{f}", .{options.version}, 0) catch |err| {
            std.log.err("failed to format version: {s}", .{@errorName(err)});
            return;
        };
        defer std.heap.c_allocator.free(version);
        p.version_label.setLabel(version);

        const svc = obtainConfigService() catch |err| {
            std.log.warn("settings: could not open config service: {t}", .{err});
            return;
        };
        const cfg = svc.get() catch |err| {
            std.log.warn("settings: config not loaded: {t}", .{err});
            return;
        };

        p.save_guard = true;
        defer p.save_guard = false;

        populatePageDropdown(p, cfg);
        applyConfig(p, cfg);

        applyScheduleVisibility(p);
        applyTrayVisibility(p);
    }

    pub fn onUnmap(self: *Self) void {
        const p = self.priv();
        if (p.save_source != 0) {
            _ = glib.Source.remove(p.save_source);
            p.save_source = 0;
        }
    }

    fn onSaveClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.save() catch |err| {
            std.log.err("settings: save failed: {t}", .{err});
            self.priv().toast.show(.@"error", translations._("Failed to save settings"));
            return;
        };
        self.priv().toast.show(.success, translations._("Settings saved"));
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

        const lang_value = language_entries[gtk.DropDown.getSelected(p.language_drop)].value;
        _ = translations.initWithLocale(lang_value);

        applyScheduleVisibility(p);
        applyTrayVisibility(p);

        if (support.getWindow(ShellyWindow, self)) |win| {
            win.applyConfig();
            win.applyDefaultPage();
        }
    }

    fn autosave(self: *Self) void {
        const p = self.priv();
        if (p.save_guard or !p.loaded) return;

        if (p.save_source != 0) {
            _ = glib.Source.remove(p.save_source);
            p.save_source = 0;
        }

        const svc = obtainConfigService() catch return;
        const cfg = svc.get() catch return;

        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();

        var updated = cfg.*;
        collectIntoConfig(p, arena.allocator(), &updated);

        const page_drop_stale =
            updated.RecommendedEnabled != cfg.RecommendedEnabled or
            updated.AurEnabled != cfg.AurEnabled or
            updated.FlatPackEnabled != cfg.FlatPackEnabled or
            updated.AppImageEnabled != cfg.AppImageEnabled or
            updated.ShellySearchEnabled != cfg.ShellySearchEnabled or
            !std.mem.eql(u8, updated.Culture, cfg.Culture);

        svc.set(updated) catch {
            p.toast.show(.@"error", translations._("Failed to save settings"));
            return;
        };
        svc.save() catch {
            p.toast.show(.@"error", translations._("Failed to save settings"));
            return;
        };

        const lang_value = language_entries[gtk.DropDown.getSelected(p.language_drop)].value;
        _ = translations.initWithLocale(lang_value);

        p.save_guard = true;
        defer p.save_guard = false;

        if (page_drop_stale) {
            populatePageDropdown(p, &updated);
        }

        if (support.getWindow(ShellyWindow, self)) |win| {
            win.applyConfig();
        }
    }

    fn scheduleAutosave(self: *Self) void {
        const p = self.priv();
        if (p.save_guard or !p.loaded) return;
        if (p.save_source != 0) return;
        p.save_source = glib.timeoutAdd(300, &onAutosaveTimeout, self);
    }

    fn onAutosaveTimeout(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data.?));
        self.priv().save_source = 0;
        self.autosave();
        return 0;
    }

    fn onAutosaveNotify(_: *gobject.Object, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        self.autosave();
    }

    fn onFlatpakNotify(_: *gobject.Object, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        self.onSupportNotify(.flatpak);
    }

    fn onAppImageNotify(_: *gobject.Object, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        self.onSupportNotify(.appimage);
    }

    fn onSupportNotify(self: *Self, feature: SupportFeature) void {
        const p = self.priv();
        if (p.save_guard or !p.loaded or p.support_install_pending != null) return;

        if (!getSwitch(supportSwitch(p, feature))) {
            self.autosave();
            return;
        }

        const svc = obtainConfigService() catch {
            self.restoreSupportSwitch(feature, false);
            return;
        };
        const cfg = svc.get() catch {
            self.restoreSupportSwitch(feature, false);
            return;
        };
        if (supportEnabled(cfg, feature)) return;

        const win = support.getWindow(ShellyWindow, self) orelse {
            self.restoreSupportSwitch(feature, false);
            return;
        };

        const selected = supportDependencies(feature);
        var package_buffer: [2][]const u8 = undefined;
        const packages = support_packages.missingPackages(
            std.heap.c_allocator,
            runtime.io,
            selected,
            &package_buffer,
        );

        p.support_install_pending = feature;
        p.support_install_stage = .dependencies;

        if (packages.len == 0) {
            onSupportInstallComplete(self, true);
            return;
        }

        const argv = ShellyCommands.install(std.heap.c_allocator, packages) catch {
            p.support_install_pending = null;
            self.restoreSupportSwitch(feature, false);
            p.toast.show(.@"error", supportStartFailureMessage(feature));
            return;
        };
        defer std.heap.c_allocator.free(argv);

        win.startTransaction(.{
            .title = supportInstallTitle(feature),
            .argv = argv,
            .packages = packages,
            .privileged = true,
            .on_complete = &onSupportInstallComplete,
            .ctx = self,
        });
    }

    fn onSupportInstallComplete(ctx: *anyopaque, success: bool) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const p = self.priv();
        const feature = p.support_install_pending orelse return;

        switch (p.support_install_stage) {
            .dependencies => {
                if (!success) return self.finishSupportInstall(feature, false);
                if (feature == .flatpak) {
                    p.support_install_stage = .backend_standard;
                    _ = glib.idleAdd(&startSupportBackendIdle, self);
                    return;
                }
            },
            .backend_standard => {
                if (!success) {
                    p.support_install_stage = .backend_aur;
                    _ = glib.idleAdd(&startSupportBackendIdle, self);
                    return;
                }
            },
            .backend_aur => if (!success) return self.finishSupportInstall(feature, false),
        }

        self.finishSupportInstall(feature, true);
    }

    fn startSupportBackendIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data.?));
        self.startSupportBackend();
        return 0;
    }

    fn startSupportBackend(self: *Self) void {
        const p = self.priv();
        const feature = p.support_install_pending orelse return;
        const packages = &.{support_packages.flatpakBackendPackage()};

        var backend_buffer: [1][]const u8 = undefined;
        const missing = support_packages.missingPackages(std.heap.c_allocator, runtime.io, packages, &backend_buffer);
        if (missing.len == 0) {
            onSupportInstallComplete(self, true);
            return;
        }

        const argv = switch (p.support_install_stage) {
            .backend_standard => ShellyCommands.install(std.heap.c_allocator, packages),
            .backend_aur => ShellyCommands.install_aur(std.heap.c_allocator, packages),
            .dependencies => unreachable,
        } catch {
            p.support_install_pending = null;
            self.restoreSupportSwitch(feature, false);
            p.toast.show(.@"error", supportStartFailureMessage(feature));
            return;
        };
        defer std.heap.c_allocator.free(argv);

        const win = support.getWindow(ShellyWindow, self) orelse {
            self.finishSupportInstall(feature, false);
            return;
        };
        win.startTransaction(.{
            .title = supportInstallTitle(feature),
            .argv = argv,
            .packages = packages,
            .privileged = true,
            .on_complete = &onSupportInstallComplete,
            .ctx = self,
        });
    }

    fn finishSupportInstall(self: *Self, feature: SupportFeature, success: bool) void {
        const p = self.priv();
        p.support_install_pending = null;

        if (!success) {
            self.restoreSupportSwitch(feature, false);
            p.toast.show(.@"error", supportFailureMessage(feature));
            return;
        }

        const save_result = switch (feature) {
            .flatpak => persistFeatureEnabled(.FlatPackEnabled, true),
            .appimage => persistFeatureEnabled(.AppImageEnabled, true),
        };
        save_result catch {
            self.restoreSupportSwitch(feature, false);
            p.toast.show(.@"error", translations._("Failed to save settings"));
            return;
        };

        const svc = obtainConfigService() catch return;
        const cfg = svc.get() catch return;

        p.save_guard = true;
        defer p.save_guard = false;

        populatePageDropdown(p, cfg);

        if (support.getWindow(ShellyWindow, self)) |win| {
            win.applyConfig();
        }

        p.toast.show(.success, supportSuccessMessage(feature));
    }

    fn restoreSupportSwitch(self: *Self, feature: SupportFeature, enabled: bool) void {
        const p = self.priv();
        p.save_guard = true;
        defer p.save_guard = false;
        setSwitch(supportSwitch(p, feature), enabled);
    }

    fn supportSwitch(p: *Private, feature: SupportFeature) *gtk.Switch {
        return switch (feature) {
            .flatpak => p.flatpak_switch,
            .appimage => p.appimage_switch,
        };
    }

    fn supportEnabled(cfg: *const ShellyConfig, feature: SupportFeature) bool {
        return switch (feature) {
            .flatpak => cfg.FlatPackEnabled,
            .appimage => cfg.AppImageEnabled,
        };
    }

    fn supportDependencies(feature: SupportFeature) []const []const u8 {
        return support_packages.dependenciesForFeature(feature);
    }

    fn supportInstallTitle(feature: SupportFeature) [:0]const u8 {
        return switch (feature) {
            .flatpak => translations._("Installing Flatpak support"),
            .appimage => translations._("Installing AppImage support"),
        };
    }

    fn supportStartFailureMessage(feature: SupportFeature) [:0]const u8 {
        return switch (feature) {
            .flatpak => translations._("Failed to start Flatpak support installation"),
            .appimage => translations._("Failed to start AppImage support installation"),
        };
    }

    fn supportFailureMessage(feature: SupportFeature) [:0]const u8 {
        return switch (feature) {
            .flatpak => translations._("Flatpak support installation failed"),
            .appimage => translations._("AppImage support installation failed"),
        };
    }

    fn supportSuccessMessage(feature: SupportFeature) [:0]const u8 {
        return switch (feature) {
            .flatpak => translations._("Flatpak support enabled"),
            .appimage => translations._("AppImage support enabled"),
        };
    }

    fn onAutosaveToggled(_: *gtk.CheckButton, self: *Self) callconv(.c) void {
        self.autosave();
    }

    fn onAutosaveValueChanged(_: *gtk.SpinButton, self: *Self) callconv(.c) void {
        self.scheduleAutosave();
    }

    fn showChangelog(self: *Self) !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        var threaded: std.Io.Threaded = .init(arena_alloc, .{});
        defer threaded.deinit();

        var http_client: std.http.Client = .{ .allocator = arena_alloc, .io = threaded.io() };
        defer http_client.deinit();

        const url = "https://api.github.com/repos/Seafoam-Labs/Shelly-ALPM/releases";
        var body: std.Io.Writer.Allocating = .init(arena_alloc);
        defer body.deinit();

        const fetch_result = http_client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &body.writer,
        }) catch |err| {
            std.log.warn("settings: changelog fetch failed: {any}", .{err});
            return err;
        };
        if (fetch_result.status != .ok) {
            std.log.warn("settings: changelog fetch returned status {d}", .{@intFromEnum(fetch_result.status)});
            return error.HttpRequestFailed;
        }

        const Release = struct {
            tag_name: []const u8 = "",
            body: []const u8 = "",
            published_at: []const u8 = "",
        };
        const parsed = std.json.parseFromSlice(
            []const Release,
            arena_alloc,
            body.written(),
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        ) catch |err| {
            std.log.warn("settings: changelog JSON parse failed: {any}", .{err});
            return err;
        };
        defer parsed.deinit();
        const releases = parsed.value;

        if (releases.len == 0) {
            self.priv().toast.show(.info, translations._("No changelog entries found"));
            return;
        }

        const c = std.heap.c_allocator;
        var entries: std.ArrayListUnmanaged(HistoryEntry) = .empty;
        defer {
            for (entries.items) |e| {
                c.free(e.version);
                c.free(e.date);
                c.free(e.note);
            }
            entries.deinit(c);
        }

        for (releases) |release| {
            const version = c.dupeSentinel(u8, release.tag_name, 0) catch continue;
            const date = datetime.extractDate(c, release.published_at) catch {
                c.free(version);
                continue;
            };
            const note = c.dupeSentinel(u8, if (release.body.len > 0) release.body else translations._("No details for this release"), 0) catch {
                c.free(version);
                c.free(date);
                continue;
            };
            entries.append(c, .{ .version = version, .date = date, .note = note }) catch {
                c.free(version);
                c.free(date);
                c.free(note);
                continue;
            };
        }

        if (entries.items.len == 0) {
            self.priv().toast.show(.@"error", translations._("Failed to load changelog"));
            return;
        }

        const owned = entries.toOwnedSlice(c) catch return;
        const dlg = VersionHistoryDialog.new(translations._("Changelog"), translations._("Shelly"), owned, &onCloseChangelog, self);

        if (support.getWindow(ShellyWindow, self)) |win| {
            win.showLockout(dlg.as(gtk.Widget));
        }
    }

    fn onChangelogClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.showChangelog() catch |err| {
            std.log.err("settings: failed to load changelog: {any}", .{err});
            self.priv().toast.show(.@"error", translations._("Failed to load changelog"));
        };
    }

    fn onCloseChangelog(ctx: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        if (support.getWindow(ShellyWindow, self)) |win| win.hideLockout();
    }

    fn onPickTrayIcon(_: *gtk.Button, self: *Self) callconv(.c) void {
        const dialog = gtk.FileDialog.new();
        gtk.FileDialog.setTitle(dialog, translations._("Select Tray Icon"));

        const root = gtk.Widget.getRoot(self.as(gtk.Widget));
        const parent: ?*gtk.Window = if (root) |r| gobject.ext.cast(gtk.Window, r) else null;

        gtk.FileDialog.open(
            dialog,
            parent,
            null,
            &onTrayIconSelected,
            self,
        );
    }

    fn onTrayIconSelected(
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

    fn onClearTrayIcon(_: *gtk.Button, self: *Self) callconv(.c) void {
        const p = self.priv();
        gtk.Button.setLabel(p.tray_icon_button, translations._("Select Icon"));

        updateConfigField(.TrayIconPath, "");
    }

    fn onPickTrayUpdatesIcon(_: *gtk.Button, self: *Self) callconv(.c) void {
        const dialog = gtk.FileDialog.new();
        gtk.FileDialog.setTitle(dialog, translations._("Select Tray Updates Icon"));

        const root = gtk.Widget.getRoot(self.as(gtk.Widget));
        const parent: ?*gtk.Window = if (root) |r| gobject.ext.cast(gtk.Window, r) else null;

        gtk.FileDialog.open(
            dialog,
            parent,
            null,
            &onTrayUpdatesIconSelected,
            self,
        );
    }

    fn onTrayUpdatesIconSelected(
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

    fn onClearTrayUpdatesIcon(_: *gtk.Button, self: *Self) callconv(.c) void {
        const p = self.priv();
        gtk.Button.setLabel(p.tray_updates_icon_button, translations._("Select Icon"));

        updateConfigField(.TrayUpdatesIconPath, "");
    }

    fn onPickAppImageInstallPath(_: *gtk.Button, self: *Self) callconv(.c) void {
        const dialog = gtk.FileDialog.new();
        gtk.FileDialog.setTitle(dialog, translations._("Select AppImage Install Directory"));

        const root = gtk.Widget.getRoot(self.as(gtk.Widget));
        const parent: ?*gtk.Window = if (root) |r| gobject.ext.cast(gtk.Window, r) else null;

        gtk.FileDialog.selectFolder(
            dialog,
            parent,
            null,
            &onAppImageFolderSelected,
            self,
        );
    }

    fn onAppImageFolderSelected(
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

        self.saveAppImageInstallPath(path_slice);
    }

    fn saveAppImageInstallPath(self: *Self, path: []const u8) void {
        const p = self.priv();
        var resolver = CliConfigResolver.init(std.heap.c_allocator, runtime.io, runtime.environ_map) catch {
            p.toast.show(.@"error", translations._("Failed to save settings"));
            return;
        };
        defer resolver.deinit();

        resolver.writeAppImageInstallPath(path) catch |err| {
            std.log.err("settings: failed to save AppImage install path: {t}", .{err});
            p.toast.show(.@"error", translations._("Failed to save settings"));
        };
    }

    fn onScheduleNotify(_: *gobject.Object, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        applyScheduleVisibility(self.priv());
        self.autosave();
    }

    fn onUseUiNotify(_: *gobject.Object, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const p = self.priv();
        const active = gtk.Switch.getActive(p.use_ui) != 0;
        updateConfigField(.UseUiForUpdate, active);
    }

    fn onTrayNotify(_: *gobject.Object, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const p = self.priv();

        applyTrayVisibility(p);
        applyScheduleVisibility(p);

        const active = gtk.Switch.getActive(p.tray_switch) != 0;

        const svc = obtainConfigService() catch return;
        const cfg = svc.get() catch return;

        if (cfg.TrayEnabled == active) return;

        if (active) {
            tray_service.start(runtime.io, std.heap.c_allocator);
            updateConfigField(.TrayEnabled, active);
            p.toast.show(.success, translations._("Tray enabled"));
        } else {
            const stopped = tray_service.end(runtime.io, std.heap.c_allocator);
            updateConfigField(.TrayEnabled, active);

            systemd_tray.removeService(std.heap.c_allocator, runtime.io) catch |err| {
                std.log.err("failed to remove systemd tray service: {s}", .{@errorName(err)});
                p.toast.show(.@"error", translations._("Tray disabled, but autostart service remains"));
                return;
            };

            p.toast.show(if (stopped) .success else .info, translations._("Tray disabled"));

            gtk.Switch.setActive(p.tray_auto_switch, 0);
            updateConfigField(.TrayAutoStart, active);
        }
    }

    fn onTrayAutoNotify(_: *gobject.Object, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const p = self.priv();
        const active = gtk.Switch.getActive(p.tray_auto_switch) != 0;

        const svc = obtainConfigService() catch return;
        const cfg = svc.get() catch return;

        if (cfg.TrayAutoStart == active) return;

        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();
        var threaded: std.Io.Threaded = .init(arena.allocator(), .{});
        defer threaded.deinit();

        if (active) {
            systemd_tray.addService(arena.allocator(), threaded.io()) catch |err| {
                std.log.err("settings: failed to add systemd tray service: {t}", .{err});
                gtk.Switch.setActive(p.tray_auto_switch, 0);
                p.toast.show(.@"error", translations._("Failed to add systemd startup service"));
                return;
            };
            p.toast.show(.success, translations._("Systemd startup service added."));
        } else {
            systemd_tray.removeService(arena.allocator(), threaded.io()) catch |err| {
                std.log.err("settings: failed to remove systemd tray service: {t}", .{err});
                gtk.Switch.setActive(p.tray_auto_switch, 1);
                p.toast.show(.@"error", translations._("Failed to remove systemd startup service"));
                return;
            };
            p.toast.show(.success, translations._("Systemd startup service removed."));
        }

        updateConfigField(.TrayAutoStart, active);
    }

    fn onAurNotify(_: *gobject.Object, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const p = self.priv();
        const active = gtk.Switch.getActive(p.aur_switch) != 0;
        if (!active) return;

        const svc = obtainConfigService() catch return;
        const cfg = svc.get() catch return;

        if (cfg.AurEnabled) return;
        if (cfg.AurWarningConfirmed) return;

        gtk.Switch.setActive(p.aur_switch, 0);

        const dialog = AurWarningDialog.new(&onAurConfirmationResponse, self);
        if (support.getWindow(ShellyWindow, self)) |win| {
            win.showLockout(dialog.as(gtk.Widget));
            dialog.focusCancel();
        }
    }

    fn onNavModeChanged(obj: *gobject.Object, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const dd: *gtk.DropDown = @ptrCast(@alignCast(obj));
        const idx = gtk.DropDown.getSelected(dd);
        if (idx >= nav_mode_entries.len) return;
        if (support.getWindow(ShellyWindow, self)) |win| {
            win.requestNav(nav_mode_entries[idx].value);
        }
    }

    fn onAurConfirmationResponse(ctx: ?*anyopaque, confirmed: bool) void {
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        if (support.getWindow(ShellyWindow, self)) |win| win.hideLockout();
        if (!confirmed) return;

        updateConfigField(.AurWarningConfirmed, true);

        const p = self.priv();
        gtk.Switch.setActive(p.aur_switch, 1);
        p.toast.show(.success, translations._("AUR enabled"));
    }

    const template_children = .{
        .{ "page_overlay", @offsetOf(Private, "page_overlay") },
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
        .{ "tray_cron_switch", @offsetOf(Private, "tray_cron_switch") },
        .{ "tray_cron_box", @offsetOf(Private, "tray_cron_box") },
        .{ "use_ui", @offsetOf(Private, "use_ui") },
        .{ "use_ui_switch_box", @offsetOf(Private, "use_ui_switch_box") },
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
        .{ "symbolic_tray_box", @offsetOf(Private, "symbolic_tray_box") },
        .{ "symbolic_tray_switch", @offsetOf(Private, "symbolic_tray_switch") },
        .{ "tray_icon_button", @offsetOf(Private, "tray_icon_button") },
        .{ "tray_icon_clear_button", @offsetOf(Private, "tray_icon_clear_button") },
        .{ "tray_updates_icon_button", @offsetOf(Private, "tray_updates_icon_button") },
        .{ "tray_updates_icon_clear_button", @offsetOf(Private, "tray_updates_icon_clear_button") },
        .{ "default_page_box", @offsetOf(Private, "default_page_box") },
        .{ "default_page_drop", @offsetOf(Private, "default_page_drop") },
        .{ "nav_mode_drop", @offsetOf(Private, "nav_mode_drop") },

        // Advanced
        .{ "remove_cache_switch", @offsetOf(Private, "remove_cache_switch") },
        .{ "no_confirm_switch", @offsetOf(Private, "no_confirm_switch") },
        .{ "shelly_search_switch", @offsetOf(Private, "shelly_search_switch") },
        .{ "webview_switch", @offsetOf(Private, "webview_switch") },
        .{ "appimage_install_path_box", @offsetOf(Private, "appimage_install_path_box") },
        .{ "appimage_install_path_button", @offsetOf(Private, "appimage_install_path_button") },

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

const PageFilter = struct {
    recommended: bool = false,
    aur: bool = false,
    flatpak: bool = false,
    app_image: bool = false,
    shelly_search: bool = false,

    fn fromConfig(cfg: *const ShellyConfig) PageFilter {
        return .{
            .recommended = cfg.RecommendedEnabled,
            .aur = cfg.AurEnabled,
            .flatpak = cfg.FlatPackEnabled,
            .app_image = cfg.AppImageEnabled,
            .shelly_search = cfg.ShellySearchEnabled,
        };
    }
};

const default_page_entries = [_]DefaultPageEntry{
    .{ .label = "Recommended", .value = .recommend },
    .{ .label = "Packages", .value = .packages },
    .{ .label = "AUR", .value = .aur },
    .{ .label = "Flatpak", .value = .flatpak },
    .{ .label = "AppImage", .value = .app_image },
    .{ .label = "Shelly Search", .value = .shelly_search },
    .{ .label = "Update", .value = .update },
};

const NavModeEntry = struct {
    label: [:0]const u8,
    value: NavMode,
};

const nav_mode_entries = [_]NavModeEntry{
    .{ .label = "Sidebar", .value = .sidebar },
    .{ .label = "Topbar", .value = .topbar },
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
    const nav_strings = gtk.StringList.new(null);
    inline for (nav_mode_entries) |entry| {
        gtk.StringList.append(nav_strings, entry.label);
    }
    gtk.DropDown.setModel(p.nav_mode_drop, nav_strings.as(gio.ListModel));

    const lang_strings = gtk.StringList.new(null);
    inline for (language_entries, 0..) |_, index| {
        const label = switch (index) {
            0 => translations._("System Default"),
            1 => translations._("English"),
            2 => translations._("Bulgarian"),
            3 => translations._("Català"),
            4 => translations._("Deutsch"),
            5 => translations._("Español"),
            6 => translations._("Français"),
            7 => translations._("Magyar"),
            8 => translations._("日本語"),
            9 => translations._("Polski"),
            10 => translations._("Português (Brasil)"),
            11 => translations._("Português (Portugal)"),
            12 => translations._("Русский"),
            13 => translations._("Türkçe"),
            14 => translations._("中文（简体）"),
            else => translations._("System Default"),
        };
        gtk.StringList.append(lang_strings, label);
    }
    gtk.DropDown.setModel(p.language_drop, lang_strings.as(gio.ListModel));
}

fn isPageEntryEnabled(entry: DefaultPageEntry, filter: PageFilter) bool {
    return switch (entry.value) {
        .recommend => filter.recommended,
        .packages => true,
        .aur => filter.aur,
        .flatpak => filter.flatpak,
        .app_image => filter.app_image,
        .shelly_search => filter.shelly_search,
        .update => true,
    };
}

fn pageEntryLabel(entry: DefaultPageEntry) [:0]const u8 {
    return switch (entry.value) {
        .recommend => translations._("Recommended"),
        .packages => translations._("Packages"),
        .aur => translations._("AUR"),
        .flatpak => translations._("Flatpak"),
        .app_image => translations._("AppImage"),
        .shelly_search => translations._("Shelly Search"),
        .update => translations._("Update"),
    };
}

fn populatePageDropdown(p: *ShellySettingsPage.Private, cfg: *const ShellyConfig) void {
    p.page_filter = PageFilter.fromConfig(cfg);
    const page_strings = gtk.StringList.new(null);
    for (default_page_entries) |entry| {
        if (!isPageEntryEnabled(entry, p.page_filter)) continue;
        gtk.StringList.append(page_strings, pageEntryLabel(entry));
    }
    gtk.DropDown.setModel(p.default_page_drop, page_strings.as(gio.ListModel));
    // Replacing the model resets the selection, so restore it.
    // Callers must hold save_guard: this emits notify::selected.
    gtk.DropDown.setSelected(
        p.default_page_drop,
        defaultPageIndex(cfg.DefaultPageDropDown, p.page_filter),
    );
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

fn persistFeatureEnabled(
    comptime field: std.meta.FieldEnum(ShellyConfig),
    enabled: bool,
) !void {
    const svc = try obtainConfigService();
    const cfg = try svc.get();
    var updated = cfg.*;
    @field(updated, @tagName(field)) = enabled;
    try svc.set(updated);
    try svc.save();
}

fn applyConfig(p: *ShellySettingsPage.Private, cfg: *ShellyConfig) void {
    setSwitch(p.aur_switch, cfg.AurEnabled);
    setSwitch(p.flatpak_switch, cfg.FlatPackEnabled);
    setSwitch(p.recommended_switch, cfg.RecommendedEnabled);
    setSwitch(p.appimage_switch, cfg.AppImageEnabled);
    setSwitch(p.tray_switch, cfg.TrayEnabled);
    setSwitch(p.tray_auto_switch, cfg.TrayAutoStart);
    setSwitch(p.daily_schedule, cfg.UseWeeklySchedule);
    setSwitch(p.tray_cron_switch, cfg.TrayRunAsCron);
    setSwitch(p.use_ui, cfg.UseUiForUpdate);

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
    setSwitch(p.symbolic_tray_switch, cfg.UseSymbolicTray);

    gtk.DropDown.setSelected(p.nav_mode_drop, navModeIndex(cfg.NavMode));
    gtk.DropDown.setSelected(p.language_drop, languageIndex(cfg.Culture));

    setButtonLabel(p.tray_icon_button, std.heap.c_allocator, cfg.TrayIconPath, translations._("Select Icon"));
    setButtonLabel(p.tray_updates_icon_button, std.heap.c_allocator, cfg.TrayUpdatesIconPath, translations._("Select Icon"));

    // Advanced
    setSwitch(p.no_confirm_switch, cfg.NoConfirm);
    setSwitch(p.shelly_search_switch, cfg.ShellySearchEnabled);
    setSwitch(p.remove_cache_switch, cfg.PackageManagementRemoveConfigs);
    setSwitch(p.webview_switch, cfg.WebviewEnabled);

    applyAppImageInstallPath(p);
}

fn applyAppImageInstallPath(p: *ShellySettingsPage.Private) void {
    const allocator = std.heap.c_allocator;
    var resolver = CliConfigResolver.init(allocator, runtime.io, runtime.environ_map) catch {
        setButtonLabel(p.appimage_install_path_button, allocator, "", translations._("Select Directory"));
        return;
    };
    defer resolver.deinit();

    const path = resolver.readAppImageInstallPath() catch |err| {
        std.log.warn("settings: could not read AppImage install path: {t}", .{err});
        setButtonLabel(p.appimage_install_path_button, allocator, "", translations._("Select Directory"));
        return;
    };
    defer if (path) |value| allocator.free(value);

    setButtonLabel(p.appimage_install_path_button, allocator, path orelse "", translations._("Select Directory"));
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
    cfg.TrayRunAsCron = getSwitch(p.tray_cron_switch);
    cfg.UseUiForUpdate = getSwitch(p.use_ui);

    cfg.TrayCheckIntervalHours = gtk.SpinButton.getValueAsInt(p.tray_interval_spin);

    cfg.DaysOfWeek = collectDays(p, allocator) catch cfg.DaysOfWeek;

    cfg.Time = datetime.formatTime(
        allocator,
        gtk.SpinButton.getValueAsInt(p.update_hour_spin),
        gtk.SpinButton.getValueAsInt(p.update_minute_spin),
    ) catch cfg.Time;

    cfg.ShellyIconsEnabled = getSwitch(p.shelly_icons_switch);
    cfg.UseSymbolicTray = getSwitch(p.symbolic_tray_switch);

    const idx = gtk.DropDown.getSelected(p.default_page_drop);
    if (idx != std.math.maxInt(u32)) {
        if (pageEntryValue(idx, p.page_filter)) |page| {
            cfg.DefaultPageDropDown = page;
        }
    }

    const nav_idx = gtk.DropDown.getSelected(p.nav_mode_drop);
    if (nav_idx != std.math.maxInt(u32) and nav_idx < nav_mode_entries.len) {
        cfg.NavMode = nav_mode_entries[nav_idx].value;
    }

    // Advanced
    cfg.NoConfirm = getSwitch(p.no_confirm_switch);
    cfg.ShellySearchEnabled = getSwitch(p.shelly_search_switch);
    cfg.PackageManagementRemoveConfigs = getSwitch(p.remove_cache_switch);
    cfg.WebviewEnabled = getSwitch(p.webview_switch);
}

test "Flatpak support uses libflatpak and the configured companion backend" {
    const packages = support_packages.dependenciesForFeature(.flatpak);
    try std.testing.expectEqualStrings("flatpak", packages[0]);

    const argv = try ShellyCommands.install(std.testing.allocator, &packages);
    defer std.testing.allocator.free(argv);
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "install", "standard", "flatpak" },
        argv,
    );

    const backend = &.{support_packages.flatpakBackendPackage()};
    const standard_argv = try ShellyCommands.install(std.testing.allocator, backend);
    defer std.testing.allocator.free(standard_argv);
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "install", "standard", options.flatpak_backend_package },
        standard_argv,
    );

    const aur_argv = try ShellyCommands.install_aur(std.testing.allocator, backend);
    defer std.testing.allocator.free(aur_argv);
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "install", "aur", options.flatpak_backend_package },
        aur_argv,
    );
}

test "AppImage support installs fuse2" {
    const packages = support_packages.dependenciesForFeature(.appimage);
    try std.testing.expectEqualStrings("fuse2", packages[0]);

    const argv = try ShellyCommands.install(std.testing.allocator, &packages);
    defer std.testing.allocator.free(argv);
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "install", "standard", "fuse2" },
        argv,
    );
}

fn applyScheduleVisibility(p: *ShellySettingsPage.Private) void {
    const tray_enabled = gtk.Switch.getActive(p.tray_switch) != 0;
    if (!tray_enabled) {
        gtk.Widget.setVisible(p.weekly_schedule_switch_box.as(gtk.Widget), 0);
        gtk.Widget.setVisible(p.tray_cron_box.as(gtk.Widget), 0);
        gtk.Widget.setVisible(p.weekly_schedule_box.as(gtk.Widget), 0);
        gtk.Widget.setVisible(p.tray_interval_box.as(gtk.Widget), 0);
        gtk.Widget.setVisible(p.use_ui_switch_box.as(gtk.Widget), 0);
        return;
    }

    gtk.Widget.setVisible(p.weekly_schedule_switch_box.as(gtk.Widget), 1);
    const daily_enabled = gtk.Switch.getActive(p.daily_schedule) != 0;
    gtk.Widget.setVisible(p.tray_cron_box.as(gtk.Widget), @intFromBool(daily_enabled));
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

fn defaultPageIndex(page: ShellyTabs, filter: PageFilter) c_uint {
    var filtered_idx: c_uint = 0;
    for (default_page_entries) |entry| {
        if (!isPageEntryEnabled(entry, filter)) continue;
        if (entry.value == page) return filtered_idx;
        filtered_idx += 1;
    }
    return 0;
}

fn pageEntryValue(index: c_uint, filter: PageFilter) ?ShellyTabs {
    var filtered_idx: c_uint = 0;
    for (default_page_entries) |entry| {
        if (!isPageEntryEnabled(entry, filter)) continue;
        if (filtered_idx == index) return entry.value;
        filtered_idx += 1;
    }
    return null;
}

fn navModeIndex(mode: NavMode) c_uint {
    inline for (nav_mode_entries, 0..) |entry, i| {
        if (entry.value == mode) return @intCast(i);
    }
    return 0;
}
