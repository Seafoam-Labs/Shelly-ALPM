const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const glib = bindings.glib;
const gio = bindings.gio;
const gobject = bindings.gobject;
const support = @import("support.zig");
const translations = @import("../helpers/translations.zig");
const ConfirmDialog = @import("../dialog/page/yn_dialog.zig").ConfirmDialog;
const AurWarningDialog = @import("../dialog/page/aur_warning.zig").AurWarningDialog;
const ShellyWindow = @import("../shelly_window.zig").ShellyWindow;
const runtime = @import("../services/runtime.zig");
const ShellyCommands = @import("../services/shelly_operation.zig").ShellyCommands;
const support_packages = @import("../services/support_packages.zig");
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

    const SupportInstallContext = struct {
        window: *ShellyWindow,
        flatpak: bool,
        appimage: bool,
        started_transaction: bool = false,
        stage: enum {
            dependencies,
            backend_standard,
            backend_aur,
        } = .dependencies,
    };

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

        buildInternalOverlay(self);

        _ = gobject.Object.signals.notify.connect(
            p.source_aur.as(gobject.Object),
            *Self,
            &onAurNotify,
            self,
            .{ .detail = "active" },
        );
        _ = gobject.Object.signals.notify.connect(
            p.source_recommended.as(gobject.Object),
            *Self,
            &onRecommendedNotify,
            self,
            .{ .detail = "active" },
        );

        support.connectLifecycle(Self, self);
    }

    fn buildInternalOverlay(self: *Self) void {
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

    fn showInternalDialog(self: *Self, dialog: *gtk.Widget) void {
        const p = self.priv();
        const scrim = p.welcome_scrim orelse return;
        const host = p.welcome_dialog_host orelse return;
        while (gtk.Widget.getFirstChild(host.as(gtk.Widget))) |c|
            gtk.Box.remove(host, c);
        gtk.Box.append(host, dialog);
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

    fn onAurNotify(_: *gobject.Object, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.suppress_warnings) return;
        if (gtk.CheckButton.getActive(p.source_aur) == 0) return;

        gtk.CheckButton.setActive(p.source_aur, 0);

        const dialog = AurWarningDialog.new(&onAurResponse, self);
        self.showInternalDialog(dialog.as(gtk.Widget));
        dialog.focusCancel();
    }

    fn onAurResponse(ctx: ?*anyopaque, confirmed: bool) void {
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        self.hideInternalDialog();
        if (!confirmed) return;
        const p = self.priv();
        p.suppress_warnings = true;
        gtk.CheckButton.setActive(p.source_aur, 1);
        p.suppress_warnings = false;
    }

    fn onRecommendedNotify(_: *gobject.Object, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.suppress_warnings) return;
        if (gtk.CheckButton.getActive(p.source_recommended) == 0) return;

        gtk.CheckButton.setActive(p.source_recommended, 0);

        const dialog = ConfirmDialog.new(
            translations._("Enable Recommended?"),
            translations._("Recommended shows curated package suggestions based on your installed software. Package data is fetched from external sources."),
            &onRecommendedResponse,
            self,
        );
        dialog.setButtons(translations._("Enable"), translations._("Cancel"));
        self.showInternalDialog(dialog.as(gtk.Widget));
    }

    fn onRecommendedResponse(ctx: ?*anyopaque, confirmed: bool) void {
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        self.hideInternalDialog();
        if (!confirmed) return;
        const p = self.priv();
        p.suppress_warnings = true;
        gtk.CheckButton.setActive(p.source_recommended, 1);
        p.suppress_warnings = false;
    }

    fn onBack(self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.current_step > 0) {
            self.goToStep(p.current_step - 1);
        }
    }

    fn onNext(self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.current_step < num_steps - 1) {
            self.goToStep(p.current_step + 1);
        }
    }

    fn onFinish(self: *Self) callconv(.c) void {
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

        const flatpak_selected = gtk.CheckButton.getActive(p.source_flatpak) != 0;
        const appimage_selected = gtk.CheckButton.getActive(p.source_appimage) != 0;

        var updated = cfg.*;
        updated.AurEnabled = gtk.CheckButton.getActive(p.source_aur) != 0;
        updated.AurWarningConfirmed = updated.AurEnabled;
        updated.FlatPackEnabled = false;
        updated.AppImageEnabled = false;
        updated.RecommendedEnabled = gtk.CheckButton.getActive(p.source_recommended) != 0;
        updated.NavMode = if (gtk.CheckButton.getActive(p.nav_topbar) != 0) NavMode.topbar else NavMode.sidebar;
        updated.TrayEnabled = gtk.Switch.getActive(p.tray_enabled) != 0;
        updated.NewInstall = false;

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
            w.applyConfig();
            if (flatpak_selected or appimage_selected) {
                startSupportInstall(w, flatpak_selected, appimage_selected);
            } else {
                w.hideLockout();
            }
        }
    }

    fn startSupportInstall(window: *ShellyWindow, flatpak: bool, appimage: bool) void {
        var selected_buffer: [2][]const u8 = undefined;
        const selected = support_packages.selectedDependencies(&selected_buffer, flatpak, appimage);

        var package_buffer: [2][]const u8 = undefined;
        const packages = support_packages.missingPackages(
            std.heap.c_allocator,
            runtime.io,
            selected,
            &package_buffer,
        );

        const ctx = std.heap.c_allocator.create(SupportInstallContext) catch {
            window.hideLockout();
            return;
        };
        ctx.* = .{
            .window = window,
            .flatpak = flatpak,
            .appimage = appimage,
        };

        if (packages.len == 0) {
            onSupportInstallComplete(ctx, true);
            return;
        }

        const argv = ShellyCommands.install(std.heap.c_allocator, packages) catch {
            std.heap.c_allocator.destroy(ctx);
            window.hideLockout();
            return;
        };
        defer std.heap.c_allocator.free(argv);

        ctx.started_transaction = true;
        window.startTransaction(.{
            .title = supportInstallTitle(flatpak, appimage),
            .argv = argv,
            .packages = packages,
            .privileged = true,
            .on_complete = &onSupportInstallComplete,
            .ctx = ctx,
        });
    }

    fn onSupportInstallComplete(raw_ctx: *anyopaque, success: bool) void {
        const ctx: *SupportInstallContext = @ptrCast(@alignCast(raw_ctx));

        switch (ctx.stage) {
            .dependencies => {
                if (!success) {
                    std.heap.c_allocator.destroy(ctx);
                    return;
                }
                if (ctx.flatpak) {
                    ctx.stage = .backend_standard;
                    _ = glib.idleAdd(&startSupportBackendIdle, ctx);
                    return;
                }
            },
            .backend_standard => {
                if (!success) {
                    ctx.stage = .backend_aur;
                    _ = glib.idleAdd(&startSupportBackendIdle, ctx);
                    return;
                }
            },
            .backend_aur => if (!success) {
                std.heap.c_allocator.destroy(ctx);
                return;
            },
        }

        finishSupportInstall(ctx);
    }

    fn startSupportBackendIdle(data: ?*anyopaque) callconv(.c) c_int {
        const ctx: *SupportInstallContext = @ptrCast(@alignCast(data.?));
        const packages = &.{support_packages.flatpakBackendPackage()};

        var backend_buffer: [1][]const u8 = undefined;
        const missing = support_packages.missingPackages(std.heap.c_allocator, runtime.io, packages, &backend_buffer);
        if (missing.len == 0) {
            onSupportInstallComplete(ctx, true);
            return 0;
        }

        const argv = switch (ctx.stage) {
            .backend_standard => ShellyCommands.install(std.heap.c_allocator, packages),
            .backend_aur => ShellyCommands.install_aur(std.heap.c_allocator, packages),
            .dependencies => unreachable,
        } catch {
            std.heap.c_allocator.destroy(ctx);
            return 0;
        };
        defer std.heap.c_allocator.free(argv);

        ctx.started_transaction = true;
        ctx.window.startTransaction(.{
            .title = supportInstallTitle(true, false),
            .argv = argv,
            .packages = packages,
            .privileged = true,
            .on_complete = &onSupportInstallComplete,
            .ctx = ctx,
        });
        return 0;
    }

    fn finishSupportInstall(ctx: *SupportInstallContext) void {
        defer std.heap.c_allocator.destroy(ctx);
        if (!ctx.started_transaction) ctx.window.hideLockout();

        const svc = runtime.config orelse return;
        const cfg = svc.get() catch return;
        var updated = cfg.*;
        if (ctx.flatpak) updated.FlatPackEnabled = true;
        if (ctx.appimage) updated.AppImageEnabled = true;
        svc.set(updated) catch |err| {
            std.log.err("welcome: failed to enable installed support: {}", .{err});
            return;
        };
        svc.save() catch |err| {
            std.log.err("welcome: failed to save installed support: {}", .{err});
            return;
        };
        ctx.window.applyConfig();
    }

    fn supportInstallTitle(flatpak: bool, appimage: bool) [:0]const u8 {
        if (flatpak and appimage)
            return translations._("Installing Flatpak and AppImage support");
        if (flatpak)
            return translations._("Installing Flatpak support");
        return translations._("Installing AppImage support");
    }

    fn goToStep(self: *Self, step: u8) void {
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
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_back", @ptrCast(&onBack));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_next", @ptrCast(&onNext));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_finish", @ptrCast(&onFinish));
        }
    };
};
