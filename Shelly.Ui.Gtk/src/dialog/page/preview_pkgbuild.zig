const std = @import("std");
const diagnostics = @import("diagnostics");
const translations = @import("../../helpers/translations.zig");
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
        p.loaded = false;
        p.responded = false;

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
        gtk.Window.present(self.as(gtk.Window));

        _ = gtk.Widget.grabFocus(p.cancel_button.as(gtk.Widget));
    }

    pub fn onUnmap(self: *Self) void {
        const p = self.priv();
        p.loaded = false;

        p.generation += 1;

        if (p.arena) |a| {
            a.deinit();
            std.heap.c_allocator.destroy(a);
            p.arena = null;
        }
    }

    // Allocate the result on the main thread so every worker failure can post
    // completion without allocating again or touching GTK from a worker thread.
    const Result = struct {
        page: *Self,
        name: []const u8,
        arena: *std.heap.ArenaAllocator,
        generation: u32,
        pkgbuild: ?PkgBuild = null,
        detail: ?[]u8 = null,
        err: ?anyerror = null,
    };

    fn start_load(self: *Self, package_name: []const u8) void {
        const p = self.priv();
        p.generation += 1;
        self.set_page_state(.Loading);
        const arena = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch {
            self.show_failure(error.OutOfMemory, null);
            return;
        };
        arena.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        const allocator = arena.allocator();
        const result = allocator.create(Result) catch {
            arena.deinit();
            std.heap.c_allocator.destroy(arena);
            self.show_failure(error.OutOfMemory, null);
            return;
        };
        const name = allocator.dupe(u8, package_name) catch {
            arena.deinit();
            std.heap.c_allocator.destroy(arena);
            self.show_failure(error.OutOfMemory, null);
            return;
        };
        result.* = .{ .page = self, .name = name, .arena = arena, .generation = p.generation };
        _ = self.as(gobject.Object).ref();
        const thread = std.Thread.spawn(.{}, worker, .{result}) catch |err| {
            self.as(gobject.Object).unref();
            arena.deinit();
            std.heap.c_allocator.destroy(arena);
            self.show_failure(err, null);
            return;
        };
        thread.detach();
    }

    fn worker(result: *Result) void {
        defer _ = glib.idleAdd(&on_complete, result);
        const allocator = result.arena.allocator();
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const cli = ShellyCli{ .allocator = allocator, .io = threaded.io(), .failure_detail = &result.detail };
        const parsed = cli.fetch_pkgbuild(result.name) catch |err| {
            result.err = err;
            return;
        };
        for (parsed.value) |package| {
            if (std.mem.eql(u8, std.mem.trimEnd(u8, package.Name, "\x00"), std.mem.trimEnd(u8, result.name, "\x00"))) {
                result.pkgbuild = package;
                return;
            }
        }
        result.err = error.PackageNotFound;
    }

    fn on_cancel(self: *Self) callconv(.c) void {
        gtk.Window.destroy(self.as(gtk.Window));
    }

    fn on_close_request(self: *Self) callconv(.c) c_int {
        gtk.Window.destroy(self.as(gtk.Window));
        return 0;
    }

    fn show_failure(self: *Self, err: anyerror, detail: ?[]const u8) void {
        const heading = translations._("Could not load the PKGBUILD preview.");
        const message = std.fmt.allocPrintSentinel(std.heap.c_allocator, "{s}\n{s}", .{
            heading, detail orelse diagnostics.cause(err),
        }, 0) catch {
            gtk.Label.setLabel(self.priv().error_label, heading);
            self.set_page_state(.Error);
            return;
        };
        defer std.heap.c_allocator.free(message);
        gtk.Label.setLabel(self.priv().error_label, message);
        self.set_page_state(.Error);
    }

    fn set_page_state(self: *Self, state: PageState) void {
        const p = self.priv();
        p.state = state;
        gtk.Widget.setVisible(p.loading_spinner.as(gtk.Widget), @intFromBool(state == .Loading));
        gtk.Widget.setVisible(p.error_label.as(gtk.Widget), @intFromBool(state == .Error));
        if (state == .Loading) p.loading_spinner.start() else p.loading_spinner.stop();
    }

    fn on_complete(data: ?*anyopaque) callconv(.c) c_int {
        const result: *Result = @ptrCast(@alignCast(data.?));
        const page = result.page;
        const arena = result.arena;
        var transferred = false;
        defer {
            if (!transferred) {
                arena.deinit();
                std.heap.c_allocator.destroy(arena);
            }
            page.as(gobject.Object).unref();
        }
        const p = page.priv();
        if (result.generation != p.generation) return 0;
        if (result.err) |err| {
            const message = diagnostics.format(arena.allocator(), err, .{
                .operation = "the PKGBUILD preview",
                .subject = result.name,
                .detail = result.detail,
            }) catch null;
            page.show_failure(err, message);
            return 0;
        }
        const package = result.pkgbuild orelse {
            page.show_failure(error.PackageNotFound, null);
            return 0;
        };
        const text = arena.allocator().dupeZ(u8, package.PkgBuild) catch {
            page.show_failure(error.OutOfMemory, null);
            return 0;
        };
        const view = gtk.TextView.new();
        gtk.TextView.setEditable(view, 0);
        gtk.TextView.setMonospace(view, 1);
        gtk.TextView.setWrapMode(view, .word_char);
        gtk.TextView.setCursorVisible(view, 0);
        gtk.TextBuffer.setText(gtk.TextView.getBuffer(view), text, @intCast(text.len));
        clear_box(p.diff_box);
        gtk.Box.append(p.diff_box, view.as(gtk.Widget));
        if (p.arena) |old| {
            old.deinit();
            std.heap.c_allocator.destroy(old);
        }
        p.arena = arena;
        transferred = true;
        p.loaded = true;
        page.set_page_state(.Loaded);
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
