//! Installed AppImage loading and browsing state. The UI polls worker completion.
const std = @import("std");
const AppImage = @import("appimage.zig").AppImage;
const ShellyCli = @import("../services/shelly_cli.zig").ShellyCli;
const Allocator = std.mem.Allocator;
const Paths = @import("../services/appimage_paths.zig").AppImagePaths;
const operation_model = @import("operation_model.zig");
const runtime = @import("../runtime.zig");

const LoadState = struct {
    result: ?std.json.Parsed([]AppImage) = null,
    failure: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),
};

pub const State = struct {
    install_form: ?*Form = null,
    install_closing: ?*Form = null,
    refresh_after_install: bool = false,
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
        if (self.install_form) |form| form.deinit(allocator);
        if (self.install_closing) |form| form.deinit(allocator);
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
    const had_form = self.appimage_state.install_form != null;
    try pollInstallForm(self);
    if (had_form and self.appimage_state.install_form == null) try ctx.requestFocus(self.widget());
    if (self.appimage_state.install_form) |form| {
        if (!form.editing_path) try ctx.requestFocus(self.widget());
    }
    if (self.appimage_state.refresh_after_install) {
        self.appimage_state.refresh_after_install = false;
        try self.appimage_state.refresh(self.gpa);
        try ctx.tick(100, self.widget());
    }
    if (self.active != .appimage or self.appimage_state.checked or self.appimage_state.load != null) return;
    try self.appimage_state.refresh(self.gpa);
    try ctx.tick(100, self.widget());
}

pub fn handleKey(self: *Model, ctx: *vxfw.EventContext, input: vaxis.Key) !bool {
    initializeWidgets(self);
    const state = &self.appimage_state;
    if (commands.matches(input, .install)) {
        try openInstall(self, ctx);
        return true;
    }
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
    if (self.appimage_state.install_form != null) return AppImageView.drawInstall(self.appimage_state.install_form.?, self.settings_state.settings.header_icons, ctx, children);
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

const PathJob = struct {
    arena: std.heap.ArenaAllocator,
    input: []const u8,
    cwd: []const u8,
    home: []const u8,
    validate: bool,
    generation: usize,
    completion: ?Paths.Completion = null,
    directory: ?[]const u8 = null,
    browsing_directory: bool = false,
    path: ?[]const u8 = null,
    failure: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),
};

const BrowserPosition = struct { directory: []u8, selected: []u8, first_visible: usize };

pub const Form = struct {
    positions: std.ArrayList(BrowserPosition) = .empty,
    field: vxfw.TextField,
    cwd: [:0]const u8,
    home: []const u8,
    generation: usize = 0,
    failure: ?anyerror = null,
    job: ?*PathJob = null,
    thread: ?std.Thread = null,
    completion: ?Paths.Completion = null,
    completion_index: usize = 0,
    editing_path: bool = false,
    first_visible: usize = 0,
    directory: ?[]const u8 = null,
    has_parent: bool = false,

    pub fn deinit(self: *Form, allocator: std.mem.Allocator) void {
        if (self.thread) |thread| thread.join();
        if (self.job) |job| destroyPathJob(job);
        for (self.positions.items) |position| {
            allocator.free(position.directory);
            allocator.free(position.selected);
        }
        self.positions.deinit(allocator);
        self.field.deinit();
        if (self.completion) |completion| (Paths{ .allocator = allocator }).freeCompletion(completion);
        if (self.directory) |directory| allocator.free(directory);
        allocator.free(self.cwd);
        allocator.free(self.home);
        allocator.destroy(self);
    }
};

fn destroyPathJob(job: *PathJob) void {
    job.arena.deinit();
    std.heap.page_allocator.destroy(job);
}

pub fn openInstall(self: *Model, ctx: *vxfw.EventContext) !void {
    if (self.operation_state.install_job != null or self.overlay != null or self.appimage_state.install_form != null or self.appimage_state.install_closing != null) return;
    const form = try self.gpa.create(Form);
    errdefer self.gpa.destroy(form);
    const home = try browserHome(self.gpa, ctx.io, runtime.environ_map.get("HOME"));
    errdefer self.gpa.free(home);
    const cwd = try self.gpa.dupeSentinel(u8, home, 0);
    errdefer self.gpa.free(cwd);
    form.* = .{ .field = vxfw.TextField.init(self.gpa), .cwd = cwd, .home = home };
    self.appimage_state.install_form = form;
    errdefer {
        self.appimage_state.install_form = null;
        form.field.deinit();
    }
    try form.field.insertSliceAtCursor(home);
    if (!std.mem.endsWith(u8, home, "/")) try form.field.insertSliceAtCursor("/");
    try ctx.requestFocus(self.widget());
    try startPathJob(self, ctx, false);
    ctx.consumeAndRedraw();
}

fn resolvePathThread(job: *PathJob) void {
    defer job.done.store(true, .release);
    const allocator = job.arena.allocator();
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const paths: Paths = .{ .allocator = allocator };
    const resolved = paths.resolve(job.input, job.cwd, job.home) catch |err| {
        job.failure = err;
        return;
    };
    const stat = std.Io.Dir.cwd().statFile(threaded.io(), resolved, .{}) catch null;
    if (stat != null and stat.?.kind == .directory) {
        job.directory = resolved;
        job.browsing_directory = true;
        const input = std.fmt.allocPrint(allocator, "{s}/", .{resolved}) catch |err| {
            job.failure = err;
            return;
        };
        job.completion = paths.complete(threaded.io(), input, job.cwd, job.home) catch |err| {
            job.failure = err;
            return;
        };
    } else if (job.validate) {
        job.path = paths.validate(threaded.io(), job.input, job.cwd, job.home) catch |err| {
            job.failure = err;
            return;
        };
    } else {
        job.directory = std.fs.path.dirname(resolved) orelse "/";
        job.completion = paths.complete(threaded.io(), job.input, job.cwd, job.home) catch |err| {
            job.failure = err;
            return;
        };
    }
}

fn startPathJob(self: *Model, ctx: *vxfw.EventContext, validate: bool) !void {
    const form = self.appimage_state.install_form.?;
    if (form.job != null) return;
    try rememberBrowserPosition(form);
    const input = try form.field.buf.dupe();
    defer self.gpa.free(input);
    const job = try std.heap.page_allocator.create(PathJob);
    errdefer std.heap.page_allocator.destroy(job);
    job.* = .{ .arena = .init(std.heap.page_allocator), .input = undefined, .cwd = undefined, .home = undefined, .validate = validate, .generation = form.generation };
    errdefer job.arena.deinit();
    job.input = try job.arena.allocator().dupe(u8, input);
    job.cwd = try job.arena.allocator().dupe(u8, form.cwd);
    job.home = try job.arena.allocator().dupe(u8, form.home);
    try ctx.tick(100, self.widget());
    form.thread = try std.Thread.spawn(.{}, resolvePathThread, .{job});
    form.job = job;
    form.failure = null;
}

fn choosePath(form: *Form) !void {
    const completion = form.completion orelse return;
    if (completion.candidates.len == 0) return;
    const path = completion.candidates[form.completion_index % completion.candidates.len].path;
    form.field.clearRetainingCapacity();
    try form.field.insertSliceAtCursor(path);
    form.completion_index = form.completion_index % completion.candidates.len + 1;
    form.generation += 1;
}

pub fn selectInstallPath(form: *Form, index: usize) !void {
    const completion = form.completion orelse return;
    if (index >= completion.candidates.len) return;
    try rememberBrowserPosition(form);
    form.completion_index = index;
    try choosePath(form);
}

fn moveInstallSelection(form: *Form, down: bool) !void {
    const completion = form.completion orelse return;
    const count = completion.candidates.len;
    if (count == 0) return;
    const current = form.completion_index -| 1;
    const index = if (form.completion_index == 0) @as(usize, 0) else if (down) @min(current + 1, count - 1) else current -| 1;
    try selectInstallPath(form, index);
}

pub fn captureInstall(self: *Model, ctx: *vxfw.EventContext, event: vxfw.Event) !bool {
    const form = self.appimage_state.install_form orelse return false;
    switch (event) {
        .key_press => |input| {
            const key = if (!form.editing_path) commands.vimNavigationKey(input) orelse input else input;
            if (!form.editing_path and (key.matches('/', .{}) or key.matches(vaxis.Key.tab, .{}))) {
                form.editing_path = true;
                try ctx.requestFocus(form.field.widget());
                ctx.consumeAndRedraw();
                return true;
            }
            if (form.editing_path and key.matches(vaxis.Key.escape, .{})) {
                form.editing_path = false;
                try ctx.requestFocus(self.widget());
                ctx.consumeAndRedraw();
                return true;
            }
            if (!form.editing_path and key.matches(vaxis.Key.left, .{})) {
                if (form.has_parent) {
                    try selectInstallPath(form, 0);
                    try startPathJob(self, ctx, false);
                }
                ctx.consumeAndRedraw();
                return true;
            }
            if (!form.editing_path and key.matches(vaxis.Key.right, .{})) {
                if (form.completion) |completion| {
                    if (form.completion_index > 0 and completion.candidates[form.completion_index - 1].is_directory)
                        return captureInstall(self, ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
                }
                ctx.consumeAndRedraw();
                return true;
            }
            if (key.matches(vaxis.Key.escape, .{})) {
                form.generation += 1;
                self.appimage_state.install_form = null;
                try ctx.requestFocus(self.widget());
                if (form.job == null) {
                    form.deinit(self.gpa);
                } else {
                    self.appimage_state.install_closing = form;
                    try ctx.tick(100, self.widget());
                }
            } else if (key.matches(vaxis.Key.up, .{}) or key.matches(vaxis.Key.down, .{})) {
                form.editing_path = false;
                try ctx.requestFocus(self.widget());
                try moveInstallSelection(form, key.matches(vaxis.Key.down, .{}));
            } else if (key.matches(vaxis.Key.tab, .{})) {
                if (form.completion) |completion| {
                    if (completion.candidates.len == 1 and completion.candidates[0].is_directory) {
                        try rememberBrowserPosition(form);
                        (Paths{ .allocator = self.gpa }).freeCompletion(completion);
                        form.completion = null;
                        try startPathJob(self, ctx, false);
                    } else try choosePath(form);
                } else try startPathJob(self, ctx, false);
            } else if (key.matches(vaxis.Key.enter, .{})) {
                try rememberBrowserPosition(form);
                var validate = true;
                if (form.completion) |completion| {
                    if (completion.candidates.len > 0 and form.completion_index > 0 and completion.candidates[(form.completion_index - 1) % completion.candidates.len].is_directory) {
                        validate = false;
                        (Paths{ .allocator = self.gpa }).freeCompletion(completion);
                        form.completion = null;
                    }
                }
                try startPathJob(self, ctx, validate);
            } else if (form.editing_path) {
                try form.field.handleEvent(ctx, event);
                form.generation += 1;
                form.failure = null;
                if (form.completion) |completion| (Paths{ .allocator = self.gpa }).freeCompletion(completion);
                form.completion = null;
            }
        },
        .paste => |text| {
            form.editing_path = true;
            try ctx.requestFocus(form.field.widget());
            try form.field.insertSliceAtCursor(text);
            form.generation += 1;
            if (form.completion) |completion| (Paths{ .allocator = self.gpa }).freeCompletion(completion);
            form.completion = null;
        },
        .mouse => |mouse| {
            if (mouse.button == .wheel_up or mouse.button == .wheel_down) {
                try moveInstallSelection(form, mouse.button == .wheel_down);
            } else return false;
        },
        else => return false,
    }
    ctx.consumeAndRedraw();
    return true;
}

fn rememberBrowserPosition(form: *Form) !void {
    const directory = form.directory orelse return;
    const completion = form.completion orelse return;
    if (form.completion_index == 0 or (form.has_parent and form.completion_index == 1)) return;
    const path = completion.candidates[form.completion_index - 1].path;
    const allocator = form.field.buf.allocator;
    for (form.positions.items) |*position| {
        if (std.mem.eql(u8, position.directory, directory)) {
            const selected = try allocator.dupe(u8, path);
            allocator.free(position.selected);
            position.selected = selected;
            position.first_visible = form.first_visible;
            return;
        }
    }
    const owned_directory = try allocator.dupe(u8, directory);
    errdefer allocator.free(owned_directory);
    const selected = try allocator.dupe(u8, path);
    errdefer allocator.free(selected);
    if (form.positions.items.len == 32) {
        const old = form.positions.orderedRemove(0);
        allocator.free(old.directory);
        allocator.free(old.selected);
    }
    try form.positions.append(allocator, .{ .directory = owned_directory, .selected = selected, .first_visible = form.first_visible });
}

fn returningDirectoryIndex(
    previous: ?[]const u8,
    directory: []const u8,
    candidates: []const Paths.Candidate,
) usize {
    const child = previous orelse return 0;
    const parent = std.fs.path.dirname(child) orelse return 0;
    if (!std.mem.eql(u8, parent, directory)) return 0;

    for (candidates, 0..) |candidate, index| {
        if (candidate.is_directory and
            std.mem.eql(u8, std.mem.trimEnd(u8, candidate.path, "/"), child))
            return index;
    }
    return 0;
}

pub fn pollInstallForm(self: *Model) !void {
    if (self.appimage_state.install_closing) |form| {
        if (form.job == null or form.job.?.done.load(.acquire)) {
            form.deinit(self.gpa);
            self.appimage_state.install_closing = null;
        }
    }
    const form = self.appimage_state.install_form orelse return;
    const job = form.job orelse return;
    if (!job.done.load(.acquire)) return;
    if (form.thread) |thread| thread.join();
    form.thread = null;
    form.job = null;
    defer destroyPathJob(job);
    if (job.generation != form.generation) return;
    form.failure = job.failure;
    if (job.failure != null) return;
    if (job.path) |path| {
        const prompt = try self.gpa.create(operation_model.SudoPrompt);
        errdefer self.gpa.destroy(prompt);
        const name = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(name);
        const review = try std.fmt.allocPrint(self.gpa, "Install from: {f}\n\nShelly executes this AppImage to extract its metadata. Only install files you trust. An existing installation may be replaced. The configured AppImage installation directory will be used.", .{@import("diagnostics").safe(path)});
        prompt.* = .{ .name = name, .backend = .appimage, .elevated = false, .review_text = review };
        self.overlay = .{ .sudo = prompt };
        self.appimage_state.install_form = null;
        form.deinit(self.gpa);
    } else if (job.completion) |completion| {
        const directory = try self.gpa.dupe(u8, job.directory.?);
        errdefer self.gpa.free(directory);
        const has_parent = !std.mem.eql(u8, directory, "/");
        const candidates = try self.gpa.alloc(Paths.Candidate, completion.candidates.len + @intFromBool(has_parent));
        var count: usize = 0;
        errdefer {
            for (candidates[0..count]) |candidate| self.gpa.free(candidate.path);
            self.gpa.free(candidates);
        }
        if (has_parent) {
            candidates[0] = .{ .path = try std.fmt.allocPrint(self.gpa, "{s}/", .{std.fs.path.dirname(directory) orelse "/"}), .is_directory = true };
            count = 1;
        }
        for (completion.candidates) |source| {
            candidates[count] = .{ .path = try self.gpa.dupe(u8, source.path), .is_directory = source.is_directory };
            count += 1;
        }
        var selected_index: usize = 0;
        selected_index = returningDirectoryIndex(form.directory, directory, candidates);
        var first_visible: usize = 0;
        for (form.positions.items) |position| {
            if (!std.mem.eql(u8, position.directory, directory)) continue;
            for (candidates, 0..) |candidate, index| {
                if (std.mem.eql(u8, candidate.path, position.selected)) {
                    selected_index = index;
                    first_visible = position.first_visible;
                    break;
                }
            }
            break;
        }
        const cwd = try self.gpa.dupeSentinel(u8, directory, 0);
        errdefer self.gpa.free(cwd);
        if (job.browsing_directory) {
            form.field.clearRetainingCapacity();
            try form.field.insertSliceAtCursor(directory);
            if (!std.mem.endsWith(u8, directory, "/")) try form.field.insertSliceAtCursor("/");
        }
        self.gpa.free(form.cwd);
        form.cwd = cwd;
        if (form.completion) |old| (Paths{ .allocator = self.gpa }).freeCompletion(old);
        if (form.directory) |old| self.gpa.free(old);
        form.directory = directory;
        form.has_parent = has_parent;
        form.completion = .{ .candidates = candidates, .truncated = completion.truncated };
        form.completion_index = 0;
        form.first_visible = first_visible;
        if (job.browsing_directory) {
            form.editing_path = false;
            if (candidates.len > 0) try selectInstallPath(form, selected_index);
        }
    }
}

test "path validation opens a user-scoped confirmation and stale results are ignored" {
    vxfw.DrawContext.init(.unicode);
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    (try tmp.dir.createFile(std.testing.io, "Editor.AppImage", .{})).close(std.testing.io);
    (try tmp.dir.createFile(std.testing.io, "notes.txt", .{})).close(std.testing.io);
    try tmp.dir.createDir(std.testing.io, "Documents", .default_dir);
    const cwd = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const home = try browserHome(allocator, std.testing.io, cwd);
    defer allocator.free(home);
    try std.testing.expectEqualStrings(cwd, home);
    const form = try allocator.create(Form);
    form.* = .{ .field = vxfw.TextField.init(allocator), .cwd = cwd, .home = try allocator.dupe(u8, cwd) };
    model.appimage_state.install_form = form;
    try form.field.insertSliceAtCursor("Editor.AppImage");
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = allocator, .cmds = .empty };
    defer events.cmds.deinit(allocator);
    form.field.clearRetainingCapacity();
    try form.field.insertSliceAtCursor("./");
    try startPathJob(model, &events, false);
    form.thread.?.join();
    form.thread = null;
    try pollInstallForm(model);
    try std.testing.expectEqual(@as(usize, 3), form.completion.?.candidates.len);
    try std.testing.expect(form.has_parent);
    try std.testing.expect(form.completion.?.candidates[1].is_directory);
    try std.testing.expect(std.mem.endsWith(u8, form.completion.?.candidates[2].path, "Editor.AppImage"));
    try selectInstallPath(form, 1);
    form.first_visible = 1;
    try std.testing.expect(try captureInstall(model, &events, .{ .key_press = .{ .codepoint = vaxis.Key.enter } }));
    form.thread.?.join();
    form.thread = null;
    try pollInstallForm(model);
    try std.testing.expect(std.mem.endsWith(u8, form.cwd, "/Documents"));
    try std.testing.expectEqual(@as(usize, 1), form.completion.?.candidates.len);
    try selectInstallPath(form, 0);
    try std.testing.expect(try captureInstall(model, &events, .{ .key_press = .{ .codepoint = vaxis.Key.enter } }));
    form.thread.?.join();
    form.thread = null;
    try pollInstallForm(model);
    try std.testing.expectEqualStrings(home, form.cwd);
    try std.testing.expectEqual(@as(usize, 1), form.first_visible);
    try std.testing.expectEqual(@as(usize, 2), form.completion_index);
    try std.testing.expect(std.mem.endsWith(u8, form.completion.?.candidates[form.completion_index - 1].path, "/Documents/"));
    form.field.clearRetainingCapacity();
    try std.testing.expect(try captureInstall(model, &events, .{ .paste = "Editor.AppImage" }));
    const pasted = try form.field.buf.dupe();
    defer allocator.free(pasted);
    try std.testing.expectEqualStrings("Editor.AppImage", pasted);
    try startPathJob(model, &events, true);
    form.thread.?.join();
    form.thread = null;
    form.generation += 1;
    try pollInstallForm(model);
    try std.testing.expect(model.overlay == null);
    try std.testing.expect(model.appimage_state.install_form != null);
    try startPathJob(model, &events, true);
    form.thread.?.join();
    form.thread = null;
    try pollInstallForm(model);
    try std.testing.expect(model.appimage_state.install_form == null);
    const prompt = model.overlay.?.sudo;
    try std.testing.expect(!prompt.elevated);
    try std.testing.expectEqual(@import("../services/shelly_operation.zig").Backend.appimage, prompt.backend);
    try std.testing.expect(std.mem.endsWith(u8, prompt.name, "/Editor.AppImage"));
    try std.testing.expect(model.operation_state.install_job == null);
}

test "path suggestions navigate in both directions and stop at the ends" {
    vxfw.DrawContext.init(.unicode);
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    const form = try allocator.create(Form);
    form.* = .{ .field = vxfw.TextField.init(allocator), .cwd = try allocator.dupeSentinel(u8, "/tmp", 0), .home = try allocator.dupe(u8, "/tmp") };
    model.appimage_state.install_form = form;
    const candidates = try allocator.alloc(Paths.Candidate, 2);
    candidates[0] = .{ .path = try allocator.dupe(u8, "/tmp/A.AppImage"), .is_directory = false };
    candidates[1] = .{ .path = try allocator.dupe(u8, "/tmp/B.AppImage"), .is_directory = false };
    form.completion = .{ .candidates = candidates, .truncated = false };
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = allocator, .cmds = .empty };
    defer events.cmds.deinit(allocator);
    for ([_]usize{ 1, 2, 2 }) |expected| {
        try std.testing.expect(try captureInstall(model, &events, .{ .key_press = .{ .codepoint = vaxis.Key.down } }));
        try std.testing.expectEqual(expected, form.completion_index);
    }
    try std.testing.expect(try captureInstall(model, &events, .{ .key_press = .{ .codepoint = vaxis.Key.up } }));
    try std.testing.expectEqual(@as(usize, 1), form.completion_index);
    const path = try form.field.buf.dupe();
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/A.AppImage", path);
    try selectInstallPath(form, 0);
    try std.testing.expectEqual(@as(usize, 1), form.completion_index);
    try std.testing.expect(try captureInstall(model, &events, .{ .key_press = .{ .codepoint = 'j', .text = "j" } }));
    try std.testing.expectEqual(@as(usize, 2), form.completion_index);
    try std.testing.expect(try captureInstall(model, &events, .{ .key_press = .{ .codepoint = '/', .text = "/" } }));
    try std.testing.expect(form.editing_path);
    form.field.clearRetainingCapacity();
    try std.testing.expect(try captureInstall(model, &events, .{ .key_press = .{ .codepoint = 'j', .text = "j" } }));
    const typed = try form.field.buf.dupe();
    defer allocator.free(typed);
    try std.testing.expectEqualStrings("j", typed);
    try std.testing.expect(try captureInstall(model, &events, .{ .key_press = .{ .codepoint = vaxis.Key.escape } }));
    try std.testing.expect(!form.editing_path);
    try std.testing.expect(model.appimage_state.install_form != null);
}

fn browserHome(allocator: Allocator, io: std.Io, configured: ?[]const u8) ![]u8 {
    if (configured) |home| {
        if (std.fs.path.isAbsolute(home)) {
            if (std.Io.Dir.openDirAbsolute(io, home, .{ .iterate = true })) |dir| {
                dir.close(io);
                return allocator.dupe(u8, home);
            } else |_| {}
        }
    }
    var buffer: [65536]u8 = undefined;
    var record: std.c.passwd = undefined;
    var result: ?*std.c.passwd = null;
    if (std.c.getpwuid_r(std.c.getuid(), &record, &buffer, buffer.len, &result) != 0 or result == null) return error.HomeDirectoryUnavailable;
    const home = std.mem.span(record.dir orelse return error.HomeDirectoryUnavailable);
    if (!std.fs.path.isAbsolute(home)) return error.HomeDirectoryUnavailable;
    const directory = try std.Io.Dir.openDirAbsolute(io, home, .{ .iterate = true });
    directory.close(io);
    return allocator.dupe(u8, home);
}
