//! Persistent TUI preferences and source visibility.
const updates_model = @import("updates_model.zig");
const flatpak_model = @import("flatpak_model.zig");
const aur_model = @import("aur_model.zig");
const operation_model = @import("operation_model.zig");
const std = @import("std");
const commands = @import("../commands.zig");
const Settings = @import("settings.zig").Settings;
const ShellyCli = @import("../services/shelly_cli.zig").ShellyCli;
const preferences = @import("settings.zig");
const settings_service = @import("../services/settings.zig");
const settings_view = @import("../views/settings_view.zig");
const footer_view = @import("../views/footer_view.zig");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const runtime = @import("../runtime.zig");

const flatpak = @import("flatpak.zig");
const Package = @import("packages.zig").Package;
const CheckUpdates = @import("sync.zig").CheckUpdates;
const ParsedCheckUpdates = @import("sync.zig").ParsedCheckUpdates;

const coordinator = @import("../model.zig");
const Model = coordinator.Model;
const Tab = coordinator.Tab;
const UpdatesJob = updates_model.UpdatesJob;

/// Page-owned state. Worker results are published to the UI loop before use.
pub const screenshots_index = @import("settings.zig").screenshots_index;
pub const save_index = @import("settings.zig").save_index;
pub const control_count: usize = save_index + 1;

pub const State = struct {
    settings: Settings = .{},
    settings_draft: Settings = .{},
    settings_store: ?settings_service.Store = null,
    settings_failure: ?anyerror = null,
    settings_selected: usize = 0,
    aur_source_url: ?[]const u8 = null,
    cli_binary: ?[]const u8 = null,
    cli_environment: ?*const std.process.Environ.Map = null,
};

pub fn deinit(self: *Model) void {
    if (self.settings_state.aur_source_url) |url| self.gpa.free(url);
    if (self.settings_state.settings_store) |store| store.deinit();
}

fn settingsCli(self: *Model, io: std.Io) ShellyCli {
    return .{ .allocator = self.gpa, .io = io, .binary = self.settings_state.cli_binary, .environment = self.settings_state.cli_environment };
}

fn loadSharedSource(self: *Model, io: std.Io) !bool {
    const source = try settingsCli(self, io).get_aur_source();
    defer source.deinit();
    try rememberAurSource(self, source.value.AurUrl);
    return preferences.isAtollUrl(source.value.AurUrl);
}

fn rememberAurSource(self: *Model, url: []const u8) !void {
    if (self.settings_state.aur_source_url) |old| {
        if (std.mem.eql(u8, old, url)) return;
    }
    const owned = try self.gpa.dupe(u8, url);
    if (self.settings_state.aur_source_url) |old| {
        aur_model.invalidateInstalledCache(self);
        self.gpa.free(old);
    }
    self.settings_state.aur_source_url = owned;
}

pub fn loadSettings(self: *Model, io: std.Io, env: *const std.process.Environ.Map) void {
    self.settings_state.cli_environment = env;
    self.settings_state.settings_store = settings_service.Store.init(self.gpa, env) catch |err| {
        self.settings_state.settings_failure = err;
        self.setNotice("Could not load TUI settings; using system-only defaults. Open Settings for details.") catch {};
        return;
    };
    var saved = self.settings_state.settings_store.?.load(io) catch |err| {
        self.settings_state.settings_failure = err;
        self.setNotice("Could not load TUI settings; using system-only defaults. Open Settings for details.") catch {};
        return;
    };
    saved.atoll_aur_enabled = loadSharedSource(self, io) catch |err| {
        applySettings(self, saved);
        self.settings_state.settings_failure = err;
        self.setNotice("Could not read the shared AUR source. Reload Settings to retry.") catch {};
        return;
    };
    applySettings(self, saved);
}

pub fn applySettings(self: *Model, saved: Settings) void {
    const atoll_changed = self.settings_state.settings.atoll_aur_enabled != saved.atoll_aur_enabled;
    const sources_changed = atoll_changed or self.settings_state.settings.aur_enabled != saved.aur_enabled or self.settings_state.settings.flatpak_enabled != saved.flatpak_enabled;
    if (atoll_changed or self.settings_state.settings.aur_enabled != saved.aur_enabled) {
        aur_model.invalidateInstalledCache(self);
        aur_model.clearAurSelection(self);
        self.aur_state.catalog_checked = false;
        self.aur_state.catalog_page = 1;
        self.aur_state.catalog_failed_page = null;
        self.aur_state.catalog_total_pages = 0;
        self.operation_state.pkgbuild_generation +%= 1;
        if (self.overlay) |overlay| {
            if (overlay == .aur or overlay == .pkgbuild) operation_model.closeOverlay(self);
        }
        self.aur_state.aur_filtered.clearRetainingCapacity();
        self.aur_state.aur_packages = &.{};
        if (self.aur_state.aur_parsed) |*parsed| parsed.deinit();
        self.aur_state.aur_parsed = null;
        self.aur_state.aur_list.item_count = 0;
        self.aur_state.aur_list.jumpToItem(0);
    }
    if (self.settings_state.settings.flatpak_enabled != saved.flatpak_enabled) {
        flatpak_model.closeScreenshots(self);
        if (self.overlay) |overlay| {
            if (overlay == .flatpak or overlay == .flatpak_install) operation_model.closeOverlay(self);
        }
        self.flatpak_state.flatpak_category_open = false;
        self.flatpak_state.flatpak_categories.clearRetainingCapacity();
        self.flatpak_state.flatpak_rows.clearRetainingCapacity();
        if (self.flatpak_state.flatpak_catalog) |*parsed| parsed.deinit();
        if (self.flatpak_state.flatpak_installed) |*parsed| parsed.deinit();
        self.flatpak_state.flatpak_catalog = null;
        self.flatpak_state.flatpak_installed = null;
        self.flatpak_state.flatpak_list.item_count = 0;
        self.flatpak_state.flatpak_list.jumpToItem(0);
        self.flatpak_state.flatpak_checked = false;
        self.flatpak_state.flatpak_available = false;
        self.flatpak_state.flatpak_probe_error = null;
    }
    if (!saved.show_flatpak_screenshots and self.settings_state.settings.show_flatpak_screenshots) flatpak_model.closeScreenshots(self);
    self.settings_state.settings = saved;
    self.settings_state.settings_draft = saved;
    self.settings_state.settings_failure = null;
    commands.apply(saved.keybindings.resolve());
    if (sources_changed) {
        self.updates_state.updates_checked = false;
        if (self.updates_state.updates_parsed) |*parsed| {
            if (atoll_changed or !saved.aur_enabled) parsed.value.Aur = &.{};
            if (!saved.flatpak_enabled) parsed.value.Flatpak = &.{};
            self.updates_state.updates_list.item_count = @intCast(parsed.value.count());
            self.updates_state.updates_list.scroll = .{};
            self.updates_state.updates_list.cursor = 0;
        }
    }
    if (!self.tabEnabled(self.active)) {
        operation_model.closeOverlay(self);
        self.active = .packages;
    }
}

pub fn hasChanges(self: *const Model) bool {
    return !self.settings_state.settings_draft.eql(self.settings_state.settings);
}

pub fn toggleSetting(self: *Model, ctx: *vxfw.EventContext) !void {
    if (self.operation_state.install_job != null) return;
    if (self.settings_state.settings_selected == save_index) return saveSettings(self, ctx);
    const draft = &self.settings_state.settings_draft;
    switch (self.settings_state.settings_selected) {
        0 => draft.aur_enabled = !draft.aur_enabled,
        1 => draft.flatpak_enabled = !draft.flatpak_enabled,
        2...4 => draft.header_icons = @import("settings.zig").header_styles[self.settings_state.settings_selected - 2],
        @import("settings.zig").atoll_index => draft.atoll_aur_enabled = !draft.atoll_aur_enabled,
        screenshots_index => draft.show_flatpak_screenshots = !draft.show_flatpak_screenshots,
        else => unreachable,
    }
}

pub fn saveSettings(self: *Model, ctx: *vxfw.EventContext) !void {
    if (self.operation_state.install_job != null or !hasChanges(self)) return;
    const store = self.settings_state.settings_store orelse {
        self.settings_state.settings_failure = error.SettingsNotInitialized;
        return;
    };
    var saved = self.settings_state.settings_draft;
    store.save(runtime.io, saved) catch |err| {
        self.settings_state.settings_failure = err;
        return;
    };
    if (saved.atoll_aur_enabled != self.settings_state.settings.atoll_aur_enabled) {
        settingsCli(self, runtime.io).set_aur_url(preferences.aurUrl(saved.atoll_aur_enabled)) catch |err| {
            const pending = saved;
            saved.atoll_aur_enabled = self.settings_state.settings.atoll_aur_enabled;
            applySettings(self, saved);
            self.settings_state.settings_draft = pending;
            self.settings_state.settings_failure = err;
            return;
        };
        try rememberAurSource(self, preferences.aurUrl(saved.atoll_aur_enabled));
    }
    applySettings(self, saved);
    if (saved.flatpak_enabled and !self.flatpak_state.flatpak_checked) try flatpak_model.startFlatpakProbe(self, ctx);
    try self.focusActiveTab(ctx);
}

pub fn reloadSettings(self: *Model, ctx: *vxfw.EventContext) !void {
    if (self.operation_state.install_job != null) return;
    const store = self.settings_state.settings_store orelse return;
    var saved = store.load(runtime.io) catch |err| {
        self.settings_state.settings_failure = err;
        return;
    };
    saved.atoll_aur_enabled = loadSharedSource(self, runtime.io) catch |err| {
        commands.apply(saved.keybindings.resolve());
        self.settings_state.settings.keybindings = saved.keybindings;
        self.settings_state.settings_draft.keybindings = saved.keybindings;
        self.settings_state.settings_failure = err;
        return;
    };
    applySettings(self, saved);
    if (saved.flatpak_enabled and !self.flatpak_state.flatpak_checked) try flatpak_model.startFlatpakProbe(self, ctx);
    try self.focusActiveTab(ctx);
}

pub fn settingsView(self: *Model) settings_view.View {
    return .{ .settings = self.settings_state.settings_draft, .dirty = hasChanges(self), .selected = self.settings_state.settings_selected, .path = if (self.settings_state.settings_store) |store| store.path else "Settings could not be initialized", .failure = self.settings_state.settings_failure, .flatpak_checked = self.flatpak_state.flatpak_checked, .flatpak_available = self.flatpak_state.flatpak_available, .checking = self.flatpak_state.flatpak_probe_job != null, .busy = self.operation_state.install_job != null };
}

/// Returns whether page input was consumed. Globals remain with the coordinator.
pub fn handleKey(self: *Model, ctx: *vxfw.EventContext, key: vaxis.Key) anyerror!bool {
    if (commands.settings(key)) |action| {
        switch (action) {
            .previous => self.settings_state.settings_selected = (self.settings_state.settings_selected + control_count - 1) % control_count,
            .next => self.settings_state.settings_selected = (self.settings_state.settings_selected + 1) % control_count,
            .toggle => if (self.operation_state.install_job == null) try toggleSetting(self, ctx),
            .save => if (self.operation_state.install_job == null) try saveSettings(self, ctx),
            .reload => if (self.operation_state.install_job == null) try reloadSettings(self, ctx),
        }
        ctx.consumeAndRedraw();
        return true;
    }
    return false;
}

test "settings determine source visibility before backend or native loading finishes" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    try std.testing.expectEqualSlices(Tab, &.{ .packages, .upgrade, .settings }, model.visibleTabs());
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer events.cmds.deinit(std.testing.allocator);
    try model.setTab(.aur, &events);
    try std.testing.expectEqual(Tab.packages, model.active);
    applySettings(model, .{ .aur_enabled = true, .flatpak_enabled = true });
    try std.testing.expect(!model.flatpak_state.flatpak_available);
    try std.testing.expect(model.packages_state.loading);
    try std.testing.expectEqualSlices(Tab, Tab.all, model.visibleTabs());
    model.active = .flatpak;
    try model.focusActiveTab(&events);
    try std.testing.expect(events.cmds.items[events.cmds.items.len - 1].request_focus.eql(model.flatpak_state.flatpak_field.widget()));
    applySettings(model, .{});
    try std.testing.expectEqual(Tab.packages, model.active);
    try std.testing.expectEqualSlices(Tab, Tab.always, model.visibleTabs());
}

// Keep settings tests independent of the checkout or installed Shelly CLI.
fn createSettingsTestCli(directory: std.Io.Dir, io: std.Io) !void {
    const fixture = try directory.createFile(io, "settings-cli", .{ .permissions = .executable_file });
    defer fixture.close(io);
    try fixture.writeStreamingAll(io,
        \\#!/bin/sh
        \\case "$1:$2:$3" in
        \\  config:get:AurUrl)
        \\    printf '%s\n' '[JSON]eyJBdXJVcmwiOiJodHRwczovL2F1ci5hcmNobGludXgub3JnIn0=[/JSON]' ;;
        \\  *) exit 97 ;;
        \\esac
    );
}

test "settings drafts apply only after explicit save and survive failed saves" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    runtime.io = io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    var env: std.process.Environ.Map = .init(allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", directory);
    try createSettingsTestCli(temporary.dir, io);
    const binary = try std.fs.path.join(allocator, &.{ directory, "settings-cli" });
    defer allocator.free(binary);
    const model = try Model.init(allocator);
    defer model.deinit();
    model.settings_state.cli_binary = binary;
    model.loadSettings(io, &env);
    try std.testing.expect(model.settings_state.settings_failure == null);
    try std.testing.expect(model.settings_state.settings.eql(.{}));
    model.active = .settings;
    var ctx: vxfw.EventContext = .{ .io = io, .alloc = allocator, .cmds = .empty };
    defer ctx.cmds.deinit(allocator);
    try toggleSetting(model, &ctx);
    try std.testing.expect(!model.settings_state.settings.aur_enabled);
    try std.testing.expect(model.settings_state.settings_draft.aur_enabled);
    try std.testing.expect(!model.tabEnabled(.aur));
    try std.testing.expect(hasChanges(model));
    try std.testing.expect(!(try model.settings_state.settings_store.?.load(io)).aur_enabled);
    try saveSettings(model, &ctx);
    try std.testing.expect(model.settings_state.settings.aur_enabled);
    try std.testing.expect(!hasChanges(model));
    const restarted = try Model.init(allocator);
    defer restarted.deinit();
    restarted.settings_state.cli_binary = binary;
    restarted.loadSettings(io, &env);
    try std.testing.expect(restarted.settings_state.settings_failure == null);
    try std.testing.expect(restarted.settings_state.settings.aur_enabled);
    try std.testing.expect(restarted.tabEnabled(.aur));
    try std.testing.expect(restarted.flatpak_state.flatpak_probe_job == null);
    var file = try std.Io.Dir.cwd().createFile(io, model.settings_state.settings_store.?.path, .{ .truncate = true });
    try file.writeStreamingAll(io, "{\"AurEnabled\":\"invalid\"}");
    file.close(io);
    try toggleSetting(model, &ctx);
    try saveSettings(model, &ctx);
    try std.testing.expectEqual(error.InvalidSettings, model.settings_state.settings_failure.?);
    try std.testing.expect(model.settings_state.settings.aur_enabled);
    try std.testing.expect(!model.settings_state.settings_draft.aur_enabled);
    try std.testing.expect(hasChanges(model));
}

test "settings changes reject late update results and disabled source data" {
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    model.settings_state.settings = .{ .aur_enabled = true, .flatpak_enabled = true };
    model.flatpak_state.flatpak_available = true;
    model.updates_state.updates_parsed = ParsedCheckUpdates.fromParsed(try std.json.parseFromSlice(CheckUpdates, allocator, "{\"Packages\":[{\"Name\":\"native\"}],\"Aur\":[{\"Name\":\"aur\"}],\"Flatpak\":[{\"Id\":\"org.example.App\"}]}", .{ .allocate = .alloc_always }));
    applySettings(model, .{});
    try std.testing.expectEqual(@as(usize, 1), model.updates_state.updates_parsed.?.value.count());
    try std.testing.expect(!updates_model.updatesView(model).canUpgradeAur());
    try std.testing.expect(!updates_model.updatesView(model).canUpgradeFlatpak());
    const job = try allocator.create(UpdatesJob);
    job.* = .{ .aur_enabled = true, .flatpak_enabled = true, .done = .init(true), .result = ParsedCheckUpdates.fromParsed(try std.json.parseFromSlice(CheckUpdates, allocator, "{\"Aur\":[{\"Name\":\"stale\"}]}", .{ .allocate = .alloc_always })) };
    const Worker = struct {
        fn finish(value: *UpdatesJob) void {
            value.done.store(true, .release);
        }
    };
    model.updates_state.updates_job = job;
    model.updates_state.updates_thread = try std.Thread.spawn(.{}, Worker.finish, .{job});
    updates_model.pollUpdates(model);
    try std.testing.expect(!model.updates_state.updates_checked);
    try std.testing.expectEqualStrings("native", model.updates_state.updates_parsed.?.value.Packages[0].Name);
}

test "settings keyboard edits survive tab changes and support Save Reload and Ctrl S" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    runtime.io = io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    var env: std.process.Environ.Map = .init(allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", directory);
    try createSettingsTestCli(temporary.dir, io);
    const binary = try std.fs.path.join(allocator, &.{ directory, "settings-cli" });
    defer allocator.free(binary);
    const model = try Model.init(allocator);
    defer model.deinit();
    model.settings_state.cli_binary = binary;
    loadSettings(model, io, &env);
    try std.testing.expect(model.settings_state.settings_failure == null);
    model.active = .settings;
    var ctx: vxfw.EventContext = .{ .io = io, .alloc = allocator, .cmds = .empty };
    defer ctx.cmds.deinit(allocator);
    try model.captureEvent(&ctx, .{ .key_press = commands.bindings.mark });
    try std.testing.expect(hasChanges(model));
    try std.testing.expect(!model.tabEnabled(.aur));
    model.switchTab(1);
    try model.setTab(.settings, &ctx);
    try std.testing.expect(model.settings_state.settings_draft.aur_enabled);
    for (0..save_index) |_| try model.captureEvent(&ctx, .{ .key_press = commands.bindings.next });
    try std.testing.expectEqual(save_index, model.settings_state.settings_selected);
    try std.testing.expect(model.commandContext().settings_save_selected);
    try model.captureEvent(&ctx, .{ .key_press = commands.bindings.confirm });
    try std.testing.expect(model.tabEnabled(.aur));
    try std.testing.expect(!hasChanges(model));
    try std.testing.expect((try model.settings_state.settings_store.?.load(io)).aur_enabled);

    // Reload discards the draft; neither editing nor tab changes save it.
    model.settings_state.settings_selected = 0;
    try model.captureEvent(&ctx, .{ .key_press = commands.bindings.mark });
    try std.testing.expect(!model.settings_state.settings_draft.aur_enabled);
    try std.testing.expect(model.settings_state.settings.aur_enabled);
    try model.captureEvent(&ctx, .{ .key_press = commands.bindings.refresh });
    try std.testing.expect(model.settings_state.settings_failure == null);
    try std.testing.expect(model.settings_state.settings_draft.aur_enabled);
    try std.testing.expect(!hasChanges(model));

    try model.captureEvent(&ctx, .{ .key_press = commands.bindings.mark });
    try model.captureEvent(&ctx, .{ .key_press = commands.bindings.save_settings });
    try std.testing.expect(!model.tabEnabled(.aur));
    try std.testing.expect(!hasChanges(model));
    try std.testing.expect(!(try model.settings_state.settings_store.?.load(io)).aur_enabled);
    model.settings_state.settings_selected = 2;
    model.updates_state.updates_checked = true;
    for ([_]@import("settings.zig").HeaderIcons{ .nerd_font, .ascii, .none }) |style| {
        model.settings_state.settings_selected = 2 + @as(usize, @backingInt(style));
        const applied = model.settings_state.settings.header_icons;
        try model.captureEvent(&ctx, .{ .key_press = commands.bindings.confirm });
        try std.testing.expectEqual(style, model.settings_state.settings_draft.header_icons);
        try model.captureEvent(&ctx, .{ .key_press = commands.bindings.mark });
        try std.testing.expectEqual(style, model.settings_state.settings_draft.header_icons);
        try std.testing.expectEqual(applied, model.settings_state.settings.header_icons);
        try std.testing.expect(model.commandContext().settings_cycle_selected);
        try model.captureEvent(&ctx, .{ .key_press = commands.bindings.save_settings });
        try std.testing.expectEqual(style, model.settings_state.settings.header_icons);
        try std.testing.expect(model.updates_state.updates_checked);
        try std.testing.expectEqual(style, (try model.settings_state.settings_store.?.load(io)).header_icons);
    }
}

test "Atoll toggle is drafted and changing the saved source clears AUR results and selections" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    applySettings(model, .{ .aur_enabled = true });
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = model.gpa, .cmds = .empty };
    defer ctx.cmds.deinit(model.gpa);
    model.settings_state.settings_selected = @import("settings.zig").atoll_index;
    try toggleSetting(model, &ctx);
    try std.testing.expect(hasChanges(model));
    try std.testing.expect(!model.settings_state.settings.atoll_aur_enabled);
    try std.testing.expect(model.settings_state.settings_draft.atoll_aur_enabled);
    try model.aur_state.aur_selection.append(model.gpa, .{ .name = try model.gpa.dupe(u8, "demo"), .installed = true });
    model.aur_state.aur_parsed = try std.json.parseFromSlice([]@import("packages.zig").AurPackage, model.gpa, "[{\"Name\":\"demo\"}]", .{ .allocate = .alloc_always });
    model.aur_state.aur_packages = model.aur_state.aur_parsed.?.value;
    try @import("aur_model.zig").rebuildAurFilter(model);
    model.overlay = .{ .aur = &model.aur_state.aur_packages[0] };
    model.updates_state.updates_checked = true;
    applySettings(model, model.settings_state.settings_draft);
    try std.testing.expect(model.overlay == null);
    try std.testing.expect(model.aur_state.aur_parsed == null);
    try std.testing.expectEqual(@as(usize, 0), model.aur_state.aur_selection.items.len);
    try std.testing.expectEqual(@as(usize, 0), model.aur_state.aur_filtered.items.len);
    try std.testing.expect(!model.updates_state.updates_checked);
}

test "changing Atoll source rejects in flight AUR and update results" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    applySettings(model, .{ .aur_enabled = true });
    const aur_job = try model.gpa.create(@import("aur_model.zig").AurSearchJob);
    aur_job.* = .{ .done = .init(true), .result = try std.json.parseFromSlice([]@import("packages.zig").AurPackage, model.gpa, "[{\"Name\":\"old-source\"}]", .{ .allocate = .alloc_always }) };
    const Worker = struct {
        fn finish() void {}
    };
    model.aur_state.aur_job = aur_job;
    model.aur_state.aur_thread = try std.Thread.spawn(.{}, Worker.finish, .{});
    const updates_job = try model.gpa.create(UpdatesJob);
    updates_job.* = .{ .aur_enabled = true, .done = .init(true), .result = @import("sync.zig").ParsedCheckUpdates.fromParsed(try std.json.parseFromSlice(CheckUpdates, model.gpa, "{}", .{})) };
    model.updates_state.updates_job = updates_job;
    model.updates_state.updates_thread = try std.Thread.spawn(.{}, Worker.finish, .{});
    applySettings(model, .{ .aur_enabled = true, .atoll_aur_enabled = true });
    try std.testing.expect(!try @import("aur_model.zig").pollAurSearch(model));
    updates_model.pollUpdates(model);
    try std.testing.expect(model.aur_state.aur_parsed == null);
    try std.testing.expect(model.updates_state.updates_parsed == null);
    try std.testing.expect(!model.updates_state.updates_checked);
}

test "Atoll setting reads and updates the shared CLI source instead of a frontend preference" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    runtime.io = io;
    defer runtime.io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(directory);
    var env: std.process.Environ.Map = .init(alloc);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", directory);
    const binary = try std.fs.path.join(alloc, &.{ directory, "fixture-cli" });
    defer alloc.free(binary);
    const fixture = try temporary.dir.createFile(io, "fixture-cli", .{ .permissions = .executable_file });
    try fixture.writeStreamingAll(io,
        \\#!/bin/sh
        \\state="$XDG_CONFIG_HOME/fixture-aur-url"
        \\case "$1:$2:$3" in
        \\  config:get:AurUrl)
        \\    url='https://atoll.seafoam-labs.org'
        \\    if [ -f "$state" ]; then IFS= read -r url < "$state"; fi
        \\    if [ "$url" = 'https://atoll.seafoam-labs.org' ]; then
        \\      printf '%s\n' '[JSON]eyJBdXJVcmwiOiJodHRwczovL2F0b2xsLnNlYWZvYW0tbGFicy5vcmcifQ==[/JSON]'
        \\    else
        \\      printf '%s\n' '[JSON]eyJBdXJVcmwiOiJodHRwczovL2F1ci5hcmNobGludXgub3JnIn0=[/JSON]'
        \\    fi ;;
        \\  config:set:AurUrl)
        \\    if [ -f "$XDG_CONFIG_HOME/fixture-fail" ]; then
        \\      printf '%s\n' '[JSON]eyIka2luZCI6ImFscG0uZXJyb3IiLCJFcnJvck1lc3NhZ2UiOiJGaXh0dXJlIGNvbmZpZyB3cml0ZSBmYWlsZWQifQ==[/JSON]'
        \\      exit 0
        \\    fi
        \\    printf '%s\n' "$4" > "$state"
        \\    printf '%s\n' '[JSON]eyIka2luZCI6ImFscG0uaW5mbyIsIk1lc3NhZ2UiOiJVcGRhdGVkIn0=[/JSON]' ;;
        \\  *) exit 97 ;;
        \\esac
    );
    fixture.close(io);
    const store = try settings_service.Store.init(alloc, &env);
    defer store.deinit();
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(store.path).?);
    const legacy = try std.Io.Dir.cwd().createFile(io, store.path, .{});
    try legacy.writeStreamingAll(io, "{\"AurEnabled\":true,\"AtollAurEnabled\":false}");
    legacy.close(io);
    const model = try Model.init(alloc);
    defer model.deinit();
    model.settings_state.cli_binary = binary;
    loadSettings(model, io, &env);
    try std.testing.expect(model.settings_state.settings_failure == null);
    try std.testing.expect(model.settings_state.settings.atoll_aur_enabled);
    try std.testing.expect(model.settings_state.settings_draft.atoll_aur_enabled);
    try std.testing.expect(!hasChanges(model));
    var ctx: vxfw.EventContext = .{ .io = io, .alloc = alloc, .cmds = .empty };
    defer ctx.cmds.deinit(alloc);
    model.settings_state.settings_selected = preferences.atoll_index;
    try toggleSetting(model, &ctx);
    try saveSettings(model, &ctx);
    try std.testing.expect(model.settings_state.settings_failure == null);
    try std.testing.expect(!model.settings_state.settings.atoll_aur_enabled);
    const url = try temporary.dir.readFileAlloc(io, "fixture-aur-url", alloc, .limited(4096));
    defer alloc.free(url);
    try std.testing.expectEqualStrings("https://aur.archlinux.org\n", url);
    const json = try std.Io.Dir.cwd().readFileAlloc(io, store.path, alloc, .limited(4096));
    defer alloc.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "AtollAurEnabled") == null);
    const external = try temporary.dir.createFile(io, "fixture-aur-url", .{});
    try external.writeStreamingAll(io, "https://atoll.seafoam-labs.org\n");
    external.close(io);
    try reloadSettings(model, &ctx);
    try std.testing.expect(model.settings_state.settings.atoll_aur_enabled);
    // CLI error frames must keep the current source and the pending draft.
    const failed = try temporary.dir.createFile(io, "fixture-fail", .{});
    failed.close(io);
    try toggleSetting(model, &ctx);
    try saveSettings(model, &ctx);
    try std.testing.expectEqual(error.CommandFailed, model.settings_state.settings_failure.?);
    try std.testing.expect(model.settings_state.settings.atoll_aur_enabled);
    try std.testing.expect(!model.settings_state.settings_draft.atoll_aur_enabled);
    try std.testing.expect(hasChanges(model));
}

const KeybindingTest = struct {
    temporary: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    env: std.process.Environ.Map,
    model: ?*Model = null,
    original_bindings: commands.Bindings,
    events: vxfw.EventContext,

    fn init(json: []const u8) !*KeybindingTest {
        const allocator = std.testing.allocator;
        const self = try allocator.create(KeybindingTest);
        self.* = .{
            .temporary = std.testing.tmpDir(.{}),
            .arena = .init(allocator),
            .env = .init(allocator),
            .original_bindings = commands.bindings,
            .events = .{ .io = std.testing.io, .alloc = allocator, .cmds = .empty },
        };
        errdefer self.deinit();
        runtime.io = std.testing.io;
        const directory = try self.temporary.dir.realPathFileAlloc(std.testing.io, ".", self.arena.allocator());
        try self.env.put("XDG_CONFIG_HOME", directory);
        try createSettingsTestCli(self.temporary.dir, std.testing.io);
        try self.write(json);
        self.model = try Model.init(allocator);
        self.model.?.settings_state.cli_binary = try std.fs.path.join(self.arena.allocator(), &.{ directory, "settings-cli" });
        return self;
    }

    fn deinit(self: *KeybindingTest) void {
        if (self.model) |model| model.deinit();
        commands.bindings = self.original_bindings;
        self.events.cmds.deinit(std.testing.allocator);
        self.env.deinit();
        self.arena.deinit();
        self.temporary.cleanup();
        std.testing.allocator.destroy(self);
    }

    fn write(self: *KeybindingTest, json: []const u8) !void {
        var staged = try self.temporary.dir.createFileAtomic(std.testing.io, "shelly/tui-settings.json", .{ .make_path = true, .replace = true });
        defer staged.deinit(std.testing.io);
        try staged.file.writeStreamingAll(std.testing.io, json);
        try staged.replace(std.testing.io);
    }

    fn load(self: *KeybindingTest) void {
        loadSettings(self.model.?, std.testing.io, &self.env);
    }

    fn reload(self: *KeybindingTest) !void {
        try reloadSettings(self.model.?, &self.events);
    }

    fn expectLabel(self: *KeybindingTest, id: commands.Id, expected: []const u8) !void {
        try std.testing.expectEqualStrings(expected, try commands.label(self.arena.allocator(), id));
    }
};

test "startup applies overrides without rewriting settings or inheriting live bindings" {
    const json = "{\"Keybindings\":{\"help\":\"F2\",\"install\":\"F3\"}}";
    const fixture = try KeybindingTest.init(json);
    defer fixture.deinit();
    commands.bindings.remove = .{ .codepoint = vaxis.Key.f8 };
    fixture.load();
    try std.testing.expect(fixture.model.?.settings_state.settings_failure == null);
    try fixture.expectLabel(.help, "F2");
    try fixture.expectLabel(.install, "F3");
    try fixture.expectLabel(.remove, "R");
    const contents = try fixture.temporary.dir.readFileAlloc(std.testing.io, "shelly/tui-settings.json", fixture.arena.allocator(), .limited(4096));
    try std.testing.expectEqualStrings(json, contents);
}

test "reload applies changed overrides and removing overrides restores defaults" {
    const fixture = try KeybindingTest.init("{\"Keybindings\":{\"help\":\"F2\"}}");
    defer fixture.deinit();
    fixture.load();
    try fixture.expectLabel(.help, "F2");
    try fixture.write("{\"Keybindings\":{\"help\":\"F3\",\"install\":\"F4\"}}");
    try fixture.reload();
    try std.testing.expect(fixture.model.?.settings_state.settings_failure == null);
    try fixture.expectLabel(.help, "F3");
    try fixture.expectLabel(.install, "F4");
    try fixture.write("{}");
    try fixture.reload();
    try fixture.expectLabel(.help, "F1");
    try fixture.expectLabel(.install, "I");
}

test "invalid overrides preserve all active bindings and pending settings" {
    const fixture = try KeybindingTest.init("{\"Keybindings\":{\"help\":\"F2\"}}");
    defer fixture.deinit();
    fixture.load();
    fixture.model.?.settings_state.settings_draft.aur_enabled = true;
    const previous = commands.bindings;
    try fixture.write("{\"Keybindings\":{\"help\":\"F3\",\"confirm\":\"F4\"}}");
    try fixture.reload();
    try std.testing.expectEqual(error.FixedCommand, fixture.model.?.settings_state.settings_failure.?);
    try std.testing.expectEqualDeep(previous, commands.bindings);
    try std.testing.expect(fixture.model.?.settings_state.settings_draft.aur_enabled);
}

test "valid keybindings apply on startup and reload despite an AUR source failure" {
    const fixture = try KeybindingTest.init("{\"Keybindings\":{\"help\":\"F2\"}}");
    defer fixture.deinit();
    const io = std.testing.io;
    const binary = fixture.model.?.settings_state.cli_binary.?;
    // Close the executable before invoking it; otherwise Linux may reject it
    // with TextFileBusy instead of exercising the intended CLI failure.
    const file = try std.Io.Dir.cwd().createFile(io, binary, .{ .truncate = true, .permissions = .executable_file });
    try file.writeStreamingAll(io, "#!/bin/sh\nexit 1\n");
    file.close(io);
    fixture.load();
    try std.testing.expectEqual(error.CommandFailed, fixture.model.?.settings_state.settings_failure.?);
    try fixture.expectLabel(.help, "F2");
    try fixture.write("{\"Keybindings\":{\"help\":\"F3\"}}");
    try fixture.reload();
    try std.testing.expectEqual(error.CommandFailed, fixture.model.?.settings_state.settings_failure.?);
    try fixture.expectLabel(.help, "F3");
}

test "remapped Quit and Help dispatch through the coordinator and retain operation protection" {
    const fixture = try KeybindingTest.init("{\"Keybindings\":{\"quit\":\"Ctrl+Z\",\"help\":\"F2\"}}");
    defer fixture.deinit();
    fixture.load();
    const model = fixture.model.?;
    const ctx = &fixture.events;
    try std.testing.expectEqualDeep(commands.bindings.quit, commands.bindings.interrupt);
    try std.testing.expect(!commands.matches(.{ .codepoint = 'c', .mods = .{ .ctrl = true } }, .quit));
    try model.captureEvent(ctx, .{ .key_press = .{ .codepoint = 'c', .mods = .{ .ctrl = true } } });
    try std.testing.expect(!ctx.quit);
    try model.captureEvent(ctx, .{ .key_press = .{ .codepoint = 'z', .mods = .{ .ctrl = true } } });
    try std.testing.expect(ctx.quit);
    ctx.quit = false;
    try model.captureEvent(ctx, .{ .key_press = .{ .codepoint = vaxis.Key.f1 } });
    try std.testing.expect(!model.help_open);
    try model.captureEvent(ctx, .{ .key_press = .{ .codepoint = vaxis.Key.f2 } });
    try std.testing.expect(model.help_open);
    model.help_open = false;
    var job: @import("../services/shelly_operation.zig").Operation = .{ .arena = .init(std.testing.allocator), .request = undefined };
    defer job.arena.deinit();
    model.operation_state.install_job = &job;
    defer model.operation_state.install_job = null;
    for ([_]Tab{ .packages, .aur, .flatpak, .upgrade, .settings }) |tab| {
        model.active = tab;
        ctx.consume_event = false;
        ctx.redraw = false;
        try model.captureEvent(ctx, .{ .key_press = .{ .codepoint = 'z', .mods = .{ .ctrl = true } } });
        try std.testing.expect(!ctx.quit);
        try std.testing.expect(ctx.consume_event and ctx.redraw);
        try std.testing.expect(model.commandContext().quit_blocked);
    }
}

test "Help and footer show loaded editable bindings" {
    const fixture = try KeybindingTest.init("{\"Keybindings\":{\"help\":\"F2\",\"install\":\"F3\"}}");
    defer fixture.deinit();
    fixture.load();
    vxfw.DrawContext.init(.unicode);
    const model = fixture.model.?;
    model.packages_state.package_list_active = true;
    model.packages_state.loading = false;
    var packages = [_]Package{.{ .Name = "example" }};
    model.packages_state.packages = &packages;
    try @import("packages_model.zig").rebuildFilter(model);
    model.help_panel.context = model.commandContext();
    const allocator = fixture.arena.allocator();
    const help_text = try model.help_panel.text(allocator);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "F2: Open/close help") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "F3: Install/reinstall") != null);
    const footer = try footer_view.draw(.{ .arena = allocator, .min = .{}, .max = .{ .width = 160, .height = 1 }, .cell_size = .{ .width = 10, .height = 20 } }, model.commandContext(), null);
    var text: std.ArrayList(u8) = .empty;
    for (footer.children) |child| for (child.surface.buffer) |cell| try text.appendSlice(allocator, cell.char.grapheme);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "F2 Help") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "F3 Install") != null);
}

test "loaded bindings route actions on all pages without executing operations" {
    const fixture = try KeybindingTest.init(
        \\{"AurEnabled":true,"FlatpakEnabled":true,"Keybindings":{"install":"F3","remove":"F4","upgrade_system":"F5","refresh":"F6"}}
    );
    defer fixture.deinit();
    fixture.load();
    const model = fixture.model.?;
    const ctx = &fixture.events;
    try std.testing.expect(model.settings_state.settings_failure == null);

    var native = [_]Package{.{ .Name = "editor" }};
    model.packages_state.packages = &native;
    model.packages_state.loading = false;
    model.packages_state.package_list_active = true;
    try @import("packages_model.zig").rebuildFilter(model);
    try model.captureEvent(ctx, .{ .key_press = .{ .codepoint = 'i' } });
    try std.testing.expect(model.overlay == null);
    try model.captureEvent(ctx, .{ .key_press = .{ .codepoint = vaxis.Key.f3 } });
    try std.testing.expectEqualStrings("editor", model.overlay.?.sudo.name);
    try std.testing.expectEqual(.standard, model.overlay.?.sudo.backend);
    operation_model.closeOverlay(model);

    model.active = .aur;
    var aur = [_]@import("packages.zig").AurPackage{.{ .Name = "editor-git" }};
    model.aur_state.aur_packages = &aur;
    model.aur_state.aur_list_active = true;
    try @import("aur_model.zig").rebuildAurFilter(model);
    try model.captureEvent(ctx, .{ .key_press = .{ .codepoint = 'i' } });
    try std.testing.expect(model.overlay == null);
    try model.captureEvent(ctx, .{ .key_press = .{ .codepoint = vaxis.Key.f3 } });
    try std.testing.expectEqualStrings("editor-git", model.overlay.?.sudo.name);
    try std.testing.expectEqual(.aur, model.overlay.?.sudo.backend);
    operation_model.closeOverlay(model);

    model.active = .flatpak;
    model.flatpak_state.flatpak_available = true;
    const app: flatpak.Flatpak = .{ .Id = "org.example.Editor", .Ref = "app/org.example.Editor/x86_64/stable", .InstallLevel = .user };
    model.overlay = .{ .flatpak = .{ .installed = &app } };
    try model.captureEvent(ctx, .{ .key_press = .{ .codepoint = 'r' } });
    try std.testing.expect(model.overlay.? == .flatpak);
    try model.captureEvent(ctx, .{ .key_press = .{ .codepoint = vaxis.Key.f4 } });
    try std.testing.expectEqual(.flatpak, model.overlay.?.sudo.backend);
    try std.testing.expectEqual(.remove, model.overlay.?.sudo.action);
    try std.testing.expectEqualStrings(app.Id, model.overlay.?.sudo.name);
    operation_model.closeOverlay(model);

    model.active = .upgrade;
    model.updates_state.updates_parsed = ParsedCheckUpdates.fromParsed(try std.json.parseFromSlice(CheckUpdates, std.testing.allocator, "{\"Packages\":[{\"Name\":\"editor\"}]}", .{ .allocate = .alloc_always }));
    try model.captureEvent(ctx, .{ .key_press = .{ .codepoint = 'u' } });
    try std.testing.expect(model.overlay == null);
    try model.captureEvent(ctx, .{ .key_press = .{ .codepoint = vaxis.Key.f5 } });
    try std.testing.expectEqual(.upgrade, model.overlay.?.sudo.action);
    try std.testing.expectEqual(.standard, model.overlay.?.sudo.backend);
    operation_model.closeOverlay(model);

    model.active = .settings;
    model.settings_state.settings_draft.aur_enabled = false;
    try model.captureEvent(ctx, .{ .key_press = .{ .codepoint = 'r' } });
    try std.testing.expect(!model.settings_state.settings_draft.aur_enabled);
    // Avoid starting a backend probe when reloading; no subprocess work is needed.
    model.flatpak_state.flatpak_checked = true;
    try model.captureEvent(ctx, .{ .key_press = .{ .codepoint = vaxis.Key.f6 } });
    try std.testing.expect(model.settings_state.settings_draft.aur_enabled);
    try std.testing.expect(model.operation_state.install_job == null);
}
