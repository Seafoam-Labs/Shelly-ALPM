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
const SupportPage = @import("pages/support.zig");
const ShellySettingsWindow = @import("windows/settings_window.zig").ShellySettingsWindow;

const NavButton = struct {
    button: *gtk.Button,
    revealer: *gtk.Revealer,
    stack: *gtk.Stack,
    name: [:0]const u8,
};

pub const ShellyWindow = extern struct {
    parent_instance: Parent,

    pub const Parent = gtk.ApplicationWindow;
    pub const NavMode = enum { sidebar, topbar };

    const ICON_SLOT: c_int = 24;
    const LABEL_GAP: c_int = 8;

    const Private = struct {
        shell_box: *gtk.Box,
        lockout_overlay: *gtk.Box,
        lockout_content: *gtk.Box,
        content_stack: *gtk.Stack,
        rail: ?*gtk.Box,
        chevron_img: ?*gtk.Image,
        nav_buttons: std.ArrayListUnmanaged(*NavButton),
        collapsed: bool,
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
        p.chevron_img = null;
        p.nav_buttons = .empty;
        p.collapsed = true;
        build_shell(self, readNavMode());
        populate_stack(self);
    }

    fn readNavMode() NavMode {
        return .sidebar;
    }

    fn build_shell(self: *ShellyWindow, mode: NavMode) void {
        const p = self.private();

        const stack = gtk.Stack.new();
        gtk.Widget.setHexpand(stack.as(gtk.Widget), 1);
        gtk.Widget.setVexpand(stack.as(gtk.Widget), 1);
        p.content_stack = stack;

        switch (mode) {
            .sidebar => {
                gtk.Orientable.setOrientation(p.shell_box.as(gtk.Orientable), .horizontal);
                const rail = build_rail(self, stack);
                const sep = gtk.Separator.new(.vertical);
                gtk.Box.append(p.shell_box, rail.as(gtk.Widget));
                gtk.Box.append(p.shell_box, sep.as(gtk.Widget));
                gtk.Box.append(p.shell_box, stack.as(gtk.Widget));
            },
            .topbar => {
                gtk.Orientable.setOrientation(p.shell_box.as(gtk.Orientable), .vertical);
                const switcher = gtk.StackSwitcher.new();
                gtk.StackSwitcher.setStack(switcher, stack);
                gtk.Orientable.setOrientation(switcher.as(gtk.Orientable), .horizontal);
                const sep = gtk.Separator.new(.horizontal);

                gtk.Box.append(p.shell_box, switcher.as(gtk.Widget));
                gtk.Box.append(p.shell_box, sep.as(gtk.Widget));
                gtk.Box.append(p.shell_box, stack.as(gtk.Widget));
            },
        }
    }

    fn build_rail(self: *ShellyWindow, stack: *gtk.Stack) *gtk.Box {
        const p = self.private();
        const rail = gtk.Box.new(.vertical, 4);
        gtk.Widget.addCssClass(rail.as(gtk.Widget), "nav-rail");
        p.rail = rail;

        const chevron = gtk.Button.new();
        gtk.Widget.addCssClass(chevron.as(gtk.Widget), "flat");
        const chevron_img = gtk.Image.newFromIconName(if (p.collapsed) "go-next-symbolic" else "go-previous-symbolic");

        gtk.Widget.setSizeRequest(chevron_img.as(gtk.Widget), ICON_SLOT, -1);
        gtk.Widget.setHalign(chevron_img.as(gtk.Widget), .center);
        gtk.Button.setChild(chevron, chevron_img.as(gtk.Widget));
        p.chevron_img = chevron_img;
        _ = gtk.Button.signals.clicked.connect(chevron, *ShellyWindow, &on_chevron, self, .{});
        gtk.Box.append(rail, chevron.as(gtk.Widget));

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
        gtk.Widget.setMarginStart(menu_box.as(gtk.Widget), 8);
        gtk.Widget.setMarginEnd(menu_box.as(gtk.Widget), 8);
        gtk.Widget.setMarginTop(menu_box.as(gtk.Widget), 8);
        gtk.Widget.setMarginBottom(menu_box.as(gtk.Widget), 8);

        const settings_btn = gtk.Button.newWithLabel("Settings");
        gtk.Widget.addCssClass(settings_btn.as(gtk.Widget), "flat");
        _ = gtk.Button.signals.clicked.connect(settings_btn, *ShellyWindow, &on_settings, self, .{});
        gtk.Box.append(menu_box, settings_btn.as(gtk.Widget));

        const utils_btn = gtk.Button.newWithLabel("Utilities");
        gtk.Widget.addCssClass(utils_btn.as(gtk.Widget), "flat");
        //    _ = gtk.Button.signals.clicked.connect(utils_btn, *ShellyWindow, &on_utils, self, .{});
        gtk.Box.append(menu_box, utils_btn.as(gtk.Widget));

        gtk.Popover.setChild(popover, menu_box.as(gtk.Widget));
        gtk.MenuButton.setPopover(menu_button, popover);

        gtk.Box.append(rail, menu_button.as(gtk.Widget));

        return rail;
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
        nb.* = .{ .button = btn, .revealer = revealer, .stack = stack, .name = name };
        p.nav_buttons.append(std.heap.c_allocator, nb) catch unreachable;

        _ = gtk.Button.signals.clicked.connect(btn, *NavButton, &on_nav_click, nb, .{});
        gtk.Box.append(rail, btn.as(gtk.Widget));
    }

    fn on_nav_click(_: *gtk.Button, nb: *NavButton) callconv(.c) void {
        gtk.Stack.setVisibleChildName(nb.stack, nb.name);
    }

    fn on_settings(_: *gtk.Button, self: *ShellyWindow) callconv(.c) void {
        const settings = ShellySettingsWindow.new(self.as(gtk.Window));
        gtk.Window.present(settings.as(gtk.Window));
    }

    fn on_chevron(_: *gtk.Button, self: *ShellyWindow) callconv(.c) void {
        const p = self.private();
        p.collapsed = !p.collapsed;
        for (p.nav_buttons.items) |nb| {
            gtk.Revealer.setRevealChild(nb.revealer, @intFromBool(!p.collapsed));
        }
        if (p.chevron_img) |img| {
            gtk.Image.setFromIconName(img, if (p.collapsed) "go-next-symbolic" else "go-previous-symbolic");
        }
    }

    fn populate_stack(self: *ShellyWindow) void {
        const stack = self.private().content_stack;

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
        }

        pub fn as(class: *Class, comptime T: type) *T {
            return gobject.ext.as(T, class);
        }
    };
};
