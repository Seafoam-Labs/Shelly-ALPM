//! Read-only maintenance queries for the Utilities tab.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Model = @import("../model.zig").Model;
const commands = @import("../commands.zig");
const ShellyCli = @import("../services/shelly_cli.zig").ShellyCli;
const utilities_view = @import("../views/utilities_view.zig");

const Pacfiles = std.json.Parsed([][]const u8);
const Job = struct {
    thread: std.Thread,
    result: ?Pacfiles = null,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *Job) void {
        const allocator = std.heap.page_allocator;
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const cli: ShellyCli = .{ .allocator = allocator, .io = threaded.io() };
        self.result = cli.get_pacfiles() catch null;
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

    pub fn label(self: Task) []const u8 {
        return switch (self) {
            .pacfiles => "List pacfiles",
            .cleanup => "Clean standard packages",
            .flatpak_cleanup => "Clean unused Flatpaks",
        };
    }

    pub fn available(self: Task, model: *const Model) bool {
        return self != .flatpak_cleanup or (model.settings_state.settings.flatpak_enabled and model.flatpak_state.flatpak_available);
    }
};

pub const State = struct {
    selected: Task = .pacfiles,
    results_focused: bool = false,
    job: ?*Job = null,
    result: ?Pacfiles = null,
    failed: bool = false,
    list: vxfw.ScrollView,
    preview_job: ?*PreviewJob = null,
    preview_open: bool = false,
    preview_wrap: bool = true,
    preview_list: vxfw.ScrollView,
    preview_back: vxfw.Button,

    pub fn init(model: *Model) State {
        return .{
            .preview_list = .{ .children = .{ .builder = .{ .userdata = model, .buildFn = buildPreviewRow } } },
            .preview_back = .{ .label = "[<]", .userdata = model, .onClick = commands.Mouse.closePacfilePreview, .style = @import("../views/components/styles.zig").action_button },
            .list = .{ .children = .{ .builder = .{ .userdata = model, .buildFn = buildRow } } },
        };
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
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

pub fn activateFromMouse(model: *Model, ctx: *vxfw.EventContext, task: Task) !void {
    if (model.active != .utilities or model.help_open or model.overlay != null or model.utilities_state.preview_open or !model.settings_state.settings.expanded_mouse_support or !task.available(model)) return;
    model.utilities_state.selected = task;
    try activate(model, ctx);
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
            try @import("operation_model.zig").startCleanup(model, ctx, if (state.selected == .cleanup) .standard else .flatpak);
        },
    }
}

pub fn ensurePacfiles(model: *Model, ctx: *vxfw.EventContext) !void {
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
    job.* = .{ .thread = undefined };
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

pub fn handleKey(model: *Model, ctx: *vxfw.EventContext, key: vaxis.Key) !bool {
    const state = &model.utilities_state;
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
        vaxis.Key.right => state.results_focused = state.selected == .pacfiles,
        vaxis.Key.up, vaxis.Key.down => {
            if (state.results_focused) return false;
            const tasks = std.enums.values(Task);
            const index = @backingInt(state.selected);
            const next = if (direction.codepoint == vaxis.Key.up) index -| 1 else @min(index + 1, tasks.len - 1);
            if (tasks[next].available(model)) state.selected = tasks[next];
        },
        else => return false,
    }
    try ensurePacfiles(model, ctx);
    ctx.consumeAndRedraw();
    return true;
}

pub fn handleScroll(model: *Model, ctx: *vxfw.EventContext, event: vxfw.Event) !void {
    if (model.utilities_state.selected != .pacfiles or model.utilities_state.message() != null) return;
    const list = if (model.utilities_state.preview_open) &model.utilities_state.preview_list else &model.utilities_state.list;
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
