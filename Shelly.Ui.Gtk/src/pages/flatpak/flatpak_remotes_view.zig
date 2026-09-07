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
const ShellyCommands = @import("../../services/shelly_operation.zig").ShellyCommands;
const ShellyWindow = @import("../../shelly_window.zig").ShellyWindow;
const translations = @import("../../helpers/translations.zig");

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
        overlay_add_remote_name_entry: *gtk.Entry,
        overlay_add_remote_url_entry: *gtk.Entry,
        overlay_add_remote_scope_dropdown: *gtk.DropDown,
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

        const list_page = gtk.Stack.getPage(p.remotes_stack, p.remotes_list_page.as(gtk.Widget));
        gtk.StackPage.setName(list_page, "list");
        const add_page = gtk.Stack.getPage(p.remotes_stack, p.add_remote_page.as(gtk.Widget));
        gtk.StackPage.setName(add_page, "add");

        support.connectLifecycle(Self, self);
    }

    pub fn showAddForm(self: *Self) void {
        gtk.Stack.setVisibleChildName(self.priv().remotes_stack, "add");
    }

    pub fn showList(self: *Self) void {
        gtk.Stack.setVisibleChildName(self.priv().remotes_stack, "list");
    }

    pub fn onMap(self: *Self) void {
        const p = self.priv();
        if (p.loaded) return;
        p.loaded = true;
        p.generation += 1;
        p.has_selection = false;

        const thread = std.Thread.spawn(.{}, loadWorker, .{ self, p.generation }) catch return;
        thread.detach();
    }

    fn loadWorker(page: *Self, generation: u64) void {
        const arena_ptr = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch return;
        arena_ptr.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        const alloc = arena_ptr.allocator();

        var threaded: std.Io.Threaded = .init(alloc, .{});
        defer threaded.deinit();

        const cli = ShellyCli{ .allocator = alloc, .io = threaded.io() };
        const parsed = cli.getRemotes() catch {
            postResult(page, &.{}, arena_ptr, generation);
            return;
        };

        postResult(page, parsed.value, arena_ptr, generation);
    }

    fn postResult(page: *Self, remotes: []Remote, arena: *std.heap.ArenaAllocator, generation: u64) void {
        const result = std.heap.c_allocator.create(LoadResult) catch {
            arena.deinit();
            std.heap.c_allocator.destroy(arena);
            return;
        };
        result.* = .{ .page = page, .remotes = remotes, .arena = arena, .generation = generation };
        _ = glib.idleAdd(&onLoadComplete, result);
    }

    fn onLoadComplete(data: ?*anyopaque) callconv(.c) c_int {
        const result: *LoadResult = @ptrCast(@alignCast(data.?));
        defer std.heap.c_allocator.destroy(result);
        const p = result.page.priv();
        if (result.generation != p.generation) {
            result.arena.deinit();
            std.heap.c_allocator.destroy(result.arena);
            return 0;
        }
        if (p.arena) |old| {
            old.deinit();
            std.heap.c_allocator.destroy(old);
        }
        p.arena = result.arena;
        p.remotes = result.remotes;

        while (gtk.Widget.getFirstChild(p.list_remotes.as(gtk.Widget))) |child| {
            gtk.ListBox.remove(p.list_remotes, child);
        }

        for (result.remotes, 0..) |r, i| {
            gtk.ListBox.append(p.list_remotes, makeRemoteRow(r, i));
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
        .{ "overlay_add_remote_name_entry", @offsetOf(Private, "overlay_add_remote_name_entry") },
        .{ "overlay_add_remote_url_entry", @offsetOf(Private, "overlay_add_remote_url_entry") },
        .{ "overlay_add_remote_scope_dropdown", @offsetOf(Private, "overlay_add_remote_scope_dropdown") },
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
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "remove_selected_remote", @ptrCast(&removeRemote));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "add_remote", @ptrCast(&addRemote));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "back_to_list", @ptrCast(&backToList));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "add_remote_confirm", @ptrCast(&addRemoteConfirm));
        }
    };

    fn removeRemote(self: *Self) callconv(.c) void {
        const p = self.priv();

        const row = gtk.ListBox.getSelectedRow(p.list_remotes) orelse return;
        const raw = gobject.Object.getData(row.as(gobject.Object), "remote-index") orelse return;
        const index = @intFromPtr(raw) - 1;

        if (index >= p.remotes.len) return;
        const remote = p.remotes[index];
        std.debug.print("remove: {s}\n", .{remote.Name});

        const argv = ShellyCommands.remove_remote(std.heap.c_allocator, remote.Name, remote.Scope) catch return;
        defer std.mem.Allocator.free(std.heap.c_allocator, argv);

        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer names.deinit(std.heap.c_allocator);

        names.append(std.heap.c_allocator, remote.Name) catch {};

        if (support.getWindow(ShellyWindow, self)) |win| {
            win.startTransaction(.{
                .title = translations._("Removing Remote"),
                .argv = argv,
                .packages = names.items,
                .on_complete = &onTransactionComplete,
                .privileged = false,
                .ctx = self,
            });
        }
    }

    fn addRemoteConfirm(self: *Self) callconv(.c) void {
        std.debug.print("test", .{});
        const p = self.priv();

        const name = std.mem.span(gtk.Editable.getText(p.overlay_add_remote_name_entry.as(gtk.Editable)));
        const url = std.mem.span(gtk.Editable.getText(p.overlay_add_remote_url_entry.as(gtk.Editable)));

        const selected = gtk.DropDown.getSelected(p.overlay_add_remote_scope_dropdown);
        const model = gtk.DropDown.getModel(p.overlay_add_remote_scope_dropdown) orelse return;
        const item = gio.ListModel.getObject(model, selected) orelse return;
        const string_obj = gobject.ext.cast(gtk.StringObject, item) orelse return;
        const scope = std.mem.span(gtk.StringObject.getString(string_obj));

        std.debug.print("name: {s}, url: {s}, scope: {s}\n", .{ name, url, scope });

        const argv = ShellyCommands.add_remote(std.heap.c_allocator, name, url, scope) catch return;
        defer std.mem.Allocator.free(std.heap.c_allocator, argv);

        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer names.deinit(std.heap.c_allocator);

        names.append(std.heap.c_allocator, name) catch {};

        if (support.getWindow(ShellyWindow, self)) |win| {
            win.startTransaction(.{
                .title = translations._("Adding Remote"),
                .argv = argv,
                .packages = names.items,
                .on_complete = &onTransactionComplete,
                .privileged = false,
                .ctx = self,
            });
        }
    }

    fn onTransactionComplete(ctx: *anyopaque, success: bool) void {
        const self: *FlatpakRemotesView = @ptrCast(@alignCast(ctx));
        const p = self.priv();
        if (!success) return;
        self.reload();
        gtk.Editable.setText(p.overlay_add_remote_name_entry.as(gtk.Editable), "");
        gtk.Editable.setText(p.overlay_add_remote_url_entry.as(gtk.Editable), "");
        self.backToList();
    }

    fn reload(self: *Self) void {
        const p = self.priv();
        p.generation += 1;
        const thread = std.Thread.spawn(.{}, loadWorker, .{ self, p.generation }) catch return;
        thread.detach();
    }

    fn addRemote(self: *Self) callconv(.c) void {
        showAddForm(self);
    }

    fn backToList(self: *Self) callconv(.c) void {
        showList(self);
    }

    fn makeRemoteRow(remote: Remote, index: usize) *gtk.Widget {
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
