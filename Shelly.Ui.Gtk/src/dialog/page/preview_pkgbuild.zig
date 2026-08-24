const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gio = bindings.gio;
const glib = bindings.glib;
const gobject = bindings.gobject;
const gdk = bindings.gdk;
const support = @import("../../pages/support.zig");
const ShellyCli = @import("../../services/shelly_cli.zig").ShellyCli;
const PkgBuild = @import("../../models/pkgbuild.zig").PkgBuild;
const ShellyWindow = @import("../../shelly_window.zig").ShellyWindow;
const theme_manager = @import("../../services/theme_manager.zig");
const window_controls = @import("../../window_controls.zig");

pub const PkgbuildReviewDialog = extern struct {
    parent_instance: Parent,
    const Self = @This();
    pub const Parent = gtk.Window;
    const resource_path = "/com/shellyorg/shelly/dialog/ui/preview_pkgbuild.ui";

    const PageState = enum {
        Loading,
        Loaded,
        Error,
    };

    const Private = struct {
        root_overlay: *gtk.Overlay,
        drag_region: *gtk.WindowHandle,
        heading_label: *gtk.Label,
        notebook: *gtk.Notebook,
        diff_box: *gtk.Box,
        cancel_button: *gtk.Button,
        loading_spinner: *gtk.Spinner,
        error_label: *gtk.Label,
        state: PageState,
        ctx: ?*anyopaque,
        generation: u32,
        arena: ?*std.heap.ArenaAllocator,
        loaded: bool,
        responded: bool,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyPkgbuildPreviewDialog",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    fn priv(self: *Self) *Private {
        return gobject.ext.impl_helpers.getPrivate(self, Private, Private.offset);
    }

    pub fn as(self: *Self, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        const p = self.priv();
        p.generation = 0;
        p.arena = null;
        window_controls.installOverlay(p.root_overlay);

        support.connectLifecycle(Self, self);
    }

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    pub fn showPreview(self: *Self, name: []const u8) void {
        const p = self.priv();
        var buf: [512]u8 = undefined;
        const heading = std.fmt.bufPrintZ(
            &buf,
            "{s}: {s}",
            .{ "PKGBUILD", name },
        ) catch "PKGBUILD";
        gtk.Label.setLabel(p.heading_label, heading);
        self.start_load(name);
    }

    pub fn onMap(self: *Self) void {
        const p = self.priv();

        if (p.loaded) return;
    }

    pub fn present(self: *Self) void {
        const p = self.priv();
        const theme = if (gtk.Window.getTransientFor(self.as(gtk.Window))) |parent| blk: {
            self.applyAvailableSize(
                gtk.Widget.getWidth(parent.as(gtk.Widget)),
                gtk.Widget.getHeight(parent.as(gtk.Widget)),
            );
            break :blk theme_manager.inherit(self.as(gtk.Widget), parent.as(gtk.Widget));
        } else blk: {
            theme_manager.apply(self.as(gtk.Widget), .classic);
            break :blk .classic;
        };
        window_controls.configureChildWindow(
            self.as(gtk.Window),
            p.root_overlay,
            p.drag_region.as(gtk.Widget),
            theme_manager.isDark(theme),
        );
        gtk.Window.present(self.as(gtk.Window));

        _ = gtk.Widget.grabFocus(p.cancel_button.as(gtk.Widget));
    }

    pub fn applyAvailableSize(self: *Self, available_width: c_int, available_height: c_int) void {
        if (available_width <= 0 or available_height <= 0) return;
        gtk.Window.setDefaultSize(
            self.as(gtk.Window),
            @divTrunc(available_width * 3, 4),
            @divTrunc(available_height * 3, 4),
        );
    }

    pub fn onUnmap(self: *Self) void {
        const p = self.priv();
        if (!p.loaded) return;
        p.loaded = false;

        p.generation += 1;

        if (p.arena) |a| {
            a.deinit();
            std.heap.c_allocator.destroy(a);
            p.arena = null;
        }
    }

    fn start_load(self: *Self, package_name: []const u8) void {
        const p = self.priv();
        p.generation += 1;
        self.set_page_state(.Loading);

        const thread = std.Thread.spawn(.{}, worker, .{ self, package_name, p.generation }) catch {
            self.set_page_state(.Error);
            return;
        };
        thread.detach();
    }

    fn worker(page: *Self, name: []const u8, gen: u32) void {
        const arena_ptr = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch return;
        arena_ptr.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        const alloc = arena_ptr.allocator();

        std.debug.print("worker: \n", .{});

        var threaded: std.Io.Threaded = .init(alloc, .{});
        defer threaded.deinit();
        const cli = ShellyCli{ .allocator = alloc, .io = threaded.io() };

        const parsed = cli.fetch_pkgbuild(name) catch |err| {
            std.debug.print("worker: fetch_pkgbuild failed: {s} err={any}\n", .{ name, err });
            arena_ptr.deinit();
            page.set_page_state(.Error);
            std.heap.c_allocator.destroy(arena_ptr);
            return;
        };

        for (parsed.value) |v| {
            const clean_v_name = std.mem.trimEnd(u8, v.Name, "\x00");
            const clean_name = std.mem.trimEnd(u8, name, "\x00");

            if (std.mem.eql(u8, clean_v_name, clean_name)) {
                std.debug.print("worker: found match: v.Name={s}\n", .{v.Name});
                post_result(page, parsed.value[0], arena_ptr, gen);
            }
        }
    }

    const Result = struct { page: *Self, pkgbuild: PkgBuild, arena: *std.heap.ArenaAllocator, generation: u64 };

    fn post_result(page: *Self, pkgbuild: PkgBuild, arena: *std.heap.ArenaAllocator, gen: u64) void {
        const r = std.heap.c_allocator.create(Result) catch {
            arena.deinit();
            std.heap.c_allocator.destroy(arena);
            std.debug.print("post_result failed: \n", .{});
            page.set_page_state(.Error);
            return;
        };
        std.debug.print("post_result: \n", .{});
        r.* = .{ .page = page, .pkgbuild = pkgbuild, .arena = arena, .generation = gen };
        _ = glib.idleAdd(&on_complete, r);
        page.set_page_state(.Loaded);
    }

    fn on_cancel(self: *Self) callconv(.c) void {
        gtk.Window.destroy(self.as(gtk.Window));
    }

    fn on_close_request(self: *Self) callconv(.c) c_int {
        gtk.Window.destroy(self.as(gtk.Window));
        return 0;
    }

    fn set_page_state(self: *Self, state: PageState) void {
        switch (state) {
            .Loading => self.priv().loading_spinner.as(gtk.Spinner).start(),
            .Loaded => self.priv().loading_spinner.as(gtk.Spinner).stop(),
            .Error => gtk.Widget.setVisible(self.priv().error_label.as(gtk.Widget), 1),
        }
    }

    fn on_complete(data: ?*anyopaque) callconv(.c) c_int {
        const r: *Result = @ptrCast(@alignCast(data.?));
        defer std.heap.c_allocator.destroy(r);
        const p = r.page.priv();

        if (r.generation != p.generation) {
            r.arena.deinit();
            std.heap.c_allocator.destroy(r.arena);
            return 0;
        }

        if (p.arena) |old| {
            old.deinit();
            std.heap.c_allocator.destroy(old);
        }
        p.arena = r.arena;

        std.debug.print("r.pkgbuild.PkgBuild: {d}", .{r.pkgbuild.PkgBuild.len});

        const view = gtk.TextView.new();
        gtk.TextView.setEditable(view, 0);
        gtk.TextView.setMonospace(view, 1);
        gtk.TextView.setWrapMode(view, .word_char);
        gtk.TextView.setCursorVisible(view, 0);
        const buffer = gtk.TextView.getBuffer(view);
        const text_z = std.heap.c_allocator.dupeZ(u8, r.pkgbuild.PkgBuild) catch return 0;
        defer std.heap.c_allocator.free(text_z);
        gtk.TextBuffer.setText(buffer, text_z, @intCast(text_z.len));

        clear_box(p.diff_box);
        gtk.Box.append(p.diff_box, view.as(gtk.Widget));

        return 0;
    }

    fn clear_box(box: *gtk.Box) void {
        while (gtk.Widget.getFirstChild(box.as(gtk.Widget))) |child| {
            gtk.Box.remove(box, child);
        }
    }

    fn finalize(self: *Self) callconv(.c) void {
        const p = self.priv();

        if (p.arena) |a| {
            a.deinit();
            std.heap.c_allocator.destroy(a);
            p.arena = null;
        }
        const parent_class: *gobject.Object.Class = @ptrCast(Class.parent);
        gobject.Object.virtual_methods.finalize.call(parent_class, self.as(gobject.Object));
    }

    const template_children = .{
        .{ "root_overlay", @offsetOf(Private, "root_overlay") },
        .{ "drag_region", @offsetOf(Private, "drag_region") },
        .{ "heading_label", @offsetOf(Private, "heading_label") },
        .{ "diff_box", @offsetOf(Private, "diff_box") },
        .{ "cancel_button", @offsetOf(Private, "cancel_button") },
        .{ "loading_spinner", @offsetOf(Private, "loading_spinner") },
        .{ "error_label", @offsetOf(Private, "error_label") },
    };

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
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);

            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_cancel", @ptrCast(&on_cancel));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_close_request", @ptrCast(&on_close_request));
        }
    };
};

test "PKGBUILD preview window uses shared client-side chrome" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;

    const dialog = PkgbuildReviewDialog.new();
    _ = dialog.as(gobject.Object).refSink();
    defer dialog.as(gobject.Object).unref();

    const root = gtk.Widget.getFirstChild(dialog.as(gtk.Widget)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(gobject.ext.cast(gtk.Overlay, root) != null);

    const Find = struct {
        fn css(widget: *gtk.Widget, class_name: [:0]const u8) bool {
            if (gtk.Widget.hasCssClass(widget, class_name) != 0) return true;
            var child = gtk.Widget.getFirstChild(widget);
            while (child) |current| : (child = gtk.Widget.getNextSibling(current)) {
                if (css(current, class_name)) return true;
            }
            return false;
        }
    };

    try std.testing.expect(Find.css(root, "app-window-drag-region"));
    try std.testing.expect(Find.css(root, "app-window-controls-overlay"));
    try std.testing.expect(gtk.Widget.hasCssClass(dialog.as(gtk.Widget), "pkgbuild-window") != 0);
}
