const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const glib = bindings.glib;
const gio = bindings.gio;
const gobject = bindings.gobject;
const support = @import("support.zig");
const translations = @import("../helpers/translations.zig");
const ConfirmDialog = @import("../dialog/page/yn_dialog.zig").ConfirmDialog;
const ShellyWindow = @import("../shelly_window.zig").ShellyWindow;
const runtime = @import("../services/runtime.zig");
const ShellyConfig = @import("../models/shelly_config.zig").ShellyConfig;
const NavMode = @import("../models/shelly_config.zig").NavMode;
const TrayService = @import("../services/tray_service.zig");

pub const WelcomePage = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gtk.Box;

    pub const title: [:0]const u8 = translations._("Welcome");
    pub const icon_name: [:0]const u8 = "software-update-available-symbolic";
    const resource_path = "/com/shellyorg/shelly/ui/welcome.ui";

    const num_steps: u8 = 3;

    const Private = struct {
        arena: ?*std.heap.ArenaAllocator,
        welcome_stack: *gtk.Stack,
        welcome_image: *gtk.Image,
        welcome_title: *gtk.Label,
        welcome_blurb: *gtk.Label,
        welcome_spinner: *gtk.Spinner,
        source_aur: *gtk.CheckButton,
        source_flatpak: *gtk.CheckButton,
        source_appimage: *gtk.CheckButton,
        source_recommended: *gtk.CheckButton,
        tray_enabled: *gtk.Switch,
        nav_sidebar: *gtk.CheckButton,
        nav_topbar: *gtk.CheckButton,
        nav_bar: *gtk.Box,
        page_welcome: *gtk.Box,
        page_sources: *gtk.Box,
        page_appearance: *gtk.Box,
        btn_back: *gtk.Button,
        btn_next: *gtk.Button,
        btn_finish: *gtk.Button,

        welcome_scrim: ?*gtk.Box,
        welcome_dialog_host: ?*gtk.Box,
        current_step: u8,
        loaded: bool,
        suppress_warnings: bool,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyWelcomePage",
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
        p.arena = null;
        p.current_step = 0;
        p.loaded = false;
        p.suppress_warnings = false;
        p.welcome_scrim = null;
        p.welcome_dialog_host = null;

        build_internal_overlay(self);

        _ = gobject.Object.signals.notify.connect(
            p.source_aur.as(gobject.Object),
            *Self,
            &on_aur_notify,
            self,
            .{ .detail = "active" },
        );
        _ = gobject.Object.signals.notify.connect(
            p.source_recommended.as(gobject.Object),
            *Self,
            &on_recommended_notify,
            self,
            .{ .detail = "active" },
        );

        support.connectLifecycle(Self, self);
    }

    fn build_internal_overlay(self: *Self) void {
        const p = self.priv();

        const overlay = gtk.Overlay.new();
        gtk.Widget.setHexpand(overlay.as(gtk.Widget), 1);
        gtk.Widget.setVexpand(overlay.as(gtk.Widget), 1);
        const inner = gtk.Box.new(.vertical, 0);
        gtk.Widget.setHexpand(inner.as(gtk.Widget), 1);
        gtk.Widget.setVexpand(inner.as(gtk.Widget), 1);

        gtk.Box.remove(self.as(gtk.Box), p.welcome_stack.as(gtk.Widget));
        gtk.Box.remove(self.as(gtk.Box), p.nav_bar.as(gtk.Widget));
        gtk.Box.append(inner, p.welcome_stack.as(gtk.Widget));
        gtk.Box.append(inner, p.nav_bar.as(gtk.Widget));

        gtk.Overlay.setChild(overlay, inner.as(gtk.Widget));

        const scrim = gtk.Box.new(.vertical, 0);
        gtk.Widget.addCssClass(scrim.as(gtk.Widget), "lockout-scrim");
        gtk.Widget.setHexpand(scrim.as(gtk.Widget), 1);
        gtk.Widget.setVexpand(scrim.as(gtk.Widget), 1);
        gtk.Widget.setHalign(scrim.as(gtk.Widget), .fill);
        gtk.Widget.setValign(scrim.as(gtk.Widget), .fill);
        gtk.Widget.setVisible(scrim.as(gtk.Widget), 0);

        const host = gtk.Box.new(.vertical, 0);
        gtk.Widget.setHalign(host.as(gtk.Widget), .center);
        gtk.Widget.setValign(host.as(gtk.Widget), .center);
        gtk.Widget.setHexpand(host.as(gtk.Widget), 1);
        gtk.Widget.setVexpand(host.as(gtk.Widget), 1);
        gtk.Box.append(scrim, host.as(gtk.Widget));

        gtk.Overlay.addOverlay(overlay, scrim.as(gtk.Widget));

        p.welcome_scrim = scrim;
        p.welcome_dialog_host = host;

        gtk.Box.append(self.as(gtk.Box), overlay.as(gtk.Widget));
    }

    pub fn onMap(self: *Self) void {
        _ = self;
    }

    pub fn onUnmap(self: *Self) void {
        _ = self;
    }

    fn showInternalDialog(self: *Self, dialog: *ConfirmDialog) void {
        const p = self.priv();
        const scrim = p.welcome_scrim orelse return;
        const host = p.welcome_dialog_host orelse return;
        while (gtk.Widget.getFirstChild(host.as(gtk.Widget))) |c|
            gtk.Box.remove(host, c);
        gtk.Box.append(host, dialog.as(gtk.Widget));
        gtk.Widget.setVisible(scrim.as(gtk.Widget), 1);
    }

    fn hideInternalDialog(self: *Self) void {
        const p = self.priv();
        const scrim = p.welcome_scrim orelse return;
        const host = p.welcome_dialog_host orelse return;
        while (gtk.Widget.getFirstChild(host.as(gtk.Widget))) |c|
            gtk.Box.remove(host, c);
        gtk.Widget.setVisible(scrim.as(gtk.Widget), 0);
    }

    fn on_aur_notify(_: *gobject.Object, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.suppress_warnings) return;
        if (gtk.CheckButton.getActive(p.source_aur) == 0) return;

        gtk.CheckButton.setActive(p.source_aur, 0);

        const dialog = ConfirmDialog.new(
            translations._("Enable AUR?"),
            translations._("The Arch User Repository is community-maintained. Packages are not officially vetted — only enable if you trust what you install."),
            &on_aur_response,
            self,
        );
        dialog.setButtons(translations._("Enable"), translations._("Cancel"));
        self.showInternalDialog(dialog);
    }

    fn on_aur_response(ctx: ?*anyopaque, confirmed: bool) void {
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        self.hideInternalDialog();
        if (!confirmed) return;
        const p = self.priv();
        p.suppress_warnings = true;
        gtk.CheckButton.setActive(p.source_aur, 1);
        p.suppress_warnings = false;
    }
    fn on_recommended_notify(_: *gobject.Object, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.suppress_warnings) return;
        if (gtk.CheckButton.getActive(p.source_recommended) == 0) return;

        gtk.CheckButton.setActive(p.source_recommended, 0);

        const dialog = ConfirmDialog.new(
            translations._("Enable Recommended?"),
            translations._("Recommended shows curated package suggestions based on your installed software. Package data is fetched from external sources."),
            &on_recommended_response,
            self,
        );
        dialog.setButtons(translations._("Enable"), translations._("Cancel"));
        self.showInternalDialog(dialog);
    }

    fn on_recommended_response(ctx: ?*anyopaque, confirmed: bool) void {
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        self.hideInternalDialog();
        if (!confirmed) return;
        const p = self.priv();
        p.suppress_warnings = true;
        gtk.CheckButton.setActive(p.source_recommended, 1);
        p.suppress_warnings = false;
    }

    fn on_back(self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.current_step > 0) {
            self.go_to_step(p.current_step - 1);
        }
    }

    fn on_next(self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.current_step < num_steps - 1) {
            self.go_to_step(p.current_step + 1);
        }
    }

    fn on_finish(self: *Self) callconv(.c) void {
        const p = self.priv();
        const win = support.getWindow(ShellyWindow, self);

        const svc = runtime.config orelse {
            if (win) |w| w.hideLockout();
            return;
        };
        const cfg = svc.get() catch {
            if (win) |w| w.hideLockout();
            return;
        };

        var updated = cfg.*;
        updated.AurEnabled = gtk.CheckButton.getActive(p.source_aur) != 0;
        updated.AurWarningConfirmed = updated.AurEnabled;
        updated.FlatPackEnabled = gtk.CheckButton.getActive(p.source_flatpak) != 0;
        updated.AppImageEnabled = gtk.CheckButton.getActive(p.source_appimage) != 0;
        updated.RecommendedEnabled = gtk.CheckButton.getActive(p.source_recommended) != 0;
        updated.NavMode = if (gtk.CheckButton.getActive(p.nav_topbar) != 0) NavMode.topbar else NavMode.sidebar;
        updated.TrayEnabled = gtk.Switch.getActive(p.tray_enabled) != 0;
        updated.NewInstall = false;
        updated.NewInstallInitSettings = true;

        if (gtk.Switch.getActive(p.tray_enabled) != 0) {
            TrayService.start(runtime.io, std.heap.c_allocator);
        }

        svc.set(updated) catch |err| {
            std.log.err("welcome: failed to apply config: {}", .{err});
        };
        svc.save() catch |err| {
            std.log.err("welcome: failed to save config: {}", .{err});
        };

        if (win) |w| {
            w.hideLockout();
            w.applyConfig();
        }
    }

    fn go_to_step(self: *Self, step: u8) void {
        const p = self.priv();
        p.current_step = step;

        const pages = [num_steps]*gtk.Widget{
            p.page_welcome.as(gtk.Widget),
            p.page_sources.as(gtk.Widget),
            p.page_appearance.as(gtk.Widget),
        };
        gtk.Stack.setVisibleChild(p.welcome_stack, pages[step]);

        gtk.Widget.setSensitive(p.btn_back.as(gtk.Widget), @intFromBool(step > 0));

        const on_last = step == num_steps - 1;
        gtk.Widget.setVisible(p.btn_next.as(gtk.Widget), @intFromBool(!on_last));
        gtk.Widget.setVisible(p.btn_finish.as(gtk.Widget), @intFromBool(on_last));
    }

    const template_children = .{
        .{ "welcome_stack", @offsetOf(Private, "welcome_stack") },
        .{ "welcome_image", @offsetOf(Private, "welcome_image") },
        .{ "welcome_title", @offsetOf(Private, "welcome_title") },
        .{ "welcome_blurb", @offsetOf(Private, "welcome_blurb") },
        .{ "welcome_spinner", @offsetOf(Private, "welcome_spinner") },
        .{ "source_aur", @offsetOf(Private, "source_aur") },
        .{ "source_flatpak", @offsetOf(Private, "source_flatpak") },
        .{ "source_appimage", @offsetOf(Private, "source_appimage") },
        .{ "source_recommended", @offsetOf(Private, "source_recommended") },
        .{ "tray_enabled", @offsetOf(Private, "tray_enabled") },
        .{ "nav_sidebar", @offsetOf(Private, "nav_sidebar") },
        .{ "nav_topbar", @offsetOf(Private, "nav_topbar") },
        .{ "nav_bar", @offsetOf(Private, "nav_bar") },
        .{ "page_welcome", @offsetOf(Private, "page_welcome") },
        .{ "page_sources", @offsetOf(Private, "page_sources") },
        .{ "page_appearance", @offsetOf(Private, "page_appearance") },
        .{ "btn_back", @offsetOf(Private, "btn_back") },
        .{ "btn_next", @offsetOf(Private, "btn_next") },
        .{ "btn_finish", @offsetOf(Private, "btn_finish") },
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
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_back", @ptrCast(&on_back));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_next", @ptrCast(&on_next));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_finish", @ptrCast(&on_finish));
        }
    };
};
