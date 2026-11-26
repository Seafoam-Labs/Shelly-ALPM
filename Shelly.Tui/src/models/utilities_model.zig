//! Read-only maintenance queries for the Utilities tab.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Model = @import("../model.zig").Model;
const operation_model = @import("operation_model.zig");
const commands = @import("../commands.zig");
const Allocator = std.mem.Allocator;
const ShellyCli = @import("../services/shelly_cli.zig").ShellyCli;
const utilities_view = @import("../views/utilities_view.zig");

const StringList = std.json.Parsed([][]const u8);
const Job = struct {
    kind: enum { pacfiles, repositories },
    thread: std.Thread = undefined,
    result: ?StringList = null,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *Job) void {
        const allocator = std.heap.page_allocator;
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const cli: ShellyCli = .{ .allocator = allocator, .io = threaded.io() };
        const result = switch (self.kind) {
            .pacfiles => cli.get_pacfiles(),
            .repositories => cli.getRepositories(),
        };
        self.result = result catch null;
        self.done.store(true, .release);
    }
};

const preview = @import("../views/pkgbuild_view.zig");

const PreviewKind = enum { file, diff };

const PreviewJob = struct {
    kind: PreviewKind,
    path: []const u8,
    thread: std.Thread,
    done: std.atomic.Value(bool) = .init(false),
    result: ?preview.Document = null,
    failure: ?anyerror = null,

    fn run(self: *PreviewJob) void {
        const allocator = std.heap.page_allocator;
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const document = switch (self.kind) {
            .file => readPacfile(allocator, threaded.io(), self.path),
            .diff => compare(allocator, threaded.io(), self.path),
        };
        self.result = document catch |err| blk: {
            self.failure = err;
            break :blk null;
        };
        self.done.store(true, .release);
    }

    fn destroy(self: *PreviewJob, allocator: std.mem.Allocator) void {
        self.thread.join();
        if (self.result) |*result| result.deinit();
        allocator.free(self.path);
        allocator.destroy(self);
    }
};

fn activePacfilePath(path: []const u8) ![]const u8 {
    if (!std.fs.path.isAbsolute(path)) return error.InvalidPacfile;
    for ([_][]const u8{ ".pacnew", ".pacsave", ".pacorig" }) |suffix| {
        if (std.mem.endsWith(u8, path, suffix)) return path[0 .. path.len - suffix.len];
    }
    const marker = ".pacsave.";
    const index = std.mem.lastIndexOf(u8, path, marker) orelse return error.InvalidPacfile;
    const rotation = path[index + marker.len ..];
    if (rotation.len == 0) return error.InvalidPacfile;
    for (rotation) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidPacfile;
    }
    return path[0..index];
}

fn readPacfile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !preview.Document {
    _ = try activePacfilePath(path);
    const dir = std.Io.Dir.cwd();
    if ((try dir.statFile(io, path, .{})).kind != .file) return error.NotRegularFile;
    const contents = try dir.readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024));
    defer allocator.free(contents);
    return preview.Document.fromFile(allocator, contents);
}

fn compare(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !preview.Document {
    const active = try activePacfilePath(path);
    const dir = std.Io.Dir.cwd();
    if ((try dir.statFile(io, path, .{})).kind != .file) return error.NotRegularFile;
    const original: ?std.Io.Dir.Stat = dir.statFile(io, active, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (original) |stat| if (stat.kind != .file) return error.NotRegularFile;
    const active_label = if (original == null) try std.fmt.allocPrint(allocator, "{s} (missing)", .{active}) else active;
    defer if (original == null) allocator.free(active_label);
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "diff", "-u", "--label", active_label, "--label", path, "--", if (original != null) active else "/dev/null", path },
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited > 1) return error.DiffFailed;
    if (result.term.exited == 0 and original == null) return preview.Document.fromDiff(allocator, "The active configuration is missing and the pacfile is empty.");
    return preview.Document.fromDiff(allocator, result.stdout);
}

pub const Task = enum {
    pacfiles,
    cleanup,
    flatpak_cleanup,
    repair_permissions,
    repair_database,
    repository,

    pub fn label(self: Task) []const u8 {
        return switch (self) {
            .pacfiles => "List pacfiles",
            .cleanup => "Clean standard packages",
            .flatpak_cleanup => "Clean unused Flatpaks",
            .repair_permissions => "Repair directory permissions",
            .repair_database => "Clear stale database locks",
            .repository => "Repository",
        };
    }

    pub fn available(self: Task, model: *const Model) bool {
        return self != .flatpak_cleanup or (model.settings_state.settings.flatpak_enabled and model.flatpak_state.flatpak_available);
    }
};

pub const State = struct {
    repositories: RepositoryState,
    selected: Task = .pacfiles,
    results_focused: bool = false,
    job: ?*Job = null,
    result: ?StringList = null,
    failed: bool = false,
    list: vxfw.ScrollView,
    preview_job: ?*PreviewJob = null,
    preview_open: bool = false,
    preview_wrap: bool = true,
    preview_list: vxfw.ScrollView,
    preview_back: vxfw.Button,

    pub fn init(model: *Model, allocator: std.mem.Allocator) State {
        return .{
            .repositories = RepositoryState.init(model, allocator),
            .preview_list = .{ .children = .{ .builder = .{ .userdata = model, .buildFn = buildPreviewRow } } },
            .preview_back = .{ .label = "[<]", .userdata = model, .onClick = commands.Mouse.closePacfilePreview, .style = @import("../views/components/styles.zig").action_button },
            .list = .{ .children = .{ .builder = .{ .userdata = model, .buildFn = buildRow } } },
        };
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.repositories.deinit(allocator);
        if (self.preview_job) |job| job.destroy(allocator);
        if (self.job) |job| {
            job.thread.join();
            if (job.result) |*result| result.deinit();
            allocator.destroy(job);
        }
        if (self.result) |*result| result.deinit();
    }

    pub fn poll(self: *State, allocator: std.mem.Allocator) void {
        const job = self.job orelse return;
        if (!job.done.load(.acquire)) return;
        job.thread.join();
        self.job = null;
        defer allocator.destroy(job);
        if (self.result) |*result| result.deinit();
        self.result = job.result;
        self.failed = job.result == null;
        self.list.item_count = if (self.result) |result| @intCast(result.value.len) else 0;
        self.list.scroll = .{};
        self.list.cursor = 0;
    }

    pub fn message(self: *const State) ?[]const u8 {
        if (self.job != null) return "Looking for pending configuration files…";
        if (self.failed) return "Could not list pending configuration files. Try again.";
        if (self.result) |result| return if (result.value.len == 0) "No pending configuration files." else null;
        return "Waiting to scan for pacfiles…";
    }
};

fn buildRow(ptr: *const anyopaque, index: usize, _: usize) ?vxfw.Widget {
    const model: *const Model = @ptrCast(@alignCast(ptr));
    const result = model.utilities_state.result orelse return null;
    if (index >= result.value.len) return null;
    const selected = model.utilities_state.results_focused and model.utilities_state.list.cursor == index;
    return .{ .userdata = @ptrCast(&result.value[index]), .drawFn = if (selected) utilities_view.drawSelectedPath else utilities_view.drawPath };
}

fn acceptsMouse(model: *const Model) bool {
    return model.active == .utilities and !model.help_open and model.overlay == null and !model.utilities_state.preview_open;
}

pub fn activateFromMouse(model: *Model, ctx: *vxfw.EventContext, task: Task) !void {
    if (!acceptsMouse(model) or model.utilities_state.repositories.editing != null or !task.available(model)) return;
    const state = &model.utilities_state;
    if (state.selected == task and !state.results_focused and model.settings_state.settings.expanded_mouse_support) {
        return activate(model, ctx);
    }
    state.selected = task;
    state.results_focused = false;
    try ensureSelected(model, ctx);
    ctx.consumeAndRedraw();
}

test "utility click selects before opening an operation" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.active = .utilities;
    model.settings_state.settings.expanded_mouse_support = true;
    model.utilities_state.results_focused = true;
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = model.gpa, .cmds = .empty };
    defer ctx.cmds.deinit(model.gpa);

    try activateFromMouse(model, &ctx, .repair_database);
    try std.testing.expectEqual(Task.repair_database, model.utilities_state.selected);
    try std.testing.expect(!model.utilities_state.results_focused);
    try std.testing.expect(model.overlay == null);

    try activateFromMouse(model, &ctx, .repair_database);
    try std.testing.expectEqual(.repair_database, model.overlay.?.sudo.action);
    try std.testing.expect(model.operation_state.install_job == null);
}

pub fn focusPaneFromMouse(model: *Model, ctx: *vxfw.EventContext, results: bool) void {
    if (!acceptsMouse(model) or model.utilities_state.repositories.editing != null) return;
    const state = &model.utilities_state;
    if (results and state.selected != .pacfiles and state.selected != .repository) return;
    state.results_focused = results;
    ctx.consumeAndRedraw();
}

pub fn selectResultFromMouse(model: *Model, ctx: *vxfw.EventContext, task: Task, name: []const u8) void {
    if (!acceptsMouse(model)) return;
    const state = &model.utilities_state;
    if (state.selected != task or state.repositories.editing != null) return;
    const names = switch (task) {
        .pacfiles => state.result orelse return,
        .repository => state.repositories.names orelse return,
        else => return,
    };
    for (names.value, 0..) |item, index| {
        if (!std.mem.eql(u8, item, name)) continue;
        const list = if (task == .pacfiles) &state.list else &state.repositories.list;
        list.cursor = @intCast(index);
        state.results_focused = true;
        return ctx.consumeAndRedraw();
    }
}

pub fn previewFromMouse(model: *Model, ctx: *vxfw.EventContext, diff: bool) !void {
    if (!acceptsMouse(model) or !model.settings_state.settings.expanded_mouse_support) return;
    const state = &model.utilities_state;
    if (state.selected != .pacfiles or state.message() != null) return;
    state.results_focused = true;
    try openPreview(model, ctx, if (diff) .diff else .file);
}

fn activate(model: *Model, ctx: *vxfw.EventContext) !void {
    const state = &model.utilities_state;
    switch (state.selected) {
        .pacfiles => {
            state.results_focused = true;
            try ensurePacfiles(model, ctx);
            ctx.consumeAndRedraw();
        },
        .cleanup, .flatpak_cleanup => {
            if (!state.selected.available(model)) return ctx.consumeEvent();
            try operation_model.startCleanup(model, ctx, if (state.selected == .cleanup) .standard else .flatpak);
        },
        .repair_permissions => try operation_model.openRepair(model, ctx, .repair_permissions),
        .repair_database => try operation_model.openRepair(model, ctx, .repair_database),
        .repository => try focusRepositories(model, ctx),
    }
}

pub fn ensureSelected(model: *Model, ctx: *vxfw.EventContext) !void {
    if (model.active == .utilities and model.utilities_state.selected == .repository) return ensureRepositories(model, ctx);
    try ensurePacfiles(model, ctx);
}

fn ensurePacfiles(model: *Model, ctx: *vxfw.EventContext) !void {
    const state = &model.utilities_state;
    if (model.active == .utilities and state.selected == .pacfiles and state.job == null and state.result == null and !state.failed)
        try discover(model, ctx);
}

fn discover(model: *Model, ctx: *vxfw.EventContext) !void {
    const state = &model.utilities_state;
    if (state.job != null) return ctx.consumeEvent();
    try ctx.tick(100, model.widget());
    const job = try model.gpa.create(Job);
    errdefer model.gpa.destroy(job);
    job.* = .{ .kind = .pacfiles };
    job.thread = try std.Thread.spawn(.{}, Job.run, .{job});
    state.job = job;
    ctx.consumeAndRedraw();
}

pub fn closePreviewFromMouse(ptr: ?*anyopaque, ctx: *vxfw.EventContext) !void {
    const model: *Model = @ptrCast(@alignCast(ptr orelse return));
    if (model.active != .utilities or model.help_open or !model.utilities_state.preview_open) return;
    model.utilities_state.preview_open = false;
    ctx.consumeAndRedraw();
}

fn openPreview(model: *Model, ctx: *vxfw.EventContext, kind: PreviewKind) !void {
    const state = &model.utilities_state;
    const result = state.result orelse return;
    if (state.job != null or state.list.cursor >= result.value.len) return;
    if (state.preview_job) |old| {
        if (!old.done.load(.acquire)) return ctx.consumeEvent();
        old.destroy(model.gpa);
        state.preview_job = null;
    }
    const path = try model.gpa.dupe(u8, result.value[state.list.cursor]);
    errdefer model.gpa.free(path);
    const job = try model.gpa.create(PreviewJob);
    errdefer model.gpa.destroy(job);
    job.* = .{ .kind = kind, .path = path, .thread = undefined };
    try ctx.tick(100, model.widget());
    job.thread = try std.Thread.spawn(.{}, PreviewJob.run, .{job});
    state.preview_job = job;
    state.preview_open = true;
    state.preview_list.scroll = .{};
    ctx.consumeAndRedraw();
}

pub fn previewLoading(state: *const State) bool {
    return if (state.preview_job) |job| !job.done.load(.acquire) else false;
}

pub fn previewView(model: *Model) preview.View {
    const state = &model.utilities_state;
    const job = state.preview_job.?;
    const loading = previewLoading(state);
    const failure = if (loading) null else job.failure;
    state.preview_list.item_count = if (!loading and job.result != null) @intCast(job.result.?.lines.len) else 0;
    return .{
        .name = job.path,
        .title = if (job.kind == .diff) "Pacfile diff (active → pending)" else "Pacfile contents",
        .back = if (model.settings_state.settings.expanded_mouse_support) &state.preview_back else null,
        .scroll = &state.preview_list,
        .wrap = state.preview_wrap,
        .loading = loading,
        .failure = failure,
        .failure_text = if (job.kind == .file) "Could not read the selected pacfile." else if (failure != null and failure.? == error.FileNotFound) "A file disappeared or the diff command is unavailable." else "Could not compare the files. Check file access and ensure diff is installed.",
        .scan_status = if (!loading) "" else if (job.kind == .diff) "Comparing configuration files…" else "Reading pacfile…",
    };
}

fn buildPreviewRow(ptr: *const anyopaque, index: usize, _: usize) ?vxfw.Widget {
    const model: *const Model = @ptrCast(@alignCast(ptr));
    const state = &model.utilities_state;
    const job = state.preview_job orelse return null;
    if (!job.done.load(.acquire)) return null;
    if (job.result) |*doc| return preview.rowWithWrap(doc, index, state.preview_wrap);
    return null;
}

pub fn moveActionFromMouse(model: *Model, ctx: *vxfw.EventContext, up: bool) !void {
    if (!acceptsMouse(model) or model.utilities_state.repositories.editing != null) return;
    model.utilities_state.results_focused = false;
    moveAction(model, up);
    try ensureSelected(model, ctx);
    ctx.consumeAndRedraw();
}

fn moveAction(model: *Model, up: bool) void {
    const state = &model.utilities_state;
    const tasks = std.enums.values(Task);
    var index: usize = @backingInt(state.selected);
    while (if (up) index > 0 else index < tasks.len - 1) {
        index = if (up) index - 1 else index + 1;
        if (tasks[index].available(model)) {
            state.selected = tasks[index];
            break;
        }
    }
}

pub fn handleKey(model: *Model, ctx: *vxfw.EventContext, key: vaxis.Key) !bool {
    const state = &model.utilities_state;
    if (state.selected == .repository and (state.results_focused or state.repositories.editing != null))
        return handleRepositoryKey(model, ctx, key);
    if (state.preview_open) {
        if (commands.closesPreview(key) or commands.matches(key, .cancel_capture)) {
            state.preview_open = false;
        } else if (commands.matches(key, .toggle_wrap)) {
            state.preview_wrap = !state.preview_wrap;
            state.preview_list.scroll.left = 0;
            state.preview_list.scroll.vertical_offset = 0;
        } else return false;
        ctx.consumeAndRedraw();
        return true;
    }
    if (state.selected == .pacfiles and state.results_focused and state.message() == null) {
        if (commands.matches(key, .confirm)) {
            try openPreview(model, ctx, .file);
            return true;
        }
        if (commands.matches(key, .pacfile_compare)) {
            try openPreview(model, ctx, .diff);
            return true;
        }
    }
    if (state.selected == .pacfiles and commands.matches(key, .refresh)) {
        try discover(model, ctx);
        return true;
    }
    if (commands.matches(key, .confirm)) {
        try activate(model, ctx);
        return true;
    }
    const direction = commands.scrollKey(key) orelse return false;
    switch (direction.codepoint) {
        vaxis.Key.left => state.results_focused = false,
        vaxis.Key.right => state.results_focused = state.selected == .pacfiles or state.selected == .repository,
        vaxis.Key.up, vaxis.Key.down => {
            if (state.results_focused) return false;
            moveAction(model, direction.codepoint == vaxis.Key.up);
        },
        else => return false,
    }
    try ensureSelected(model, ctx);
    ctx.consumeAndRedraw();
    return true;
}

pub fn handleScroll(model: *Model, ctx: *vxfw.EventContext, event: vxfw.Event) !void {
    const state = &model.utilities_state;
    const list = switch (state.selected) {
        .pacfiles => if (state.message() != null) return else if (state.preview_open) &state.preview_list else &state.list,
        .repository => if (state.repositories.selected() != null and state.repositories.editing == null) &state.repositories.list else return,
        else => return,
    };
    if (event == .key_press) {
        if (!model.utilities_state.results_focused) return;
        const key = commands.scrollKey(event.key_press) orelse event.key_press;
        const page_up = key.matches(vaxis.Key.page_up, .{});
        if (page_up or key.matches(vaxis.Key.page_down, .{})) {
            const page = @max(list.last_height, 1);
            if (model.utilities_state.preview_open) {
                const moved = if (page_up) list.scroll.linesUp(page) else list.scroll.linesDown(page);
                if (moved) ctx.consumeAndRedraw();
            } else {
                const last = (list.item_count orelse 0) -| 1;
                list.cursor = if (page_up) list.cursor -| page else @min(list.cursor +| page, last);
                list.ensureScroll();
                ctx.consumeAndRedraw();
            }
            return;
        }
        // Move the selection without asking ScrollView to wrap the row in a cursor gutter.
        if (!model.utilities_state.preview_open) {
            if (key.matches(vaxis.Key.up, .{})) return list.prevItem(ctx);
            if (key.matches(vaxis.Key.down, .{})) return list.nextItem(ctx);
        }
        return list.handleEvent(ctx, .{ .key_press = key });
    }
    try list.handleEvent(ctx, event);
}

test "Utilities switches actions with keyboard and keeps results navigation separate" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.active = .utilities;
    model.utilities_state.result = try std.json.parseFromSlice([][]const u8, std.testing.allocator, "[]", .{});
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(ctx.alloc);

    try model.captureEvent(&ctx, .{ .key_press = commands.bindings.next });
    try std.testing.expectEqual(Task.cleanup, model.utilities_state.selected);
    try std.testing.expectEqualStrings("Clean standard packages", model.commandContext().utilities_action);
    try model.captureEvent(&ctx, .{ .key_press = commands.bindings.previous });
    try model.captureEvent(&ctx, .{ .key_press = commands.bindings.details });
    try model.captureEvent(&ctx, .{ .key_press = commands.bindings.previous });
    try std.testing.expectEqual(Task.pacfiles, model.utilities_state.selected);
    try std.testing.expect(model.utilities_state.results_focused);
    try model.captureEvent(&ctx, .{ .key_press = commands.bindings.back });
    try model.captureEvent(&ctx, .{ .key_press = commands.bindings.previous });
    try std.testing.expectEqual(Task.pacfiles, model.utilities_state.selected);
    try std.testing.expectEqualStrings("Browse files", model.commandContext().utilities_action);
}

test "pacfile preview shows file contents, changes, and backups without an active file" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "app.conf", .data = "setting=old\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "app.conf.pacnew", .data = "setting=new\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "removed.conf.pacsave", .data = "saved=true\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "app.conf.pacsave.2", .data = "setting=backup\n" });
    const pacnew = try tmp.dir.realPathFileAlloc(io, "app.conf.pacnew", allocator);
    defer allocator.free(pacnew);
    const pacsave = try tmp.dir.realPathFileAlloc(io, "removed.conf.pacsave", allocator);
    defer allocator.free(pacsave);
    var contents = try readPacfile(allocator, io, pacnew);
    defer contents.deinit();
    try std.testing.expect(std.mem.endsWith(u8, contents.lines[0], "setting=new"));
    var changed = compare(allocator, io, pacnew) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest, // diff may be absent on a build host.
        else => return err,
    };
    defer changed.deinit();
    const lines = try std.mem.join(allocator, "\n", changed.lines);
    defer allocator.free(lines);
    try std.testing.expect(std.mem.indexOf(u8, lines, "-setting=old") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines, "+setting=new") != null);
    var saved = try compare(allocator, io, pacsave);
    defer saved.deinit();
    const saved_lines = try std.mem.join(allocator, "\n", saved.lines);
    defer allocator.free(saved_lines);
    try std.testing.expect(std.mem.indexOf(u8, saved_lines, "+saved=true") != null);
    const numbered = try tmp.dir.realPathFileAlloc(io, "app.conf.pacsave.2", allocator);
    defer allocator.free(numbered);
    var rotated = try compare(allocator, io, numbered);
    defer rotated.deinit();
    const rotated_lines = try std.mem.join(allocator, "\n", rotated.lines);
    defer allocator.free(rotated_lines);
    try std.testing.expect(std.mem.indexOf(u8, rotated_lines, "-setting=old") != null);
    try std.testing.expect(std.mem.indexOf(u8, rotated_lines, "+setting=backup") != null);
    try std.testing.expectError(error.InvalidPacfile, activePacfilePath("/etc/app.conf.pacsave.old"));
}

test "permission repair remains reachable with Flatpak disabled and opens a confirmation" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.active = .utilities;
    model.settings_state.settings.flatpak_enabled = false;
    model.utilities_state.selected = .cleanup;
    model.utilities_state.repositories.names = try std.json.parseFromSlice([][]const u8, model.gpa, "[]", .{});
    model.utilities_state.result = try std.json.parseFromSlice([][]const u8, std.testing.allocator, "[]", .{});
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(ctx.alloc);
    try model.captureEvent(&ctx, .{ .key_press = commands.bindings.next });
    try std.testing.expectEqual(Task.repair_permissions, model.utilities_state.selected);
    try model.captureEvent(&ctx, .{ .key_press = commands.bindings.confirm });
    const prompt = model.overlay.?.sudo;
    try std.testing.expectEqual(@import("../services/shelly_operation.zig").Action.repair_permissions, prompt.action);
    try std.testing.expectEqual(@TypeOf(prompt.state).entering, prompt.state);
    try std.testing.expect(model.operation_state.install_job == null);

    try model.captureEvent(&ctx, .{ .key_press = commands.bindings.cancel });
    try std.testing.expect(model.overlay == null);
    try model.captureEvent(&ctx, .{ .key_press = commands.bindings.next });
    try std.testing.expectEqual(Task.repair_database, model.utilities_state.selected);
    try model.captureEvent(&ctx, .{ .key_press = commands.bindings.confirm });
    try std.testing.expectEqual(@import("../services/shelly_operation.zig").Action.repair_database, model.overlay.?.sudo.action);
    try std.testing.expect(model.operation_state.install_job == null);
    try model.captureEvent(&ctx, .{ .key_press = commands.bindings.cancel });
    try std.testing.expect(model.overlay == null);
    for (0..3) |_| try model.captureEvent(&ctx, .{ .key_press = commands.bindings.next });
    try std.testing.expectEqual(Task.repository, model.utilities_state.selected);
    for (0..5) |_| try model.captureEvent(&ctx, .{ .key_press = commands.bindings.previous });
    try std.testing.expectEqual(Task.pacfiles, model.utilities_state.selected);
}

pub const RepositoryField = enum { name, url };

const RepositoryState = struct {
    editing: ?RepositoryField = null,
    name: vxfw.TextField,
    url: vxfw.TextField,
    list: vxfw.ScrollView,
    names: ?StringList = null,
    job: ?*Job = null,
    message: []const u8 = "",
    verification: ?struct { name: []const u8, should_exist: ?bool } = null,

    pub fn init(model: *Model, allocator: Allocator) RepositoryState {
        return .{
            .name = vxfw.TextField.init(allocator),
            .url = vxfw.TextField.init(allocator),
            .list = .{ .children = .{ .builder = .{ .userdata = model, .buildFn = buildRepositoryRow } } },
        };
    }

    pub fn deinit(self: *RepositoryState, allocator: Allocator) void {
        if (self.job) |job| {
            job.thread.join();
            if (job.result) |*names| names.deinit();
            allocator.destroy(job);
        }
        if (self.names) |*names| names.deinit();
        if (self.verification) |verification| allocator.free(verification.name);
        self.name.deinit();
        self.url.deinit();
    }

    pub fn verifyAfterOperation(self: *RepositoryState, allocator: Allocator, name: []const u8, should_exist: ?bool) !void {
        const owned = try allocator.dupe(u8, name);
        if (self.verification) |previous| allocator.free(previous.name);
        self.verification = .{ .name = owned, .should_exist = should_exist };
        self.message = "Checking repository configuration…";
    }

    pub fn field(self: *RepositoryState, which: RepositoryField) *vxfw.TextField {
        return if (which == .name) &self.name else &self.url;
    }

    pub fn selected(self: *const RepositoryState) ?[]const u8 {
        const names = self.names orelse return null;
        if (self.list.cursor >= names.value.len) return null;
        return names.value[self.list.cursor];
    }
};

fn buildRepositoryRow(ptr: *const anyopaque, index: usize, cursor: usize) ?vxfw.Widget {
    const model: *const Model = @ptrCast(@alignCast(ptr));
    const names = model.utilities_state.repositories.names orelse return null;
    if (index >= names.value.len) return null;
    return .{ .userdata = @ptrCast(&names.value[index]), .drawFn = if (index == cursor and model.utilities_state.results_focused) utilities_view.drawSelectedPath else utilities_view.drawPath };
}

fn ensureRepositories(model: *Model, ctx: *vxfw.EventContext) !void {
    const state = &model.utilities_state.repositories;
    if (state.names == null and state.message.len == 0) try refreshRepositories(model, ctx);
}

fn refreshRepositories(model: *Model, ctx: *vxfw.EventContext) !void {
    const state = &model.utilities_state.repositories;
    if (state.job != null) return;
    try ctx.tick(100, model.widget());
    const job = try model.gpa.create(Job);
    errdefer model.gpa.destroy(job);
    job.* = .{ .kind = .repositories };
    job.thread = try std.Thread.spawn(.{}, Job.run, .{job});
    state.job = job;
    state.message = if (state.verification != null) "Checking repository configuration…" else "Loading repositories…";
    ctx.consumeAndRedraw();
}

pub fn pollRepositories(model: *Model, ctx: *vxfw.EventContext) !void {
    const state = &model.utilities_state.repositories;
    const job = state.job orelse {
        if (state.verification != null) try refreshRepositories(model, ctx);
        return;
    };
    if (!job.done.load(.acquire)) return;
    job.thread.join();
    state.job = null;
    defer model.gpa.destroy(job);

    const previous = state.selected();
    if (job.result) |names| {
        state.list.cursor = 0;
        if (previous) |name| {
            for (names.value, 0..) |item, index| {
                if (std.mem.eql(u8, item, name)) {
                    state.list.cursor = @intCast(index);
                    break;
                }
            }
        }
    }
    if (state.names) |*old| old.deinit();
    state.names = job.result;
    state.list.item_count = if (state.names) |names| @intCast(names.value.len) else 0;
    state.list.scroll = .{};
    if (state.list.item_count.? > 0) state.list.ensureScroll();

    if (state.verification) |verification| {
        defer model.gpa.free(verification.name);
        state.verification = null;
        const should_exist = verification.should_exist orelse {
            state.message = if (state.names == null) "Could not reload repositories." else "";
            return;
        };
        const warning = if (state.names) |names| blk: {
            var present = false;
            for (names.value) |name| {
                if (std.mem.eql(u8, name, verification.name)) {
                    present = true;
                    break;
                }
            }
            break :blk if (present == should_exist) null else if (present)
                "Repository is still configured. Check the included configuration files."
            else
                "The added repository is missing from the configuration.";
        } else "Could not reload the repository list to verify the change.";

        state.message = warning orelse if (should_exist) "Repository is configured." else "Repository is no longer configured.";
        if (warning) |message| {
            if (operation_model.operationPrompt(model)) |prompt| {
                if (prompt.state == .succeeded and prompt.action.isRepositoryMutation()) {
                    const detail = try model.gpa.dupe(u8, message);
                    if (prompt.detail.len != 0) model.gpa.free(prompt.detail);
                    prompt.detail = detail;
                    prompt.state = .failed;
                }
            }
        }
    } else {
        state.message = if (state.names == null) "Could not load repositories." else if (state.list.item_count.? == 0) "No repositories are configured." else "";
    }
}

fn focusRepositories(model: *Model, ctx: *vxfw.EventContext) !void {
    model.utilities_state.results_focused = true;
    try ensureRepositories(model, ctx);
    ctx.consumeAndRedraw();
}

pub const RepositoryControl = union(enum) { add, remove, refresh, back, review, focus_field: RepositoryField };

pub fn repositoryControl(model: *Model, ctx: *vxfw.EventContext, action: RepositoryControl) !void {
    const state = &model.utilities_state.repositories;
    if (model.active != .utilities or model.help_open or model.overlay != null or model.utilities_state.selected != .repository) return;
    switch (action) {
        .focus_field => |field| {
            if (state.editing == null) return;
            try focusRepositoryField(state, ctx, field);
        },
        .review => {
            if (state.editing == null) return;
            try submitRepository(model, ctx);
        },
        .back => {
            if (state.editing != null) {
                try ctx.requestFocus(model.widget());
                state.editing = null;
                state.message = "";
            } else model.utilities_state.results_focused = false;
        },
        .refresh => try refreshRepositories(model, ctx),
        .add, .remove => {
            if (state.job != null or state.verification != null or model.operation_state.install_job != null) return ctx.consumeEvent();
            model.utilities_state.results_focused = true;
            if (action == .remove) {
                if (state.selected()) |name| try operation_model.openRepositoryPrompt(model, ctx, name, null);
            } else {
                state.name.clearRetainingCapacity();
                state.url.clearRetainingCapacity();
                state.message = "";
                try focusRepositoryField(state, ctx, .name);
            }
        },
    }
    ctx.consumeAndRedraw();
}

fn handleRepositoryKey(model: *Model, ctx: *vxfw.EventContext, key: vaxis.Key) !bool {
    const state = &model.utilities_state.repositories;
    if (state.editing != null) {
        if (commands.matches(key, .cancel_capture)) {
            try repositoryControl(model, ctx, .back);
            return true;
        } else if (key.matches(vaxis.Key.tab, .{})) {
            try focusRepositoryField(state, ctx, if (state.editing.? == .name) .url else .name);
        } else if (commands.matches(key, .confirm)) {
            if (state.editing.? == .name) try focusRepositoryField(state, ctx, .url) else try submitRepository(model, ctx);
        } else {
            state.message = "";
            try state.field(state.editing.?).handleEvent(ctx, .{ .key_press = key });
        }
        ctx.consumeAndRedraw();
        return true;
    }

    if (commands.matches(key, .back) or commands.matches(key, .close) or commands.matches(key, .cancel_capture)) {
        try repositoryControl(model, ctx, .back);
    } else if (commands.matches(key, .install)) {
        try repositoryControl(model, ctx, .add);
    } else if (commands.matches(key, .remove)) {
        try repositoryControl(model, ctx, .remove);
    } else if (commands.matches(key, .refresh_list)) {
        try repositoryControl(model, ctx, .refresh);
    } else return false;
    return true;
}

fn focusRepositoryField(state: *RepositoryState, ctx: *vxfw.EventContext, which: RepositoryField) !void {
    try ctx.requestFocus(state.field(which).widget());
    state.editing = which;
}

pub fn pasteRepository(model: *Model, ctx: *vxfw.EventContext, text: []const u8) !bool {
    const state = &model.utilities_state.repositories;
    if (model.active != .utilities or model.utilities_state.selected != .repository or model.help_open or model.overlay != null) return false;
    const editing = state.editing orelse return false;
    try state.field(editing).insertSliceAtCursor(text);
    ctx.consumeAndRedraw();
    return true;
}

fn submitRepository(model: *Model, ctx: *vxfw.EventContext) !void {
    const state = &model.utilities_state.repositories;
    const name = try state.name.buf.dupe();
    defer model.gpa.free(name);
    const url = try state.url.buf.dupe();
    defer model.gpa.free(url);

    if (!validRepositoryName(name)) {
        state.message = "Enter a repository name using letters, numbers, dots, underscores, or hyphens.";
        try focusRepositoryField(state, ctx, .name);
        return;
    }
    if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "file://")) {
        state.message = "Enter an HTTPS, HTTP, or file URL.";
        try focusRepositoryField(state, ctx, .url);
        return;
    }
    for (url) |byte| {
        if (byte <= ' ' or byte == 0x7f or byte == '#') {
            state.message = "Server URLs must be a single line without spaces or comments.";
            try focusRepositoryField(state, ctx, .url);
            return;
        }
    }
    try operation_model.openRepositoryPrompt(model, ctx, name, url);
    state.editing = null;
}

fn validRepositoryName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '-' or std.ascii.eqlIgnoreCase(name, "options") or
        std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "._-", byte) == null) return false;
    }
    return true;
}

test "repository removal names the selected entry and warns before starting sudo" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.active = .utilities;
    model.utilities_state.selected = .repository;
    model.utilities_state.results_focused = true;
    model.utilities_state.repositories.names = try std.json.parseFromSlice([][]const u8, model.gpa, "[\"core\",\"included-test\"]", .{ .allocate = .alloc_always });
    model.utilities_state.repositories.list.item_count = 2;
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = model.gpa, .cmds = .empty };
    defer ctx.cmds.deinit(model.gpa);
    try Model.typeErasedEventHandler(model, &ctx, .{ .key_press = commands.bindings.next });
    try model.captureEvent(&ctx, .{ .key_press = commands.bindings.remove });
    const prompt = model.overlay.?.sudo;
    try std.testing.expectEqualStrings("included-test", prompt.name);
    try std.testing.expect(std.mem.indexOf(u8, prompt.review_text, "included file") != null);
    try std.testing.expect(prompt.state == .entering);
    try std.testing.expect(model.operation_state.install_job == null);
}

test "repository add reviews the literal server URL and rejects config line injection" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.active = .utilities;
    model.utilities_state.selected = .repository;
    model.utilities_state.results_focused = true;
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = model.gpa, .cmds = .empty };
    defer ctx.cmds.deinit(model.gpa);
    try model.captureEvent(&ctx, .{ .key_press = commands.bindings.install });
    try std.testing.expect(try pasteRepository(model, &ctx, "custom"));
    try model.captureEvent(&ctx, .{ .key_press = commands.bindings.confirm });
    try std.testing.expect(try pasteRepository(model, &ctx, "https://example.invalid/\nSigLevel = Never"));
    try model.captureEvent(&ctx, .{ .key_press = commands.bindings.confirm });
    try std.testing.expect(model.overlay == null);
    model.utilities_state.repositories.url.clearRetainingCapacity();
    try std.testing.expect(try pasteRepository(model, &ctx, "https://example.invalid/$repo/$arch"));
    try model.captureEvent(&ctx, .{ .key_press = commands.bindings.confirm });
    const prompt = model.overlay.?.sudo;
    try std.testing.expectEqualStrings("custom", prompt.name);
    try std.testing.expectEqualStrings("https://example.invalid/$repo/$arch", prompt.repository_url.?);
    try std.testing.expect(model.operation_state.install_job == null);
}

test "read-back catches a repository still present after reported removal" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.active = .utilities;
    model.utilities_state.selected = .repository;
    model.utilities_state.results_focused = true;
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = model.gpa, .cmds = .empty };
    defer ctx.cmds.deinit(model.gpa);
    try operation_model.openRepositoryPrompt(model, &ctx, "included-test", null);
    model.overlay.?.sudo.state = .succeeded;
    try model.utilities_state.repositories.verifyAfterOperation(model.gpa, "included-test", false);
    const names = try std.json.parseFromSlice([][]const u8, model.gpa, "[\"included-test\"]", .{ .allocate = .alloc_always });
    const job = try model.gpa.create(Job);
    job.* = .{
        .kind = .repositories,
        .thread = try std.Thread.spawn(.{}, struct {
            fn finish() void {}
        }.finish, .{}),
        .result = names,
        .done = .init(true),
    };
    model.utilities_state.repositories.job = job;
    try pollRepositories(model, &ctx);
    try std.testing.expect(model.overlay.?.sudo.state == .failed);
    try std.testing.expectEqualStrings("Repository is still configured. Check the included configuration files.", model.overlay.?.sudo.detail);
    try std.testing.expectEqualStrings("included-test", model.utilities_state.repositories.selected().?);
}
