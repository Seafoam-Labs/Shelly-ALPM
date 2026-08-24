const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gdk = bindings.gdk;
const gobject = bindings.gobject;
const glib = bindings.glib;
const ShellyCommands = @import("../services/shelly_operation.zig").ShellyCommands;
const ShellyCli = @import("../services/shelly_cli.zig").ShellyCli;
const support = @import("support.zig");
const ShellyWindow = @import("../shelly_window.zig").ShellyWindow;
const Toast = @import("../helpers/custom_ui_comps/toast.zig").Toast;
const translations = @import("../helpers/translations.zig");
const settings_layout = @import("../helpers/settings_layout.zig");

pub const UtilitiesPage = ShellyUtilitiesPage;

pub const ShellyUtilitiesPage = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gtk.Box;

    pub const title: [:0]const u8 = "Utilities";
    pub const icon_name: [:0]const u8 = "applications-engineering-symbolic";
    const resource_path = "/com/shellyorg/shelly/ui/utilities_page.ui";

    const Private = struct {
        page_overlay: *gtk.Overlay,
        utilities_settings_section: *gtk.Box,
        sync_button: *gtk.Button,
        rm_db_lock_button: *gtk.Button,
        fix_permissions_button: *gtk.Button,
        purify_button: *gtk.Button,
        clean_cache_button: *gtk.Button,
        cache_keep_spin: *gtk.SpinButton,

        toast: *Toast,
        surface: ?*gdk.Surface,
        surface_layout_handler: c_ulong,

        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyUtilitiesPage",
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
        p.surface = null;
        p.surface_layout_handler = 0;

        _ = gtk.Button.signals.clicked.connect(p.sync_button, *Self, &on_sync_db, self, .{});
        _ = gtk.Button.signals.clicked.connect(p.rm_db_lock_button, *Self, &on_remove_db_lock, self, .{});
        _ = gtk.Button.signals.clicked.connect(p.fix_permissions_button, *Self, &on_fix_permissions, self, .{});
        _ = gtk.Button.signals.clicked.connect(p.purify_button, *Self, &on_purify, self, .{});
        _ = gtk.Button.signals.clicked.connect(p.clean_cache_button, *Self, &on_clean_cache, self, .{});

        support.connectLifecycle(Self, self);

        const toast = Toast.new();
        gtk.Overlay.addOverlay(p.page_overlay, toast.as(gtk.Widget));
        p.toast = toast;
    }

    pub fn onMap(self: *Self) void {
        self.connectSurfaceLayout();
    }

    pub fn onUnmap(self: *Self) void {
        const p = self.priv();
        if (p.surface) |surface| {
            if (p.surface_layout_handler != 0) {
                gobject.signalHandlerDisconnect(surface.as(gobject.Object), p.surface_layout_handler);
            }
        }
        p.surface = null;
        p.surface_layout_handler = 0;
    }

    fn updateSettingsLayout(self: *Self, width: c_int) void {
        const section = self.priv().utilities_settings_section;
        if (settings_layout.usesWideLayout(width)) {
            gtk.Widget.addCssClass(section.as(gtk.Widget), "settings-section-wide");
        } else {
            gtk.Widget.removeCssClass(section.as(gtk.Widget), "settings-section-wide");
        }
    }

    fn connectSurfaceLayout(self: *Self) void {
        const p = self.priv();
        if (p.surface_layout_handler != 0) return;

        const native = gtk.Widget.getNative(self.as(gtk.Widget)) orelse return;
        const surface = gtk.Native.getSurface(native) orelse return;
        p.surface = surface;
        p.surface_layout_handler = gdk.Surface.signals.layout.connect(
            surface,
            *Self,
            &onSurfaceLayout,
            self,
            .{},
        );
        updateSettingsLayout(self, gdk.Surface.getWidth(surface));
    }

    fn onSurfaceLayout(_: *gdk.Surface, width: c_int, _: c_int, self: *Self) callconv(.c) void {
        updateSettingsLayout(self, width);
    }

    fn on_sync_db(_: *gtk.Button, self: *Self) callconv(.c) void {
        const argv = ShellyCommands.sync_db(std.heap.c_allocator) catch return;
        defer std.mem.Allocator.free(std.heap.c_allocator, argv);

        const win = support.getWindow(ShellyWindow, self) orelse return;
        win.startTransaction(.{
            .title = translations._("Refreshing package databases"),
            .argv = argv,
            .packages = &.{},
            .on_complete = &on_transaction_complete,
            .privileged = true,
            .ctx = self,
        });
    }

    fn on_remove_db_lock(_: *gtk.Button, self: *Self) callconv(.c) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();
        var threaded: std.Io.Threaded = .init(arena.allocator(), .{});
        defer threaded.deinit();

        const cli = ShellyCli{ .allocator = arena.allocator(), .io = threaded.io() };
        const parsed = cli.repair_db() catch |err| {
            std.log.err("utilities: repair-db failed: {any}", .{err});
            return;
        };
        defer parsed.deinit();

        const response = parsed.value;
        if (response.isSuccess()) {
            self.priv().toast.show(.success, translations._("Database lock removed successfully"));
        } else {
            self.priv().toast.show(.@"error", translations._("Failed to remove database lock"));
        }
    }

    fn on_fix_permissions(_: *gtk.Button, self: *Self) callconv(.c) void {
        const argv = ShellyCommands.fix_permissions(std.heap.c_allocator) catch return;
        defer std.mem.Allocator.free(std.heap.c_allocator, argv);

        const win = support.getWindow(ShellyWindow, self) orelse return;
        win.startTransaction(.{
            .title = translations._("Fixing permissions"),
            .argv = argv,
            .packages = &.{},
            .on_complete = &on_transaction_complete,
            .privileged = true,
            .ctx = self,
        });
    }

    fn on_purify(_: *gtk.Button, self: *Self) callconv(.c) void {
        const argv = ShellyCommands.purify(std.heap.c_allocator) catch return;
        defer std.mem.Allocator.free(std.heap.c_allocator, argv);

        const win = support.getWindow(ShellyWindow, self) orelse return;
        win.startTransaction(.{
            .title = translations._("Purifying packages"),
            .argv = argv,
            .packages = &.{},
            .on_complete = &on_transaction_complete,
            .privileged = true,
            .ctx = self,
        });
    }

    fn on_clean_cache(_: *gtk.Button, self: *Self) callconv(.c) void {
        const keep: usize = @intCast(gtk.SpinButton.getValueAsInt(self.priv().cache_keep_spin));

        var keep_buf: [16]u8 = undefined;
        const keep_str = std.fmt.bufPrint(&keep_buf, "{d}", .{keep}) catch return;

        const argv = ShellyCommands.clean_cache(std.heap.c_allocator, keep_str) catch return;
        defer std.mem.Allocator.free(std.heap.c_allocator, argv);

        const win = support.getWindow(ShellyWindow, self) orelse return;
        win.startTransaction(.{
            .title = translations._("Cleaning package cache"),
            .argv = argv,
            .packages = &.{},
            .on_complete = &on_transaction_complete,
            .privileged = true,
            .ctx = self,
        });
    }

    fn on_transaction_complete(ctx: *anyopaque, success: bool) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (success) {
            self.priv().toast.show(.success, translations._("Operation completed successfully"));
        } else {
            self.priv().toast.show(.@"error", translations._("Operation failed"));
        }
    }

    const template_children = .{
        .{ "page_overlay", @offsetOf(Private, "page_overlay") },
        .{ "utilities_settings_section", @offsetOf(Private, "utilities_settings_section") },
        .{ "sync_button", @offsetOf(Private, "sync_button") },
        .{ "rm_db_lock_button", @offsetOf(Private, "rm_db_lock_button") },
        .{ "fix_permissions_button", @offsetOf(Private, "fix_permissions_button") },
        .{ "purify_button", @offsetOf(Private, "purify_button") },
        .{ "clean_cache_button", @offsetOf(Private, "clean_cache_button") },
        .{ "cache_keep_spin", @offsetOf(Private, "cache_keep_spin") },
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
