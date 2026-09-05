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
const NavMode = @import("models/shelly_config.zig").NavMode;
const ShellyTabs = @import("models/shelly_config.zig").ShellyTabs;
const translations = @import("helpers/translations.zig");
const deep_link = @import("helpers/deep_link.zig");
const ConfirmDialog = @import("dialog/page/yn_dialog.zig").ConfirmDialog;
const PolkitDialog = @import("dialog/page/polkit_warning.zig").PolkitDialog;
const DBus = @import("services/dbus.zig").DBus;

const NavButton = struct {
    button: *gtk.Button,
    revealer: *gtk.Revealer,
    stack: *gtk.Stack,
    name: [:0]const u8,
    window: *ShellyWindow,
    is_rail: bool,
};

pub const ShellyWindow = extern struct {
    parent_instance: Parent,

    pub const Parent = gtk.ApplicationWindow;

    const ICON_SLOT: c_int = 24;
    const LABEL_GAP: c_int = 8;

    const Private = struct {
        shell_box: *gtk.Box,
        lockout_overlay: *gtk.Box,
        lockout_content: *gtk.Box,
        content_stack: *gtk.Stack,
        rail: ?*gtk.Box,
        topnav: ?*gtk.Box,
        chevron_img: ?*gtk.Image,
        nav_buttons: std.ArrayListUnmanaged(*NavButton),
        collapsed: bool,
        nav_mode: NavMode,
        pending_nav: NavMode,
        flatpak_page: *FlatpakPage,
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
        p.rail = null;
        p.topnav = null;
        p.chevron_img = null;
        p.nav_buttons = .empty;
        p.collapsed = true;
        p.nav_mode = .sidebar;
        p.pending_nav = .sidebar;
        build_shell(self);
        populate_stack(self);
        applyConfig(self);
        applyDefaultPage(self);
        showWelcomeIfFirstStart(self);
        checkPolkitLockout(self);
        _ = gtk.Window.signals.close_request.connect(self.as(gtk.Window), *ShellyWindow, &on_close_request, self, .{});
    }

    pub fn applyConfig(self: *ShellyWindow) void {
        const svc = runtime.config orelse return;
        const cfg = svc.get() catch return;

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

    fn canShowTopLevelPage(self: *ShellyWindow, name: [:0]const u8) bool {
        const p = self.private();

        const child = gtk.Stack.getChildByName(
            p.content_stack,
            name,
        ) orelse return false;

        const page = gtk.Stack.getPage(p.content_stack, child);
        return gtk.StackPage.getVisible(page) != 0;
    }

    fn showTopLevelPage(self: *ShellyWindow, name: [:0]const u8) bool {
        if (!self.canShowTopLevelPage(name))
            return false;

        const p = self.private();
        gtk.Stack.setVisibleChildName(p.content_stack, name);
        sync_active_nav(self);
        return true;
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

        gtk.Box.append(p.shell_box, p.rail.?.as(gtk.Widget));
        gtk.Box.append(p.shell_box, p.topnav.?.as(gtk.Widget));
        gtk.Box.append(p.shell_box, stack.as(gtk.Widget));

        applyNavMode(self, readNavMode());
    }

    fn readNavMode() NavMode {
        const svc = runtime.config orelse return .sidebar;
        const cfg = svc.get() catch return .sidebar;
        return cfg.NavMode;
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
        gtk.Orientable.setOrientation(
            p.shell_box.as(gtk.Orientable),
            if (sidebar) .horizontal else .vertical,
        );
        gtk.Widget.setVisible(p.rail.?.as(gtk.Widget), @intFromBool(sidebar));
        gtk.Widget.setVisible(p.topnav.?.as(gtk.Widget), @intFromBool(!sidebar));

        sync_active_nav(self);
    }

    fn build_rail(self: *ShellyWindow, stack: *gtk.Stack) *gtk.Box {
        const p = self.private();
        const rail = gtk.Box.new(.vertical, 6);
        gtk.Widget.addCssClass(rail.as(gtk.Widget), "nav-rail");
        gtk.Widget.setMarginTop(rail.as(gtk.Widget), 8);
        gtk.Widget.setMarginBottom(rail.as(gtk.Widget), 8);
        gtk.Widget.setMarginStart(rail.as(gtk.Widget), 6);
        gtk.Widget.setMarginEnd(rail.as(gtk.Widget), 6);
        p.rail = @ptrCast(rail.as(gobject.Object).ref());

        const chevron = gtk.Button.new();
        gtk.Widget.addCssClass(chevron.as(gtk.Widget), "flat");
        const chevron_img = gtk.Image.newFromIconName(if (p.collapsed) "go-next-symbolic" else "go-previous-symbolic");
        gtk.Widget.setSizeRequest(chevron_img.as(gtk.Widget), ICON_SLOT, -1);
        gtk.Widget.setHalign(chevron_img.as(gtk.Widget), .center);
        gtk.Button.setChild(chevron, chevron_img.as(gtk.Widget));
        p.chevron_img = chevron_img;
        _ = gtk.Button.signals.clicked.connect(chevron, *ShellyWindow, &on_chevron, self, .{});
        gtk.Box.append(rail, chevron.as(gtk.Widget));

        const items = gtk.Box.new(.vertical, 6);
        gtk.Widget.setMarginTop(items.as(gtk.Widget), 4);
        gtk.Widget.setMarginBottom(items.as(gtk.Widget), 4);
        gtk.Box.append(rail, items.as(gtk.Widget));

        add_nav_button(self, items, stack, true, "recommend", RecommendPage.icon_name, translations._(RecommendPage.title));
        add_nav_button(self, items, stack, true, "package", PackagePage.icon_name, translations._(PackagePage.title));
        add_nav_button(self, items, stack, true, "aur", AurPage.icon_name, translations._(AurPage.title));
        add_nav_button(self, items, stack, true, "flatpak", FlatpakPage.icon_name, translations._(FlatpakPage.title));
        add_nav_button(self, items, stack, true, "appimage", AppImagePage.icon_name, translations._(AppImagePage.title));
        add_nav_button(self, items, stack, true, "search", ShellySearchPage.icon_name, translations._(ShellySearchPage.title));
        add_nav_button(self, items, stack, true, "update", UpdatePage.icon_name, translations._(UpdatePage.title));

        const sep = gtk.Box.new(.horizontal, 0);
        gtk.Widget.setVexpand(sep.as(gtk.Widget), 1);
        gtk.Box.append(rail, sep.as(gtk.Widget));

        const menu_button = gtk.MenuButton.new();
        gtk.Widget.addCssClass(menu_button.as(gtk.Widget), "flat");
        gtk.MenuButton.setIconName(menu_button, "open-menu-symbolic");
        const popover = gtk.Popover.new();
        const menu_box = gtk.Box.new(.vertical, 4);
        const utils_btn = gtk.Button.newWithLabel(translations._("Utilities"));
        gtk.Widget.addCssClass(utils_btn.as(gtk.Widget), "flat");
        _ = gtk.Button.signals.clicked.connect(utils_btn, *ShellyWindow, &on_utilities, self, .{});
        gtk.Box.append(menu_box, utils_btn.as(gtk.Widget));
        const sp_btn = gtk.Button.newWithLabel(translations._("Settings"));
        gtk.Widget.addCssClass(sp_btn.as(gtk.Widget), "flat");
        _ = gtk.Button.signals.clicked.connect(sp_btn, *ShellyWindow, &on_settings, self, .{});
        gtk.Box.append(menu_box, sp_btn.as(gtk.Widget));
        gtk.Popover.setChild(popover, menu_box.as(gtk.Widget));
        gtk.MenuButton.setPopover(menu_button, popover);
        gtk.Box.append(rail, menu_button.as(gtk.Widget));
        return rail;
    }

    fn build_topnav(self: *ShellyWindow, stack: *gtk.Stack) *gtk.Box {
        const p = self.private();
        const bar = gtk.Box.new(.horizontal, 4);
        gtk.Widget.addCssClass(bar.as(gtk.Widget), "nav-topbar");
        gtk.Widget.setHexpand(bar.as(gtk.Widget), 1);
        gtk.Widget.setMarginTop(bar.as(gtk.Widget), 6);
        gtk.Widget.setMarginBottom(bar.as(gtk.Widget), 6);
        gtk.Widget.setMarginStart(bar.as(gtk.Widget), 6);
        gtk.Widget.setMarginEnd(bar.as(gtk.Widget), 6);
        p.topnav = @ptrCast(bar.as(gobject.Object).ref());

        const left_spacer = gtk.Box.new(.horizontal, 0);
        gtk.Widget.setHexpand(left_spacer.as(gtk.Widget), 1);
        gtk.Box.append(bar, left_spacer.as(gtk.Widget));

        const items = gtk.Box.new(.horizontal, 0);
        gtk.Box.append(bar, items.as(gtk.Widget));

        add_nav_button(self, items, stack, false, "recommend", RecommendPage.icon_name, translations._(RecommendPage.title));
        add_nav_button(self, items, stack, false, "package", PackagePage.icon_name, translations._(PackagePage.title));
        add_nav_button(self, items, stack, false, "aur", AurPage.icon_name, translations._(AurPage.title));
        add_nav_button(self, items, stack, false, "flatpak", FlatpakPage.icon_name, translations._(FlatpakPage.title));
        add_nav_button(self, items, stack, false, "appimage", AppImagePage.icon_name, translations._(AppImagePage.title));
        add_nav_button(self, items, stack, false, "search", ShellySearchPage.icon_name, translations._(ShellySearchPage.title));
        add_nav_button(self, items, stack, false, "update", UpdatePage.icon_name, translations._(UpdatePage.title));

        const right_spacer = gtk.Box.new(.horizontal, 0);
        gtk.Widget.setHexpand(right_spacer.as(gtk.Widget), 1);
        gtk.Box.append(bar, right_spacer.as(gtk.Widget));

        const menu_button = gtk.MenuButton.new();
        gtk.Widget.addCssClass(menu_button.as(gtk.Widget), "flat");
        gtk.MenuButton.setIconName(menu_button, "view-more-symbolic");
        const popover = gtk.Popover.new();
        const menu_box = gtk.Box.new(.vertical, 4);
        const utils_btn = gtk.Button.newWithLabel(translations._("Utilities"));
        gtk.Widget.addCssClass(utils_btn.as(gtk.Widget), "flat");
        _ = gtk.Button.signals.clicked.connect(utils_btn, *ShellyWindow, &on_utilities, self, .{});
        gtk.Box.append(menu_box, utils_btn.as(gtk.Widget));
        const sp_btn = gtk.Button.newWithLabel(translations._("Settings"));
        gtk.Widget.addCssClass(sp_btn.as(gtk.Widget), "flat");
        _ = gtk.Button.signals.clicked.connect(sp_btn, *ShellyWindow, &on_settings, self, .{});
        gtk.Box.append(menu_box, sp_btn.as(gtk.Widget));
        gtk.Popover.setChild(popover, menu_box.as(gtk.Widget));
        gtk.MenuButton.setPopover(menu_button, popover);
        gtk.Box.append(bar, menu_button.as(gtk.Widget));

        return bar;
    }

    fn on_chevron(_: *gtk.Button, self: *ShellyWindow) callconv(.c) void {
        const p = self.private();
        p.collapsed = !p.collapsed;

        if (p.chevron_img) |img| {
            gtk.Image.setFromIconName(img, if (p.collapsed) "go-next-symbolic" else "go-previous-symbolic");
        }

        for (p.nav_buttons.items) |nb| {
            if (!nb.is_rail) continue;
            gtk.Revealer.setRevealChild(nb.revealer, @intFromBool(!p.collapsed));
        }
    }

    fn add_nav_button(self: *ShellyWindow, parent_box: *gtk.Box, stack: *gtk.Stack, is_rail: bool, name: [:0]const u8, icon: [:0]const u8, text: [:0]const u8) void {
        const p = self.private();
        const box = gtk.Box.new(.horizontal, 0);
        const img = gtk.Image.newFromIconName(icon);

        gtk.Widget.setSizeRequest(img.as(gtk.Widget), ICON_SLOT, -1);
        gtk.Widget.setHalign(img.as(gtk.Widget), .center);
        gtk.Box.append(box, img.as(gtk.Widget));

        const label = gtk.Label.new(text);
        gtk.Widget.setMarginStart(label.as(gtk.Widget), LABEL_GAP);
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

    fn on_settings(btn: *gtk.Button, self: *ShellyWindow) callconv(.c) void {
        const p = self.private();
        gtk.Stack.setVisibleChildName(p.content_stack, "settings");
        if (gtk.Widget.getAncestor(btn.as(gtk.Widget), gtk.Popover.getGObjectType())) |pop| {
            gtk.Popover.popdown(@ptrCast(@alignCast(pop)));
        }
    }

    fn on_utilities(btn: *gtk.Button, self: *ShellyWindow) callconv(.c) void {
        const p = self.private();
        gtk.Stack.setVisibleChildName(p.content_stack, "utilities");
        if (gtk.Widget.getAncestor(btn.as(gtk.Widget), gtk.Popover.getGObjectType())) |pop| {
            gtk.Popover.popdown(@ptrCast(@alignCast(pop)));
        }
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
        self.private().flatpak_page = fp;
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
        const up_utils_page = gtk.Stack.addTitled(stack, up_utils.as(gtk.Widget), "utilities", translations._("Utilities"));
        gtk.StackPage.setIconName(up_utils_page, UtilitiesPage.icon_name);
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

    pub fn openFlatpakApp(self: *ShellyWindow, app_id: [:0]const u8) bool {
        if (!self.canShowTopLevelPage("flatpak"))
            return false;
        self.private().flatpak_page.openApp(app_id);
        return self.showTopLevelPage("flatpak");
    }

    pub fn navigateTo(self: *ShellyWindow, target: deep_link.PageTarget) bool {
        return switch (target) {
            .updates => self.showTopLevelPage("update"),

            .flatpak_install => blk: {
                if (!self.canShowTopLevelPage("flatpak"))
                    break :blk false;

                self.private().flatpak_page.navigateTo(.install);
                break :blk self.showTopLevelPage("flatpak");
            },

            .flatpak_remove => blk: {
                if (!self.canShowTopLevelPage("flatpak"))
                    break :blk false;

                self.private().flatpak_page.navigateTo(.remove);
                break :blk self.showTopLevelPage("flatpak");
            },
        };
    }

    const template_children = .{
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
        for (p.nav_buttons.items) |nb| {
            std.heap.c_allocator.destroy(nb);
        }
        p.nav_buttons.deinit(std.heap.c_allocator);
        if (p.rail) |rail| rail.as(gobject.Object).unref();
        if (p.topnav) |topnav| topnav.as(gobject.Object).unref();
        gobject.Object.virtual_methods.finalize.call(Class.parent, self.as(Parent));
    }
};
