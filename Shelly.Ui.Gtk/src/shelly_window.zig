const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const glib = bindings.glib;
const gio = bindings.gio;
const gobject = bindings.gobject;
const FlatpakPage = @import("pages/flatpak/flatpak_page.zig").FlatpakPage;
const AppImagePage = @import("pages/appimage_page.zig").AppImagePage;
const PackagePage = @import("pages/package_page.zig").PackagePage;
const AurPage = @import("pages/aur_page.zig").AurPage;
const ShellySearchPage = @import("pages/search_page.zig").ShellySearchPage;
const UpdatePage = @import("pages/update_page.zig").UpdatePage;
const RecommendPage = @import("pages/recommend_page.zig").RecommendPage;
const WelcomePage = @import("pages/welcome.zig").WelcomePage;
const SupportPage = @import("pages/support.zig");
const SettingsPage = @import("pages/settings_page.zig").SettingsPage;
const UtilitiesPage = @import("pages/utilities_page.zig").UtilitiesPage;
const TransactionPage = @import("pages/transaction_page.zig").TransactionPage;
const TransactionRequest = @import("pages/transaction_page.zig").TransactionRequest;
const runtime = @import("services/runtime.zig");
const ConfigResolver = @import("services/ui_config_resolver.zig").ConfigResolver;
const theme_manager = @import("services/theme_manager.zig");
const AppTheme = @import("models/shelly_config.zig").AppTheme;
const NavMode = @import("models/shelly_config.zig").NavMode;
const ShellyTabs = @import("models/shelly_config.zig").ShellyTabs;
const translations = @import("helpers/translations.zig");
const ConfirmDialog = @import("dialog/page/yn_dialog.zig").ConfirmDialog;
const PolkitDialog = @import("dialog/page/polkit_warning.zig").PolkitDialog;
const DBus = @import("services/dbus.zig").DBus;
const window_controls = @import("window_controls.zig");
const Sidebar = @import("sidebar.zig").Sidebar;
const wayland_blur = @import("wayland/blur.zig");

fn shouldRequestBlur(theme: AppTheme, mode: NavMode) bool {
    return theme_manager.isDark(theme) and mode == .sidebar;
}

const NavButton = struct {
    button: *gtk.Button,
    revealer: *gtk.Revealer,
    stack: *gtk.Stack,
    name: [:0]const u8,
    window: *ShellyWindow,
    is_rail: bool,
};

const MainColumn = struct {
    root: *gtk.Box,
    chrome: *gtk.Box,
    topnav_scroll: *gtk.ScrolledWindow,
};

fn applyTopnavViewportWidth(topnav: *gtk.Box, viewport_width: c_int) void {
    gtk.Widget.setSizeRequest(topnav.as(gtk.Widget), viewport_width, -1);
}

fn onTopnavViewportWidthChanged(
    source: *gobject.Object,
    _: *gobject.ParamSpec,
    topnav: *gtk.Box,
) callconv(.c) void {
    const viewport: *gtk.Widget = @ptrCast(@alignCast(source));
    const viewport_width = gtk.Widget.getWidth(viewport);
    applyTopnavViewportWidth(topnav, viewport_width);
}

fn buildMainColumn(toggle: *gtk.Button, topnav: *gtk.Box, stack: *gtk.Stack) MainColumn {
    const root = gtk.Box.new(.vertical, 0);
    gtk.Widget.addCssClass(root.as(gtk.Widget), "app-main-column");
    gtk.Widget.setHexpand(root.as(gtk.Widget), 1);
    gtk.Widget.setVexpand(root.as(gtk.Widget), 1);

    const chrome = window_controls.buildChromeRow(toggle);
    const topnav_scroll = gtk.ScrolledWindow.new();
    gtk.Widget.addCssClass(topnav_scroll.as(gtk.Widget), "app-topbar-scroll");
    gtk.ScrolledWindow.setPolicy(topnav_scroll, .automatic, .never);
    gtk.ScrolledWindow.setOverlayScrolling(topnav_scroll, 0);
    gtk.ScrolledWindow.setChild(topnav_scroll, topnav.as(gtk.Widget));
    _ = gobject.Object.signals.notify.connect(
        topnav_scroll.as(gobject.Object),
        *gtk.Box,
        &onTopnavViewportWidthChanged,
        topnav,
        .{ .detail = "width" },
    );

    gtk.Box.append(root, chrome.as(gtk.Widget));
    gtk.Box.append(root, topnav_scroll.as(gtk.Widget));
    gtk.Box.append(root, stack.as(gtk.Widget));

    return .{ .root = root, .chrome = chrome, .topnav_scroll = topnav_scroll };
}

pub const ShellyWindow = extern struct {
    parent_instance: Parent,

    pub const Parent = gtk.ApplicationWindow;

    const Private = struct {
        root_overlay: *gtk.Overlay,
        shell_box: *gtk.Box,
        lockout_overlay: *gtk.Overlay,
        lockout_content: *gtk.Box,
        content_stack: *gtk.Stack,
        main_column: *gtk.Box,
        chrome_row: *gtk.Box,
        sidebar: ?Sidebar,
        rail: ?*gtk.Box,
        topnav: ?*gtk.Box,
        nav_buttons: std.ArrayListUnmanaged(*NavButton),
        blur: ?*wayland_blur.Blur,
        active_theme: AppTheme,
        collapsed: bool,
        nav_mode: NavMode,
        pending_nav: NavMode,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(ShellyWindow, .{
        .name = "ShellyWindow",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub fn new(app: *gtk.Application) *ShellyWindow {
        return gobject.ext.newInstance(ShellyWindow, .{ .application = app });
    }

    pub fn as(self: *ShellyWindow, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    fn private(self: *ShellyWindow) *Private {
        return gobject.ext.impl_helpers.getPrivate(self, Private, Private.offset);
    }

    fn init(self: *ShellyWindow, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        const p = self.private();
        p.sidebar = null;
        p.rail = null;
        p.topnav = null;
        p.nav_buttons = .empty;
        p.blur = null;
        p.active_theme = .classic;
        p.collapsed = readSidebarCollapsed();
        p.nav_mode = .sidebar;
        p.pending_nav = .sidebar;
        window_controls.installLockoutDragRegion(p.lockout_overlay);
        build_shell(self);
        populate_stack(self);
        applyConfig(self);
        applyDefaultPage(self);
        showWelcomeIfFirstStart(self);
        checkPolkitLockout(self);
        _ = gtk.Widget.signals.map.connect(self.as(gtk.Widget), *ShellyWindow, &on_map, self, .{});
        _ = gtk.Widget.signals.unmap.connect(self.as(gtk.Widget), *ShellyWindow, &on_unmap, self, .{});
        _ = gtk.Window.signals.close_request.connect(self.as(gtk.Window), *ShellyWindow, &on_close_request, self, .{});
    }

    pub fn applyConfig(self: *ShellyWindow) void {
        const svc = runtime.config orelse return;
        const cfg = svc.get() catch return;

        self.applyTheme(cfg.Theme);

        setNavEnabled(self, "recommend", cfg.RecommendedEnabled);
        setNavEnabled(self, "aur", cfg.AurEnabled);
        setNavEnabled(self, "flatpak", cfg.FlatPackEnabled);
        setNavEnabled(self, "appimage", cfg.AppImageEnabled);
        setNavEnabled(self, "search", cfg.ShellySearchEnabled);

        self.changeNav(cfg.NavMode);

        if (cfg.WindowLastWidth > 0 and cfg.WindowLastHeight > 0) {
            gtk.Window.setDefaultSize(
                self.as(gtk.Window),
                @intCast(cfg.WindowLastWidth),
                @intCast(cfg.WindowLastHeight),
            );
        }
    }

    pub fn applyTheme(self: *ShellyWindow, theme: AppTheme) void {
        self.private().active_theme = theme;
        theme_manager.apply(self.as(gtk.Widget), theme);
        updateBlurRegion(self);
    }

    fn on_map(_: *gtk.Widget, self: *ShellyWindow) callconv(.c) void {
        const p = self.private();
        if (p.blur != null) return;

        const native = gtk.Widget.getNative(self.as(gtk.Widget)) orelse return;
        const surface = gtk.Native.getSurface(native) orelse return;
        const display = gtk.Widget.getDisplay(self.as(gtk.Widget));
        p.blur = wayland_blur.Blur.init(display, surface);
        updateBlurRegion(self);
    }

    fn on_unmap(_: *gtk.Widget, self: *ShellyWindow) callconv(.c) void {
        const p = self.private();
        if (p.blur) |blur| blur.deinit();
        p.blur = null;
    }

    fn on_blur_geometry_changed(_: *gobject.Object, _: *gobject.ParamSpec, self: *ShellyWindow) callconv(.c) void {
        updateBlurRegion(self);
    }

    fn updateBlurRegion(self: *ShellyWindow) void {
        const p = self.private();
        const blur = p.blur orelse return;
        const rail = p.rail orelse return;
        blur.update(
            shouldRequestBlur(p.active_theme, p.nav_mode),
            gtk.Widget.getWidth(rail.as(gtk.Widget)),
            gtk.Widget.getHeight(self.as(gtk.Widget)),
        );
    }

    fn on_close_request(_: *gtk.Window, self: *ShellyWindow) callconv(.c) c_int {
        const svc = runtime.config orelse return 0;
        const w = gtk.Widget.getWidth(self.as(gtk.Widget));
        const h = gtk.Widget.getHeight(self.as(gtk.Widget));
        if (w > 0 and h > 0) {
            const cfg = svc.get() catch return 0;
            var updated = cfg.*;
            updated.WindowLastWidth = w;
            updated.WindowLastHeight = h;
            svc.set(updated) catch return 0;
            svc.save() catch return 0;
        }
        return 0;
    }

    fn showWelcomeIfFirstStart(self: *ShellyWindow) void {
        const svc = runtime.config orelse return;
        const cfg = svc.get() catch return;
        if (!cfg.NewInstall) return;
        const wp = WelcomePage.new();
        self.showLockout(wp.as(gtk.Widget));
    }

    fn checkPolkitLockout(self: *ShellyWindow) void {
        var dbus = DBus{};
        defer dbus.deinit();

        const status = dbus.checkPolkitStatus();
        if (status == .no_agent or status == .no_daemon) {
            const dialog = PolkitDialog.new(&on_polkit_close, self);
            self.showLockout(dialog.as(gtk.Widget));
            dialog.focusClose();
        }
    }

    fn on_polkit_close(ctx: ?*anyopaque) void {
        const self: *ShellyWindow = @ptrCast(@alignCast(ctx.?));
        self.hideLockout();
    }

    fn setNavEnabled(self: *ShellyWindow, name: [:0]const u8, enabled: bool) void {
        const p = self.private();
        const visible: c_int = @intFromBool(enabled);
        var active_stack: ?*gtk.Stack = null;

        for (p.nav_buttons.items) |nb| {
            if (!std.mem.eql(u8, nb.name, name)) continue;
            gtk.Widget.setVisible(nb.button.as(gtk.Widget), visible);
            active_stack = nb.stack;
            if (gtk.Stack.getChildByName(nb.stack, name)) |child| {
                const page = gtk.Stack.getPage(nb.stack, child);
                gtk.StackPage.setVisible(page, visible);
            }
        }

        if (enabled) return;

        const stack = active_stack orelse return;
        const cn_opt = gtk.Stack.getVisibleChildName(stack);
        const is_active = if (cn_opt) |cn| std.mem.eql(u8, std.mem.span(cn), name) else false;
        if (!is_active) return;

        gtk.Stack.setVisibleChildName(stack, "package");
        for (p.nav_buttons.items) |n| {
            if (std.mem.eql(u8, n.name, "package")) {
                set_active_nav(self, n);
                break;
            }
        }
    }

    fn build_shell(self: *ShellyWindow) void {
        const p = self.private();

        const stack = gtk.Stack.new();
        gtk.Widget.setHexpand(stack.as(gtk.Widget), 1);
        gtk.Widget.setVexpand(stack.as(gtk.Widget), 1);
        p.content_stack = stack;

        _ = build_rail(self, stack);
        _ = build_topnav(self, stack);

        const main = buildMainColumn(p.sidebar.?.collapse_button, p.topnav.?, stack);
        p.main_column = main.root;
        p.chrome_row = main.chrome;
        gtk.Box.append(p.shell_box, p.rail.?.as(gtk.Widget));
        gtk.Box.append(p.shell_box, main.root.as(gtk.Widget));
        window_controls.installOverlay(p.root_overlay);

        _ = gobject.Object.signals.notify.connect(
            p.rail.?.as(gobject.Object),
            *ShellyWindow,
            &on_blur_geometry_changed,
            self,
            .{ .detail = "width" },
        );
        _ = gobject.Object.signals.notify.connect(
            self.as(gobject.Object),
            *ShellyWindow,
            &on_blur_geometry_changed,
            self,
            .{ .detail = "height" },
        );

        applyNavMode(self, readNavMode());
    }

    fn readNavMode() NavMode {
        const svc = runtime.config orelse return .sidebar;
        const cfg = svc.get() catch return .sidebar;
        return cfg.NavMode;
    }

    fn readSidebarCollapsed() bool {
        const svc = runtime.config orelse return true;
        const cfg = svc.get() catch return true;
        return cfg.SidebarCollapsed;
    }

    pub fn requestNav(self: *ShellyWindow, mode: NavMode) void {
        self.private().pending_nav = mode;
        _ = glib.idleAdd(&apply_pending_nav, self);
    }

    fn apply_pending_nav(data: ?*anyopaque) callconv(.c) c_int {
        const self: *ShellyWindow = @ptrCast(@alignCast(data));
        self.changeNav(self.private().pending_nav);
        return 0;
    }

    pub fn changeNav(self: *ShellyWindow, mode: NavMode) void {
        if (self.private().nav_mode == mode) return;
        applyNavMode(self, mode);
    }

    fn applyNavMode(self: *ShellyWindow, mode: NavMode) void {
        const p = self.private();
        p.nav_mode = mode;

        const sidebar = mode == .sidebar;
        gtk.Orientable.setOrientation(p.shell_box.as(gtk.Orientable), .horizontal);
        gtk.Widget.setVisible(p.rail.?.as(gtk.Widget), @intFromBool(sidebar));
        gtk.Widget.setVisible(p.topnav.?.as(gtk.Widget), @intFromBool(!sidebar));
        gtk.Widget.setVisible(p.sidebar.?.collapse_button.as(gtk.Widget), @intFromBool(sidebar));
        gtk.Widget.removeCssClass(
            p.chrome_row.as(gtk.Widget),
            if (sidebar) "app-window-chrome-topbar" else "app-window-chrome-sidebar",
        );
        gtk.Widget.addCssClass(
            p.chrome_row.as(gtk.Widget),
            if (sidebar) "app-window-chrome-sidebar" else "app-window-chrome-topbar",
        );

        updateBlurRegion(self);
        sync_active_nav(self);
    }

    fn build_rail(self: *ShellyWindow, stack: *gtk.Stack) *gtk.Box {
        const p = self.private();
        const sidebar = Sidebar.init(p.collapsed);
        p.sidebar = sidebar;
        p.rail = @ptrCast(sidebar.root.as(gobject.Object).ref());
        _ = gtk.Button.signals.clicked.connect(sidebar.collapse_button, *ShellyWindow, &on_chevron, self, .{});

        const items = sidebar.primary;

        add_nav_button(self, items, stack, true, "recommend", RecommendPage.icon_name, translations._(RecommendPage.title));
        add_nav_button(self, items, stack, true, "package", PackagePage.icon_name, translations._(PackagePage.title));
        add_nav_button(self, items, stack, true, "aur", AurPage.icon_name, translations._(AurPage.title));
        add_nav_button(self, items, stack, true, "flatpak", FlatpakPage.icon_name, translations._(FlatpakPage.title));
        add_nav_button(self, items, stack, true, "appimage", AppImagePage.icon_name, translations._(AppImagePage.title));
        add_nav_button(self, items, stack, true, "search", ShellySearchPage.icon_name, translations._(ShellySearchPage.title));
        add_nav_button(self, items, stack, true, "update", UpdatePage.icon_name, translations._(UpdatePage.title));
        add_nav_button(self, sidebar.bottom, stack, true, "settings", SettingsPage.icon_name, translations._(SettingsPage.title));
        return sidebar.root;
    }

    fn build_topnav(self: *ShellyWindow, stack: *gtk.Stack) *gtk.Box {
        const p = self.private();
        const bar = gtk.Box.new(.horizontal, 0);
        gtk.Widget.addCssClass(bar.as(gtk.Widget), "nav-topbar");
        gtk.Widget.addCssClass(bar.as(gtk.Widget), "app-topbar");
        gtk.Widget.setHexpand(bar.as(gtk.Widget), 1);
        p.topnav = @ptrCast(bar.as(gobject.Object).ref());

        const left_spacer = gtk.Box.new(.horizontal, 0);
        gtk.Widget.addCssClass(left_spacer.as(gtk.Widget), "app-topbar-spacer");
        gtk.Widget.setHexpand(left_spacer.as(gtk.Widget), 1);
        gtk.Box.append(bar, left_spacer.as(gtk.Widget));

        const items = gtk.Box.new(.horizontal, 0);
        gtk.Widget.addCssClass(items.as(gtk.Widget), "app-topbar-items");
        gtk.Box.append(bar, items.as(gtk.Widget));

        add_nav_button(self, items, stack, false, "recommend", RecommendPage.icon_name, translations._(RecommendPage.title));
        add_nav_button(self, items, stack, false, "package", PackagePage.icon_name, translations._(PackagePage.title));
        add_nav_button(self, items, stack, false, "aur", AurPage.icon_name, translations._(AurPage.title));
        add_nav_button(self, items, stack, false, "flatpak", FlatpakPage.icon_name, translations._(FlatpakPage.title));
        add_nav_button(self, items, stack, false, "appimage", AppImagePage.icon_name, translations._(AppImagePage.title));
        add_nav_button(self, items, stack, false, "search", ShellySearchPage.icon_name, translations._(ShellySearchPage.title));
        add_nav_button(self, items, stack, false, "update", UpdatePage.icon_name, translations._(UpdatePage.title));
        add_nav_button(self, items, stack, false, "settings", SettingsPage.icon_name, translations._(SettingsPage.title));

        const right_spacer = gtk.Box.new(.horizontal, 0);
        gtk.Widget.addCssClass(right_spacer.as(gtk.Widget), "app-topbar-spacer");
        gtk.Widget.setHexpand(right_spacer.as(gtk.Widget), 1);
        gtk.Box.append(bar, right_spacer.as(gtk.Widget));

        return bar;
    }

    fn on_chevron(_: *gtk.Button, self: *ShellyWindow) callconv(.c) void {
        const p = self.private();
        p.collapsed = !p.collapsed;

        if (p.sidebar) |sidebar| sidebar.setCollapsed(p.collapsed);

        for (p.nav_buttons.items) |nb| {
            if (!nb.is_rail) continue;
            gtk.Revealer.setRevealChild(nb.revealer, @intFromBool(!p.collapsed));
        }

        if (runtime.config) |config| {
            persistSidebarCollapsed(config, p.collapsed) catch |err| {
                std.log.err("window: failed to save sidebar state: {t}", .{err});
            };
        }
        updateBlurRegion(self);
    }

    fn persistSidebarCollapsed(config: *ConfigResolver, collapsed: bool) !void {
        try config.updateField(.SidebarCollapsed, collapsed);
    }

    fn add_nav_button(self: *ShellyWindow, parent_box: *gtk.Box, stack: *gtk.Stack, is_rail: bool, name: [:0]const u8, icon: [:0]const u8, text: [:0]const u8) void {
        const p = self.private();
        const box = gtk.Box.new(.horizontal, 0);
        const img = gtk.Image.newFromIconName(icon);

        gtk.Image.setIconSize(img, .normal);
        if (is_rail) gtk.Widget.addCssClass(img.as(gtk.Widget), "sidebar-nav-icon");
        gtk.Widget.setHalign(img.as(gtk.Widget), .center);
        gtk.Box.append(box, img.as(gtk.Widget));

        const label = gtk.Label.new(text);
        gtk.Widget.addCssClass(label.as(gtk.Widget), "nav-label");
        gtk.Widget.setHalign(label.as(gtk.Widget), .start);

        const revealer = gtk.Revealer.new();
        if (is_rail) {
            gtk.Revealer.setTransitionType(revealer, .slide_right);
            gtk.Revealer.setRevealChild(revealer, @intFromBool(!p.collapsed));
        } else {
            gtk.Revealer.setTransitionType(revealer, .none);
            gtk.Revealer.setRevealChild(revealer, 1);
        }
        gtk.Revealer.setChild(revealer, label.as(gtk.Widget));
        gtk.Box.append(box, revealer.as(gtk.Widget));

        const btn = gtk.Button.new();
        gtk.Button.setChild(btn, box.as(gtk.Widget));
        gtk.Widget.addCssClass(btn.as(gtk.Widget), "flat");
        gtk.Widget.addCssClass(btn.as(gtk.Widget), "nav-btn");
        gtk.Widget.addCssClass(btn.as(gtk.Widget), "app-nav-button");
        gtk.Widget.setTooltipText(btn.as(gtk.Widget), text);

        const nb = std.heap.c_allocator.create(NavButton) catch unreachable;
        nb.* = .{
            .button = btn,
            .revealer = revealer,
            .stack = stack,
            .name = name,
            .window = self,
            .is_rail = is_rail,
        };
        p.nav_buttons.append(std.heap.c_allocator, nb) catch unreachable;
        _ = gtk.Button.signals.clicked.connect(btn, *NavButton, &on_nav_click, nb, .{});

        gtk.Box.append(parent_box, btn.as(gtk.Widget));
    }

    fn on_nav_click(_: *gtk.Button, nb: *NavButton) callconv(.c) void {
        gtk.Stack.setVisibleChildName(nb.stack, nb.name);
        set_active_nav(nb.window, nb);
    }

    fn set_active_nav(self: *ShellyWindow, active: *NavButton) void {
        const p = self.private();
        for (p.nav_buttons.items) |nb| {
            if (std.mem.eql(u8, nb.name, active.name)) {
                gtk.Widget.addCssClass(nb.button.as(gtk.Widget), "nav-selected");
            } else {
                gtk.Widget.removeCssClass(nb.button.as(gtk.Widget), "nav-selected");
            }
        }
    }

    fn sync_active_nav(self: *ShellyWindow) void {
        const p = self.private();
        const current_name: []const u8 = blk: {
            const cn_opt = gtk.Stack.getVisibleChildName(p.content_stack);
            break :blk if (cn_opt) |cn| std.mem.span(cn) else "";
        };
        for (p.nav_buttons.items) |nb| {
            if (std.mem.eql(u8, nb.name, current_name)) {
                set_active_nav(self, nb);
                return;
            }
        }
        if (p.nav_buttons.items.len > 0) {
            set_active_nav(self, p.nav_buttons.items[0]);
        }
    }

    fn tabStackName(tab: ShellyTabs) ?[:0]const u8 {
        return switch (tab) {
            .packages => "package",
            .aur => "aur",
            .flatpak => "flatpak",
            .app_image => "appimage",
            .recommend => "recommend",
            .update => "update",
            .shelly_search => "search",
        };
    }

    pub fn applyDefaultPage(self: *ShellyWindow) void {
        const p = self.private();
        const svc = runtime.config orelse {
            sync_active_nav(self);
            return;
        };
        const cfg = svc.get() catch {
            sync_active_nav(self);
            return;
        };

        if (tabStackName(cfg.DefaultPageDropDown)) |name| {
            if (gtk.Stack.getChildByName(p.content_stack, name)) |child| {
                const page = gtk.Stack.getPage(p.content_stack, child);
                if (gtk.StackPage.getVisible(page) != 0) {
                    gtk.Stack.setVisibleChildName(p.content_stack, name);
                }
            }
        }
        sync_active_nav(self);
    }

    fn populate_stack(self: *ShellyWindow) void {
        const stack = self.private().content_stack;

        const rp = RecommendPage.new();
        const rp_page = gtk.Stack.addTitled(stack, rp.as(gtk.Widget), "recommend", RecommendPage.title);
        gtk.StackPage.setIconName(rp_page, RecommendPage.icon_name);

        const pp = PackagePage.new();
        const pp_page = gtk.Stack.addTitled(stack, pp.as(gtk.Widget), "package", translations._("Package"));
        gtk.StackPage.setIconName(pp_page, PackagePage.icon_name);

        const fp = FlatpakPage.new();
        const fp_page = gtk.Stack.addTitled(stack, fp.as(gtk.Widget), "flatpak", translations._("Flatpak"));
        gtk.StackPage.setIconName(fp_page, FlatpakPage.icon_name);

        const ai = AppImagePage.new();
        const ai_page = gtk.Stack.addTitled(stack, ai.as(gtk.Widget), "appimage", translations._("AppImage"));
        gtk.StackPage.setIconName(ai_page, AppImagePage.icon_name);

        const au = AurPage.new();
        const au_page = gtk.Stack.addTitled(stack, au.as(gtk.Widget), "aur", translations._("AUR"));
        gtk.StackPage.setIconName(au_page, AurPage.icon_name);

        const ss = ShellySearchPage.new();
        const ss_page = gtk.Stack.addTitled(stack, ss.as(gtk.Widget), "search", translations._(ShellySearchPage.title));
        gtk.StackPage.setIconName(ss_page, ShellySearchPage.icon_name);

        const up = UpdatePage.new();
        const up_page = gtk.Stack.addTitled(stack, up.as(gtk.Widget), "update", translations._("Update"));
        gtk.StackPage.setIconName(up_page, UpdatePage.icon_name);

        const sp = SettingsPage.new();
        const sp_page = gtk.Stack.addTitled(stack, sp.as(gtk.Widget), "settings", translations._("Settings"));
        gtk.StackPage.setIconName(sp_page, SettingsPage.icon_name);

        const up_utils = UtilitiesPage.new();
        _ = sp.addPage(up_utils.as(gtk.Widget), "utilities", translations._("Utilities"));
    }

    pub fn showLockout(self: *ShellyWindow, content: *gtk.Widget) void {
        const p = self.private();
        while (gtk.Widget.getFirstChild(p.lockout_content.as(gtk.Widget))) |c| {
            gtk.Box.remove(p.lockout_content, c);
        }
        gtk.Box.append(p.lockout_content, content);

        gtk.Widget.setSensitive(p.content_stack.as(gtk.Widget), 0);
        if (p.rail) |r| gtk.Widget.setSensitive(r.as(gtk.Widget), 0);
        if (p.topnav) |t| gtk.Widget.setSensitive(t.as(gtk.Widget), 0);

        gtk.Widget.setVisible(p.lockout_overlay.as(gtk.Widget), 1);

        if (gobject.ext.cast(ConfirmDialog, content)) |dlg| {
            dlg.focusConfirm();
        } else {
            _ = gtk.Widget.grabFocus(content);
        }
    }

    pub fn hideLockout(self: *ShellyWindow) void {
        const p = self.private();
        gtk.Widget.setVisible(p.lockout_overlay.as(gtk.Widget), 0);

        gtk.Widget.setSensitive(p.content_stack.as(gtk.Widget), 1);
        if (p.rail) |r| gtk.Widget.setSensitive(r.as(gtk.Widget), 1);
        if (p.topnav) |t| gtk.Widget.setSensitive(t.as(gtk.Widget), 1);

        while (gtk.Widget.getFirstChild(p.lockout_content.as(gtk.Widget))) |c| {
            gtk.Box.remove(p.lockout_content, c);
        }
    }

    pub fn startTransaction(self: *ShellyWindow, request: TransactionRequest) void {
        const tp = TransactionPage.new();
        self.showLockout(tp.as(gtk.Widget));
        tp.run(request);
    }

    pub fn navigateToUpdates(self: *ShellyWindow) void {
        const p = self.private();
        gtk.Stack.setVisibleChildName(p.content_stack, "update");
        for (p.nav_buttons.items) |nb| {
            if (std.mem.eql(u8, nb.name, "update")) {
                set_active_nav(self, nb);
                break;
            }
        }
    }

    const template_children = .{
        .{ "root_overlay", @offsetOf(Private, "root_overlay") },
        .{ "lockout_overlay", @offsetOf(Private, "lockout_overlay") },
        .{ "lockout_content", @offsetOf(Private, "lockout_content") },
    };

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = ShellyWindow;

        fn init(class: *Class) callconv(.c) void {
            const wc = gobject.ext.as(gtk.Widget.Class, class);
            gtk.Widget.Class.setTemplateFromResource(wc, "/com/shellyorg/shelly/ui/main_window.ui");
            gtk.Widget.Class.bindTemplateChildFull(
                wc,
                "shell_box",
                @intFromBool(false),
                @as(c_long, @intCast(Private.offset)) + @as(c_long, @intCast(@offsetOf(Private, "shell_box"))),
            );
            inline for (template_children) |c| {
                SupportPage.bindChild(class, Private.offset, c[0], c[1]);
            }
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub fn as(class: *Class, comptime T: type) *T {
            return gobject.ext.as(T, class);
        }
    };

    fn finalize(self: *ShellyWindow) callconv(.c) void {
        const p = self.private();
        if (p.blur) |blur| blur.deinit();
        p.blur = null;
        for (p.nav_buttons.items) |nb| {
            std.heap.c_allocator.destroy(nb);
        }
        p.nav_buttons.deinit(std.heap.c_allocator);
        if (p.rail) |rail| rail.as(gobject.Object).unref();
        if (p.topnav) |topnav| topnav.as(gobject.Object).unref();
        gobject.Object.virtual_methods.finalize.call(Class.parent, self.as(Parent));
    }
};

test "sidebar rail fills the shell without outer gaps" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;

    const sidebar = Sidebar.init(false);
    const rail = sidebar.root;
    _ = rail.as(gobject.Object).refSink();
    defer rail.as(gobject.Object).unref();

    const widget = rail.as(gtk.Widget);
    try std.testing.expectEqual(@as(c_int, 0), gtk.Widget.getMarginTop(widget));
    try std.testing.expectEqual(@as(c_int, 0), gtk.Widget.getMarginBottom(widget));
    try std.testing.expectEqual(@as(c_int, 0), gtk.Widget.getMarginStart(widget));
    try std.testing.expectEqual(@as(c_int, 0), gtk.Widget.getMarginEnd(widget));
    try std.testing.expectEqual(@as(c_int, 1), gtk.Widget.getVexpand(widget));
}

test "main column keeps chrome beside the full-height sidebar" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;

    const shell = gtk.Box.new(.horizontal, 0);
    _ = shell.as(gobject.Object).refSink();
    defer shell.as(gobject.Object).unref();

    const sidebar = Sidebar.init(false);
    const topnav = gtk.Box.new(.horizontal, 0);
    const stack = gtk.Stack.new();
    const main = buildMainColumn(sidebar.collapse_button, topnav, stack);

    gtk.Box.append(shell, sidebar.root.as(gtk.Widget));
    gtk.Box.append(shell, main.root.as(gtk.Widget));

    try std.testing.expect(gtk.Widget.getFirstChild(shell.as(gtk.Widget)) == sidebar.root.as(gtk.Widget));
    try std.testing.expect(gtk.Widget.getNextSibling(sidebar.root.as(gtk.Widget)) == main.root.as(gtk.Widget));
    try std.testing.expect(gtk.Widget.getFirstChild(main.root.as(gtk.Widget)) == main.chrome.as(gtk.Widget));
    try std.testing.expect(gtk.Widget.getParent(sidebar.collapse_button.as(gtk.Widget)) == main.chrome.as(gtk.Widget));
    try std.testing.expect(gtk.Widget.getNextSibling(main.chrome.as(gtk.Widget)) == main.topnav_scroll.as(gtk.Widget));
    try std.testing.expect(
        gtk.Widget.getAncestor(topnav.as(gtk.Widget), gtk.ScrolledWindow.getGObjectType()) ==
            main.topnav_scroll.as(gtk.Widget),
    );
    try std.testing.expect(gtk.Widget.getNextSibling(main.topnav_scroll.as(gtk.Widget)) == stack.as(gtk.Widget));

    applyTopnavViewportWidth(topnav, 900);
    var minimum_width: c_int = 0;
    gtk.Widget.measure(topnav.as(gtk.Widget), .horizontal, -1, &minimum_width, null, null, null);
    try std.testing.expectEqual(@as(c_int, 900), minimum_width);
}

test "topbar is scrollable and keeps every destination labeled" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;

    const sidebar = Sidebar.init(false);
    const topnav = gtk.Box.new(.horizontal, 0);
    const stack = gtk.Stack.new();
    const main = buildMainColumn(sidebar.collapse_button, topnav, stack);
    _ = main.root.as(gobject.Object).refSink();
    defer main.root.as(gobject.Object).unref();

    const topnav_container = gtk.Widget.getNextSibling(main.chrome.as(gtk.Widget)) orelse
        return error.TestUnexpectedResult;
    const scroll = gobject.ext.cast(gtk.ScrolledWindow, topnav_container) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(
        gtk.Widget.getAncestor(topnav.as(gtk.Widget), gtk.ScrolledWindow.getGObjectType()) ==
            scroll.as(gtk.Widget),
    );

    const app = gtk.Application.new("com.shellyorg.shelly.TopbarTest", .{});
    defer app.unref();
    const window = ShellyWindow.new(app);
    _ = window.as(gobject.Object).refSink();
    defer window.as(gobject.Object).unref();

    const bar = window.private().topnav.?;
    const left_spacer = gtk.Widget.getFirstChild(bar.as(gtk.Widget)) orelse
        return error.TestUnexpectedResult;
    const items = gtk.Widget.getNextSibling(left_spacer) orelse
        return error.TestUnexpectedResult;
    const right_spacer = gtk.Widget.getNextSibling(items) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(gtk.Widget.hasCssClass(left_spacer, "app-topbar-spacer") != 0);
    try std.testing.expect(gtk.Widget.hasCssClass(items, "app-topbar-items") != 0);
    try std.testing.expect(gtk.Widget.hasCssClass(right_spacer, "app-topbar-spacer") != 0);
    try std.testing.expect(gtk.Widget.getHexpand(left_spacer) != 0);
    try std.testing.expect(gtk.Widget.getHexpand(right_spacer) != 0);
    try std.testing.expect(gtk.Widget.getNextSibling(right_spacer) == null);

    var topbar_count: usize = 0;
    var has_settings = false;
    for (window.private().nav_buttons.items) |nb| {
        if (nb.is_rail) continue;
        topbar_count += 1;
        try std.testing.expect(gtk.Revealer.getRevealChild(nb.revealer) != 0);
        if (std.mem.eql(u8, nb.name, "settings")) has_settings = true;
    }

    try std.testing.expectEqual(@as(usize, 8), topbar_count);
    try std.testing.expect(has_settings);
}

test "sidebar collapsed state survives save and reload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var config = ConfigResolver.initDir(std.testing.allocator, std.testing.io, tmp.dir);
        defer config.deinit();
        try config.load();
        try ShellyWindow.persistSidebarCollapsed(&config, false);
    }

    var reloaded = ConfigResolver.initDir(std.testing.allocator, std.testing.io, tmp.dir);
    defer reloaded.deinit();
    try reloaded.load();

    const config = try reloaded.get();
    try std.testing.expectEqual(false, config.SidebarCollapsed);
}

test "main window close request allows GTK to destroy the window after saving size" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;

    const app = gtk.Application.new(
        "com.shellyorg.shelly.CloseRequestTest",
        .{ .non_unique = true },
    );
    defer app.unref();
    try std.testing.expect(gio.Application.register(app.as(gio.Application), null, null) != 0);
    const window = ShellyWindow.new(app);
    _ = window.as(gobject.Object).refSink();
    defer window.as(gobject.Object).unref();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var config = ConfigResolver.initDir(std.testing.allocator, std.testing.io, tmp.dir);
    defer config.deinit();
    try config.load();

    const previous_config = runtime.config;
    runtime.config = &config;
    defer runtime.config = previous_config;

    try std.testing.expectEqual(
        @as(c_int, 0),
        ShellyWindow.on_close_request(window.as(gtk.Window), window),
    );
}

test "native blur is requested for dark themes in sidebar mode" {
    try std.testing.expect(shouldRequestBlur(.midnight, .sidebar));
    try std.testing.expect(!shouldRequestBlur(.midnight, .topbar));
    try std.testing.expect(shouldRequestBlur(.seafoam, .sidebar));
    try std.testing.expect(!shouldRequestBlur(.seafoam, .topbar));
    try std.testing.expect(!shouldRequestBlur(.classic, .sidebar));
    try std.testing.expect(!shouldRequestBlur(.classic, .topbar));
    _ = wayland_blur.Region;
}
