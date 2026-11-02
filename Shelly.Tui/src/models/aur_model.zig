//! AUR searches, installed listings, batch selection, and details.
const operation_model = @import("operation_model.zig");
const std = @import("std");
const commands = @import("../commands.zig");
const aur_view = @import("../views/aur_view.zig");
const pkgbuild_view = @import("../views/pkgbuild_view.zig");
const PkgBuild = @import("pkgbuild.zig").PkgBuild;
const shelly_operation = @import("../services/shelly_operation.zig");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const shelly_cli = @import("../services/shelly_cli.zig");
const ShellyCli = shelly_cli.ShellyCli;
const Package = @import("packages.zig").Package;
const AurPackage = @import("packages.zig").AurPackage;

const Allocator = std.mem.Allocator;
const OperationBackend = shelly_operation.Backend;

const coordinator = @import("../model.zig");
const Model = coordinator.Model;
const Tab = coordinator.Tab;
const PkgbuildJob = operation_model.PkgbuildJob;
const SudoPrompt = operation_model.SudoPrompt;

/// Page-owned state. Worker results are published to the UI loop before use.
pub const State = struct {
    aur_selection: std.ArrayList(AurSelection) = .empty,

    /// AUR tab state.
    aur_packages: []const AurPackage = &.{},
    aur_parsed: ?std.json.Parsed([]AurPackage) = null,
    aur_job: ?*AurSearchJob = null,
    /// Last executed AUR query; owned by `gpa` unless empty.
    aur_query: []const u8 = "",
    aur_failed: bool = false,
    aur_installed_only: bool = false,
    aur_thread: ?std.Thread = null,
    aur_filtered: std.ArrayList(*const AurPackage) = .empty,
    refresh_aur_after_operation: bool = false,
    aur_list: vxfw.ListView,
    aur_preview_button: vxfw.Button,
    aur_details_scroll: vxfw.ScrollView,
    aur_details_cursor: ?u32 = null,
    aur_list_active: bool = false,
    aur_field: vxfw.TextField,
};

pub const AurSearchJob = struct {
    installed_only: bool = false,
    result: ?std.json.Parsed([]AurPackage) = null,
    failed: bool = false,
    done: std.atomic.Value(bool) = .init(false),
};

pub const AurSelection = struct { name: []const u8, installed: bool };

pub fn init(gpa: Allocator, model: *Model) State {
    return .{
        .aur_preview_button = .{ .label = " PKGBUILD ", .userdata = model, .onClick = onAurPreviewClick, .style = .{
            .default = .{ .fg = .{ .index = 0 }, .bg = .{ .index = 7 } },
            .focus = .{ .fg = .{ .index = 0 }, .bg = .{ .index = 15 }, .bold = true },
            .hover = .{ .fg = .{ .index = 0 }, .bg = .{ .index = 15 }, .bold = true },
            .mouse_down = .{ .reverse = true },
        } },
        .aur_details_scroll = .{ .item_count = 2, .children = .{ .builder = .{ .userdata = model, .buildFn = buildAurDetails } } },
        .aur_list = .{
            .children = .{ .builder = .{
                .userdata = model,
                .buildFn = buildAurRow,
            } },
        },
        .aur_field = .{
            .buf = .init(gpa),
            .userdata = model,
            .onSubmit = onAurSubmit,
            .onChange = onAurQueryChange,
        },
    };
}

pub fn deinit(self: *Model) void {
    const gpa = self.gpa;

    self.aur_state.aur_field.deinit();
    clearAurSelection(self);
    self.aur_state.aur_selection.deinit(gpa);
    if (self.aur_state.aur_thread) |thread| thread.join();
    if (self.aur_state.aur_job) |job| {
        if (job.result) |*result| result.deinit();
        gpa.destroy(job);
    }
    self.aur_state.aur_filtered.deinit(gpa);
    if (self.aur_state.aur_query.len > 0) gpa.free(self.aur_state.aur_query);
    if (self.aur_state.aur_parsed) |*parsed| parsed.deinit();
}

pub fn onAurSubmit(maybe_ptr: ?*anyopaque, ctx: *vxfw.EventContext, str: []const u8) anyerror!void {
    const ptr = maybe_ptr orelse return;
    const self: *Model = @ptrCast(@alignCast(ptr));
    if (!self.settings_state.settings.aur_enabled) return;
    const query = std.mem.trim(u8, str, " \t");

    if (self.aur_state.aur_job != null) return;
    if (self.aur_state.aur_installed_only) {
        if (self.aur_state.aur_list.cursor < self.aur_state.aur_filtered.items.len)
            self.overlay = .{ .aur = self.aur_state.aur_filtered.items[self.aur_state.aur_list.cursor] };
        self.aur_state.aur_list_active = true;
        return ctx.consumeAndRedraw();
    }
    // Enter with an unchanged query opens the selected result instead
    // of repeating the search
    if (self.aur_state.aur_filtered.items.len > 0 and
        (query.len == 0 or std.mem.eql(u8, query, self.aur_state.aur_query)))
    {
        if (@as(usize, self.aur_state.aur_list.cursor) < self.aur_state.aur_filtered.items.len) {
            self.overlay = .{ .aur = self.aur_state.aur_filtered.items[self.aur_state.aur_list.cursor] };
            self.aur_state.aur_list_active = true;
            return ctx.consumeAndRedraw();
        }
        return;
    }
    if (query.len == 0) return;
    if (self.aur_state.aur_job != null) return; // search in flight
    try startAurSearch(self, ctx, query);
}

pub fn startAurSearch(self: *Model, ctx: *vxfw.EventContext, query: []const u8) !void {
    if (!self.settings_state.settings.aur_enabled) return;
    try ctx.tick(100, self.widget());
    const job = try self.gpa.create(AurSearchJob);
    errdefer self.gpa.destroy(job);
    job.* = .{ .installed_only = self.aur_state.aur_installed_only };

    const duped = try self.gpa.dupe(u8, query);
    errdefer self.gpa.free(duped);
    const thread = try std.Thread.spawn(.{}, aurSearchThread, .{ job, duped });
    if (self.aur_state.aur_query.len > 0) self.gpa.free(self.aur_state.aur_query);
    self.aur_state.aur_query = duped;
    self.aur_state.aur_failed = false;
    self.aur_state.aur_job = job;

    self.aur_state.aur_thread = thread;
}

pub fn aurSearchThread(job: *AurSearchJob, query: []const u8) void {
    const alloc = std.heap.page_allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();

    const cli: ShellyCli = .{ .allocator = alloc, .io = threaded.io() };
    const parsed = (if (job.installed_only) cli.list_aur_installed() else if (query.len == 0) std.json.parseFromSlice([]AurPackage, alloc, "[]", .{}) else cli.search_aur(query)) catch {
        job.failed = true;
        job.done.store(true, .release);
        return;
    };

    const configured = cli.get_aur_source() catch null;
    defer if (configured) |value| value.deinit();
    const base = parsed.arena.allocator().dupe(u8, if (configured) |value| value.value.AurUrl else "https://aur.archlinux.org") catch {
        parsed.deinit();
        job.failed = true;
        job.done.store(true, .release);
        return;
    };
    for (parsed.value) |*pkg| pkg.AurBaseUrl = base;

    if (job.installed_only) {
        for (parsed.value) |*pkg| pkg.Installed = true;
        job.result = parsed;
        job.done.store(true, .release);
        return;
    }
    const installed = cli.get_installed_packages() catch {
        parsed.deinit();
        job.failed = true;
        job.done.store(true, .release);
        return;
    };
    defer installed.deinit();
    for (parsed.value) |*pkg| {
        for (installed.value) |local| {
            if (std.mem.eql(u8, pkg.Name, local.Name)) {
                pkg.Installed = true;
                break;
            }
        }
    }

    job.result = parsed;
    job.done.store(true, .release);
}

pub fn pollAurSearch(self: *Model) !bool {
    const job = self.aur_state.aur_job orelse return false;
    if (!job.done.load(.acquire)) return true;

    if (self.aur_state.aur_thread) |thread| thread.join();
    self.aur_state.aur_thread = null;
    const parsed = job.result;
    const failed = job.failed;
    self.aur_state.aur_job = null;
    self.gpa.destroy(job);
    if (!self.settings_state.settings.aur_enabled) {
        if (parsed) |owner| owner.deinit();
        return false;
    }

    if (self.overlay) |overlay| {
        if (overlay == .aur) self.overlay = null;
    }
    if (self.aur_state.aur_parsed) |*old| old.deinit();
    self.aur_state.aur_parsed = null;
    self.aur_state.aur_packages = &.{};
    self.aur_state.aur_failed = failed;
    if (parsed) |p| {
        self.aur_state.aur_parsed = p;
        self.aur_state.aur_packages = p.value;
        for (self.aur_state.aur_selection.items) |*selected| for (p.value) |pkg| {
            if (std.mem.eql(u8, selected.name, pkg.Name)) {
                selected.installed = pkg.Installed;
                break;
            }
        };
    }
    try rebuildAurFilter(self);
    return false;
}

pub fn aurMarked(self: *const Model, name: []const u8) bool {
    for (self.aur_state.aur_selection.items) |selected| if (std.mem.eql(u8, selected.name, name)) return true;
    return false;
}

pub fn clearAurSelection(self: *Model) void {
    for (self.aur_state.aur_selection.items) |selected| self.gpa.free(selected.name);
    self.aur_state.aur_selection.clearRetainingCapacity();
}

pub fn toggleAurSelection(self: *Model) !void {
    const pkg = selectedAur(self) orelse return;
    for (self.aur_state.aur_selection.items, 0..) |selected, index| {
        if (std.mem.eql(u8, selected.name, pkg.Name)) {
            self.gpa.free(self.aur_state.aur_selection.orderedRemove(index).name);
            return;
        }
    }
    const name = try self.gpa.dupe(u8, pkg.Name);
    errdefer self.gpa.free(name);
    try self.aur_state.aur_selection.append(self.gpa, .{ .name = name, .installed = pkg.Installed });
}

pub fn openAurPrompt(self: *Model, action: shelly_operation.Action) !void {
    if (!self.settings_state.settings.aur_enabled or self.operation_state.install_job != null) return;
    var packages: std.ArrayList(Package) = .empty;
    defer packages.deinit(self.gpa);
    for (self.aur_state.aur_selection.items) |selected| try packages.append(self.gpa, .{ .Name = selected.name, .Installed = selected.installed });
    if (packages.items.len == 0) {
        const pkg = selectedAur(self) orelse return;
        try packages.append(self.gpa, .{ .Name = pkg.Name, .Installed = pkg.Installed });
    }
    try operation_model.openPackageBatchPrompt(self, action, .aur, packages.items, true);
}

pub fn onAurQueryChange(ptr: ?*anyopaque, _: *vxfw.EventContext, _: []const u8) anyerror!void {
    const self: *Model = @ptrCast(@alignCast(ptr orelse return));
    if (self.aur_state.aur_installed_only) try rebuildAurFilter(self);
}

pub fn rebuildAurFilter(self: *Model) Allocator.Error!void {
    self.aur_state.aur_details_scroll.scroll = .{};
    self.aur_state.aur_details_cursor = null;
    self.aur_state.aur_filtered.clearRetainingCapacity();
    if (self.aur_state.aur_job != null) {
        self.aur_state.aur_list.item_count = 0;
        self.aur_state.aur_list.jumpToItem(0);
        return;
    }
    const query = try self.aur_state.aur_field.buf.dupe();
    defer self.gpa.free(query);
    for (self.aur_state.aur_packages) |*pkg| {
        if (!self.aur_state.aur_installed_only or query.len == 0 or Model.containsFold(pkg.Name, query) or Model.containsFold(pkg.Description orelse "", query))
            try self.aur_state.aur_filtered.append(self.gpa, pkg);
    }
    self.aur_state.aur_list.item_count = @intCast(self.aur_state.aur_filtered.items.len);
    self.aur_state.aur_list.jumpToItem(0);
}

pub fn aurView(self: *Model) aur_view.View {
    if (self.aur_state.aur_details_cursor == null or self.aur_state.aur_details_cursor.? != self.aur_state.aur_list.cursor) {
        self.aur_state.aur_details_scroll.scroll = .{};
        self.aur_state.aur_preview_button.focused = false;
        self.aur_state.aur_details_cursor = self.aur_state.aur_list.cursor;
    }
    return .{
        .list_percent = self.list_percent,
        .aur_field = &self.aur_state.aur_field,
        .selected = selectedAur(self),
        .details_scroll = &self.aur_state.aur_details_scroll,
        .details_active = !self.help_open and self.overlay != null and self.overlay.? == .aur,
        .list_active = self.aur_state.aur_list_active and !self.help_open,
        .preview = if (self.overlay != null and self.overlay.? == .pkgbuild) operation_model.pkgbuildView(self) else null,
        .help = if (self.help_open) &self.help_panel else null,
        .aur_list = &self.aur_state.aur_list,
        .searching = self.aur_state.aur_job != null,
        .aur_failed = self.aur_state.aur_failed,
        .aur_query = self.aur_state.aur_query,
        .result_count = self.aur_state.aur_filtered.items.len,
        .installed_only = self.aur_state.aur_installed_only,
    };
}

pub fn selectedAur(self: *const Model) ?*const AurPackage {
    if (self.aur_state.aur_job != null or self.aur_state.aur_list.cursor >= self.aur_state.aur_filtered.items.len) return null;
    return self.aur_state.aur_filtered.items[self.aur_state.aur_list.cursor];
}

pub fn onAurPreviewClick(ptr: ?*anyopaque, ctx: *vxfw.EventContext) anyerror!void {
    const self: *Model = @ptrCast(@alignCast(ptr.?));
    if (selectedAur(self)) |pkg| try operation_model.openPkgbuild(self, ctx, pkg.Name);
    ctx.consumeAndRedraw();
}

pub fn buildAurDetails(ptr: *const anyopaque, index: usize, _: usize) ?vxfw.Widget {
    if (index > 1) return null;
    const self: *const Model = @ptrCast(@alignCast(ptr));
    const pkg = selectedAur(self) orelse return null;
    if (index == 1) {
        var button_widget = @constCast(&self.aur_state.aur_preview_button).widget();
        button_widget.drawFn = aur_view.drawPreviewButton;
        return button_widget;
    }
    return .{ .userdata = @constCast(pkg), .drawFn = aur_view.drawDetails };
}

pub fn buildAurRow(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
    const self: *const Model = @ptrCast(@alignCast(ptr));
    if (idx >= self.aur_state.aur_filtered.items.len) return null;
    const pkg = self.aur_state.aur_filtered.items[idx];
    return .{
        .userdata = @constCast(pkg),
        .drawFn = if (aurMarked(self, pkg.Name)) aur_view.drawSelectedAurRow else aur_view.drawAurRow,
    };
}

test "PKGBUILD preview renders scrolls and returns to AUR details" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.active = .aur;
    var package = [_]AurPackage{.{ .Name = "demo" }};
    model.aur_state.aur_packages = &package;
    model.operation_state.pkgbuild_name = try std.testing.allocator.dupe(u8, "demo");
    const line = "echo a long source line with content and more content and more content and more content\n";
    var source_buffer: [line.len * 80]u8 = undefined;
    for (0..80) |index| @memcpy(source_buffer[index * line.len ..][0..line.len], line);
    const source = &source_buffer;
    model.operation_state.pkgbuild_document = try pkgbuild_view.Document.init(std.testing.allocator, &.{.{ .Name = "demo", .PkgBuild = source }});
    model.operation_state.pkgbuild_scroll.item_count = @intCast(model.operation_state.pkgbuild_document.?.lines.len);
    model.overlay = .pkgbuild;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]vxfw.Size{ .{ .width = 80, .height = 24 }, .{ .width = 40, .height = 12 } }) |size| {
        const ctx: vxfw.DrawContext = .{
            .arena = arena.allocator(),
            .min = .{},
            .max = .{ .width = size.width, .height = size.height },
            .cell_size = .{ .width = 10, .height = 20 },
        };
        const first = (try operation_model.pkgbuildView(model).draw(ctx)).?;
        var state_view = operation_model.pkgbuildView(model);
        state_view.loading = true;
        try std.testing.expectEqual(first.surface.size, (try state_view.draw(ctx)).?.surface.size);
        state_view.loading = false;
        state_view.failure = error.CommandFailed;
        try std.testing.expectEqual(first.surface.size, (try state_view.draw(ctx)).?.surface.size);
        var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
        defer events.cmds.deinit(std.testing.allocator);
        for (0..6) |_| {
            try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
            _ = try operation_model.pkgbuildView(model).draw(ctx);
        }
        try std.testing.expect(model.operation_state.pkgbuild_scroll.scroll.top > 0);
        const after = (try operation_model.pkgbuildView(model).draw(ctx)).?;
        try std.testing.expectEqual(first.surface.size, after.surface.size);
    }
    operation_model.closePkgbuild(model);
    try std.testing.expect(model.overlay.? == .aur);
    try std.testing.expectEqualStrings("demo", model.overlay.?.aur.Name);
}

test "PKGBUILD preview discards stale results and joins unpolled jobs" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.operation_state.pkgbuild_name = try std.testing.allocator.dupe(u8, "new-target");
    const Worker = struct {
        fn finish(job: *PkgbuildJob) void {
            job.done.store(true, .release);
        }
    };
    const job = try std.testing.allocator.create(PkgbuildJob);
    job.* = .{
        .name = try std.testing.allocator.dupe(u8, "old-target"),
        .result = try std.json.parseFromSlice([]PkgBuild, std.testing.allocator,
            \\[{"Name":"old-target","PkgBuild":"echo old"}]
        , .{ .allocate = .alloc_always }),
    };
    model.operation_state.pkgbuild_job = job;
    model.operation_state.pkgbuild_thread = try std.Thread.spawn(.{}, Worker.finish, .{job});
    job.done.store(true, .release);
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);
    try operation_model.pollPkgbuild(model, &ctx);
    try std.testing.expect(model.operation_state.pkgbuild_document == null);
    try std.testing.expect(model.operation_state.pkgbuild_job == null);
    const pending = try std.testing.allocator.create(PkgbuildJob);
    pending.* = .{
        .name = try std.testing.allocator.dupe(u8, "new-target"),
        .result = try std.json.parseFromSlice([]PkgBuild, std.testing.allocator,
            \\[{"Name":"new-target","PkgBuild":"echo new"}]
        , .{ .allocate = .alloc_always }),
    };
    model.operation_state.pkgbuild_job = pending;
    model.operation_state.pkgbuild_thread = try std.Thread.spawn(.{}, Worker.finish, .{pending});
    // Model.deinit joins and frees this unconsumed result.
}

test "operation PKGBUILD review owns each revision and returns to progress" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    const prompt = try std.testing.allocator.create(SudoPrompt);
    prompt.* = .{
        .name = try std.testing.allocator.dupe(u8, "demo"),
        .backend = .aur,
        .action = .upgrade,
        .password = .empty,
        .state = .running,
    };
    model.overlay = .{ .sudo = prompt };
    const first = try shelly_operation.decodeJson(std.testing.allocator,
        \\{"$kind":"q.pkgbuilddiff","QuestionId":"1","PackageName":"demo","OldPkgbuild":"pkgver=1","NewPkgbuild":"pkgver=2","Warnings":[{"Tool":"scanner","Severity":"Critical","Hook":"build","Message":"Review this before building","MatchedLine":"curl script | sh"}],"DiffLines":["-pkgver=1","+pkgver=2"],"SourceFiles":{"demo.install":"post_install() {}"}}
    );
    try operation_model.showOperationQuestion(model, first);
    try std.testing.expect(model.overlay.? == .pkgbuild);
    try std.testing.expect(operation_model.pkgbuildView(model).review);
    try std.testing.expectEqualStrings("Security scan: 1 finding, 1 critical.", model.operation_state.pkgbuild_document.?.lines[0]);
    try std.testing.expectEqual(pkgbuild_view.Action.approve, operation_model.pkgbuildView(model).handleKey(.{ .codepoint = 'y' }).?);
    vxfw.DrawContext.init(.unicode);
    for ([_]Tab{ .aur, .upgrade }) |tab| {
        model.active = tab;
        for ([_]vxfw.Size{ .{ .width = 100, .height = 30 }, .{ .width = 40, .height = 12 } }) |size| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const surface = try model.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = size.width, .height = size.height }, .cell_size = .{ .width = 10, .height = 20 } });
            var bottom_panel = false;
            for (surface.children) |child| {
                try std.testing.expectEqual(@as(u8, 0), child.z_index);
                if (child.surface.size.width == size.width and child.surface.size.height > 1 and child.origin.row > 3) {
                    bottom_panel = true;
                    try std.testing.expectEqual(@as(i17, size.height - 1), child.origin.row + child.surface.size.height);
                }
            }
            try std.testing.expectEqual(size.height >= 20, bottom_panel);
            try std.testing.expectEqual(commands.Mode.review, model.commandContext().mode);
        }
    }
    const text = try std.mem.join(std.testing.allocator, "\n", model.operation_state.pkgbuild_document.?.lines);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "pkgver=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pkgver=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "demo.install") != null);
    operation_model.finishOperationQuestion(model);
    try std.testing.expect(model.overlay.?.sudo == prompt);
    try std.testing.expect(model.operation_state.operation_question == null);
    const second = try shelly_operation.decodeJson(std.testing.allocator,
        \\{"$kind":"q.pkgbuilddiff","QuestionId":"2","PackageName":"demo","OldPkgbuild":"","NewPkgbuild":"pkgver=3","Warnings":[]}
    );
    try operation_model.showOperationQuestion(model, second);
    try std.testing.expectEqualStrings("Security scan: no findings reported by the CLI.", model.operation_state.pkgbuild_document.?.lines[0]);
    try std.testing.expectEqualStrings("2", shelly_operation.questionId(model.operation_state.operation_question.?.value.question));
    try std.testing.expectEqual(pkgbuild_view.Action.decline, operation_model.pkgbuildView(model).handleKey(.{ .codepoint = 'n' }).?);
    // Model.deinit owns the suspended progress prompt and outstanding review.
}

test "installed AUR list filters locally and opens the displayed package" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.settings_state.settings.aur_enabled = true;
    const packages = [_]AurPackage{
        .{ .Name = "first", .Installed = true },
        .{ .Name = "editor-git", .Installed = true },
    };
    model.aur_state.aur_packages = &packages;
    model.aur_state.aur_installed_only = true;
    try model.aur_state.aur_field.buf.insertSliceAtCursor("EDITOR");
    try rebuildAurFilter(model);
    try std.testing.expectEqual(@as(usize, 1), model.aur_state.aur_filtered.items.len);
    try std.testing.expectEqualStrings("editor-git", model.aur_state.aur_filtered.items[0].Name);
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);
    try onAurSubmit(model, &ctx, "EDITOR");
    try std.testing.expectEqualStrings("editor-git", model.overlay.?.aur.Name);
    model.overlay = null;
    model.aur_state.aur_field.buf.clearRetainingCapacity();
    try rebuildAurFilter(model);
    try std.testing.expectEqual(@as(usize, 2), model.aur_state.aur_filtered.items.len);
}

test "AUR preview replaces the details pane and preserves search and selection" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.active = .aur;
    model.settings_state.settings.aur_enabled = true;
    const packages = [_]AurPackage{ .{ .Name = "first" }, .{ .Name = "second" } };
    model.aur_state.aur_packages = &packages;
    model.aur_state.aur_query = try std.testing.allocator.dupe(u8, "query");
    try model.aur_state.aur_field.buf.insertSliceAtCursor("query");
    try rebuildAurFilter(model);
    model.aur_state.aur_list.jumpToItem(1);
    model.aur_state.aur_list_active = true;
    model.aur_state.aur_details_cursor = 1;
    model.aur_state.aur_details_scroll.scroll.vertical_offset = -2;
    model.operation_state.pkgbuild_name = try std.testing.allocator.dupe(u8, "second");
    model.operation_state.pkgbuild_document = try pkgbuild_view.Document.init(std.testing.allocator, &.{.{ .Name = "second", .PkgBuild = "pkgname=second\npkgver=1\nbuild() {\n  echo \"hello\"\n}" }});
    model.operation_state.pkgbuild_scroll.item_count = @intCast(model.operation_state.pkgbuild_document.?.lines.len);
    model.overlay = .pkgbuild;
    for ([_]vxfw.Size{ .{ .width = 80, .height = 24 }, .{ .width = 120, .height = 40 }, .{ .width = 40, .height = 12 } }) |size| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const surface = try model.widget().draw(.{
            .arena = arena.allocator(),
            .min = .{},
            .max = .{ .width = size.width, .height = size.height },
            .cell_size = .{ .width = 10, .height = 20 },
        });
        var preview_found = false;
        for (surface.children) |child| {
            try std.testing.expectEqual(@as(u8, 0), child.z_index);
            if (child.surface.children.len > 0 and child.surface.children[0].surface.widget.eql(model.operation_state.pkgbuild_scroll.widget())) {
                preview_found = true;
                try std.testing.expectEqual(size.width >= 64, child.origin.col > 0);
            }
        }
        try std.testing.expect(preview_found);
        try std.testing.expect(model.aur_state.aur_job == null); // Drawing never fetches the catalog.
        try std.testing.expectEqual(@as(i17, -2), model.aur_state.aur_details_scroll.scroll.vertical_offset);
    }
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer events.cmds.deinit(std.testing.allocator);
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = 'y' } });
    try std.testing.expect(model.overlay.? == .pkgbuild);
    try std.testing.expect(model.operation_state.operation_question == null);
    try std.testing.expect(model.operation_state.pkgbuild_wrap);
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = commands.bindings.toggle_wrap });
    try std.testing.expect(!model.operation_state.pkgbuild_wrap);
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = commands.bindings.toggle_wrap });
    try std.testing.expect(model.operation_state.pkgbuild_wrap);
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = 'q' } });
    try std.testing.expectEqualStrings("second", model.overlay.?.aur.Name);
    try std.testing.expectEqual(@as(u32, 1), model.aur_state.aur_list.cursor);
    try std.testing.expectEqualStrings("query", model.aur_state.aur_query);
    try std.testing.expectEqual(@as(i17, -2), model.aur_state.aur_details_scroll.scroll.vertical_offset);
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = vaxis.Key.left } });
    try std.testing.expect(model.overlay == null);
    try std.testing.expect(model.aur_state.aur_list_active);
}

test "AUR details button is keyboard accessible and opens the selected preview" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.active = .aur;
    const packages = [_]AurPackage{.{ .Name = "demo", .Description = "A wrapped description", .Version = "1" }};
    model.aur_state.aur_packages = &packages;
    try rebuildAurFilter(model);
    model.overlay = .{ .aur = &packages[0] };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{ .width = 40 }, .max = .{ .width = 40, .height = null }, .cell_size = .{ .width = 10, .height = 20 } };
    const details = try buildAurDetails(model, 0, 0).?.draw(draw_ctx);
    try std.testing.expectEqual(@as(u16, 40), details.size.width);
    const button = try buildAurDetails(model, 1, 0).?.draw(draw_ctx);
    try std.testing.expectEqual(@as(u16, 1), button.size.height);
    try std.testing.expectEqual(@as(u16, @intCast(draw_ctx.stringWidth(model.aur_state.aur_preview_button.label))), button.size.width);
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);
    model.aur_state.aur_details_scroll.scroll.has_more_vertical = false;
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = commands.bindings.next });
    try std.testing.expect(model.aur_state.aur_preview_button.focused);
    try std.testing.expect(model.commandContext().preview_button);
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = commands.bindings.previous });
    try std.testing.expect(!model.aur_state.aur_preview_button.focused);
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = commands.bindings.next });
    // A pending fetch prevents this interaction test from starting a subprocess.
    const pending = try std.testing.allocator.create(PkgbuildJob);
    pending.* = .{ .name = try std.testing.allocator.dupe(u8, "demo") };
    model.operation_state.pkgbuild_job = pending;
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = commands.bindings.confirm });
    try std.testing.expect(model.overlay.? == .pkgbuild);
    try std.testing.expectEqualStrings("demo", model.operation_state.pkgbuild_name);
}

test "AUR batch selections own names across searches and preserve per-package reviews" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.active = .aur;
    model.settings_state.settings.aur_enabled = true;
    model.aur_state.aur_list_active = true;
    model.aur_state.aur_parsed = try std.json.parseFromSlice([]AurPackage, std.testing.allocator,
        \\[{"Name":"first","Installed":false},{"Name":"second","Installed":true}]
    , .{ .allocate = .alloc_always });
    model.aur_state.aur_packages = model.aur_state.aur_parsed.?.value;
    try rebuildAurFilter(model);
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = commands.bindings.select });
    try std.testing.expect(model.overlay == null);
    model.aur_state.aur_list.jumpToItem(1);
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = commands.bindings.mark });
    try std.testing.expectEqual(@as(usize, 2), model.aur_state.aur_selection.items.len);
    // Replace the entire query result, as a new search does.
    model.aur_state.aur_parsed.?.deinit();
    model.aur_state.aur_parsed = null;
    model.aur_state.aur_packages = &.{};
    try rebuildAurFilter(model);
    try std.testing.expectEqualStrings("first", model.aur_state.aur_selection.items[0].name);
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = commands.bindings.install });
    const prompt = model.overlay.?.sudo;
    try std.testing.expectEqual(OperationBackend.aur, prompt.backend);
    try std.testing.expectEqualSlices(u8, "2 packages", prompt.name);
    try std.testing.expectEqual(@as(usize, 2), prompt.targets.len);
    try std.testing.expectEqualStrings("first", prompt.targets[0]);
    try std.testing.expectEqualStrings("second", prompt.targets[1]);
    try std.testing.expect(std.mem.indexOf(u8, prompt.review_text, "Install (1): first") != null);
    clearAurSelection(model); // Confirmation owns its target copies.
    try std.testing.expectEqualStrings("first", prompt.targets[0]);
    prompt.state = .running;
    for ([_][]const u8{
        \\{"$kind":"q.pkgbuilddiff","QuestionId":"201","PackageName":"first","OldPkgbuild":"","NewPkgbuild":"pkgname=first"}
        ,
        \\{"$kind":"q.pkgbuilddiff","QuestionId":"202","PackageName":"second","OldPkgbuild":"","NewPkgbuild":"pkgname=second"}
    }, [_][]const u8{ "first", "second" }) |json, name| {
        try operation_model.showOperationQuestion(model, try shelly_operation.decodeJson(std.testing.allocator, json));
        try std.testing.expectEqualStrings(name, model.operation_state.pkgbuild_name);
        try std.testing.expectEqual(@as(usize, 2), model.operation_state.review_prompt.?.targets.len);
        operation_model.finishOperationQuestion(model);
        try std.testing.expect(model.overlay.?.sudo == prompt);
    }
    operation_model.closeOverlay(model);
    const items = [_]AurPackage{.{ .Name = "third" }};
    model.aur_state.aur_packages = &items;
    try rebuildAurFilter(model);
    try toggleAurSelection(model);
    try openAurPrompt(model, .install);
    try std.testing.expectEqualStrings("third", model.overlay.?.sudo.targets[0]);
    operation_model.resetPackageSelection(model);
    try std.testing.expectEqual(@as(usize, 0), model.aur_state.aur_selection.items.len);
}

test "PKGBUILD shortcuts appear only in the contextual footer" {
    const Text = struct {
        fn append(alloc: Allocator, text: *std.ArrayList(u8), surface: vxfw.Surface) Allocator.Error!void {
            for (surface.buffer) |cell| try text.appendSlice(alloc, cell.char.grapheme);
            for (surface.children) |child| try append(alloc, text, child.surface);
        }
    };
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.active = .aur;
    model.settings_state.settings.aur_enabled = true;
    model.overlay = .pkgbuild;
    model.operation_state.pkgbuild_name = try std.testing.allocator.dupe(u8, "demo");
    model.operation_state.pkgbuild_document = try pkgbuild_view.Document.init(std.testing.allocator, &.{.{ .Name = "demo", .PkgBuild = "pkgname=demo" }});
    model.operation_state.pkgbuild_scroll.item_count = @intCast(model.operation_state.pkgbuild_document.?.lines.len);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const surface = try model.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 100, .height = 24 }, .cell_size = .{ .width = 10, .height = 20 } });
    var body: std.ArrayList(u8) = .empty;
    var footer: std.ArrayList(u8) = .empty;
    for (surface.children) |child| try Text.append(arena.allocator(), if (child.origin.row == 23) &footer else &body, child.surface);
    try std.testing.expect(std.mem.indexOf(u8, body.items, "pkgname") != null);
    for ([_][]const u8{ "Retry", "Unwrap", "F1 Help" }) |hint| {
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, footer.items, hint));
        try std.testing.expect(std.mem.indexOf(u8, body.items, hint) == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, body.items, "wrap on") == null);
}

test "AUR removal uses installed selections from list and details and excludes available entries" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.active = .aur;
    model.settings_state.settings.aur_enabled = true;
    model.aur_state.aur_list_active = true;
    var packages = [_]AurPackage{
        .{ .Name = "first-git", .Installed = true },
        .{ .Name = "available-git" },
        .{ .Name = "second-git", .Installed = true },
    };
    model.aur_state.aur_packages = &packages;
    try rebuildAurFilter(model);
    for (0..3) |index| {
        model.aur_state.aur_list.jumpToItem(@intCast(index));
        try toggleAurSelection(model);
    }
    // Even when the highlighted package is unavailable, R removes the
    // installed entries in the selection rather than the highlighted row.
    model.aur_state.aur_list.jumpToItem(1);
    try std.testing.expect(model.commandContext().removable);
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = commands.bindings.remove });
    var prompt = model.overlay.?.sudo;
    try std.testing.expectEqual(shelly_operation.Action.remove, prompt.action);
    try std.testing.expectEqual(OperationBackend.aur, prompt.backend);
    try std.testing.expectEqual(@as(usize, 2), prompt.targets.len);
    try std.testing.expectEqualStrings("first-git", prompt.targets[0]);
    try std.testing.expectEqualStrings("second-git", prompt.targets[1]);
    try std.testing.expect(std.mem.indexOf(u8, prompt.review_text, "1 uninstalled selections excluded.") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt.review_text, "Remove (2): first-git, second-git") != null);
    operation_model.closeOverlay(model);
    try std.testing.expectEqual(@as(usize, 0), model.aur_state.aur_selection.items.len);
    // Details use the same selected batch, including names outside this query.
    model.aur_state.aur_list.jumpToItem(0);
    try toggleAurSelection(model);
    model.aur_state.aur_list.jumpToItem(2);
    try toggleAurSelection(model);
    model.aur_state.aur_packages = packages[1..2];
    try rebuildAurFilter(model);
    model.overlay = .{ .aur = &packages[1] };
    try std.testing.expect(model.commandContext().removable);
    try operation_model.operationFromOverlay(model, .remove);
    prompt = model.overlay.?.sudo;
    try std.testing.expectEqual(@as(usize, 2), prompt.targets.len);
    operation_model.closeOverlay(model);
    // No selection falls back to the highlighted installed package.
    model.aur_state.aur_packages = &packages;
    try rebuildAurFilter(model);
    model.aur_state.aur_list.jumpToItem(2);
    try openAurPrompt(model, .remove);
    try std.testing.expectEqualStrings("second-git", model.overlay.?.sudo.targets[0]);
    operation_model.closeOverlay(model);
    model.aur_state.aur_list.jumpToItem(1);
    try toggleAurSelection(model);
    try std.testing.expect(!model.commandContext().removable);
    try openAurPrompt(model, .remove);
    try std.testing.expect(model.overlay == null);
    try std.testing.expect(std.mem.indexOf(u8, model.notice, "No installed packages") != null);
}
