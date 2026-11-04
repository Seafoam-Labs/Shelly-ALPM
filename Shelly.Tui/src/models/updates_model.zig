//! Update checks, source availability, and upgrade requests.
const flatpak_model = @import("flatpak_model.zig");
const operation_model = @import("operation_model.zig");
const std = @import("std");
const commands = @import("../commands.zig");
const updates_view = @import("../views/updates_view.zig");
const shelly_operation = @import("../services/shelly_operation.zig");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const shelly_cli = @import("../services/shelly_cli.zig");
const ShellyCli = shelly_cli.ShellyCli;

const flatpak = @import("flatpak.zig");
const CheckUpdates = @import("sync.zig").CheckUpdates;

const Allocator = std.mem.Allocator;
const OperationBackend = shelly_operation.Backend;

const coordinator = @import("../model.zig");
const Model = coordinator.Model;
const SudoPrompt = operation_model.SudoPrompt;

/// Page-owned state. Worker results are published to the UI loop before use.
pub const State = struct {
    /// Result of the last finished operation; owned by `gpa` unless empty.
    updates_job: ?*UpdatesJob = null,
    updates_thread: ?std.Thread = null,
    updates_parsed: ?std.json.Parsed(CheckUpdates) = null,
    refresh_after_upgrade: bool = false,
    refresh_updates_after_operation: bool = false,
    updates_checked: bool = false,
    updates_failed: bool = false,
    updates_list: vxfw.ScrollView,
};

pub const UpdatesJob = struct {
    aur_enabled: bool = false,
    flatpak_enabled: bool = false,
    result: ?std.json.Parsed(CheckUpdates) = null,
    failed: bool = false,
    done: std.atomic.Value(bool) = .init(false),
};

pub fn init(_: Allocator, model: *Model) State {
    return .{
        .updates_list = .{ .children = .{ .builder = .{
            .userdata = model,
            .buildFn = buildUpdateRow,
        } } },
    };
}

pub fn deinit(self: *Model) void {
    const gpa = self.gpa;

    if (self.updates_state.updates_thread) |thread| thread.join();
    if (self.updates_state.updates_job) |job| {
        if (job.result) |*result| result.deinit();
        gpa.destroy(job);
    }
    if (self.updates_state.updates_parsed) |*parsed| parsed.deinit();
}

pub fn ensureUpdates(self: *Model, ctx: *vxfw.EventContext) !void {
    if (self.active == .upgrade and !self.updates_state.updates_checked and self.updates_state.updates_job == null)
        try startUpdates(self, ctx);
}

pub fn startUpdates(self: *Model, ctx: *vxfw.EventContext) !void {
    if (self.updates_state.updates_job != null or self.operation_state.install_job != null) return;
    try ctx.tick(100, self.widget());
    const job = try self.gpa.create(UpdatesJob);
    errdefer self.gpa.destroy(job);
    job.* = .{ .aur_enabled = self.settings_state.settings.aur_enabled, .flatpak_enabled = self.settings_state.settings.flatpak_enabled and self.flatpak_state.flatpak_available };
    const thread = try std.Thread.spawn(.{}, checkUpdatesThread, .{job});
    self.updates_state.updates_thread = thread;
    self.updates_state.updates_job = job;
    self.updates_state.updates_checked = true;
    self.updates_state.updates_failed = false;
}

pub fn checkUpdatesThread(job: *UpdatesJob) void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const cli: ShellyCli = .{ .allocator = std.heap.page_allocator, .io = threaded.io() };
    job.result = cli.check_updates_for_sources(job.aur_enabled, job.flatpak_enabled) catch {
        job.failed = true;
        job.done.store(true, .release);
        return;
    };
    job.done.store(true, .release);
}

pub fn pollUpdates(self: *Model) void {
    const job = self.updates_state.updates_job orelse return;
    if (!job.done.load(.acquire)) return;
    self.updates_state.updates_thread.?.join();
    self.updates_state.updates_thread = null;
    self.updates_state.updates_job = null;
    defer self.gpa.destroy(job);
    if (job.aur_enabled != self.settings_state.settings.aur_enabled or job.flatpak_enabled != (self.settings_state.settings.flatpak_enabled and self.flatpak_state.flatpak_available)) {
        if (job.result) |*parsed| parsed.deinit();
        self.updates_state.updates_checked = false;
        return;
    }
    self.updates_state.updates_failed = job.failed;
    if (job.result) |parsed| {
        if (self.updates_state.updates_parsed) |*old| old.deinit();
        self.updates_state.updates_parsed = parsed;
        self.updates_state.updates_list.item_count = @intCast(parsed.value.count());
        self.updates_state.updates_list.scroll = .{};
        self.updates_state.updates_list.cursor = 0;
    }
}

pub fn updatesView(self: *Model) updates_view.View {
    return .{
        .list = &self.updates_state.updates_list,
        .data = if (self.updates_state.updates_parsed) |*parsed| &parsed.value else null,
        .loading = self.updates_state.updates_job != null,
        .failed = self.updates_state.updates_failed,
        .checked = self.updates_state.updates_checked,
        .aur_enabled = self.settings_state.settings.aur_enabled,
        .flatpak_enabled = self.settings_state.settings.flatpak_enabled,
        .flatpak_available = self.settings_state.settings.flatpak_enabled and self.flatpak_state.flatpak_available,
    };
}

/// This page scrolls a document; navigation never selects upgrade targets.
pub fn handleScrollEvent(self: *Model, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const scroll = &self.updates_state.updates_list;
    if (event == .key_press) {
        const key = event.key_press;
        if (commands.matches(key, .page_up) or commands.matches(key, .page_down)) {
            const lines = @max(scroll.last_height / 2, 1);
            const changed = if (commands.matches(key, .page_up)) scroll.scroll.linesUp(lines) else scroll.scroll.linesDown(lines);
            if (changed) ctx.consumeAndRedraw();
            return;
        }
        if (commands.matches(key, .previous) or commands.matches(key, .next)) {
            return scroll.handleEvent(ctx, .{ .key_press = .{ .codepoint = if (commands.matches(key, .previous)) vaxis.Key.up else vaxis.Key.down } });
        }
    }
    return scroll.handleEvent(ctx, event);
}

pub fn buildUpdateRow(ptr: *const anyopaque, index: usize, _: usize) ?vxfw.Widget {
    const self: *const Model = @ptrCast(@alignCast(ptr));
    const parsed = self.updates_state.updates_parsed orelse return null;
    return updates_view.row(&parsed.value, index);
}

pub fn upgradeSystemFromUpdates(self: *Model) !void {
    return upgradeFromUpdates(self, .standard);
}

pub fn upgradeFromUpdates(self: *Model, backend: OperationBackend) !void {
    if (self.operation_state.install_job != null or self.overlay != null) return;
    if (backend == .all and !updatesView(self).canUpgradeAll()) return;
    if (backend == .standard and !updatesView(self).canUpgrade()) return;
    if (backend == .aur and !updatesView(self).canUpgradeAur()) return;
    if (backend == .flatpak) {
        if (updatesView(self).canUpgradeFlatpak()) try flatpak_model.openFlatpakPrompt(self, .upgrade, "Flatpak applications and runtimes (system + user)", null);
        return;
    }
    const prompt = try self.gpa.create(SudoPrompt);
    errdefer self.gpa.destroy(prompt);
    prompt.* = .{
        .name = try self.gpa.dupe(u8, if (backend == .all) "all enabled package sources" else if (backend == .aur) "AUR packages" else "system packages"),
        .backend = backend,
        .action = .upgrade,
        .include_flatpak = self.settings_state.settings.flatpak_enabled and self.flatpak_state.flatpak_available,
        .include_aur = self.settings_state.settings.aur_enabled,
    };
    self.overlay = .{ .sudo = prompt };
}

/// Returns whether page input was consumed. Globals remain with the coordinator.
pub fn handleKey(self: *Model, ctx: *vxfw.EventContext, key: vaxis.Key) anyerror!bool {
    if (commands.matches(key, .previous) or commands.matches(key, .next)) {
        try handleScrollEvent(self, ctx, .{ .key_press = .{ .codepoint = if (commands.matches(key, .previous)) vaxis.Key.up else vaxis.Key.down } });
        ctx.consumeAndRedraw();
        return true;
    }
    if (updatesView(self).handleKey(key)) |action| {
        switch (action) {
            .refresh => try startUpdates(self, ctx),
            .upgrade_all => try upgradeFromUpdates(self, .all),
            .upgrade_system => try upgradeSystemFromUpdates(self),
            .upgrade_aur => try upgradeFromUpdates(self, .aur),
            .upgrade_flatpak => try upgradeFromUpdates(self, .flatpak),
        }
        ctx.consumeAndRedraw();
        return true;
    }
    return false;
}

test "updates view renders source rows and distinguishes query states" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.active = .upgrade;
    model.updates_state.updates_checked = true;
    model.updates_state.updates_parsed = try std.json.parseFromSlice(CheckUpdates, std.testing.allocator,
        \\{"Packages":[{"Name":"native","CurrentVersion":"1","NewVersion":"2"}],"Aur":[{"Name":"aur","Version":"2","NewVersion":"3"}],"Flatpak":[{"Id":"org.test.App","NewVersion":"4","InstallLevel":1}],"AppImage":[{"Name":"image","Version":"5","IsUpdateAvailable":true}]}
    , .{ .allocate = .alloc_always });
    model.updates_state.updates_list.item_count = 4;
    try std.testing.expectEqual(@as(usize, 4), model.updates_state.updates_parsed.?.value.count());
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]vxfw.Size{ .{ .width = 80, .height = 24 }, .{ .width = 40, .height = 12 } }) |size| {
        const ctx: vxfw.DrawContext = .{
            .arena = arena.allocator(),
            .min = .{},
            .max = .{ .width = size.width, .height = size.height },
            .cell_size = .{ .width = 10, .height = 20 },
        };
        _ = try model.widget().draw(ctx);
        for (0..4) |index| {
            const widget = buildUpdateRow(model, index, 0) orelse return error.MissingUpdateRow;
            _ = try widget.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = 1 }));
        }
        try std.testing.expect(buildUpdateRow(model, 4, 0) == null);
    }
    var view = updatesView(model);
    view.failed = true;
    try std.testing.expectEqualStrings("Update check failed", try view.statusText(arena.allocator()));
    view.loading = true;
    try std.testing.expectEqualStrings("Checking for updates…", try view.statusText(arena.allocator()));
}

test "updates polling transfers results and cleans unconsumed results" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    const Worker = struct {
        fn complete(job: *UpdatesJob) void {
            job.done.store(true, .release);
        }
    };
    const job = try std.testing.allocator.create(UpdatesJob);
    job.* = .{ .result = try std.json.parseFromSlice(CheckUpdates, std.testing.allocator,
        \\{"Packages":[{"Name":"test","CurrentVersion":"1","NewVersion":"2"}]}
    , .{ .allocate = .alloc_always }) };
    model.updates_state.updates_job = job;
    model.updates_state.updates_thread = try std.Thread.spawn(.{}, Worker.complete, .{job});
    job.done.store(true, .release);
    pollUpdates(model);
    try std.testing.expect(model.updates_state.updates_job == null);
    try std.testing.expectEqual(@as(?u32, 1), model.updates_state.updates_list.item_count);
    try std.testing.expectEqualStrings("test", model.updates_state.updates_parsed.?.value.Packages[0].Name);

    // A failed refresh must remain a failure, retaining the previous owned data.
    const failed = try std.testing.allocator.create(UpdatesJob);
    failed.* = .{ .failed = true };
    model.updates_state.updates_job = failed;
    model.updates_state.updates_thread = try std.Thread.spawn(.{}, Worker.complete, .{failed});
    failed.done.store(true, .release);
    pollUpdates(model);
    try std.testing.expect(model.updates_state.updates_failed);
    try std.testing.expectEqualStrings("test", model.updates_state.updates_parsed.?.value.Packages[0].Name);

    // deinit owns an unpolled worker and its result.
    const pending = try std.testing.allocator.create(UpdatesJob);
    pending.* = .{ .result = try std.json.parseFromSlice(CheckUpdates, std.testing.allocator, "{}", .{}) };
    model.updates_state.updates_job = pending;
    model.updates_state.updates_thread = try std.Thread.spawn(.{}, Worker.complete, .{pending});
}

test "updates action opens a native-only upgrade prompt" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.updates_state.updates_checked = true;
    model.updates_state.updates_parsed = try std.json.parseFromSlice(CheckUpdates, std.testing.allocator,
        \\{"Packages":[{"Name":"native","CurrentVersion":"1","NewVersion":"2"}],"Aur":[{"Name":"foreign"}]}
    , .{ .allocate = .alloc_always });
    const action = updatesView(model).handleKey(.{ .codepoint = 'u' });
    try std.testing.expectEqual(commands.Updates.upgrade_system, action.?);
    try upgradeSystemFromUpdates(model);
    const prompt = model.overlay.?.sudo;
    try std.testing.expectEqual(shelly_operation.Action.upgrade, prompt.action);
    try std.testing.expectEqual(OperationBackend.standard, prompt.backend);
    try std.testing.expectEqualStrings("system packages", prompt.name);
    operation_model.closeOverlay(model);
    model.updates_state.updates_failed = true;
    try std.testing.expect(updatesView(model).handleKey(.{ .codepoint = 'u' }) == null);
}

test "AUR updates open a separate AUR upgrade prompt" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.settings_state.settings.aur_enabled = true;
    model.updates_state.updates_checked = true;
    model.updates_state.updates_parsed = try std.json.parseFromSlice(CheckUpdates, std.testing.allocator,
        \\{"Packages":[],"Aur":[{"Name":"foreign","Version":"1","NewVersion":"2"}]}
    , .{ .allocate = .alloc_always });
    try std.testing.expect(updatesView(model).handleKey(.{ .codepoint = 'u' }) == null);
    try std.testing.expectEqual(commands.Updates.upgrade_aur, updatesView(model).handleKey(.{ .codepoint = 'a' }).?);
    try upgradeFromUpdates(model, .aur);
    try std.testing.expectEqual(OperationBackend.aur, model.overlay.?.sudo.backend);
    try std.testing.expectEqual(shelly_operation.Action.upgrade, model.overlay.?.sudo.action);
}

test "combined update shortcut opens an authenticated prompt even for an empty cached check" {
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    model.updates_state.updates_parsed = try std.json.parseFromSlice(CheckUpdates, allocator, "{}", .{});
    const key: vaxis.Key = .{ .codepoint = 'g' };
    try std.testing.expectEqual(commands.Updates.upgrade_all, updatesView(model).handleKey(key).?);
    try upgradeFromUpdates(model, .all);
    const prompt = model.overlay.?.sudo;
    try std.testing.expectEqual(OperationBackend.all, prompt.backend);
    try std.testing.expect(prompt.elevated);
    try std.testing.expect(!prompt.include_flatpak);
    try std.testing.expectEqualStrings("all enabled package sources", prompt.name);
    operation_model.closeOverlay(model);
    model.settings_state.settings.flatpak_enabled = true;
    model.flatpak_state.flatpak_available = true;
    try upgradeFromUpdates(model, .all);
    try std.testing.expect(model.overlay.?.sudo.include_flatpak);
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try model.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 24 }, .cell_size = .{ .width = 10, .height = 20 } });
    operation_model.closeOverlay(model);
    model.updates_state.updates_failed = true;
    try std.testing.expect(updatesView(model).handleKey(key) == null);
    try upgradeFromUpdates(model, .all);
    try std.testing.expect(model.overlay == null);
}

test "combined operation completion refreshes every included source after partial failure" {
    const allocator = std.testing.allocator;
    var env: std.process.Environ.Map = .init(allocator);
    defer env.deinit();
    for ([_]bool{ false, true }) |include_flatpak| {
        const model = try Model.init(allocator);
        defer model.deinit();
        const job = try std.heap.page_allocator.create(shelly_operation.Operation);
        job.* = .{
            .arena = .init(std.heap.page_allocator),
            .done = .init(true),
            .result = .{ .failed = true },
            .request = .{ .action = .upgrade, .shelly_bin = "unused", .environ_map = &env, .backend = "all", .name = "combined upgrade", .include_flatpak = include_flatpak, .include_aur = true },
        };
        model.operation_state.install_job = job;
        try std.testing.expect(!try operation_model.pollInstall(model));
        try std.testing.expect(model.updates_state.refresh_after_upgrade);
        try std.testing.expect(model.aur_state.refresh_aur_after_operation);
        try std.testing.expect(model.updates_state.refresh_updates_after_operation);
        try std.testing.expectEqual(include_flatpak, model.flatpak_state.refresh_flatpak_after_operation);
    }
}

test "updates scroll without selecting packages and reset after refresh" {
    vxfw.DrawContext.init(.unicode);
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    var packages: [30]@import("sync.zig").CheckUpdatesPackage = undefined;
    for (&packages, 0..) |*pkg, index| pkg.* = .{
        .Name = if (index == 0) "first-package" else "other-package",
        .CurrentVersion = "1.0",
        .NewVersion = "2.0",
    };
    const data: CheckUpdates = .{ .Packages = &packages };
    const json = try std.json.Stringify.valueAlloc(allocator, data, .{});
    defer allocator.free(json);
    model.updates_state.updates_parsed = try std.json.parseFromSlice(CheckUpdates, allocator, json, .{ .allocate = .alloc_always });
    model.updates_state.updates_list.item_count = packages.len;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 8 }, .cell_size = .{ .width = 10, .height = 20 } };
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = allocator, .cmds = .empty };
    defer ctx.cmds.deinit(allocator);
    const scroll = &model.updates_state.updates_list;
    try std.testing.expect(!scroll.draw_cursor);
    _ = try scroll.draw(draw_ctx);
    for (0..12) |_| {
        try scroll.handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
        _ = try scroll.draw(draw_ctx);
    }
    try std.testing.expect(scroll.scroll.top > 0);
    try std.testing.expectEqual(@as(u32, 0), scroll.cursor);
    const previous_top = scroll.scroll.top;
    try handleScrollEvent(model, &ctx, .{ .key_press = commands.bindings.page_down });
    _ = try scroll.draw(draw_ctx);
    try std.testing.expect(scroll.scroll.top > previous_top);
    try scroll.handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try std.testing.expectEqual(@as(u32, 0), scroll.cursor);
    try std.testing.expect(model.overlay == null);

    const job = try allocator.create(UpdatesJob);
    job.* = .{ .result = try std.json.parseFromSlice(CheckUpdates, allocator, "{}", .{}) };
    const Worker = struct {
        fn complete(value: *UpdatesJob) void {
            value.done.store(true, .release);
        }
    };
    model.updates_state.updates_job = job;
    model.updates_state.updates_thread = try std.Thread.spawn(.{}, Worker.complete, .{job});
    job.done.store(true, .release);
    pollUpdates(model);
    try std.testing.expectEqual(@as(u32, 0), scroll.scroll.top);
    try std.testing.expectEqual(@as(i17, 0), scroll.scroll.vertical_offset);
    try std.testing.expectEqual(@as(?u32, 0), scroll.item_count);
}

test "update confirmations retain the list while PKGBUILD reviews use the full content area" {
    const contains = struct {
        fn text(surface: vxfw.Surface, needle: []const u8, allocator: Allocator) !bool {
            var chars: std.ArrayList(u8) = .empty;
            defer chars.deinit(allocator);
            for (surface.buffer) |cell| try chars.appendSlice(allocator, cell.char.grapheme);
            if (std.mem.indexOf(u8, chars.items, needle) != null) return true;
            for (surface.children) |child| if (try text(child.surface, needle, allocator)) return true;
            return false;
        }
    }.text;
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.active = .upgrade;
    model.updates_state.updates_checked = true;
    model.updates_state.updates_parsed = try std.json.parseFromSlice(CheckUpdates, std.testing.allocator,
        \\{"Packages":[{"Name":"visible-update","CurrentVersion":"1","NewVersion":"2"}]}
    , .{});
    const prompt = try std.testing.allocator.create(SudoPrompt);
    prompt.* = .{ .name = try std.testing.allocator.dupe(u8, "all"), .backend = .all, .action = .upgrade, .state = .running };
    model.overlay = .{ .sudo = prompt };
    for ([_][]const u8{
        \\{"$kind":"q.yesno","QuestionId":"1","QuestionText":"Proceed with updates?"}
        ,
        \\{"$kind":"q.optdeps","QuestionId":"2","QuestionText":"Choose dependencies","Options":[{"Index":0,"Name":"docs"}]}
        ,
        \\{"$kind":"q.pkgbuilddiff","QuestionId":"3","PackageName":"demo","OldPkgbuild":"pkgver=1","NewPkgbuild":"pkgver=2"}
        ,
    }) |json| {
        try operation_model.showOperationQuestion(model, try shelly_operation.decodeJson(std.testing.allocator, json));
        defer operation_model.finishOperationQuestion(model);
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const surface = try model.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 100, .height = 30 }, .cell_size = .{ .width = 10, .height = 20 } });
        if (model.operation_state.operation_question.?.value.question == .pkgbuild) {
            try std.testing.expect(!try contains(surface, "visible-update", std.testing.allocator));
            try std.testing.expect(try contains(surface, "pkgver=2", std.testing.allocator));
            try std.testing.expectEqual(@as(usize, 3), surface.children.len);
            try std.testing.expectEqual(@as(u16, 26), surface.children[1].surface.size.height);
            operation_model.finishOperationQuestion(model);
            const restored = try model.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 100, .height = 30 }, .cell_size = .{ .width = 10, .height = 20 } });
            try std.testing.expect(try contains(restored, "visible-update", std.testing.allocator));
        } else {
            try std.testing.expect(try contains(surface.children[1].surface, "visible-update", std.testing.allocator));
            const review = surface.children[surface.children.len - 2];
            try std.testing.expect(review.origin.row > surface.children[1].origin.row);
            try std.testing.expect(surface.children[1].origin.row + surface.children[1].surface.size.height <= review.origin.row);
            try std.testing.expect(!try contains(review.surface, "visible-update", std.testing.allocator));
        }
        try std.testing.expectEqual(@as(usize, 0), model.updates_state.updates_list.cursor);
    }
}
