const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const glib = bindings.glib;
const gobject = bindings.gobject;
const support = @import("../support.zig");
const ShellyCli = @import("../../services/shelly_cli.zig").ShellyCli;
const Remote = @import("../../models/flatpak.zig").Remote;
const cstr = @import("../../helpers/c_string.zig").cstr;

pub const FlatpakRemotesView = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gtk.Box;

    const resource_path = "/com/shellyorg/shelly/ui/flatpak/flatpak_remotes_view.ui";

    const Private = struct {
        remotes_stack: *gtk.Stack,
        remotes_list_page: *gtk.Box,
        add_remote_page: *gtk.Box,
        list_remotes: *gtk.ListBox,
        arena: ?*std.heap.ArenaAllocator,
        remotes: []Remote,
        selected_index: usize,
        has_selection: bool,
        generation: u64,
        loaded: bool,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyFlatpakRemotesView",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const LoadResult = struct {
        page: *Self,
        remotes: []Remote,
        arena: *std.heap.ArenaAllocator,
        generation: u64,
    };

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
        p.loaded = false;

        // name the inner stack pages so we can switch by name
        const list_page = gtk.Stack.getPage(p.remotes_stack, p.remotes_list_page.as(gtk.Widget));
        gtk.StackPage.setName(list_page, "list");
        const add_page = gtk.Stack.getPage(p.remotes_stack, p.add_remote_page.as(gtk.Widget));
        gtk.StackPage.setName(add_page, "add");

        support.connectLifecycle(Self, self);
    }

    pub fn show_add_form(self: *Self) void {
        gtk.Stack.setVisibleChildName(self.priv().remotes_stack, "add");
    }

    pub fn show_list(self: *Self) void {
        gtk.Stack.setVisibleChildName(self.priv().remotes_stack, "list");
    }

    pub fn onMap(self: *Self) void {
        const p = self.priv();
        if (p.loaded) return;
        p.loaded = true;
        p.generation += 1;
        p.has_selection = false;

        const thread = std.Thread.spawn(.{}, load_worker, .{ self, p.generation }) catch return;
        thread.detach();
    }

    fn load_worker(page: *Self, generation: u64) void {
        const arena_ptr = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch return;
        arena_ptr.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        const alloc = arena_ptr.allocator();

        var threaded: std.Io.Threaded = .init(alloc, .{});
        defer threaded.deinit();

        const cli = ShellyCli{ .allocator = alloc, .io = threaded.io() };
        const parsed = cli.get_remotes() catch {
            post_result(page, &.{}, arena_ptr, generation);
            return;
        };

        post_result(page, parsed.value, arena_ptr, generation);
    }

    fn post_result(page: *Self, remotes: []Remote, arena: *std.heap.ArenaAllocator, generation: u64) void {
        const result = std.heap.c_allocator.create(LoadResult) catch return;
        result.* = .{ .page = page, .remotes = remotes, .arena = arena, .generation = generation };
        _ = glib.idleAdd(&on_load_complete, result);
    }

    fn on_load_complete(data: ?*anyopaque) callconv(.c) c_int {
        const result: *LoadResult = @ptrCast(@alignCast(data.?));
        defer std.heap.c_allocator.destroy(result);

        const p = result.page.priv();

        if (result.generation != p.generation) {
            result.arena.deinit();
            std.heap.c_allocator.destroy(result.arena);
            return 0;
        }

        // take ownership of the arena — the DTOs live here now
        if (p.arena) |old| {
            old.deinit();
            std.heap.c_allocator.destroy(old);
        }
        p.arena = result.arena;
        p.remotes = result.remotes;

        for (result.remotes, 0..) |r, i| {
            gtk.ListBox.append(p.list_remotes, make_remote_row(r, i));
        }

        return 0;
    }

    pub fn onUnmap(self: *Self) void {
        const p = self.priv();
        if (!p.loaded) return;
        p.loaded = false;
        p.generation += 1;
        p.has_selection = false;

        gtk.ListBox.removeAll(p.list_remotes);
        p.remotes = &.{};

        if (p.arena) |a| {
            a.deinit();
            std.heap.c_allocator.destroy(a);
            p.arena = null;
        }
    }
    const template_children = .{
        .{ "remotes_stack", @offsetOf(Private, "remotes_stack") },
        .{ "remotes_list_page", @offsetOf(Private, "remotes_list_page") },
        .{ "add_remote_page", @offsetOf(Private, "add_remote_page") },
        .{ "list_remotes", @offsetOf(Private, "list_remotes") },
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
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "remove_selected_remote", @ptrCast(&remove_remote));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "add_remote", @ptrCast(&add_remote));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "back_to_list", @ptrCast(&back_to_list));
        }
    };

    fn remove_remote(self: *Self) callconv(.c) void {
        const p = self.priv();

        const row = gtk.ListBox.getSelectedRow(p.list_remotes) orelse return;
        const raw = gobject.Object.getData(row.as(gobject.Object), "remote-index") orelse return;
        const index = @intFromPtr(raw) - 1;

        if (index >= p.remotes.len) return;
        const remote = p.remotes[index];
        std.debug.print("remove: {s}\n", .{remote.Name});
        // remove through cli after
    }

    fn add_remote(self: *Self) callconv(.c) void {
        show_add_form(self);
    }

    fn back_to_list(self: *Self) callconv(.c) void {
        show_list(self);
    }

    fn make_remote_row(remote: Remote, index: usize) *gtk.Widget {
        const row = gtk.ListBoxRow.new();
        var buf: [512]u8 = undefined;
        gobject.Object.setData(
            row.as(gobject.Object),
            "remote-index",
            @ptrFromInt(index + 1),
        );

        const grid = gtk.Grid.new();
        gtk.Widget.setMarginStart(grid.as(gtk.Widget), 12);
        gtk.Widget.setMarginEnd(grid.as(gtk.Widget), 12);
        gtk.Widget.setMarginTop(grid.as(gtk.Widget), 6);
        gtk.Widget.setMarginBottom(grid.as(gtk.Widget), 6);
        gtk.Grid.setColumnSpacing(grid, 12);

        const name_label = gtk.Label.new(cstr(&buf, remote.Name));
        gtk.Widget.setHalign(name_label.as(gtk.Widget), .start);
        gtk.Label.setXalign(name_label, 0);
        gtk.Widget.setHexpand(name_label.as(gtk.Widget), 1);
        gtk.Widget.addCssClass(name_label.as(gtk.Widget), "bold");
        gtk.Grid.attach(grid, name_label.as(gtk.Widget), 0, 0, 1, 1);

        const scope_label = gtk.Label.new(@tagName(remote.Scope));
        gtk.Widget.setHalign(scope_label.as(gtk.Widget), .start);
        gtk.Label.setXalign(scope_label, 0);
        gtk.Widget.addCssClass(scope_label.as(gtk.Widget), "dim-label");
        gtk.Grid.attach(grid, scope_label.as(gtk.Widget), 1, 0, 1, 1);

        const url_label = gtk.Label.new(cstr(&buf, remote.Url));
        gtk.Widget.setHalign(url_label.as(gtk.Widget), .start);
        gtk.Label.setXalign(url_label, 0);
        gtk.Widget.addCssClass(url_label.as(gtk.Widget), "dim-label");
        gtk.Grid.attach(grid, url_label.as(gtk.Widget), 2, 0, 1, 1);

        gtk.ListBoxRow.setChild(row, grid.as(gtk.Widget));
        return row.as(gtk.Widget);
    }
};
