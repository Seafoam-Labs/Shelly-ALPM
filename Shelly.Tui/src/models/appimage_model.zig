//! Installed AppImage loading and browsing state. The UI polls worker completion.
const std = @import("std");
const AppImage = @import("appimage.zig").AppImage;
const ShellyCli = @import("../services/shelly_cli.zig").ShellyCli;
const Allocator = std.mem.Allocator;

const LoadState = struct {
    result: ?std.json.Parsed([]AppImage) = null,
    failure: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),
};

pub const State = struct {
    details_scroll: @import("vaxis").vxfw.ScrollView = .{ .children = .{ .slice = &.{} } },
    list_view: @import("vaxis").vxfw.ListView = .{ .children = .{ .slice = &.{} } },
    widgets_initialized: bool = false,
    parsed: ?std.json.Parsed([]AppImage) = null,
    cursor: usize = 0,
    details_active: bool = false,
    details_cursor: ?u32 = null,
    list_active: bool = false,
    checked: bool = false,
    failure: ?anyerror = null,
    load: ?*LoadState = null,
    load_thread: ?std.Thread = null,
    refresh_pending: bool = false,

    pub fn items(self: *const State) []const AppImage {
        return if (self.parsed) |parsed| parsed.value else &.{};
    }

    pub fn selected(self: *const State) ?*const AppImage {
        const apps = self.items();
        return if (self.cursor < apps.len) &apps[self.cursor] else null;
    }

    pub fn deinit(self: *State, allocator: Allocator) void {
        if (self.load_thread) |thread| thread.join();
        if (self.load) |load| {
            if (load.result) |result| result.deinit();
            allocator.destroy(load);
        }
        if (self.parsed) |parsed| parsed.deinit();
        self.* = .{};
    }

    pub fn refresh(self: *State, allocator: Allocator) !void {
        if (self.load != null) {
            self.refresh_pending = true;
            return;
        }
        const load = try allocator.create(LoadState);
        errdefer allocator.destroy(load);
        load.* = .{};
        self.load_thread = try std.Thread.spawn(.{}, loadInstalled, .{load});
        self.load = load;
        self.failure = null;
    }

    pub fn poll(self: *State, allocator: Allocator) !bool {
        const load = self.load orelse return false;
        if (!load.done.load(.acquire)) return false;
        if (self.load_thread) |thread| thread.join();
        self.load_thread = null;
        self.load = null;
        defer allocator.destroy(load);
        self.checked = true;
        self.failure = load.failure;
        if (load.result) |result| {
            var cursor = @min(self.cursor, result.value.len -| 1);
            if (self.selected()) |previous| for (result.value, 0..) |app, index| {
                const matches = if (previous.Path) |path|
                    if (app.Path) |candidate| std.mem.eql(u8, path, candidate) else false
                else
                    std.mem.eql(u8, previous.Name, app.Name);
                if (matches) {
                    cursor = index;
                    break;
                }
            };
            if (self.parsed) |parsed| parsed.deinit();
            self.parsed = result;
            self.cursor = cursor;
            self.list_view.item_count = @intCast(result.value.len);
            self.list_view.jumpToItem(@intCast(cursor));
            self.details_scroll.scroll = .{};
            self.details_cursor = null;
            if (result.value.len == 0) self.details_active = false;
        }
        if (self.refresh_pending) {
            self.refresh_pending = false;
            try self.refresh(allocator);
        }
        return true;
    }
};

fn loadInstalled(load: *LoadState) void {
    const allocator = std.heap.page_allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const cli: ShellyCli = .{ .allocator = allocator, .io = threaded.io() };
    load.result = cli.get_installed_appimages() catch |err| {
        load.failure = err;
        load.done.store(true, .release);
        return;
    };
    load.done.store(true, .release);
}

test "refresh results preserve identity and failures retain owned data" {
    const allocator = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(allocator);
    state.parsed = try std.json.parseFromSlice([]AppImage, allocator, "[{\"Name\":\"Editor\",\"Path\":\"/apps/editor\"}]", .{ .allocate = .alloc_always });
    state.details_active = true;
    const load = try allocator.create(LoadState);
    load.* = .{ .result = try std.json.parseFromSlice([]AppImage, allocator, "[{\"Name\":\"Other\"},{\"Name\":\"Renamed\",\"Path\":\"/apps/editor\"}]", .{ .allocate = .alloc_always }), .done = .init(true) };
    state.load = load;
    try std.testing.expect(try state.poll(allocator));
    try std.testing.expectEqual(@as(usize, 1), state.cursor);
    try std.testing.expect(state.details_active);
    const failed = try allocator.create(LoadState);
    failed.* = .{ .failure = error.CommandFailed, .done = .init(true) };
    state.load = failed;
    try std.testing.expect(try state.poll(allocator));
    try std.testing.expectEqual(error.CommandFailed, state.failure.?);
    try std.testing.expectEqualStrings("Renamed", state.selected().?.Name);
    try std.testing.expect(!try state.poll(allocator));
}

test "refresh requests coalesce and completed empty results clear details" {
    const allocator = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(allocator);
    const load = try allocator.create(LoadState);
    load.* = .{};
    state.load = load;
    try state.refresh(allocator);
    try state.refresh(allocator);
    try std.testing.expect(state.load == load);
    try std.testing.expect(state.refresh_pending);
    try std.testing.expect(!try state.poll(allocator));
    state.refresh_pending = false;
    state.details_active = true;
    state.cursor = 10;
    load.result = try std.json.parseFromSlice([]AppImage, allocator, "[]", .{});
    load.done.store(true, .release);
    try std.testing.expect(try state.poll(allocator));
    try std.testing.expect(state.checked);
    try std.testing.expect(state.selected() == null);
    try std.testing.expect(!state.details_active);
    try std.testing.expectEqual(@as(usize, 0), state.cursor);
}

test "list and details builders terminate at bounds and follow the cursor" {
    const allocator = std.testing.allocator;
    var model = try Model.init(allocator);
    defer model.deinit();
    model.appimage_state.parsed = try std.json.parseFromSlice([]AppImage, allocator, "[{\"Name\":\"First\",\"Path\":\"/a\"},{\"Name\":\"Second\",\"Path\":\"/b\"}]", .{ .allocate = .alloc_always });
    const ptr: *const Model = @constCast(model);

    try std.testing.expect(buildRow(ptr, 0, 0) != null);
    try std.testing.expect(buildRow(ptr, 1, 0) != null);
    try std.testing.expect(buildRow(ptr, 2, 0) == null);

    model.appimage_state.cursor = 0;
    try std.testing.expect(buildDetails(ptr, 0, 0) != null);
    try std.testing.expect(buildDetails(ptr, 1, 0) == null);
    model.appimage_state.cursor = 1;
    try std.testing.expect(buildDetails(ptr, 0, 0) != null);
    try std.testing.expect(buildDetails(ptr, 1, 0) == null);

    model.appimage_state.parsed.?.deinit();
    model.appimage_state.parsed = null;
    try std.testing.expect(buildDetails(ptr, 0, 0) == null);
}

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Model = @import("../model.zig").Model;
const commands = @import("../commands.zig");
const AppImageView = @import("../views/appimage_view.zig");

pub fn ensureLoaded(self: *Model, ctx: *vxfw.EventContext) !void {
    if (self.active != .appimage or self.appimage_state.checked or self.appimage_state.load != null) return;
    try self.appimage_state.refresh(self.gpa);
    try ctx.tick(100, self.widget());
}

pub fn handleKey(self: *Model, ctx: *vxfw.EventContext, input: vaxis.Key) !bool {
    initializeWidgets(self);
    const state = &self.appimage_state;
    syncSelection(state);
    const key = commands.vimNavigationKey(input) orelse input;
    if (commands.matches(key, .refresh_list)) {
        try state.refresh(self.gpa);
        try ctx.tick(100, self.widget());
    } else if (commands.matches(key, .back) or (state.details_active and commands.matches(key, .close))) {
        state.details_active = false;
        state.list_active = true;
    } else if (commands.matches(key, .details) or commands.matches(key, .select)) {
        state.details_active = state.selected() != null;
        state.list_active = !state.details_active;
    } else if (state.details_active) {
        if (commands.scrollKey(key)) |canonical| {
            try state.details_scroll.handleEvent(ctx, .{ .key_press = canonical });
        } else return false;
    } else if (commands.scrollKey(key) != null) {
        state.list_active = true;
        if (state.items().len > 0) try state.list_view.handleEvent(ctx, .{ .key_press = commands.scrollKey(key).? });
        syncSelection(state);
    } else return false;
    ctx.consumeAndRedraw();
    return true;
}

fn buildRow(ptr: *const anyopaque, index: usize, _: usize) ?vxfw.Widget {
    const self: *const Model = @ptrCast(@alignCast(ptr));
    const apps = self.appimage_state.items();
    if (index >= apps.len) return null;
    return .{ .userdata = @constCast(&apps[index]), .drawFn = AppImageView.drawRow };
}

fn buildDetails(ptr: *const anyopaque, index: usize, _: usize) ?vxfw.Widget {
    const self: *const Model = @ptrCast(@alignCast(ptr));
    if (index != 0 or self.appimage_state.selected() == null) return null;
    return .{ .userdata = @constCast(self), .drawFn = drawDetails };
}

fn drawDetails(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const self: *Model = @ptrCast(@alignCast(ptr));
    if (self.appimage_state.selected()) |app| return AppImageView.drawDetails(@constCast(app), ctx);
    var text: vxfw.Text = .{ .text = "Select an AppImage to see details." };
    return text.draw(ctx);
}

pub fn appImageView(self: *Model) AppImageView.View {
    const state = &self.appimage_state;
    syncSelection(state);
    if (state.details_cursor == null or state.details_cursor.? != @as(u32, @intCast(state.cursor))) {
        state.details_scroll.scroll = .{};
        state.details_cursor = @as(u32, @intCast(state.cursor));
    }
    return .{ .state = state, .list_percent = self.list_percent, .help = if (self.help_open) &self.help_panel else null };
}

fn syncSelection(state: *State) void {
    const cursor = @min(state.list_view.cursor, state.items().len -| 1);
    if (state.cursor != cursor) {
        state.cursor = cursor;
        state.details_scroll.scroll = .{};
        state.details_cursor = null;
    }
}

fn initializeWidgets(self: *Model) void {
    const state = &self.appimage_state;
    if (!state.widgets_initialized) {
        state.list_view = .{ .item_count = @intCast(state.items().len), .children = .{ .builder = .{ .userdata = self, .buildFn = buildRow } } };
        state.list_view.jumpToItem(@intCast(state.cursor));
        state.details_scroll = .{ .item_count = 1, .children = .{ .builder = .{ .userdata = self, .buildFn = buildDetails } } };
        state.widgets_initialized = true;
    }
    state.list_view.item_count = @intCast(state.items().len);
}

pub fn appendContent(self: *Model, ctx: vxfw.DrawContext, children: *std.ArrayList(vxfw.SubSurface)) Allocator.Error!void {
    initializeWidgets(self);
    try appImageView(self).appendContent(ctx, children);
}

test "optional AppImage page renders loaded and empty states and navigates details" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    const settings_model = @import("settings_model.zig");
    try std.testing.expect(!model.tabEnabled(.appimage));
    settings_model.applySettings(model, .{ .appimage_enabled = true });
    try std.testing.expect(model.tabEnabled(.appimage));
    model.active = .appimage;
    model.appimage_state.checked = true;
    model.appimage_state.parsed = try std.json.parseFromSlice([]AppImage, std.testing.allocator, "[{\"Name\":\"Editor\",\"Description\":\"An editor\",\"Path\":\"/tmp/Editor.AppImage\"}]", .{ .allocate = .alloc_always });
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer events.cmds.deinit(std.testing.allocator);
    try std.testing.expect(try handleKey(model, &events, commands.bindings.details));
    try std.testing.expect(model.appimage_state.details_active);
    for ([_]u16{ 1, 40, 100 }) |width| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var children: std.ArrayList(vxfw.SubSurface) = .empty;
        try appendContent(model, .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 24 }, .cell_size = .{ .width = 10, .height = 20 } }, &children);
        for (children.items) |child| {
            try std.testing.expect(child.origin.col + child.surface.size.width <= width);
            try std.testing.expect(child.origin.row + child.surface.size.height <= 24);
        }
    }
    try std.testing.expect(try handleKey(model, &events, commands.bindings.back));
    try std.testing.expect(!model.appimage_state.details_active);
    settings_model.applySettings(model, .{});
    try std.testing.expectEqual(@import("../model.zig").Tab.packages, model.active);
}

test "moving selection shows the correct app, resets details scroll, and stacks on narrow terminals" {
    const allocator = std.testing.allocator;
    var model = try Model.init(allocator);
    defer model.deinit();
    const settings_model = @import("settings_model.zig");
    try std.testing.expect(!model.tabEnabled(.appimage));
    settings_model.applySettings(model, .{ .appimage_enabled = true });
    model.active = .appimage;
    model.appimage_state.checked = true;
    model.appimage_state.parsed = try std.json.parseFromSlice([]AppImage, allocator, "[{\"Name\":\"First\",\"Path\":\"/a\"},{\"Name\":\"Second\",\"Path\":\"/b\"},{\"Name\":\"Third\",\"Path\":\"/c\"}]", .{ .allocate = .alloc_always });
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer events.cmds.deinit(std.testing.allocator);

    const collect = struct {
        fn text(alloc: Allocator, output: *std.ArrayList(u8), surface: vxfw.Surface) Allocator.Error!void {
            for (surface.buffer) |cell| try output.appendSlice(alloc, cell.char.grapheme);
            for (surface.children) |child| try text(alloc, output, child.surface);
        }
    };

    // Select the middle app and open its details on a wide terminal.
    try std.testing.expect(try handleKey(model, &events, commands.bindings.next));
    try std.testing.expectEqual(@as(usize, 1), model.appimage_state.cursor);
    try std.testing.expect(try handleKey(model, &events, commands.bindings.details));
    try std.testing.expect(model.appimage_state.details_active);

    var wide: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer wide.deinit();
    var wide_children: std.ArrayList(vxfw.SubSurface) = .empty;
    try appendContent(model, .{ .arena = wide.allocator(), .min = .{}, .max = .{ .width = 100, .height = 30 }, .cell_size = .{ .width = 10, .height = 20 } }, &wide_children);
    var rendered: std.ArrayList(u8) = .empty;
    try collect.text(wide.allocator(), &rendered, wide_children.items[1].surface);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "Second") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "First") == null);

    // Scrolling the details then moving selection resets the details scroll so
    // the newly selected app is shown from the top instead of stale content.
    model.appimage_state.details_scroll.scroll.top = 5;
    try std.testing.expect(try handleKey(model, &events, commands.bindings.back));
    try std.testing.expect(try handleKey(model, &events, commands.bindings.next));
    try std.testing.expectEqual(@as(usize, 2), model.appimage_state.cursor);
    var again: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer again.deinit();
    var again_children: std.ArrayList(vxfw.SubSurface) = .empty;
    try appendContent(model, .{ .arena = again.allocator(), .min = .{}, .max = .{ .width = 100, .height = 30 }, .cell_size = .{ .width = 10, .height = 20 } }, &again_children);
    try std.testing.expectEqual(@as(u32, 0), model.appimage_state.details_scroll.scroll.top);
    rendered.clearRetainingCapacity();
    try collect.text(again.allocator(), &rendered, again_children.items[1].surface);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "Third") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "Second") == null);

    // Mouse/widget navigation can change the ListView cursor outside handleKey.
    model.appimage_state.list_view.jumpToItem(0);
    _ = appImageView(model);
    try std.testing.expectEqualStrings("First", model.appimage_state.selected().?.Name);
    try std.testing.expectEqual(@as(u32, 0), model.appimage_state.details_scroll.scroll.top);

    // Narrow terminals keep the active pane within bounds.
    model.appimage_state.details_active = false;
    var narrow: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer narrow.deinit();
    var narrow_children: std.ArrayList(vxfw.SubSurface) = .empty;
    try appendContent(model, .{ .arena = narrow.allocator(), .min = .{}, .max = .{ .width = 40, .height = 24 }, .cell_size = .{ .width = 10, .height = 20 } }, &narrow_children);
    for (narrow_children.items) |child| {
        try std.testing.expect(child.origin.col + child.surface.size.width <= 40);
        try std.testing.expect(child.origin.row + child.surface.size.height <= 24);
    }
}
