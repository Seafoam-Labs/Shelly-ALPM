const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const glib = bindings.glib;
const gio = bindings.gio;
const gobject = bindings.gobject;
const support = @import("../support.zig");
const cstr = @import("../../helpers/c_string.zig").cstr;

const ShellyCli = @import("../../services/shelly_cli.zig").ShellyCli;
const Remote = @import("../../models/flatpak.zig").Remote;
const ShellyWindow = @import("../../shelly_window.zig").ShellyWindow;
const translations = @import("../../helpers/translations.zig");
const ShellyCommands = @import("../../services/shelly_operation.zig").ShellyCommands;

pub const FlatpakInstallLocalView = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gtk.Box;
    const resource_path = "/com/shellyorg/shelly/ui/flatpak/flatpak_install_local.ui";

    const Private = struct {
        choose_file_button: *gtk.Button,
        chosen_file_label: *gtk.Label,
        scope_dropdown: *gtk.DropDown,
        install_button: *gtk.Button,
        status_label: *gtk.Label,
        selected_path: ?[:0]u8,
        loaded: bool,
        disposed: bool,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyFlatpakInstallLocalView",
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
        p.selected_path = null;
        p.loaded = false;
        p.disposed = false;
        _ = gtk.Button.signals.clicked.connect(p.choose_file_button, *Self, &onChooseClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(p.install_button, *Self, &onInstallClicked, self, .{});
        support.connectLifecycle(Self, self);
    }

    pub fn onMap(self: *Self) void {
        const p = self.priv();
        if (p.loaded) return;
        p.loaded = true;
    }

    pub fn onUnmap(self: *Self) void {
        const p = self.priv();
        if (!p.loaded) return;
        p.loaded = false;
    }

    fn onChooseClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const dialog = gtk.FileDialog.new();
        gtk.FileDialog.setTitle(dialog, translations._("Choose a Flatpak file"));

        const filter = gtk.FileFilter.new();
        gtk.FileFilter.setName(filter, translations._("Flatpak files"));
        gtk.FileFilter.addSuffix(filter, "flatpak");
        gtk.FileFilter.addSuffix(filter, "flatpakref");

        const filters = gio.ListStore.new(gtk.FileFilter.getGObjectType());
        gio.ListStore.append(filters, filter.as(gobject.Object));
        gtk.FileDialog.setFilters(dialog, filters.as(gio.ListModel));
        filter.as(gobject.Object).unref();
        filters.as(gobject.Object).unref();

        const root = gtk.Widget.getRoot(self.as(gtk.Widget));
        const parent_window: ?*gtk.Window = if (root) |r| gobject.ext.cast(gtk.Window, r) else null;

        _ = self.as(gobject.Object).ref();
        gtk.FileDialog.open(dialog, parent_window, null, &onFileChosen, self);
    }

    fn onFileChosen(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data.?));
        defer self.as(gobject.Object).unref();
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source.?));

        const file = gtk.FileDialog.openFinish(dialog, result, null) orelse return;
        defer file.as(gobject.Object).unref();

        const p = self.priv();
        if (p.disposed) return;

        const path_c = gio.File.getPath(file) orelse return;
        defer glib.free(path_c);
        const path = std.mem.span(path_c);

        if (p.selected_path) |old| std.heap.c_allocator.free(old);
        p.selected_path = std.heap.c_allocator.dupeZ(u8, path) catch {
            p.selected_path = null;
            gtk.Label.setLabel(p.chosen_file_label, translations._("Choose file…"));
            gtk.Widget.setSensitive(p.install_button.as(gtk.Widget), 0);
            return;
        };

        const basename_c = gio.File.getBasename(file);
        if (basename_c) |bn| {
            defer glib.free(bn);
            gtk.Label.setLabel(p.chosen_file_label, bn);
        } else {
            gtk.Label.setLabel(p.chosen_file_label, p.selected_path.?);
        }
        gtk.Widget.setSensitive(p.install_button.as(gtk.Widget), 1);
    }

    fn onInstallClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const p = self.priv();
        const path = p.selected_path orelse return;
        const selected: usize = @intCast(gtk.DropDown.getSelected(p.scope_dropdown));
        const user_scope = selected == 1;

        const kind: BundleKind = if (std.ascii.endsWithIgnoreCase(path, ".flatpakref"))
            .ref
        else if (std.ascii.endsWithIgnoreCase(path, ".flatpak"))
            .bundle
        else {
            self.showStatus(translations._("Unsupported file type. Choose a .flatpak or .flatpakref file."));
            return;
        };

        var argv: []const []const u8 = undefined;
        if (kind == .ref) {
            argv = ShellyCommands.install_local_flatpak_ref(std.heap.c_allocator, path, user_scope) catch return;
        } else {
            argv = ShellyCommands.install_local_flatpak_bundle(std.heap.c_allocator, path, user_scope) catch return;
        }
        defer std.mem.Allocator.free(std.heap.c_allocator, argv);

        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer names.deinit(std.heap.c_allocator);
        names.append(std.heap.c_allocator, std.fs.path.basename(path)) catch {};

        if (support.getWindow(ShellyWindow, self)) |win| {
            win.startTransaction(.{
                .title = translations._("Installing local flatpak"),
                .argv = argv,
                .packages = names.items,
                .on_complete = &onTransactionComplete,
                .privileged = !user_scope,
                .ctx = self,
            });
        }
    }

    const BundleKind = enum { bundle, ref };

    fn onTransactionComplete(ctx: *anyopaque, success: bool) void {
        const self: *FlatpakInstallLocalView = @ptrCast(@alignCast(ctx));
        const p = self.priv();
        if (p.disposed) return;
        if (!success) {
            self.showStatus(translations._("Installation failed."));
            return;
        }
        self.showStatus(translations._("Installation complete."));
        if (p.selected_path) |old| {
            std.heap.c_allocator.free(old);
            p.selected_path = null;
        }
        gtk.Label.setLabel(p.chosen_file_label, translations._("Choose file..."));
        gtk.Widget.setSensitive(p.install_button.as(gtk.Widget), 0);
    }

    fn showStatus(self: *Self, message: [:0]const u8) void {
        const p = self.priv();
        gtk.Label.setLabel(p.status_label, message);
        gtk.Widget.setVisible(p.status_label.as(gtk.Widget), 1);
    }

    const template_children = .{
        .{ "choose_file_button", @offsetOf(Private, "choose_file_button") },
        .{ "chosen_file_label", @offsetOf(Private, "chosen_file_label") },
        .{ "scope_dropdown", @offsetOf(Private, "scope_dropdown") },
        .{ "install_button", @offsetOf(Private, "install_button") },
        .{ "status_label", @offsetOf(Private, "status_label") },
    };

    fn dispose(object: *gobject.Object) callconv(.c) void {
        const self = gobject.ext.cast(Self, object) orelse {
            gobject.ext.as(gobject.Object.Class, Class.parent).f_dispose.?(object);
            return;
        };
        const p = self.priv();
        if (!p.disposed) {
            p.disposed = true;
            if (p.selected_path) |old| {
                std.heap.c_allocator.free(old);
                p.selected_path = null;
            }
        }
        gobject.ext.as(gobject.Object.Class, Class.parent).f_dispose.?(object);
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            const wc = gobject.ext.as(gtk.Widget.Class, class);
            gtk.Widget.Class.setTemplateFromResource(wc, resource_path);
            inline for (template_children) |c| {
                support.bindChild(class, Private.offset, c[0], c[1]);
            }
            const object_class = gobject.ext.as(gobject.Object.Class, class);
            object_class.f_dispose = &dispose;
        }
    };
};
