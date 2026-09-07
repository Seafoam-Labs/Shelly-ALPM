const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gobject = bindings.gobject;
const glib = bindings.glib;
const ShellyCommands = @import("../services/shelly_operation.zig").ShellyCommands;
const ShellyCli = @import("../services/shelly_cli.zig").ShellyCli;
const support = @import("support.zig");
const ShellyWindow = @import("../shelly_window.zig").ShellyWindow;
const Toast = @import("../helpers/custom_ui_comps/toast.zig").Toast;
const translations = @import("../helpers/translations.zig");

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
        sync_button: *gtk.Button,
        rm_db_lock_button: *gtk.Button,
        fix_permissions_button: *gtk.Button,
        purify_button: *gtk.Button,
        clean_cache_button: *gtk.Button,
        cache_keep_spin: *gtk.SpinButton,

        toast: *Toast,

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

    pub fn onMap(_: *Self) void {}

    pub fn onUnmap(_: *Self) void {}

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

        var failure_detail: ?[]u8 = null;
        const cli = ShellyCli{ .allocator = arena.allocator(), .io = threaded.io(), .failure_detail = &failure_detail };
        const parsed = cli.repair_db() catch |err| {
            std.log.err("utilities: repair-db failed: {any}", .{err});
            const message = arena.allocator().dupeZ(u8, failure_detail orelse "Could not remove the database lock. No error details were returned by Shelly.") catch return;
            self.priv().toast.show(.@"error", message);
            return;
        };
        defer parsed.deinit();

        const response = parsed.value;
        if (response.isSuccess()) {
            self.priv().toast.show(.success, translations._("Database lock removed successfully"));
        } else {
            const message = arena.allocator().dupeZ(u8, response.text()) catch return;
            self.priv().toast.show(.@"error", message);
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
