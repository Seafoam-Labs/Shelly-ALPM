const std = @import("std");
const diagnostics = @import("diagnostics");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const glib = bindings.glib;
const gobject = bindings.gobject;
const support = @import("support.zig");
const ShellyWindow = @import("../shelly_window.zig").ShellyWindow;
const ShellyCli = @import("../services/shelly_cli.zig").ShellyCli;
const ShellyCommands = @import("../services/shelly_operation.zig").ShellyCommands;
const MiseTool = @import("../models/mise.zig").MiseTool;
const MiseUpdate = @import("../models/mise.zig").MiseUpdate;
const Toast = @import("../helpers/custom_ui_comps/toast.zig").Toast;
const ConfirmDialog = @import("../dialog/page/yn_dialog.zig").ConfirmDialog;
const a11y = @import("../helpers/a11y.zig");
const c_string = @import("../helpers/c_string.zig");
const translations = @import("../helpers/translations.zig");

/// Developer tools managed by mise. Every operation runs the CLI as the
/// current user; mise state is never touched with elevated privileges.
pub const MisePage = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gtk.Box;

    pub const title: [:0]const u8 = "mise";
    pub const icon_name: [:0]const u8 = "applications-engineering-symbolic";
    const resource_path = "/com/shellyorg/shelly/ui/mise_page.ui";

    const Private = struct {
        page_overlay: *gtk.Overlay,
        search_entry: *gtk.SearchEntry,
        refresh_button: *gtk.Button,
        upgrade_all_button: *gtk.Button,
        stack: *gtk.Stack,
        loading_page: *gtk.Widget,
        list_page: *gtk.Widget,
        empty_page: *gtk.Widget,
        error_page: *gtk.Widget,
        spinner: *gtk.Spinner,
        tool_list: *gtk.ListBox,

        tools: []MiseTool = &.{},
        updates: []MiseUpdate = &.{},
        arena: ?*std.heap.ArenaAllocator = null,
        pending_remove: ?[]u8 = null,
        generation: u64 = 0,
        loaded: bool = false,
        toast: *Toast,
        var offset: c_int = 0;
    };

    const LoadResult = struct {
        page: *Self,
        tools: []MiseTool,
        updates: []MiseUpdate,
        arena: *std.heap.ArenaAllocator,
        generation: u64,
        failed: bool,
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyMisePage",
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
        p.tools = &.{};
        p.updates = &.{};
        p.arena = null;
        p.pending_remove = null;
        p.generation = 0;
        p.loaded = false;

        const toast = Toast.new();
        gtk.Overlay.addOverlay(p.page_overlay, toast.as(gtk.Widget));
        p.toast = toast;
        support.connectLifecycle(Self, self);
    }

    pub fn onMap(self: *Self) void {
        const p = self.priv();
        if (p.loaded) return;
        p.loaded = true;
        self.reload();
    }

    pub fn onUnmap(self: *Self) void {
        const p = self.priv();
        if (!p.loaded) return;
        p.loaded = false;
        p.generation += 1;
        clear_data(self);
    }

    fn clear_data(self: *Self) void {
        const p = self.priv();
        gtk.ListBox.removeAll(p.tool_list);
        if (p.arena) |arena| {
            arena.deinit();
            std.heap.c_allocator.destroy(arena);
            p.arena = null;
        }
        p.tools = &.{};
        p.updates = &.{};
    }

    fn reload(self: *Self) void {
        const p = self.priv();
        p.generation += 1;
        set_busy(self, true);
        gtk.Stack.setVisibleChild(p.stack, p.loading_page);
        const thread = std.Thread.spawn(.{}, load_worker, .{ self, p.generation }) catch {
            set_busy(self, false);
            gtk.Stack.setVisibleChild(p.stack, p.error_page);
            return;
        };
        thread.detach();
    }

    fn load_worker(page: *Self, generation: u64) void {
        const arena = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch return;
        arena.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        const allocator = arena.allocator();
        var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
        defer threaded.deinit();

        const cli = ShellyCli{ .allocator = allocator, .io = threaded.io() };
        const tools = cli.get_mise_tools() catch |err| {
            std.debug.print("Could not load the mise tool list. {0s}\n\nTechnical details: {1s}\n", .{ diagnostics.cause(err), @errorName(err) });
            post_result(page, &.{}, &.{}, arena, generation, true);
            return;
        };
        // A failed update check still leaves the installed tools usable.
        const updates: []MiseUpdate = if (cli.get_mise_updates()) |parsed| parsed.value else |_| &.{};
        post_result(page, tools.value, updates, arena, generation, false);
    }

    fn post_result(
        page: *Self,
        tools: []MiseTool,
        updates: []MiseUpdate,
        arena: *std.heap.ArenaAllocator,
        generation: u64,
        failed: bool,
    ) void {
        const result = std.heap.c_allocator.create(LoadResult) catch {
            arena.deinit();
            std.heap.c_allocator.destroy(arena);
            return;
        };
        result.* = .{
            .page = page,
            .tools = tools,
            .updates = updates,
            .arena = arena,
            .generation = generation,
            .failed = failed,
        };
        _ = glib.idleAdd(&on_load_complete, result);
    }

    fn on_load_complete(data: ?*anyopaque) callconv(.c) c_int {
        const result: *LoadResult = @ptrCast(@alignCast(data.?));
        const self = result.page;
        const p = self.priv();
        if (result.generation != p.generation) {
            result.arena.deinit();
            std.heap.c_allocator.destroy(result.arena);
            std.heap.c_allocator.destroy(result);
            return 0;
        }

        clear_data(self);
        set_busy(self, false);
        if (result.failed) {
            result.arena.deinit();
            std.heap.c_allocator.destroy(result.arena);
            std.heap.c_allocator.destroy(result);
            gtk.Stack.setVisibleChild(p.stack, p.error_page);
            return 0;
        }

        p.arena = result.arena;
        p.tools = result.tools;
        p.updates = result.updates;
        std.heap.c_allocator.destroy(result);

        for (p.tools, 0..) |*tool, index| {
            const row = make_tool_row(self, tool, findUpdateFor(p.updates, tool.Name), index);
            gtk.ListBox.append(p.tool_list, row);
        }
        gtk.Widget.setSensitive(p.upgrade_all_button.as(gtk.Widget), @intFromBool(p.updates.len != 0));
        gtk.Stack.setVisibleChild(p.stack, if (p.tools.len == 0) p.empty_page else p.list_page);
        apply_search_filter(self);
        return 0;
    }

    fn set_busy(self: *Self, busy: bool) void {
        const p = self.priv();
        if (busy) gtk.Spinner.start(p.spinner) else gtk.Spinner.stop(p.spinner);
        gtk.Widget.setSensitive(p.refresh_button.as(gtk.Widget), @intFromBool(!busy));
        if (busy) gtk.Widget.setSensitive(p.upgrade_all_button.as(gtk.Widget), 0);
    }

    fn findUpdateFor(updates: []const MiseUpdate, name: []const u8) ?*const MiseUpdate {
        for (updates) |*update| {
            if (std.mem.eql(u8, update.Name, name)) return update;
        }
        return null;
    }

    fn make_tool_row(self: *Self, tool: *const MiseTool, update: ?*const MiseUpdate, index: usize) *gtk.Widget {
        const row = gtk.ListBoxRow.new();
        gtk.ListBoxRow.setActivatable(row, 0);

        const hbox = gtk.Box.new(.horizontal, 12);
        gtk.Widget.setMarginStart(hbox.as(gtk.Widget), 12);
        gtk.Widget.setMarginEnd(hbox.as(gtk.Widget), 12);
        gtk.Widget.setMarginTop(hbox.as(gtk.Widget), 8);
        gtk.Widget.setMarginBottom(hbox.as(gtk.Widget), 8);

        const icon = gtk.Image.newFromIconName(icon_name);
        gtk.Image.setPixelSize(icon, 32);
        gtk.Box.append(hbox, icon.as(gtk.Widget));

        const vbox = gtk.Box.new(.vertical, 2);
        gtk.Widget.setHexpand(vbox.as(gtk.Widget), 1);
        gtk.Widget.setValign(vbox.as(gtk.Widget), .center);

        var name_buffer: [512]u8 = undefined;
        const name_label = gtk.Label.new(c_string.cstr(&name_buffer, tool.Name));
        gtk.Widget.addCssClass(name_label.as(gtk.Widget), "title-4");
        gtk.Label.setXalign(name_label, 0);
        gtk.Label.setEllipsize(name_label, .end);
        gtk.Box.append(vbox, name_label.as(gtk.Widget));

        var detail_buffer: [1024]u8 = undefined;
        const detail = formatDetail(&detail_buffer, tool);
        const detail_label = gtk.Label.new(detail);
        gtk.Widget.addCssClass(detail_label.as(gtk.Widget), "caption");
        gtk.Widget.addCssClass(detail_label.as(gtk.Widget), "dim-label");
        gtk.Label.setXalign(detail_label, 0);
        gtk.Label.setEllipsize(detail_label, .middle);
        gtk.Box.append(vbox, detail_label.as(gtk.Widget));

        if (update) |available| {
            var update_buffer: [256]u8 = undefined;
            const text = std.fmt.bufPrintSentinel(&update_buffer, "{s}: {s}", .{ translations._("Update Available"), available.NewVersion }, 0) catch translations._("Update Available");
            const update_label = gtk.Label.new(text);
            gtk.Widget.addCssClass(update_label.as(gtk.Widget), "caption");
            gtk.Widget.addCssClass(update_label.as(gtk.Widget), "accent");
            gtk.Label.setXalign(update_label, 0);
            gtk.Box.append(vbox, update_label.as(gtk.Widget));
        }
        gtk.Box.append(hbox, vbox.as(gtk.Widget));

        const upgrade_button = gtk.Button.newFromIconName("software-update-available-symbolic");
        styleRowButton(upgrade_button, translations._("Upgrade this tool"), index);
        gtk.Widget.setVisible(upgrade_button.as(gtk.Widget), @intFromBool(update != null));
        _ = gtk.Button.signals.clicked.connect(upgrade_button, *Self, &on_row_upgrade_clicked, self, .{});
        gtk.Box.append(hbox, upgrade_button.as(gtk.Widget));

        const remove_button = gtk.Button.newFromIconName("user-trash-symbolic");
        styleRowButton(remove_button, translations._("Remove this tool"), index);
        _ = gtk.Button.signals.clicked.connect(remove_button, *Self, &on_row_remove_clicked, self, .{});
        gtk.Box.append(hbox, remove_button.as(gtk.Widget));

        gtk.ListBoxRow.setChild(row, hbox.as(gtk.Widget));
        return row.as(gtk.Widget);
    }

    fn styleRowButton(button: *gtk.Button, label: [:0]const u8, index: usize) void {
        gtk.Widget.setValign(button.as(gtk.Widget), .center);
        gtk.Widget.setTooltipText(button.as(gtk.Widget), label);
        a11y.setName(button.as(gtk.Widget), label);
        gtk.Widget.addCssClass(button.as(gtk.Widget), "flat");
        gtk.Widget.addCssClass(button.as(gtk.Widget), "circular");
        gobject.Object.setData(button.as(gobject.Object), "tool-index", @ptrFromInt(index + 1));
    }

    /// "26.8.1 · Requested: 26 · ~/.config/mise/config.toml"
    fn formatDetail(buffer: []u8, tool: *const MiseTool) [:0]const u8 {
        var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
        writer.writeAll(if (tool.Version.len != 0) tool.Version else "?") catch {};
        if (!tool.Installed) writer.print(" ({s})", .{translations._("not installed")}) catch {};
        if (tool.RequestedVersion) |requested| {
            if (requested.len != 0) writer.print(" · {s}: {s}", .{ translations._("Requested"), requested }) catch {};
        }
        if (tool.SourcePath orelse tool.SourceType) |source| {
            if (source.len != 0) writer.print(" · {s}", .{source}) catch {};
        }
        const length = writer.end;
        buffer[length] = 0;
        return buffer[0..length :0];
    }

    fn toolForButton(self: *Self, button: *gtk.Button) ?*const MiseTool {
        const raw = gobject.Object.getData(button.as(gobject.Object), "tool-index") orelse return null;
        const index = @intFromPtr(raw) - 1;
        const p = self.priv();
        if (index >= p.tools.len) return null;
        return &p.tools[index];
    }

    fn on_row_upgrade_clicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const tool = self.toolForButton(button) orelse return;
        const argv = ShellyCommands.upgrade_mise(std.heap.c_allocator, &.{tool.Name}) catch return;
        defer std.heap.c_allocator.free(argv);
        self.startOperation(translations._("Upgrading mise tool"), argv, &.{tool.Name});
    }

    fn upgrade_all(self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.updates.len == 0) {
            p.toast.show(.info, translations._("All mise tools are up to date"));
            return;
        }
        const argv = ShellyCommands.upgrade_mise(std.heap.c_allocator, &.{}) catch return;
        defer std.heap.c_allocator.free(argv);
        const names = std.heap.c_allocator.alloc([]const u8, p.updates.len) catch return;
        defer std.heap.c_allocator.free(names);
        for (p.updates, names) |update, *name| name.* = update.Name;
        self.startOperation(translations._("Upgrading mise tools"), argv, names);
    }

    fn on_row_remove_clicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const tool = self.toolForButton(button) orelse return;
        const p = self.priv();
        if (p.pending_remove) |previous| std.heap.c_allocator.free(previous);
        p.pending_remove = std.heap.c_allocator.dupe(u8, tool.Name) catch null;
        if (p.pending_remove == null) return;

        var buffer: [1024]u8 = undefined;
        const message = std.fmt.bufPrintSentinel(
            &buffer,
            "{s} {s}? {s}",
            .{
                translations._("Remove"),
                tool.Name,
                translations._("mise removes it from the configuration file that declares it and prunes installs nothing else uses."),
            },
            0,
        ) catch translations._("Remove this mise tool?");
        const dialog = ConfirmDialog.new(translations._("Remove mise tool"), message, &on_remove_response, self);
        dialog.setButtons(translations._("Remove"), translations._("Cancel"));
        if (support.getWindow(ShellyWindow, self)) |win| win.showLockout(dialog.as(gtk.Widget));
    }

    fn on_remove_response(ctx: ?*anyopaque, confirmed: bool) void {
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        if (support.getWindow(ShellyWindow, self)) |win| win.hideLockout();
        const p = self.priv();
        const name = p.pending_remove orelse return;
        defer {
            std.heap.c_allocator.free(name);
            p.pending_remove = null;
        }
        if (!confirmed) return;

        const argv = ShellyCommands.remove_mise(std.heap.c_allocator, &.{name}) catch return;
        defer std.heap.c_allocator.free(argv);
        self.startOperation(translations._("Removing mise tool"), argv, &.{name});
    }

    fn startOperation(
        self: *Self,
        operation_title: [:0]const u8,
        argv: []const []const u8,
        names: []const []const u8,
    ) void {
        const win = support.getWindow(ShellyWindow, self) orelse return;
        win.startTransaction(.{
            .title = operation_title,
            .argv = argv,
            .packages = names,
            .on_complete = &on_op_complete,
            .ctx = self,
            .privileged = false,
        });
    }

    fn on_op_complete(ctx: *anyopaque, success: bool) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const p = self.priv();
        if (success) {
            p.toast.show(.success, translations._("Operation completed successfully"));
        } else {
            p.toast.show(.@"error", translations._("Could not complete the requested operation."));
        }
        self.reload();
    }

    fn refresh_tools(self: *Self) callconv(.c) void {
        self.reload();
    }

    fn on_search_changed(self: *Self) callconv(.c) void {
        apply_search_filter(self);
    }

    fn apply_search_filter(self: *Self) void {
        const p = self.priv();
        const text = std.mem.span(gtk.Editable.getText(p.search_entry.as(gtk.Editable)));
        var index: usize = 0;
        var maybe_child = gtk.Widget.getFirstChild(p.tool_list.as(gtk.Widget));
        while (maybe_child) |child| : (maybe_child = gtk.Widget.getNextSibling(child)) {
            if (index >= p.tools.len) break;
            defer index += 1;
            gtk.Widget.setVisible(child, @intFromBool(matchesQuery(p.tools[index].Name, text)));
        }
    }

    fn matchesQuery(name: []const u8, query: []const u8) bool {
        return query.len == 0 or std.ascii.indexOfIgnoreCase(name, query) != null;
    }

    fn dispose(self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.pending_remove) |name| {
            std.heap.c_allocator.free(name);
            p.pending_remove = null;
        }
        self.onUnmap();
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    const template_children = .{
        .{ "MiseOverlay", @offsetOf(Private, "page_overlay") },
        .{ "MiseSearchEntry", @offsetOf(Private, "search_entry") },
        .{ "MiseRefreshButton", @offsetOf(Private, "refresh_button") },
        .{ "MiseUpgradeAllButton", @offsetOf(Private, "upgrade_all_button") },
        .{ "MiseStack", @offsetOf(Private, "stack") },
        .{ "MiseLoadingPage", @offsetOf(Private, "loading_page") },
        .{ "MiseListPage", @offsetOf(Private, "list_page") },
        .{ "MiseEmptyPage", @offsetOf(Private, "empty_page") },
        .{ "MiseErrorPage", @offsetOf(Private, "error_page") },
        .{ "MiseSpinner", @offsetOf(Private, "spinner") },
        .{ "MiseListBox", @offsetOf(Private, "tool_list") },
    };

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            const wc = gobject.ext.as(gtk.Widget.Class, class);
            gtk.Widget.Class.setTemplateFromResource(wc, resource_path);
            inline for (template_children) |child| {
                support.bindChild(class, Private.offset, child[0], child[1]);
            }
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "refresh_tools", @ptrCast(&refresh_tools));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "upgrade_all", @ptrCast(&upgrade_all));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "search_changed", @ptrCast(&on_search_changed));
        }
    };
};

test "mise page search matches tool names case-insensitively" {
    try std.testing.expect(MisePage.matchesQuery("npm:Playwright", "playw"));
    try std.testing.expect(MisePage.matchesQuery("node", ""));
    try std.testing.expect(!MisePage.matchesQuery("node", "python"));
}

test "mise page update lookup matches the exact tool name" {
    const updates = [_]MiseUpdate{
        .{ .Name = "node", .NewVersion = "26.10.0" },
        .{ .Name = "npm:node-gyp", .NewVersion = "11.0.0" },
    };
    try std.testing.expectEqualStrings("26.10.0", MisePage.findUpdateFor(&updates, "node").?.NewVersion);
    try std.testing.expect(MisePage.findUpdateFor(&updates, "gh") == null);
}
