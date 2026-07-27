const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gio = bindings.gio;
const gobject = bindings.gobject;
const FlatpakPage = @import("pages/flatpak/flatpak_page.zig").FlatpakPage;
const AppImagePage = @import("pages/appimage_page.zig").AppImagePage;
const PackagePage = @import("pages/package_page.zig").PackagePage;
const AurPage = @import("pages/aur_page.zig").AurPage;
const UpdatePage = @import("pages/update_page.zig").UpdatePage;
const RecommendPage = @import("pages/recommend_page.zig").RecommendPage;
const SupportPage = @import("pages/support.zig");
const SettingsPage = @import("pages/settings_page.zig").SettingsPage;
const TransactionPage = @import("pages/transaction_page.zig").TransactionPage;
const TransactionRequest = @import("pages/transaction_page.zig").TransactionRequest;
const runtime = @import("services/runtime.zig");
const NavMode = @import("models/shelly_config.zig").NavMode;
const ShellyTabs = @import("models/shelly_config.zig").ShellyTabs;

const NavButton = struct {
    button: *gtk.Button,
    revealer: *gtk.Revealer,
    stack: *gtk.Stack,
    name: [:0]const u8,
    window: *ShellyWindow,
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
        switcher: ?*gtk.StackSwitcher,
        chevron_img: ?*gtk.Image,
        nav_buttons: std.ArrayListUnmanaged(*NavButton),
        collapsed: bool,
        nav_mode: NavMode,
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
        p.switcher = null;
        p.chevron_img = null;
        p.nav_buttons = .empty;
        p.collapsed = true;
        p.nav_mode = .sidebar;
        build_shell(self);
        populate_stack(self);
        applyConfig(self);
    }

    pub fn applyConfig(self: *ShellyWindow) void {
        const svc = runtime.config orelse return;
        const cfg = svc.get() catch return;

        setNavEnabled(self, "recommend", cfg.RecommendedEnabled);
        setNavEnabled(self, "aur", cfg.AurEnabled);
        setNavEnabled(self, "flatpak", cfg.FlatPackEnabled);
        setNavEnabled(self, "appimage", cfg.AppImageEnabled);

        self.changeNav(cfg.NavMode);
        applyDefaultPage(self);
    }

    fn setNavEnabled(self: *ShellyWindow, name: [:0]const u8, enabled: bool) void {
        const p = self.private();

        var nb_opt: ?*NavButton = null;
        for (p.nav_buttons.items) |nb| {
            if (std.mem.eql(u8, nb.name, name)) {
                nb_opt = nb;
                break;
            }
        }
        const nb = nb_opt orelse return;
        const visible: c_int = @intFromBool(enabled);

        gtk.Widget.setVisible(nb.button.as(gtk.Widget), visible);

        if (gtk.Stack.getChildByName(nb.stack, name)) |child| {
            const page = gtk.Stack.getPage(nb.stack, child);
            gtk.StackPage.setVisible(page, visible);
        }

        if (enabled) return;

        const cn_opt = gtk.Stack.getVisibleChildName(nb.stack);
        const is_active = if (cn_opt) |cn| std.mem.eql(u8, std.mem.span(cn), name) else false;
        if (!is_active) return;

        gtk.Stack.setVisibleChildName(nb.stack, "package");
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

        layoutNav(self, readNavMode());
    }

    fn readNavMode() NavMode {
        const svc = runtime.config orelse return .sidebar;
        const cfg = svc.get() catch return .sidebar;
        return cfg.NavMode;
    }

    pub fn changeNav(self: *ShellyWindow, mode: NavMode) void {
        if (self.private().nav_mode == mode) return;
        layoutNav(self, mode);
    }

    fn layoutNav(self: *ShellyWindow, mode: NavMode) void {
        const p = self.private();
        p.nav_mode = mode;

        removeFromShell(p, p.content_stack.as(gtk.Widget));
        if (p.rail) |rail| removeFromShell(p, rail.as(gtk.Widget));
        if (p.switcher) |switcher| {
            removeFromShell(p, switcher.as(gtk.Widget));
            p.switcher = null;
        }

        switch (mode) {
            .sidebar => {
                if (p.rail == null) _ = build_rail(self, p.content_stack);
                gtk.Orientable.setOrientation(p.shell_box.as(gtk.Orientable), .horizontal);
                gtk.Box.append(p.shell_box, p.rail.?.as(gtk.Widget));
                gtk.Box.append(p.shell_box, p.content_stack.as(gtk.Widget));
                sync_active_nav(self);
            },
            .topbar => {
                const switcher = gtk.StackSwitcher.new();
                gtk.StackSwitcher.setStack(switcher, p.content_stack);
                gtk.Orientable.setOrientation(switcher.as(gtk.Orientable), .horizontal);
                p.switcher = switcher;
                gtk.Orientable.setOrientation(p.shell_box.as(gtk.Orientable), .vertical);
                gtk.Box.append(p.shell_box, switcher.as(gtk.Widget));
                gtk.Box.append(p.shell_box, p.content_stack.as(gtk.Widget));
            },
        }
    }

    fn removeFromShell(p: *Private, child: *gtk.Widget) void {
        const parent = gtk.Widget.getParent(child) orelse return;
        if (parent == p.shell_box.as(gtk.Widget)) {
            gtk.Box.remove(p.shell_box, child);
        }
    }

    fn build_rail(self: *ShellyWindow, stack: *gtk.Stack) *gtk.Box {
        const p = self.private();
        const rail = gtk.Box.new(.vertical, 4);
        gtk.Widget.addCssClass(rail.as(gtk.Widget), "nav-rail");
        // Hold our own reference: removeFromShell drops the shell's reference,
        // which would destroy the rail when switching modes.
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

        add_nav_button(self, rail, stack, "recommend", RecommendPage.icon_name, RecommendPage.title);
        add_nav_button(self, rail, stack, "package", PackagePage.icon_name, PackagePage.title);
        add_nav_button(self, rail, stack, "aur", AurPage.icon_name, AurPage.title);
        add_nav_button(self, rail, stack, "flatpak", FlatpakPage.icon_name, FlatpakPage.title);
        add_nav_button(self, rail, stack, "appimage", AppImagePage.icon_name, AppImagePage.title);
        add_nav_button(self, rail, stack, "update", UpdatePage.icon_name, UpdatePage.title);

        const sep = gtk.Box.new(.horizontal, 0);
        gtk.Widget.setVexpand(sep.as(gtk.Widget), 1);
        gtk.Box.append(rail, sep.as(gtk.Widget));

        const menu_button = gtk.MenuButton.new();
        gtk.Widget.addCssClass(menu_button.as(gtk.Widget), "flat");
        gtk.MenuButton.setIconName(menu_button, "open-menu-symbolic");

        const popover = gtk.Popover.new();

        const menu_box = gtk.Box.new(.vertical, 4);

        const utils_btn = gtk.Button.newWithLabel("Utilities");
        gtk.Widget.addCssClass(utils_btn.as(gtk.Widget), "flat");
        //    _ = gtk.Button.signals.clicked.connect(utils_btn, *ShellyWindow, &on_utils, self, .{});
        gtk.Box.append(menu_box, utils_btn.as(gtk.Widget));

        const sp_btn = gtk.Button.newWithLabel("Settings");
        gtk.Widget.addCssClass(sp_btn.as(gtk.Widget), "flat");
        _ = gtk.Button.signals.clicked.connect(sp_btn, *ShellyWindow, &on_settings, self, .{});
        gtk.Box.append(menu_box, sp_btn.as(gtk.Widget));

        gtk.Popover.setChild(popover, menu_box.as(gtk.Widget));
        gtk.MenuButton.setPopover(menu_button, popover);

        gtk.Box.append(rail, menu_button.as(gtk.Widget));

        return rail;
    }

    fn on_chevron(_: *gtk.Button, self: *ShellyWindow) callconv(.c) void {
        const p = self.private();
        p.collapsed = !p.collapsed;

        if (p.chevron_img) |img| {
            gtk.Image.setFromIconName(img, if (p.collapsed) "go-next-symbolic" else "go-previous-symbolic");
        }

        for (p.nav_buttons.items) |nb| {
            gtk.Revealer.setRevealChild(nb.revealer, @intFromBool(!p.collapsed));
        }
    }

    fn add_nav_button(self: *ShellyWindow, rail: *gtk.Box, stack: *gtk.Stack, name: [:0]const u8, icon: [:0]const u8, text: [:0]const u8) void {
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
        gtk.Revealer.setTransitionType(revealer, .slide_right);
        gtk.Revealer.setChild(revealer, label.as(gtk.Widget));
        gtk.Revealer.setRevealChild(revealer, @intFromBool(!p.collapsed));
        gtk.Box.append(box, revealer.as(gtk.Widget));

        const btn = gtk.Button.new();
        gtk.Button.setChild(btn, box.as(gtk.Widget));
        gtk.Widget.addCssClass(btn.as(gtk.Widget), "flat");
        gtk.Widget.addCssClass(btn.as(gtk.Widget), "nav-btn");

        const nb = std.heap.c_allocator.create(NavButton) catch unreachable;
        nb.* = .{ .button = btn, .revealer = revealer, .stack = stack, .name = name, .window = self };
        p.nav_buttons.append(std.heap.c_allocator, nb) catch unreachable;

        _ = gtk.Button.signals.clicked.connect(btn, *NavButton, &on_nav_click, nb, .{});
        gtk.Box.append(rail, btn.as(gtk.Widget));
    }

    fn on_nav_click(_: *gtk.Button, nb: *NavButton) callconv(.c) void {
        gtk.Stack.setVisibleChildName(nb.stack, nb.name);
        set_active_nav(nb.window, nb);
    }

    fn set_active_nav(self: *ShellyWindow, active: *NavButton) void {
        const p = self.private();
        for (p.nav_buttons.items) |nb| {
            if (nb == active) {
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
            .shelly_search => null,
        };
    }

    fn applyDefaultPage(self: *ShellyWindow) void {
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

    fn populate_stack(self: *ShellyWindow) void {
        const stack = self.private().content_stack;

        const rp = RecommendPage.new();
        const rp_page = gtk.Stack.addTitled(stack, rp.as(gtk.Widget), "recommend", RecommendPage.title);
        gtk.StackPage.setIconName(rp_page, RecommendPage.icon_name);

        const pp = PackagePage.new();
        const pp_page = gtk.Stack.addTitled(stack, pp.as(gtk.Widget), "package", PackagePage.title);
        gtk.StackPage.setIconName(pp_page, PackagePage.icon_name);

        const fp = FlatpakPage.new();
        const fp_page = gtk.Stack.addTitled(stack, fp.as(gtk.Widget), "flatpak", FlatpakPage.title);
        gtk.StackPage.setIconName(fp_page, FlatpakPage.icon_name);

        const ai = AppImagePage.new();
        const ai_page = gtk.Stack.addTitled(stack, ai.as(gtk.Widget), "appimage", AppImagePage.title);
        gtk.StackPage.setIconName(ai_page, AppImagePage.icon_name);

        const au = AurPage.new();
        const au_page = gtk.Stack.addTitled(stack, au.as(gtk.Widget), "aur", AurPage.title);
        gtk.StackPage.setIconName(au_page, AurPage.icon_name);

        const up = UpdatePage.new();
        const up_page = gtk.Stack.addTitled(stack, up.as(gtk.Widget), "update", UpdatePage.title);
        gtk.StackPage.setIconName(up_page, UpdatePage.icon_name);

        const sp = SettingsPage.new();
        const sp_page = gtk.Stack.addTitled(stack, sp.as(gtk.Widget), "settings", SettingsPage.title);
        gtk.StackPage.setIconName(sp_page, SettingsPage.icon_name);
    }

    pub fn showLockout(self: *ShellyWindow, content: *gtk.Widget) void {
        const p = self.private();
        while (gtk.Widget.getFirstChild(p.lockout_content.as(gtk.Widget))) |c| {
            gtk.Box.remove(p.lockout_content, c);
        }
        gtk.Box.append(p.lockout_content, content);
        gtk.Widget.setVisible(p.lockout_overlay.as(gtk.Widget), 1);
    }

    pub fn hideLockout(self: *ShellyWindow) void {
        const p = self.private();
        while (gtk.Widget.getFirstChild(p.lockout_content.as(gtk.Widget))) |c| {
            gtk.Box.remove(p.lockout_content, c);
        }
        gtk.Widget.setVisible(p.lockout_overlay.as(gtk.Widget), 0);
    }
    pub fn startTransaction(self: *ShellyWindow, request: TransactionRequest) void {
        const tp = TransactionPage.new();
        self.showLockout(tp.as(gtk.Widget));
        tp.run(request);
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
        if (p.rail) |rail| rail.as(gobject.Object).unref();
        gobject.Object.virtual_methods.finalize.call(Class.parent, self.as(Parent));
    }
};
