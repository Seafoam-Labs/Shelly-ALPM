const std = @import("std");
const Border = @import("views/border.zig");
const Settings = @import("models/settings.zig").Settings;
const settings_service = @import("services/settings.zig");
const settings_view = @import("views/settings_view.zig");
const commands = @import("commands.zig");
const help_view = @import("views/help_view.zig");
const footer_view = @import("views/footer_view.zig");
const packages_view = @import("views/packages_view.zig");
const flatpak_view = @import("views/flatpak_view.zig");
const aur_view = @import("views/aur_view.zig");
const updates_view = @import("views/updates_view.zig");
const pkgbuild_view = @import("views/pkgbuild_view.zig");
const PkgBuild = @import("models/pkgbuild.zig").PkgBuild;
const operation_view = @import("views/operation_view.zig");
const shelly_operation = @import("services/shelly_operation.zig");
const diagnostics = @import("diagnostics");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const shelly_cli = @import("services/shelly_cli.zig");
const ShellyCli = shelly_cli.ShellyCli;
const runtime = @import("runtime.zig");
const Package = @import("models/packages.zig").Package;
const AurPackage = @import("models/packages.zig").AurPackage;

const flatpak = @import("models/flatpak.zig");
const CheckUpdates = @import("models/sync.zig").CheckUpdates;

const Allocator = std.mem.Allocator;
const OperationBackend = shelly_operation.Backend;

pub const Tab = enum {
    packages,
    aur,
    flatpak,
    upgrade,
    settings,

    pub const always: []const Tab = &.{ .packages, .upgrade, .settings };

    pub const all: []const Tab = &.{ .packages, .aur, .flatpak, .upgrade, .settings };

    pub fn title(self: Tab) []const u8 {
        return switch (self) {
            .packages => "Packages",
            .aur => "AUR",
            .upgrade => "Upgrade",
            .flatpak => "Flatpak",
            .settings => "Settings",
        };
    }
};

/// Shared state between the UI and the background package loader. The
/// loader writes exactly once; `done` is published with release semantics
/// after the result fields are written, so the UI can read them with an
/// acquire load and no lock.
const LoadState = struct {
    result: ?std.json.Parsed([]Package) = null,
    failed: bool = false,
    done: std.atomic.Value(bool) = .init(false),
};

const AurSearchJob = struct {
    installed_only: bool = false,
    result: ?std.json.Parsed([]AurPackage) = null,
    failed: bool = false,
    done: std.atomic.Value(bool) = .init(false),
};

const FlatpakProbeJob = struct {
    failure: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),
};

const FlatpakJob = struct {
    installed_only: bool,
    catalog: ?std.json.Parsed([]flatpak.AppstreamApp) = null,
    installed: ?std.json.Parsed([]flatpak.Flatpak) = null,
    failure: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),
};

const UpdatesJob = struct {
    aur_enabled: bool = false,
    flatpak_enabled: bool = false,
    result: ?std.json.Parsed(CheckUpdates) = null,
    failed: bool = false,
    done: std.atomic.Value(bool) = .init(false),
};

const PkgbuildJob = struct {
    name: []const u8,
    result: ?std.json.Parsed([]PkgBuild) = null,
    failure: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),
};

/// Operation state owned by Model and presented by the reusable panel.
const SudoPrompt = struct {
    /// Package being installed; owned by `gpa`.
    name: []const u8,
    targets: []const []const u8 = &.{},
    review_text: []const u8 = "",
    panel: operation_view.Panel = .{},
    backend: OperationBackend,
    action: shelly_operation.Action = .install,
    elevated: bool = true,
    include_flatpak: bool = true,
    include_aur: bool = true,
    flatpak_target: ?shelly_operation.FlatpakTarget = null,
    password: std.ArrayList(u8),
    state: State = .entering,
    /// Failure detail shown after a failed attempt; owned by `gpa`.
    detail: []const u8 = "",

    progress: shelly_operation.Progress = .{},

    const State = enum { entering, running, succeeded, failed, declined };

    fn operationView(self: *const SudoPrompt) operation_view.View {
        return .{
            .name = self.name,
            .elevated = self.elevated,
            .combined = self.backend == .all,
            .backend = self.backend,
            .include_aur = self.include_aur,
            .include_flatpak = self.include_flatpak,
            .target = self.flatpak_target,
            .review = self.review_text,
            .password_length = Model.codepointCount(self.password.items),
            .action = self.action,
            .detail = self.detail,
            .progress = self.progress,
            .state = switch (self.state) {
                .entering => .entering,
                .running => .running,
                .succeeded => .succeeded,
                .failed => .failed,
                .declined => .declined,
            },
        };
    }

    fn deinit(self: *SudoPrompt, gpa: Allocator) void {
        // Scrub the password before releasing its memory.
        @memset(self.password.items, 0);
        self.password.deinit(gpa);
        gpa.free(self.name);
        for (self.targets) |target| gpa.free(target);
        if (self.targets.len > 0) gpa.free(self.targets);
        if (self.review_text.len > 0) gpa.free(self.review_text);
        if (self.flatpak_target) |target| target.deinit(gpa);
        if (self.detail.len > 0) gpa.free(self.detail);
        gpa.destroy(self);
    }
};

const Overlay = union(enum) {
    package: *const Package,
    aur: *const AurPackage,
    flatpak: flatpak_view.Row,
    flatpak_install: struct { app: *const flatpak.AppstreamApp, selected: usize = 0 },
    sudo: *SudoPrompt,
    pkgbuild,
};

pub const Model = struct {
    gpa: Allocator,

    active: Tab = .packages,
    settings: Settings = .{},
    settings_store: ?settings_service.Store = null,
    settings_failure: ?anyerror = null,
    settings_selected: usize = 0,
    visible_tabs: [5]Tab = undefined,
    flatpak_checked: bool = false,
    flatpak_probe_job: ?*FlatpakProbeJob = null,
    flatpak_probe_thread: ?std.Thread = null,
    flatpak_available: bool = false,
    flatpak_probe_error: ?anyerror = null,
    flatpak_job: ?*FlatpakJob = null,
    flatpak_thread: ?std.Thread = null,
    flatpak_catalog: ?std.json.Parsed([]flatpak.AppstreamApp) = null,
    flatpak_installed: ?std.json.Parsed([]flatpak.Flatpak) = null,
    flatpak_failure: ?anyerror = null,
    flatpak_installed_only: bool = false,
    flatpak_rows: std.ArrayList(flatpak_view.Row) = .empty,
    flatpak_field: vxfw.TextField,
    flatpak_list: vxfw.ListView,
    refresh_flatpak_after_operation: bool = false,

    /// All known packages, borrowed from `parsed`.
    packages: []Package = &.{},
    selected_packages: std.ArrayList([]const u8),
    /// Owns the package data returned by the CLI.
    parsed: ?std.json.Parsed([]Package) = null,

    load: *LoadState,
    load_thread: ?std.Thread = null,
    loading: bool = true,
    load_failed: bool = false,

    /// Packages matching `query`, in display order.
    filtered: std.ArrayList(*const Package),
    /// Owned by `gpa` unless empty.
    query: []const u8 = "",

    /// AUR tab state.
    aur_packages: []const AurPackage = &.{},
    aur_parsed: ?std.json.Parsed([]AurPackage) = null,
    aur_job: ?*AurSearchJob = null,
    /// Last executed AUR query; owned by `gpa` unless empty.
    aur_query: []const u8 = "",
    aur_failed: bool = false,
    installed_only: bool = false,
    aur_installed_only: bool = false,
    aur_thread: ?std.Thread = null,
    aur_filtered: std.ArrayList(*const AurPackage) = .empty,

    /// Modal package details.
    overlay: ?Overlay = null,
    pkgbuild_name: []const u8 = "",
    pkgbuild_job: ?*PkgbuildJob = null,
    pkgbuild_thread: ?std.Thread = null,
    pkgbuild_document: ?pkgbuild_view.Document = null,
    pkgbuild_failure: ?anyerror = null,
    pkgbuild_scroll: vxfw.ScrollView,

    /// The currently running install, if any.
    install_job: ?*shelly_operation.Operation = null,
    operation_question: ?shelly_operation.OwnedMessage = null,
    review_prompt: ?*SudoPrompt = null,
    answer_input: std.ArrayList(u8) = .empty,
    answer_error: []const u8 = "",
    refresh_aur_after_operation: bool = false,
    /// Result of the last finished operation; owned by `gpa` unless empty.
    updates_job: ?*UpdatesJob = null,
    updates_thread: ?std.Thread = null,
    updates_parsed: ?std.json.Parsed(CheckUpdates) = null,
    refresh_after_upgrade: bool = false,
    refresh_updates_after_operation: bool = false,
    updates_checked: bool = false,
    updates_failed: bool = false,
    updates_list: vxfw.ListView,

    notice: []const u8 = "",
    help_open: bool = false,
    help_panel: help_view.Panel = .{},

    selected_list_view: vxfw.ListView,
    package_details_scroll: vxfw.ScrollView,
    package_details_cursor: ?u32 = null,
    package_list_active: bool = false,
    list_view: vxfw.ListView,
    text_field: vxfw.TextField,
    aur_list: vxfw.ListView,
    aur_field: vxfw.TextField,

    pub fn init(gpa: Allocator) !*Model {
        const load = try gpa.create(LoadState);
        errdefer gpa.destroy(load);
        load.* = .{};

        const model = try gpa.create(Model);
        errdefer gpa.destroy(model);

        model.* = .{
            .package_details_scroll = .{ .item_count = 1, .children = .{ .builder = .{
                .userdata = model,
                .buildFn = buildPackageDetails,
            } } },
            .flatpak_field = .{ .buf = .init(gpa), .userdata = model, .onChange = onFlatpakQueryChange },
            .flatpak_list = .{ .children = .{ .builder = .{ .userdata = model, .buildFn = buildFlatpakRow } } },
            .updates_list = .{ .children = .{ .builder = .{
                .userdata = model,
                .buildFn = Model.buildUpdateRow,
            } } },
            .pkgbuild_scroll = .{ .children = .{ .builder = .{
                .userdata = model,
                .buildFn = Model.buildPkgbuildLine,
            } } },
            .gpa = gpa,
            .load = load,
            .filtered = .empty,
            .selected_packages = .empty,
            .list_view = .{
                .children = .{ .builder = .{
                    .userdata = model,
                    .buildFn = Model.buildRow,
                } },
            },
            .text_field = .{
                .buf = .init(gpa),
                .userdata = model,
                .onChange = Model.onQueryChange,
            },
            .aur_list = .{
                .children = .{ .builder = .{
                    .userdata = model,
                    .buildFn = Model.buildAurRow,
                } },
            },
            .aur_field = .{
                .buf = .init(gpa),
                .userdata = model,
                .onSubmit = Model.onAurSubmit,
                .onChange = Model.onAurQueryChange,
            },
            .selected_list_view = .{
                .children = .{ .builder = .{
                    .userdata = model,
                    .buildFn = Model.buildSelectedRow,
                } },
            },
        };
        return model;
    }

    pub fn deinit(self: *Model) void {
        const gpa = self.gpa;
        if (self.settings_store) |store| store.deinit();
        if (self.flatpak_probe_thread) |thread| thread.join();
        if (self.flatpak_probe_job) |job| gpa.destroy(job);
        if (self.flatpak_thread) |thread| thread.join();
        if (self.flatpak_job) |job| {
            if (job.catalog) |*parsed| parsed.deinit();
            if (job.installed) |*parsed| parsed.deinit();
            gpa.destroy(job);
        }
        if (self.flatpak_catalog) |*parsed| parsed.deinit();
        if (self.flatpak_installed) |*parsed| parsed.deinit();
        self.flatpak_rows.deinit(gpa);
        self.flatpak_field.deinit();
        if (self.operation_question) |*question| question.deinit();
        if (self.review_prompt) |prompt| prompt.deinit(gpa);
        self.answer_input.deinit(gpa);
        if (self.pkgbuild_thread) |thread| thread.join();
        if (self.pkgbuild_job) |job| {
            if (job.result) |*result| result.deinit();
            gpa.free(job.name);
            gpa.destroy(job);
        }
        if (self.pkgbuild_document) |*document| document.deinit();
        if (self.pkgbuild_name.len > 0) gpa.free(self.pkgbuild_name);
        if (self.updates_thread) |thread| thread.join();
        if (self.updates_job) |job| {
            if (job.result) |*result| result.deinit();
            gpa.destroy(job);
        }
        if (self.updates_parsed) |*parsed| parsed.deinit();
        if (self.load_thread) |thread| {
            thread.join();
            self.load_thread = null;
        }
        if (self.load.result) |*result| result.deinit();
        gpa.destroy(self.load);
        self.text_field.deinit();
        self.aur_field.deinit();
        self.filtered.deinit(gpa);
        self.selected_packages.deinit(gpa);
        if (self.query.len > 0) gpa.free(self.query);
        if (self.aur_thread) |thread| thread.join();
        if (self.aur_job) |job| {
            if (job.result) |*result| result.deinit();
            gpa.destroy(job);
        }
        self.aur_filtered.deinit(gpa);
        if (self.aur_query.len > 0) gpa.free(self.aur_query);
        if (self.notice.len > 0) gpa.free(self.notice);
        if (self.parsed) |*parsed| parsed.deinit();
        if (self.aur_parsed) |*parsed| parsed.deinit();
        if (self.install_job) |operation| operation.deinit();
        if (self.overlay) |overlay| {
            switch (overlay) {
                .sudo => |prompt| prompt.deinit(gpa),
                else => {},
            }
        }
        gpa.destroy(self);
    }

    pub fn widget(self: *Model) vxfw.Widget {
        return .{
            .userdata = self,
            .captureHandler = typeErasedCaptureHandler,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    // -- events ------------------------------------------------------------

    /// Capture phase runs root-first, before the focused widget sees the
    /// event. This is where we intercept keys that must work even while the
    /// user is typing, and where the modal overlay swallows all input.
    fn typeErasedCaptureHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        const had_operation = self.operationPrompt() != null;
        const had_help = self.help_open;
        try self.captureEvent(ctx, event);
        if (ctx.quit) return;
        if (self.help_open or self.operationPrompt() != null) {
            // The root remains present when a small terminal temporarily
            // replaces browsing with the operation panel.
            try ctx.requestFocus(self.widget());
        } else if (had_operation or had_help) {
            const list_active = self.package_list_active;
            try self.focusActiveTab(ctx);
            self.package_list_active = list_active;
        }
    }

    fn captureEvent(self: *Model, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .key_press => |key| {
                const command = commands.global(key, self.visibleTabs().len);
                if (command) |action| {
                    if (action == .quit) {
                        ctx.quit = true;
                        return ctx.consumeEvent();
                    }
                }
                if (commands.matches(key, .help)) {
                    self.help_open = !self.help_open;
                    return ctx.consumeAndRedraw();
                }
                if (self.help_open) {
                    try self.help_panel.handleKey(ctx, key);
                    return ctx.consumeAndRedraw();
                }
                if (self.overlay) |overlay| {
                    switch (overlay) {
                        .flatpak => |row| {
                            if (commands.detail(key)) |action| {
                                switch (action) {
                                    .close => self.closeOverlay(),
                                    .install => if (row == .catalog and self.install_job == null) {
                                        if (row.catalog.Remotes.len == 0) try self.setNotice("No configured remote is available for this catalog entry.") else self.overlay = .{ .flatpak_install = .{ .app = row.catalog } };
                                    },
                                    .remove => if (row == .installed) try self.openFlatpakPrompt(.remove, row.installed.Id, .{
                                        .scope = row.installed.InstallLevel,
                                        .remote = row.installed.Remote,
                                        .arch = row.installed.Arch,
                                        .branch = row.installed.Branch,
                                        .kind = row.installed.Kind,
                                        .reference = row.installed.FullRef,
                                    }),
                                    .preview => {},
                                }
                            }
                            return ctx.consumeAndRedraw();
                        },
                        .flatpak_install => |choice| {
                            if (commands.choice(key)) |action| switch (action) {
                                .close => self.overlay = .{ .flatpak = .{ .catalog = choice.app } },
                                .previous => self.overlay.?.flatpak_install.selected = if (choice.selected == 0) choice.app.Remotes.len - 1 else choice.selected - 1,
                                .next => self.overlay.?.flatpak_install.selected = (choice.selected + 1) % choice.app.Remotes.len,
                                .confirm => {
                                    const remote = choice.app.Remotes[choice.selected];
                                    try self.openFlatpakPrompt(.install, choice.app.Id, .{
                                        .scope = remote.Scope,
                                        .remote = remote.Name,
                                        .kind = if (std.mem.eql(u8, choice.app.Type, "runtime")) .runtime else .app,
                                    });
                                },
                            };
                            return ctx.consumeAndRedraw();
                        },
                        .package, .aur => {
                            if (overlay == .package and commands.leavesPackageDetails(key)) {
                                self.closeOverlay();
                                self.package_list_active = true;
                                return ctx.consumeAndRedraw();
                            }
                            if (commands.detail(key)) |action| {
                                switch (action) {
                                    .close => self.closeOverlay(),
                                    .install => try self.operationFromOverlay(.install),
                                    .remove => try self.operationFromOverlay(.remove),
                                    .preview => if (overlay == .aur) try self.openPkgbuild(ctx, overlay.aur.Name),
                                }
                                return ctx.consumeAndRedraw();
                            }
                            if (overlay == .package) {
                                if (command) |action| {
                                    self.closeOverlay();
                                    switch (action) {
                                        .quit => unreachable,
                                        .next_tab, .previous_tab => self.switchTab(if (action == .next_tab) 1 else -1),
                                        .select_tab => |index| try self.setTab(self.visibleTabs()[index], ctx),
                                    }
                                    try self.focusActiveTab(ctx);
                                    try self.ensureUpdates(ctx);
                                    try self.ensureFlatpak(ctx);
                                } else try self.package_details_scroll.handleEvent(ctx, .{ .key_press = commands.scrollKey(key) orelse key });
                                return ctx.consumeAndRedraw();
                            }
                            return ctx.consumeEvent();
                        },
                        .sudo => |prompt| {
                            return self.handleSudoKey(prompt, ctx, key);
                        },
                        .pkgbuild => {
                            const view = self.pkgbuildView();
                            if (view.handleKey(key)) |action| {
                                switch (action) {
                                    .close => self.closePkgbuild(),
                                    .retry => if (self.pkgbuild_job == null) try self.openPkgbuild(ctx, self.pkgbuild_name),
                                    .approve => try self.answerOperationQuestion(true),
                                    .decline => try self.answerOperationQuestion(false),
                                }
                                return ctx.consumeAndRedraw();
                            }
                            if (self.operation_question) |question| {
                                if (question.value.question == .select_one or question.value.question == .select_many) {
                                    if (key.matches(vaxis.Key.backspace, .{})) {
                                        popGrapheme(&self.answer_input);
                                        self.answer_error = "";
                                    } else if (key.text) |text| {
                                        for (text) |byte| {
                                            if ((std.ascii.isDigit(byte) or byte == ',' or byte == ' ') and self.answer_input.items.len < 1024)
                                                try self.answer_input.append(self.gpa, byte);
                                        }
                                        self.answer_error = "";
                                    }
                                }
                            }
                            if (self.pkgbuild_document != null and self.pkgbuild_job == null)
                                try self.pkgbuild_scroll.handleEvent(ctx, .{ .key_press = commands.scrollKey(key) orelse key });
                            return ctx.consumeAndRedraw();
                        },
                    }
                }
                if (self.active != .packages and self.active != .settings and
                    (commands.matches(key, .previous) or commands.matches(key, .next)))
                {
                    const canonical: vxfw.Event = .{ .key_press = .{ .codepoint = if (commands.matches(key, .previous)) vaxis.Key.up else vaxis.Key.down } };
                    switch (self.active) {
                        .aur => try self.aur_list.handleEvent(ctx, canonical),
                        .flatpak => try self.flatpak_list.handleEvent(ctx, canonical),
                        .upgrade => try self.updates_list.handleEvent(ctx, canonical),
                        else => unreachable,
                    }
                    return ctx.consumeAndRedraw();
                }
                if (self.active == .aur and commands.matches(key, .confirm)) {
                    const query = try self.aur_field.buf.dupe();
                    defer self.gpa.free(query);
                    try onAurSubmit(self, ctx, query);
                    return ctx.consumeAndRedraw();
                }
                if (self.active == .flatpak and commands.matches(key, .confirm)) {
                    if (self.flatpak_job == null and self.flatpak_failure == null and self.flatpak_list.cursor < self.flatpak_rows.items.len)
                        self.overlay = .{ .flatpak = self.flatpak_rows.items[self.flatpak_list.cursor] };
                    return ctx.consumeAndRedraw();
                }
                if (self.active == .settings) {
                    if (commands.settings(key)) |action| {
                        switch (action) {
                            .previous, .next => self.settings_selected = 1 - self.settings_selected,
                            .toggle => if (self.install_job == null) try self.toggleSetting(ctx),
                            .reload => if (self.install_job == null) try self.reloadSettings(ctx),
                        }
                        return ctx.consumeAndRedraw();
                    }
                }
                if (self.active == .packages and command == null) {
                    if (self.package_list_active) {
                        if (commands.packageAction(key)) |action| {
                            try self.openNativePrompt(if (action == .install) .install else .remove);
                            return ctx.consumeAndRedraw();
                        }
                    }
                    if (commands.packageNavigation(key, !self.package_list_active)) |action| {
                        switch (action) {
                            .previous, .next => {
                                if (action == .previous and self.package_list_active and self.list_view.cursor == 0) {
                                    self.package_list_active = false;
                                } else {
                                    self.package_list_active = true;
                                    try self.list_view.handleEvent(ctx, .{ .key_press = .{ .codepoint = if (action == .previous) vaxis.Key.up else vaxis.Key.down } });
                                }
                            },
                            .details => if (self.selectedPackage()) |pkg| {
                                self.overlay = .{ .package = pkg };
                            },
                            .search => self.package_list_active = false,
                            .select => {
                                self.package_list_active = true;
                                if (self.selectedPackage() != null) try self.toggleSelectedList();
                            },
                        }
                        return ctx.consumeAndRedraw();
                    }
                }
                if (self.active == .flatpak) {
                    if (commands.togglesInstalled(key)) {
                        if (self.flatpak_job == null) {
                            self.flatpak_installed_only = !self.flatpak_installed_only;
                            self.flatpak_rows.clearRetainingCapacity();
                            self.flatpak_list.item_count = 0;
                            self.flatpak_list.jumpToItem(0);
                            try self.startFlatpak(ctx);
                        }
                        return ctx.consumeAndRedraw();
                    }
                    if (commands.refreshesList(key)) {
                        if (!self.flatpak_available or self.flatpak_failure != null) try self.startFlatpakProbe(ctx) else try self.startFlatpak(ctx);
                        return ctx.consumeAndRedraw();
                    }
                }
                if (self.active == .aur and self.aur_installed_only and commands.refreshesList(key)) {
                    if (self.aur_job == null) try self.startAurSearch(ctx, "");
                    return ctx.consumeAndRedraw();
                }
                if (commands.togglesInstalled(key) and (self.active == .packages or self.active == .aur)) {
                    if (self.active == .packages) {
                        self.installed_only = !self.installed_only;
                        try self.rebuildFilter();
                    } else if (self.aur_job == null) {
                        self.aur_installed_only = !self.aur_installed_only;
                        try self.startAurSearch(ctx, "");
                        self.aur_filtered.clearRetainingCapacity();
                        self.aur_list.item_count = 0;
                        self.aur_list.jumpToItem(0);
                    }
                    return ctx.consumeAndRedraw();
                }
                if (self.active == .upgrade) {
                    if (self.updatesView().handleKey(key)) |action| {
                        switch (action) {
                            .refresh => try self.startUpdates(ctx),
                            .upgrade_all => try self.upgradeFromUpdates(.all),
                            .upgrade_system => try self.upgradeSystemFromUpdates(),
                            .upgrade_aur => try self.upgradeFromUpdates(.aur),
                            .upgrade_flatpak => try self.upgradeFromUpdates(.flatpak),
                        }
                        return ctx.consumeAndRedraw();
                    }
                }
                if (self.active == .packages and self.package_list_active and commands.matches(key, .mark)) {
                    if (self.list_view.cursor < self.filtered.items.len) try self.toggleSelectedList();
                    return ctx.consumeAndRedraw();
                }
                // Search editing is explicit while browsing: Up at the first
                // package or / returns to the text field.
                if (self.active == .packages and self.package_list_active and command == null)
                    return ctx.consumeEvent();

                if (command) |action| {
                    switch (action) {
                        .quit => unreachable,
                        .next_tab, .previous_tab => {
                            self.switchTab(if (action == .next_tab) 1 else -1);
                            try self.focusActiveTab(ctx);
                            try self.ensureUpdates(ctx);
                            try self.ensureFlatpak(ctx);
                        },
                        .select_tab => |index| try self.setTab(self.visibleTabs()[index], ctx),
                    }
                    return ctx.consumeAndRedraw();
                }
            },
            .mouse => if (self.help_open) {
                try self.help_panel.scroll.handleEvent(ctx, event);
                return ctx.consumeAndRedraw();
            },
            else => {},
        }
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => {
                try self.startLoad(ctx);
                if (self.settings.flatpak_enabled) try self.startFlatpakProbe(ctx);
                ctx.redraw = true;
                return self.focusActiveTab(ctx);
            },
            .focus_in => {
                return self.focusActiveTab(ctx);
            },
            .tick => {
                const loading = try self.pollLoad();
                try self.pollFlatpakProbe(ctx);
                const searching = try self.pollAurSearch();
                const installing = try self.pollInstall();
                self.pollUpdates();
                try self.ensureUpdates(ctx);
                try self.pollFlatpak();
                try self.pollPkgbuild(ctx);
                if (self.refresh_after_upgrade and !self.loading) {
                    try self.reloadPackages(ctx);
                    self.refresh_after_upgrade = false;
                }
                if (self.refresh_flatpak_after_operation and self.flatpak_job == null) {
                    if (self.flatpak_installed_only) {
                        if (self.flatpak_catalog) |*parsed| parsed.deinit();
                        self.flatpak_catalog = null;
                    } else {
                        if (self.flatpak_installed) |*parsed| parsed.deinit();
                        self.flatpak_installed = null;
                    }
                    try self.startFlatpak(ctx);
                    self.refresh_flatpak_after_operation = false;
                }
                if (self.refresh_updates_after_operation and self.updates_job == null) {
                    try self.startUpdates(ctx);
                    self.refresh_updates_after_operation = false;
                }
                if (self.refresh_aur_after_operation and self.aur_job == null) {
                    if (self.aur_installed_only or self.aur_query.len > 0) try self.startAurSearch(ctx, self.aur_query);
                    self.refresh_aur_after_operation = false;
                }
                if (loading or searching or installing or self.loading or self.updates_job != null or self.pkgbuild_job != null or self.aur_job != null or self.flatpak_job != null or self.flatpak_probe_job != null) {
                    try ctx.tick(100, self.widget());
                }
                return ctx.consumeAndRedraw();
            },
            .key_press => |key| {
                // Enter opens the details of the selected package. On the
                // AUR tab Enter is consumed by the search field instead.
                if (commands.matches(key, .confirm) or (self.active == .packages and commands.matches(key, .select))) {
                    if (self.active == .flatpak and self.flatpak_job == null and self.flatpak_failure == null and self.flatpak_list.cursor < self.flatpak_rows.items.len) {
                        self.overlay = .{ .flatpak = self.flatpak_rows.items[self.flatpak_list.cursor] };
                        return ctx.consumeAndRedraw();
                    }
                    if (self.active == .packages and commands.matches(key, .select) and
                        self.filtered.items.len > 0 and
                        @as(usize, self.list_view.cursor) < self.filtered.items.len)
                    {
                        self.package_list_active = true;
                        try self.toggleSelectedList();
                        return ctx.consumeAndRedraw();
                    }
                }
                // Let the active list handle whatever the search field
                // ignored (arrow keys, mouse wheel, ...)
                return switch (self.active) {
                    .packages => {
                        const previous = self.list_view.cursor;
                        try self.list_view.handleEvent(ctx, event);
                        if (previous != self.list_view.cursor) self.package_details_scroll.scroll = .{};
                    },
                    .aur => self.aur_list.handleEvent(ctx, event),
                    .upgrade => self.updates_list.handleEvent(ctx, event),
                    .flatpak => self.flatpak_list.handleEvent(ctx, event),
                    .settings => {},
                };
            },
            .mouse => {
                if (self.overlay) |overlay| {
                    if (overlay == .pkgbuild and self.pkgbuild_document != null and self.pkgbuild_job == null)
                        return self.pkgbuild_scroll.handleEvent(ctx, event);
                }
                if (self.active == .upgrade and self.overlay == null)
                    return self.updates_list.handleEvent(ctx, event);
            },
            else => {},
        }
    }

    /// Read the small preference file before the first frame, never CLI/catalog data.
    pub fn loadSettings(self: *Model, io: std.Io, env: *const std.process.Environ.Map) void {
        self.settings_store = settings_service.Store.init(self.gpa, env) catch |err| {
            self.settings_failure = err;
            self.setNotice("Could not load TUI settings; using system-only defaults. Open Settings for details.") catch {};
            return;
        };
        const saved = self.settings_store.?.load(io) catch |err| {
            self.settings_failure = err;
            self.setNotice("Could not load TUI settings; using system-only defaults. Open Settings for details.") catch {};
            return;
        };
        self.applySettings(saved);
    }

    fn applySettings(self: *Model, saved: Settings) void {
        if (self.settings.aur_enabled != saved.aur_enabled) {
            if (self.overlay) |overlay| {
                if (overlay == .aur) self.closeOverlay();
            }
            self.aur_filtered.clearRetainingCapacity();
            self.aur_packages = &.{};
            if (self.aur_parsed) |*parsed| parsed.deinit();
            self.aur_parsed = null;
            self.aur_list.item_count = 0;
            self.aur_list.jumpToItem(0);
        }
        if (self.settings.flatpak_enabled != saved.flatpak_enabled) {
            if (self.overlay) |overlay| {
                if (overlay == .flatpak or overlay == .flatpak_install) self.closeOverlay();
            }
            self.flatpak_rows.clearRetainingCapacity();
            if (self.flatpak_catalog) |*parsed| parsed.deinit();
            if (self.flatpak_installed) |*parsed| parsed.deinit();
            self.flatpak_catalog = null;
            self.flatpak_installed = null;
            self.flatpak_list.item_count = 0;
            self.flatpak_list.jumpToItem(0);
            self.flatpak_checked = false;
            self.flatpak_available = false;
            self.flatpak_probe_error = null;
        }
        self.settings = saved;
        self.settings_failure = null;
        self.updates_checked = false;
        if (self.updates_parsed) |*parsed| {
            if (!saved.aur_enabled) parsed.value.Aur = &.{};
            if (!saved.flatpak_enabled) parsed.value.Flatpak = &.{};
            self.updates_list.item_count = @intCast(parsed.value.count());
            self.updates_list.jumpToItem(0);
        }
        if (!self.tabEnabled(self.active)) {
            self.closeOverlay();
            self.active = .packages;
        }
    }

    fn toggleSetting(self: *Model, ctx: *vxfw.EventContext) !void {
        const store = self.settings_store orelse {
            self.settings_failure = error.SettingsNotInitialized;
            return;
        };
        var saved = self.settings;
        if (self.settings_selected == 0) saved.aur_enabled = !saved.aur_enabled else saved.flatpak_enabled = !saved.flatpak_enabled;
        store.save(runtime.io, saved) catch |err| {
            self.settings_failure = err;
            return;
        };
        self.applySettings(saved);
        if (saved.flatpak_enabled and !self.flatpak_checked) try self.startFlatpakProbe(ctx);
        try self.focusActiveTab(ctx);
    }

    fn reloadSettings(self: *Model, ctx: *vxfw.EventContext) !void {
        const store = self.settings_store orelse return;
        const saved = store.load(runtime.io) catch |err| {
            self.settings_failure = err;
            return;
        };
        self.applySettings(saved);
        if (saved.flatpak_enabled and !self.flatpak_checked) try self.startFlatpakProbe(ctx);
        try self.focusActiveTab(ctx);
    }

    fn settingsView(self: *Model) settings_view.View {
        return .{ .settings = self.settings, .selected = self.settings_selected, .path = if (self.settings_store) |store| store.path else "Settings could not be initialized", .failure = self.settings_failure, .flatpak_checked = self.flatpak_checked, .flatpak_available = self.flatpak_available, .checking = self.flatpak_probe_job != null, .busy = self.install_job != null };
    }

    fn startFlatpakProbe(self: *Model, ctx: *vxfw.EventContext) !void {
        if (!self.settings.flatpak_enabled or self.flatpak_probe_job != null) return;
        try ctx.tick(100, self.widget());
        const job = try self.gpa.create(FlatpakProbeJob);
        errdefer self.gpa.destroy(job);
        job.* = .{};
        const thread = try std.Thread.spawn(.{}, flatpakProbeThread, .{job});
        self.flatpak_probe_job = job;
        self.flatpak_probe_thread = thread;
        self.flatpak_probe_error = null;
        self.flatpak_failure = null;
    }

    fn flatpakProbeThread(job: *FlatpakProbeJob) void {
        defer job.done.store(true, .release);
        var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        const cli: ShellyCli = .{ .allocator = std.heap.page_allocator, .io = threaded.io() };
        cli.probe_flatpak() catch |err| {
            job.failure = err;
        };
    }

    fn pollFlatpakProbe(self: *Model, ctx: *vxfw.EventContext) !void {
        const job = self.flatpak_probe_job orelse return;
        if (!job.done.load(.acquire)) return;
        if (self.flatpak_probe_thread) |thread| thread.join();
        self.flatpak_probe_thread = null;
        self.flatpak_probe_job = null;
        self.flatpak_checked = true;
        self.flatpak_probe_error = job.failure;
        self.flatpak_available = job.failure == null;
        self.gpa.destroy(job);
        if (self.settings.flatpak_enabled) {
            self.updates_checked = false;
            if (self.flatpak_available and self.active == .flatpak) try self.startFlatpak(ctx);
        }
    }

    // -- tabs --------------------------------------------------------------

    fn tabEnabled(self: *const Model, tab: Tab) bool {
        return switch (tab) {
            .aur => self.settings.aur_enabled,
            .flatpak => self.settings.flatpak_enabled,
            else => true,
        };
    }

    fn visibleTabs(self: *Model) []const Tab {
        var count: usize = 0;
        for (Tab.all) |tab| {
            if (!self.tabEnabled(tab)) continue;
            self.visible_tabs[count] = tab;
            count += 1;
        }
        return self.visible_tabs[0..count];
    }

    fn switchTab(self: *Model, delta: i32) void {
        const tabs = self.visibleTabs();
        const count: i32 = @intCast(tabs.len);
        const current: i32 = for (tabs, 0..) |tab, index| {
            if (tab == self.active) break @intCast(index);
        } else unreachable;
        var next = @rem(current + delta, count);
        if (next < 0) next += count;
        self.active = tabs[@intCast(next)];
    }

    fn setTab(self: *Model, tab: Tab, ctx: *vxfw.EventContext) !void {
        if (!self.tabEnabled(tab)) return;
        if (tab == self.active) return;
        self.active = tab;
        try self.focusActiveTab(ctx);
        try self.ensureUpdates(ctx);
        try self.ensureFlatpak(ctx);
    }

    fn focusActiveTab(self: *Model, ctx: *vxfw.EventContext) !void {
        if (self.help_open or self.operationPrompt() != null) return ctx.requestFocus(self.widget());
        self.package_list_active = false;
        switch (self.active) {
            .packages => try ctx.requestFocus(self.text_field.widget()),
            .aur => try ctx.requestFocus(self.aur_field.widget()),
            .upgrade, .settings => try ctx.requestFocus(self.widget()),
            .flatpak => try ctx.requestFocus(self.flatpak_field.widget()),
        }
    }

    fn ensureFlatpak(self: *Model, ctx: *vxfw.EventContext) !void {
        if (self.active != .flatpak or !self.settings.flatpak_enabled) return;
        if (!self.flatpak_checked and self.flatpak_probe_job == null) try self.startFlatpakProbe(ctx);
        if (!self.flatpak_available or self.flatpak_job != null or self.flatpak_failure != null) return;
        if (if (self.flatpak_installed_only) self.flatpak_installed == null else self.flatpak_catalog == null)
            try self.startFlatpak(ctx);
    }

    fn startFlatpak(self: *Model, ctx: *vxfw.EventContext) !void {
        if (!self.settings.flatpak_enabled or !self.flatpak_available or self.flatpak_job != null) return;
        try ctx.tick(100, self.widget());
        const job = try self.gpa.create(FlatpakJob);
        errdefer self.gpa.destroy(job);
        job.* = .{ .installed_only = self.flatpak_installed_only };
        const thread = try std.Thread.spawn(.{}, flatpakThread, .{job});
        self.flatpak_job = job;
        self.flatpak_thread = thread;
        self.flatpak_failure = null;
    }

    fn flatpakThread(job: *FlatpakJob) void {
        defer job.done.store(true, .release);
        var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        const cli: ShellyCli = .{ .allocator = std.heap.page_allocator, .io = threaded.io() };
        if (job.installed_only) {
            job.installed = cli.get_installed_flatpaks() catch |err| {
                job.failure = err;
                return;
            };
        } else {
            job.catalog = cli.get_remote_appstream_apps() catch |err| {
                job.failure = err;
                return;
            };
        }
    }

    fn pollFlatpak(self: *Model) !void {
        const job = self.flatpak_job orelse return;
        if (!job.done.load(.acquire)) return;
        if (self.flatpak_thread) |thread| thread.join();
        self.flatpak_thread = null;
        self.flatpak_job = null;
        defer self.gpa.destroy(job);
        var old_catalog = self.flatpak_catalog;
        var old_installed = self.flatpak_installed;
        defer if (!job.installed_only) {
            if (old_catalog) |*parsed| parsed.deinit();
        };
        defer if (job.installed_only) {
            if (old_installed) |*parsed| parsed.deinit();
        };
        if (self.overlay) |overlay| {
            if (overlay == .flatpak or overlay == .flatpak_install) self.overlay = null;
        }
        self.flatpak_failure = job.failure;
        if (job.installed_only) self.flatpak_installed = job.installed else self.flatpak_catalog = job.catalog;
        try self.rebuildFlatpakFilter();
    }

    fn onFlatpakQueryChange(ptr: ?*anyopaque, _: *vxfw.EventContext, _: []const u8) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr orelse return));
        try self.rebuildFlatpakFilter();
    }

    fn rebuildFlatpakFilter(self: *Model) Allocator.Error!void {
        const selected: ?flatpak_view.Row = if (self.flatpak_list.cursor < self.flatpak_rows.items.len) self.flatpak_rows.items[self.flatpak_list.cursor] else null;
        self.flatpak_rows.clearRetainingCapacity();
        const query = try self.flatpak_field.buf.dupe();
        defer self.gpa.free(query);
        if (self.flatpak_failure == null) {
            if (self.flatpak_installed_only) {
                if (self.flatpak_installed) |parsed| for (parsed.value) |*app| {
                    const row: flatpak_view.Row = .{ .installed = app };
                    if (row.matches(query)) try self.flatpak_rows.append(self.gpa, row);
                };
            } else {
                if (self.flatpak_catalog) |parsed| for (parsed.value) |*app| {
                    const row: flatpak_view.Row = .{ .catalog = app };
                    if (row.matches(query)) try self.flatpak_rows.append(self.gpa, row);
                };
            }
        }
        self.flatpak_list.item_count = @intCast(self.flatpak_rows.items.len);
        self.flatpak_list.jumpToItem(0);
        if (selected) |previous| for (self.flatpak_rows.items, 0..) |row, index| {
            if (row.sameIdentity(previous)) {
                self.flatpak_list.jumpToItem(@intCast(index));
                break;
            }
        };
    }

    fn buildFlatpakRow(ptr: *const anyopaque, index: usize, _: usize) ?vxfw.Widget {
        const self: *const Model = @ptrCast(@alignCast(ptr));
        if (index >= self.flatpak_rows.items.len) return null;
        return self.flatpak_rows.items[index].widget();
    }

    fn flatpakView(self: *Model) flatpak_view.View {
        return .{ .field = &self.flatpak_field, .list = &self.flatpak_list, .installed_only = self.flatpak_installed_only, .loading = self.flatpak_job != null, .checking_backend = self.flatpak_probe_job != null, .backend_failure = self.flatpak_probe_error, .failure = self.flatpak_failure, .checked = if (self.flatpak_installed_only) self.flatpak_installed != null else self.flatpak_catalog != null, .count = self.flatpak_rows.items.len };
    }

    // -- background jobs ---------------------------------------------------

    fn openPkgbuild(self: *Model, ctx: *vxfw.EventContext, name: []const u8) !void {
        // Duplicate before releasing the old name, including retry of the same target.
        const owned = try self.gpa.dupe(u8, name);
        if (self.pkgbuild_name.len > 0) self.gpa.free(self.pkgbuild_name);
        self.pkgbuild_name = owned;
        if (self.pkgbuild_document) |*document| document.deinit();
        self.pkgbuild_document = null;
        self.pkgbuild_failure = null;
        self.pkgbuild_scroll.scroll = .{};
        self.pkgbuild_scroll.cursor = 0;
        self.pkgbuild_scroll.item_count = 0;
        self.overlay = .pkgbuild;
        if (self.pkgbuild_job == null) self.startPkgbuild(ctx) catch |err| {
            self.pkgbuild_failure = err;
        };
    }

    fn startPkgbuild(self: *Model, ctx: *vxfw.EventContext) !void {
        try ctx.tick(100, self.widget());
        const job = try self.gpa.create(PkgbuildJob);
        errdefer self.gpa.destroy(job);
        job.* = .{ .name = try self.gpa.dupe(u8, self.pkgbuild_name) };
        errdefer self.gpa.free(job.name);
        const thread = try std.Thread.spawn(.{}, fetchPkgbuildThread, .{job});
        self.pkgbuild_thread = thread;
        self.pkgbuild_job = job;
    }

    fn fetchPkgbuildThread(job: *PkgbuildJob) void {
        var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        const cli: ShellyCli = .{ .allocator = std.heap.page_allocator, .io = threaded.io() };
        job.result = cli.fetch_pkgbuild(job.name) catch |err| {
            job.failure = err;
            job.done.store(true, .release);
            return;
        };
        job.done.store(true, .release);
    }

    fn pollPkgbuild(self: *Model, ctx: *vxfw.EventContext) !void {
        const job = self.pkgbuild_job orelse return;
        if (!job.done.load(.acquire)) return;
        self.pkgbuild_thread.?.join();
        self.pkgbuild_thread = null;
        self.pkgbuild_job = null;
        defer {
            if (job.result) |*result| result.deinit();
            self.gpa.free(job.name);
            self.gpa.destroy(job);
        }
        if (self.operation_question != null) return;
        if (!std.mem.eql(u8, job.name, self.pkgbuild_name)) {
            // The user selected a different package while this request was running.
            if (self.overlay != null and self.overlay.? == .pkgbuild)
                self.startPkgbuild(ctx) catch |err| {
                    self.pkgbuild_failure = err;
                };
            return;
        }
        self.pkgbuild_failure = job.failure;
        if (job.result) |result| {
            self.pkgbuild_document = pkgbuild_view.Document.init(self.gpa, result.value) catch |err| {
                self.pkgbuild_failure = err;
                return;
            };
            self.pkgbuild_scroll.item_count = @intCast(self.pkgbuild_document.?.lines.len);
        }
    }

    fn closePkgbuild(self: *Model) void {
        self.overlay = null;
        for (self.aur_packages) |*pkg| {
            if (std.mem.eql(u8, pkg.Name, self.pkgbuild_name)) {
                self.overlay = .{ .aur = pkg };
                break;
            }
        }
    }

    fn pkgbuildView(self: *Model) pkgbuild_view.View {
        return .{
            .name = self.pkgbuild_name,
            .scroll = &self.pkgbuild_scroll,
            .loading = self.pkgbuild_job != null,
            .failure = self.pkgbuild_failure,
            .review = self.operation_question != null,
            .choices = if (self.operation_question) |message|
                message.value.question == .select_one or message.value.question == .select_many
            else
                false,
            .answer_input = self.answer_input.items,
            .answer_error = self.answer_error,
        };
    }

    fn buildPkgbuildLine(ptr: *const anyopaque, index: usize, _: usize) ?vxfw.Widget {
        const self: *const Model = @ptrCast(@alignCast(ptr));
        if (self.pkgbuild_document) |*document| return pkgbuild_view.row(document, index);
        return null;
    }

    fn ensureUpdates(self: *Model, ctx: *vxfw.EventContext) !void {
        if (self.active == .upgrade and !self.updates_checked and self.updates_job == null)
            try self.startUpdates(ctx);
    }

    fn startUpdates(self: *Model, ctx: *vxfw.EventContext) !void {
        if (self.updates_job != null or self.install_job != null) return;
        try ctx.tick(100, self.widget());
        const job = try self.gpa.create(UpdatesJob);
        errdefer self.gpa.destroy(job);
        job.* = .{ .aur_enabled = self.settings.aur_enabled, .flatpak_enabled = self.settings.flatpak_enabled and self.flatpak_available };
        const thread = try std.Thread.spawn(.{}, checkUpdatesThread, .{job});
        self.updates_thread = thread;
        self.updates_job = job;
        self.updates_checked = true;
        self.updates_failed = false;
    }

    fn checkUpdatesThread(job: *UpdatesJob) void {
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

    fn pollUpdates(self: *Model) void {
        const job = self.updates_job orelse return;
        if (!job.done.load(.acquire)) return;
        self.updates_thread.?.join();
        self.updates_thread = null;
        self.updates_job = null;
        defer self.gpa.destroy(job);
        if (job.aur_enabled != self.settings.aur_enabled or job.flatpak_enabled != (self.settings.flatpak_enabled and self.flatpak_available)) {
            if (job.result) |*parsed| parsed.deinit();
            self.updates_checked = false;
            return;
        }
        self.updates_failed = job.failed;
        if (job.result) |parsed| {
            if (self.updates_parsed) |*old| old.deinit();
            self.updates_parsed = parsed;
            self.updates_list.item_count = @intCast(parsed.value.count());
            self.updates_list.jumpToItem(0);
        }
    }

    fn updatesView(self: *Model) updates_view.View {
        return .{
            .list = &self.updates_list,
            .data = if (self.updates_parsed) |*parsed| &parsed.value else null,
            .loading = self.updates_job != null,
            .failed = self.updates_failed,
            .checked = self.updates_checked,
            .aur_enabled = self.settings.aur_enabled,
            .flatpak_available = self.settings.flatpak_enabled and self.flatpak_available,
        };
    }

    fn buildUpdateRow(ptr: *const anyopaque, index: usize, _: usize) ?vxfw.Widget {
        const self: *const Model = @ptrCast(@alignCast(ptr));
        const parsed = self.updates_parsed orelse return null;
        return updates_view.row(&parsed.value, index);
    }

    fn upgradeSystemFromUpdates(self: *Model) !void {
        return self.upgradeFromUpdates(.standard);
    }

    fn upgradeFromUpdates(self: *Model, backend: OperationBackend) !void {
        if (self.install_job != null or self.overlay != null) return;
        if (backend == .all and !self.updatesView().canUpgradeAll()) return;
        if (backend == .standard and !self.updatesView().canUpgrade()) return;
        if (backend == .aur and !self.updatesView().canUpgradeAur()) return;
        if (backend == .flatpak) {
            if (self.updatesView().canUpgradeFlatpak()) try self.openFlatpakPrompt(.upgrade, "Flatpak applications and runtimes (system + user)", null);
            return;
        }
        const prompt = try self.gpa.create(SudoPrompt);
        errdefer self.gpa.destroy(prompt);
        prompt.* = .{
            .name = try self.gpa.dupe(u8, if (backend == .all) "all enabled package sources" else if (backend == .aur) "AUR packages" else "system packages"),
            .backend = backend,
            .action = .upgrade,
            .include_flatpak = self.settings.flatpak_enabled and self.flatpak_available,
            .include_aur = self.settings.aur_enabled,
            .password = .empty,
        };
        self.overlay = .{ .sudo = prompt };
    }

    fn reloadPackages(self: *Model, ctx: *vxfw.EventContext) !void {
        if (self.load_thread) |thread| thread.join();
        self.load_thread = null;
        self.load.* = .{};
        try self.startLoad(ctx);
        self.loading = true;
        self.load_failed = false;
    }

    fn startLoad(self: *Model, ctx: *vxfw.EventContext) !void {
        self.load_thread = try std.Thread.spawn(.{}, loadPackages, .{self.load});
        try ctx.tick(100, self.widget());
    }

    fn loadPackages(load: *LoadState) void {
        // Workers run their own threaded IO and use the page allocator so
        // they never share state with the UI thread.
        const alloc = std.heap.page_allocator;
        var threaded: std.Io.Threaded = .init(alloc, .{});
        defer threaded.deinit();

        const cli: ShellyCli = .{ .allocator = alloc, .io = threaded.io() };
        const parsed = cli.get_packages(false) catch {
            load.failed = true;
            load.done.store(true, .release);
            return;
        };
        const installed = cli.get_installed_packages() catch {
            parsed.deinit();
            load.failed = true;
            load.done.store(true, .release);
            return;
        };
        defer installed.deinit();
        for (installed.value) |pkg| {
            for (parsed.value) |*p_pkg| {
                if (std.ascii.eqlIgnoreCase(p_pkg.Name, pkg.Name)) p_pkg.Installed = true;
            }
        }
        load.result = parsed;
        load.done.store(true, .release);
    }

    fn pollLoad(self: *Model) !bool {
        if (!self.loading) return false;
        if (!self.load.done.load(.acquire)) return true;

        const failed = self.load.failed;
        const parsed = self.load.result;
        self.load.result = null;
        self.loading = false;
        self.load_failed = failed;
        if (parsed) |p| {
            var old = self.parsed;
            defer if (old) |*owner| owner.deinit();
            const selected = if (self.list_view.cursor < self.filtered.items.len)
                self.filtered.items[self.list_view.cursor]
            else
                null;
            if (self.overlay) |overlay| {
                if (overlay == .package) self.overlay = null;
            }
            var previous_selection = self.selected_packages;
            defer previous_selection.deinit(self.gpa);
            self.selected_packages = .empty;
            self.parsed = p;
            self.packages = p.value;
            for (previous_selection.items) |name| {
                for (self.packages) |pkg| {
                    if (std.mem.eql(u8, pkg.Name, name)) {
                        try self.selected_packages.append(self.gpa, pkg.Name);
                        break;
                    }
                }
            }
            self.selected_list_view.item_count = @intCast(self.selected_packages.items.len);
            try self.rebuildFilter();
            if (selected) |previous| {
                for (self.filtered.items, 0..) |pkg, index| {
                    if (std.mem.eql(u8, pkg.Name, previous.Name) and
                        std.mem.eql(u8, pkg.Repository, previous.Repository))
                    {
                        self.list_view.jumpToItem(@intCast(index));
                        break;
                    }
                }
            }
        } else {
            try self.rebuildFilter();
        }
        return false;
    }

    fn onAurSubmit(maybe_ptr: ?*anyopaque, ctx: *vxfw.EventContext, str: []const u8) anyerror!void {
        const ptr = maybe_ptr orelse return;
        const self: *Model = @ptrCast(@alignCast(ptr));
        if (!self.settings.aur_enabled) return;
        const query = std.mem.trim(u8, str, " \t");

        if (self.aur_job != null) return;
        if (self.aur_installed_only) {
            if (self.aur_list.cursor < self.aur_filtered.items.len)
                self.overlay = .{ .aur = self.aur_filtered.items[self.aur_list.cursor] };
            return ctx.consumeAndRedraw();
        }
        // Enter with an unchanged query opens the selected result instead
        // of repeating the search
        if (self.aur_filtered.items.len > 0 and
            (query.len == 0 or std.mem.eql(u8, query, self.aur_query)))
        {
            if (@as(usize, self.aur_list.cursor) < self.aur_filtered.items.len) {
                self.overlay = .{ .aur = self.aur_filtered.items[self.aur_list.cursor] };
                return ctx.consumeAndRedraw();
            }
            return;
        }
        if (query.len == 0) return;
        if (self.aur_job != null) return; // search in flight
        try self.startAurSearch(ctx, query);
    }

    fn startAurSearch(self: *Model, ctx: *vxfw.EventContext, query: []const u8) !void {
        if (!self.settings.aur_enabled) return;
        try ctx.tick(100, self.widget());
        const job = try self.gpa.create(AurSearchJob);
        errdefer self.gpa.destroy(job);
        job.* = .{ .installed_only = self.aur_installed_only };

        const duped = try self.gpa.dupe(u8, query);
        errdefer self.gpa.free(duped);
        const thread = try std.Thread.spawn(.{}, aurSearchThread, .{ job, duped });
        if (self.aur_query.len > 0) self.gpa.free(self.aur_query);
        self.aur_query = duped;
        self.aur_failed = false;
        self.aur_job = job;

        self.aur_thread = thread;
    }

    fn aurSearchThread(job: *AurSearchJob, query: []const u8) void {
        const alloc = std.heap.page_allocator;
        var threaded: std.Io.Threaded = .init(alloc, .{});
        defer threaded.deinit();

        const cli: ShellyCli = .{ .allocator = alloc, .io = threaded.io() };
        const parsed = (if (job.installed_only) cli.list_aur_installed() else if (query.len == 0) std.json.parseFromSlice([]AurPackage, alloc, "[]", .{}) else cli.search_aur(query)) catch {
            job.failed = true;
            job.done.store(true, .release);
            return;
        };

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

    fn pollAurSearch(self: *Model) !bool {
        const job = self.aur_job orelse return false;
        if (!job.done.load(.acquire)) return true;

        if (self.aur_thread) |thread| thread.join();
        self.aur_thread = null;
        const parsed = job.result;
        const failed = job.failed;
        self.aur_job = null;
        self.gpa.destroy(job);
        if (!self.settings.aur_enabled) {
            if (parsed) |owner| owner.deinit();
            return false;
        }

        if (self.overlay) |overlay| {
            if (overlay == .aur) self.overlay = null;
        }
        if (self.aur_parsed) |*old| old.deinit();
        self.aur_parsed = null;
        self.aur_packages = &.{};
        self.aur_failed = failed;
        if (parsed) |p| {
            self.aur_parsed = p;
            self.aur_packages = p.value;
        }
        try self.rebuildAurFilter();
        return false;
    }

    fn operationFromOverlay(self: *Model, action: shelly_operation.Action) !void {
        if (self.install_job != null) return; // one install at a time
        const overlay = self.overlay orelse return;
        var name: []const u8 = undefined;
        var backend: OperationBackend = undefined;
        switch (overlay) {
            .package => |pkg| {
                _ = pkg;
                return self.openNativePrompt(action);
            },
            .aur => |pkg| {
                if (!self.settings.aur_enabled) return;
                if (action == .remove and !pkg.Installed) return;
                name = pkg.Name;
                backend = .aur;
            },
            .sudo, .pkgbuild, .flatpak, .flatpak_install => return,
        }
        try self.openPackagePrompt(name, backend, action);
    }

    fn packageMarked(self: *const Model, name: []const u8) bool {
        for (self.selected_packages.items) |selected| {
            if (std.mem.eql(u8, name, selected)) return true;
        }
        return false;
    }

    fn openNativePrompt(self: *Model, action: shelly_operation.Action) !void {
        if (self.install_job != null or self.loading or self.load_failed) return;
        var targets: std.ArrayList([]const u8) = .empty;
        defer targets.deinit(self.gpa);
        var review: std.ArrayList(u8) = .empty;
        defer review.deinit(self.gpa);
        var installed_names: std.ArrayList([]const u8) = .empty;
        defer installed_names.deinit(self.gpa);
        var available_names: std.ArrayList([]const u8) = .empty;
        defer available_names.deinit(self.gpa);
        var installed: usize = 0;
        var available: usize = 0;
        var excluded: usize = 0;
        const highlighted = self.selectedPackage();
        for (self.packages) |pkg| {
            const included = if (self.selected_packages.items.len > 0)
                self.packageMarked(pkg.Name)
            else if (highlighted) |item|
                std.mem.eql(u8, item.Name, pkg.Name)
            else
                false;
            if (!included) continue;
            if (action == .remove and !pkg.Installed) {
                excluded += 1;
                continue;
            }
            var duplicate = false;
            for (targets.items) |target| {
                if (std.mem.eql(u8, target, pkg.Name)) duplicate = true;
            }
            if (duplicate) continue;
            try targets.append(self.gpa, pkg.Name);
            if (pkg.Installed) {
                installed += 1;
                try installed_names.append(self.gpa, pkg.Name);
            } else {
                available += 1;
                try available_names.append(self.gpa, pkg.Name);
            }
        }
        if (targets.items.len == 0) {
            try self.setNotice(if (action == .remove) "No installed packages selected for removal." else "No packages selected.");
            return;
        }
        const groups = [_]struct { label: []const u8, names: []const []const u8 }{
            .{ .label = "Install", .names = available_names.items },
            .{ .label = if (action == .remove) "Remove" else "Reinstall", .names = installed_names.items },
        };
        for (groups) |group| {
            if (group.names.len == 0) continue;
            const names = try std.mem.join(self.gpa, ", ", group.names);
            defer self.gpa.free(names);
            const line = try std.fmt.allocPrint(self.gpa, "{s}: {f}\n", .{ group.label, diagnostics.safe(names) });
            defer self.gpa.free(line);
            try review.appendSlice(self.gpa, line);
        }
        const summary = if (action == .remove)
            try std.fmt.allocPrint(self.gpa, "Remove {d} installed packages.\n{d} uninstalled selections excluded.\nUnused dependencies and configuration will be kept.\n", .{ installed, excluded })
        else
            try std.fmt.allocPrint(self.gpa, "Install {d} available packages; reinstall {d} installed packages.\n", .{ available, installed });
        defer self.gpa.free(summary);
        const prompt = try self.gpa.create(SudoPrompt);
        prompt.* = .{ .name = "", .backend = .standard, .action = action, .password = .empty };
        errdefer prompt.deinit(self.gpa);
        prompt.name = if (targets.items.len == 1) try self.gpa.dupe(u8, targets.items[0]) else try std.fmt.allocPrint(self.gpa, "{d} packages", .{targets.items.len});
        var owned: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (owned.items) |target| self.gpa.free(target);
            owned.deinit(self.gpa);
        }
        for (targets.items) |target| {
            const copy = try self.gpa.dupe(u8, target);
            errdefer self.gpa.free(copy);
            try owned.append(self.gpa, copy);
        }
        prompt.targets = try owned.toOwnedSlice(self.gpa);
        prompt.review_text = try std.mem.concat(self.gpa, u8, &.{ summary, review.items });
        self.overlay = .{ .sudo = prompt };
    }

    fn openPackagePrompt(self: *Model, name: []const u8, backend: OperationBackend, action: shelly_operation.Action) !void {
        if (self.install_job != null) return;
        const prompt = try self.gpa.create(SudoPrompt);
        errdefer self.gpa.destroy(prompt);
        prompt.* = .{
            .name = try self.gpa.dupe(u8, name),
            .backend = backend,
            .action = action,
            .password = .empty,
        };
        self.overlay = .{ .sudo = prompt };
    }

    fn openFlatpakPrompt(self: *Model, action: shelly_operation.Action, name: []const u8, target: ?shelly_operation.FlatpakTarget) !void {
        if (!self.settings.flatpak_enabled or !self.flatpak_available or self.install_job != null) return;
        const prompt = try self.gpa.create(SudoPrompt);
        errdefer self.gpa.destroy(prompt);
        const owned_name = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned_name);
        prompt.* = .{
            .name = owned_name,
            .backend = .flatpak,
            .action = action,
            .password = .empty,
            .elevated = shelly_operation.flatpakNeedsElevation(action, target),
            .flatpak_target = if (target) |value| try value.clone(self.gpa) else null,
        };
        self.overlay = .{ .sudo = prompt };
    }

    fn toggleSelectedList(self: *Model) !void {
        try self.setNotice("");
        const package_name = self.filtered.items[self.list_view.cursor].Name;
        for (self.selected_packages.items, 0..) |*item, index| {
            if (std.mem.eql(u8, item.*, package_name)) {
                _ = self.selected_packages.orderedRemove(index);
                return;
            }
        }
        try self.selected_packages.append(self.gpa, package_name);
    }

    fn closeOverlay(self: *Model) void {
        if (self.overlay) |overlay| {
            switch (overlay) {
                .sudo => |prompt| {
                    prompt.deinit(self.gpa);
                    if (self.notice.len > 0) self.gpa.free(self.notice);
                    self.notice = "";
                },
                else => {},
            }
        }
        self.overlay = null;
    }

    fn showOperationQuestion(self: *Model, message: shelly_operation.OwnedMessage) !void {
        const overlay = self.overlay orelse return error.NoOperationDialog;
        if (overlay != .sudo) return error.NoOperationDialog;
        const question = message.value.question;
        var document = try pkgbuild_view.Document.fromQuestion(self.gpa, question);
        errdefer document.deinit();
        const name = try self.gpa.dupe(u8, if (question == .pkgbuild) question.pkgbuild.package_name else overlay.sudo.name);
        if (self.pkgbuild_document) |*old| old.deinit();
        if (self.pkgbuild_name.len > 0) self.gpa.free(self.pkgbuild_name);
        self.pkgbuild_name = name;
        self.pkgbuild_document = document;
        self.pkgbuild_failure = null;
        self.pkgbuild_scroll.scroll = .{};
        self.pkgbuild_scroll.cursor = 0;
        self.pkgbuild_scroll.item_count = @intCast(document.lines.len);
        self.operation_question = message;
        self.review_prompt = overlay.sudo;
        self.answer_input.clearRetainingCapacity();
        self.answer_error = "";
        self.overlay = .pkgbuild;
    }

    fn finishOperationQuestion(self: *Model) void {
        if (self.operation_question) |*question| question.deinit();
        self.operation_question = null;
        if (self.pkgbuild_document) |*document| document.deinit();
        self.pkgbuild_document = null;
        self.answer_input.clearRetainingCapacity();
        self.answer_error = "";
        if (self.review_prompt) |prompt| self.overlay = .{ .sudo = prompt };
        self.review_prompt = null;
    }

    fn answerOperationQuestion(self: *Model, approve: bool) !void {
        const message = self.operation_question orelse return;
        const job = self.install_job orelse return;
        const question = message.value.question;
        var indices: std.ArrayList(usize) = .empty;
        defer indices.deinit(self.gpa);
        const answer: shelly_operation.Answer = switch (question) {
            .pkgbuild => .{ .pkgbuild = approve },
            .yes_no => .{ .yes_no = approve },
            .transaction => .{ .transaction = approve },
            .select_one => |request| blk: {
                if (!approve) return;
                const input = std.mem.trim(u8, self.answer_input.items, " ");
                const index = std.fmt.parseInt(usize, input, 10) catch {
                    self.answer_error = "Enter one listed index.";
                    return;
                };
                for (request.options) |option| {
                    if (option.index == index) break :blk .{ .provider = index };
                }
                self.answer_error = "That index is not listed.";
                return;
            },
            .select_many => |request| blk: {
                if (!approve) return;
                const input = std.mem.trim(u8, self.answer_input.items, " ");
                if (input.len > 0) {
                    var tokens = std.mem.splitScalar(u8, input, ',');
                    while (tokens.next()) |token| {
                        const index = std.fmt.parseInt(usize, std.mem.trim(u8, token, " "), 10) catch {
                            self.answer_error = "Use listed indices separated by commas, or leave blank for none.";
                            return;
                        };
                        var found = false;
                        for (request.options) |option| {
                            if (option.index == index) {
                                found = true;
                                break;
                            }
                        }
                        if (!found or std.mem.indexOfScalar(usize, indices.items, index) != null) {
                            self.answer_error = "Use unique listed indices.";
                            return;
                        }
                        try indices.append(self.gpa, index);
                    }
                }
                break :blk .{ .optional_dependencies = indices.items };
            },
        };
        job.sendAnswer(runtime.io, shelly_operation.questionId(question), answer) catch {
            self.answer_error = "Could not send the answer. The operation may have ended.";
            return;
        };
        self.finishOperationQuestion();
    }

    fn handleSudoKey(self: *Model, prompt: *SudoPrompt, ctx: *vxfw.EventContext, key: vaxis.Key) anyerror!void {
        switch (try prompt.panel.handleKey(self.promptView(prompt), ctx, key)) {
            .none => {},
            .close => self.closeOverlay(),
            .confirm => {
                try self.startElevatedInstall(ctx, prompt);
                @memset(prompt.password.items, 0);
                prompt.password.clearRetainingCapacity();
                prompt.state = .running;
            },
            .erase => popGrapheme(&prompt.password),
            .text => |text| for (text) |byte| {
                if (byte >= 0x20) try prompt.password.append(self.gpa, byte);
            },
        }
        return ctx.consumeAndRedraw();
    }

    fn operationPrompt(self: *Model) ?*SudoPrompt {
        const overlay = self.overlay orelse return null;
        return if (overlay == .sudo) overlay.sudo else null;
    }

    fn promptView(self: *const Model, prompt: *const SudoPrompt) operation_view.View {
        var view = prompt.operationView();
        view.refresh_pending = self.refresh_after_upgrade or self.refresh_flatpak_after_operation or
            self.refresh_updates_after_operation or self.loading or self.updates_job != null or self.flatpak_job != null;
        return view;
    }

    fn startElevatedInstall(self: *Model, ctx: *vxfw.EventContext, prompt: *SudoPrompt) !void {
        if (self.install_job != null) return error.OperationAlreadyRunning;
        // Schedule polling before starting so scheduling failure cannot orphan a worker.
        try ctx.tick(100, self.widget());
        self.install_job = try shelly_operation.Operation.start(.{
            .shelly_bin = shellyBin(),
            .environ_map = runtime.environ_map,
            .name = prompt.name,
            .targets = prompt.targets,
            .action = prompt.action,
            .backend = @tagName(prompt.backend),
            .password = prompt.password.items,
            .flatpak = prompt.flatpak_target,
            .include_flatpak = prompt.include_flatpak,
            .include_aur = prompt.include_aur,
        });
    }

    fn shellyBin() []const u8 {
        return if (runtime.is_debug)
            "../Shelly.Cli.Zig/zig-out/bin/shelly"
        else
            "shelly";
    }

    fn popGrapheme(list: *std.ArrayList(u8)) void {
        const len = list.items.len;
        if (len == 0) return;
        var n: usize = 1;
        // Walk back over UTF-8 continuation bytes to drop a whole codepoint
        while (n < len and (list.items[len - n] & 0xC0) == 0x80) n += 1;
        list.shrinkRetainingCapacity(len - n);
    }

    fn pollInstall(self: *Model) !bool {
        const job = self.install_job orelse return false;
        const result = job.poll();
        if (result == null and self.operation_question == null) {
            if (job.takeQuestion(runtime.io)) |message| {
                self.showOperationQuestion(message) catch |err| {
                    var owned = message;
                    owned.deinit();
                    job.closeInput(runtime.io);
                    const detail = try std.fmt.allocPrint(self.gpa, "Could not display operation review: {s}", .{@errorName(err)});
                    defer self.gpa.free(detail);
                    try self.setNotice(detail);
                };
            }
        }
        if (result != null and self.operation_question != null) self.finishOperationQuestion();
        if (self.overlay) |overlay| {
            if (overlay == .sudo) overlay.sudo.progress = job.snapshot(runtime.io);
        }
        const completed = result orelse return true;
        defer job.deinit();

        const failed = completed.failed;
        self.install_job = null;
        const is_flatpak = std.mem.eql(u8, job.request.backend, "flatpak");
        const is_combined = std.mem.eql(u8, job.request.backend, "all");
        const native_batch = job.request.targets.len > 0;
        if (native_batch) {
            self.refresh_after_upgrade = true;
            self.refresh_updates_after_operation = true;
            if (!failed and !completed.declined) self.clearCompletedSelection(job.request.targets);
        }
        if (is_flatpak or (is_combined and job.request.include_flatpak)) self.refresh_flatpak_after_operation = true;
        if (job.request.action == .upgrade or is_flatpak or std.mem.eql(u8, job.request.backend, "aur")) self.refresh_updates_after_operation = true;
        if (!is_flatpak and (job.request.action == .upgrade or std.mem.eql(u8, job.request.backend, "aur"))) self.refresh_after_upgrade = true;
        if ((is_combined and job.request.include_aur) or std.mem.eql(u8, job.request.backend, "aur")) self.refresh_aur_after_operation = true;

        // Native and AUR operations change the same installed package database.
        if (!native_batch and !is_flatpak and !failed and !completed.declined and job.request.action != .upgrade) {
            for (self.packages) |*pkg| {
                if (std.mem.eql(u8, pkg.Name, job.request.name)) {
                    pkg.Installed = job.request.action == .install;
                    break;
                }
            }
        }
        if (!native_batch and !is_flatpak and !failed and !completed.declined and job.request.action != .upgrade) {
            if (self.aur_parsed) |parsed| {
                for (parsed.value) |*pkg| {
                    if (std.mem.eql(u8, pkg.Name, job.request.name))
                        pkg.Installed = job.request.action == .install;
                }
            }
        }
        if (self.installed_only) try self.rebuildFilter();
        // Reflect the outcome in the sudo prompt if it is still open
        if (self.overlay) |overlay| {
            switch (overlay) {
                .sudo => |prompt| {
                    if (failed or completed.declined) {
                        prompt.state = if (completed.declined) .declined else .failed;
                        if (prompt.detail.len > 0) self.gpa.free(prompt.detail);
                        prompt.detail = if (completed.error_detail.len > 0)
                            self.gpa.dupe(u8, completed.error_detail) catch ""
                        else
                            "";
                    } else {
                        prompt.state = .succeeded;
                    }
                },
                else => {},
            }
        }

        return false;
    }

    fn clearCompletedSelection(self: *Model, targets: []const []const u8) void {
        var index: usize = 0;
        while (index < self.selected_packages.items.len) {
            var completed = false;
            for (targets) |target| {
                if (std.mem.eql(u8, self.selected_packages.items[index], target)) completed = true;
            }
            if (completed) _ = self.selected_packages.orderedRemove(index) else index += 1;
        }
    }

    fn setNotice(self: *Model, message: []const u8) Allocator.Error!void {
        if (self.notice.len > 0) self.gpa.free(self.notice);
        self.notice = if (message.len > 0) try self.gpa.dupe(u8, message) else "";
    }

    // -- filtering ---------------------------------------------------------

    fn onQueryChange(maybe_ptr: ?*anyopaque, _: *vxfw.EventContext, str: []const u8) anyerror!void {
        const ptr = maybe_ptr orelse return;
        const self: *Model = @ptrCast(@alignCast(ptr));
        try self.setQuery(str);
    }

    fn setQuery(self: *Model, str: []const u8) Allocator.Error!void {
        const duped = if (str.len > 0) try self.gpa.dupe(u8, str) else "";
        if (self.query.len > 0) self.gpa.free(self.query);
        self.query = duped;
        try self.rebuildFilter();
    }

    fn onAurQueryChange(ptr: ?*anyopaque, _: *vxfw.EventContext, _: []const u8) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr orelse return));
        if (self.aur_installed_only) try self.rebuildAurFilter();
    }

    fn rebuildAurFilter(self: *Model) Allocator.Error!void {
        self.aur_filtered.clearRetainingCapacity();
        if (self.aur_job != null) {
            self.aur_list.item_count = 0;
            self.aur_list.jumpToItem(0);
            return;
        }
        const query = try self.aur_field.buf.dupe();
        defer self.gpa.free(query);
        for (self.aur_packages) |*pkg| {
            if (!self.aur_installed_only or query.len == 0 or containsFold(pkg.Name, query) or containsFold(pkg.Description orelse "", query))
                try self.aur_filtered.append(self.gpa, pkg);
        }
        self.aur_list.item_count = @intCast(self.aur_filtered.items.len);
        self.aur_list.jumpToItem(0);
    }

    fn rebuildFilter(self: *Model) Allocator.Error!void {
        self.package_details_scroll.scroll = .{};
        self.filtered.clearRetainingCapacity();
        for (self.packages) |*pkg| {
            if (self.installed_only and !pkg.Installed) continue;
            if (self.query.len == 0 or
                containsFold(pkg.Name, self.query) or
                containsFold(pkg.Description, self.query))
            {
                try self.filtered.append(self.gpa, pkg);
            }
        }
        self.list_view.item_count = @intCast(self.filtered.items.len);
        self.list_view.jumpToItem(0);
    }

    /// Case-insensitive substring match (ASCII folding only, which is all
    /// that package names need).
    fn containsFold(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (haystack.len < needle.len) return false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            var j: usize = 0;
            while (j < needle.len and
                std.ascii.toLower(haystack[i + j]) == std.ascii.toLower(needle[j])) j += 1;
            if (j == needle.len) return true;
        }
        return false;
    }

    // -- drawing -----------------------------------------------------------

    fn packagesView(self: *Model) packages_view.View {
        if (self.package_details_cursor == null or self.package_details_cursor.? != self.list_view.cursor) {
            self.package_details_scroll.scroll = .{};
            self.package_details_cursor = self.list_view.cursor;
        }
        var selected_installed: usize = 0;
        for (self.selected_packages.items) |name| {
            for (self.packages) |pkg| {
                if (std.mem.eql(u8, pkg.Name, name)) {
                    if (pkg.Installed) selected_installed += 1;
                    break;
                }
            }
        }
        return .{
            .text_field = &self.text_field,
            .list_view = &self.list_view,
            .details_scroll = &self.package_details_scroll,
            .help = if (self.help_open) &self.help_panel else null,
            .selected = self.selectedPackage(),
            .details_active = !self.help_open and (if (self.overlay) |overlay| overlay == .package else false),
            .list_active = self.package_list_active and !self.help_open,
            .selected_count = self.selected_packages.items.len,
            .selected_installed = selected_installed,
            .loading = self.loading,
            .load_failed = self.load_failed,
            .query = self.query,
            .filtered_count = self.filtered.items.len,
            .package_count = self.packages.len,
            .installed_only = self.installed_only,
        };
    }

    fn aurView(self: *Model) aur_view.View {
        return .{
            .aur_field = &self.aur_field,
            .aur_list = &self.aur_list,
            .searching = self.aur_job != null,
            .aur_failed = self.aur_failed,
            .aur_query = self.aur_query,
            .result_count = self.aur_filtered.items.len,
            .installed_only = self.aur_installed_only,
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        const arena = ctx.arena;
        const max = ctx.max.size();

        // Need room for the tab bar, at least one content row and the
        // status bar
        if (max.width == 0 or max.height < 4) {
            return .{
                .size = max,
                .widget = self.widget(),
                .buffer = &.{},
                .children = &.{},
            };
        }

        var children: std.ArrayList(vxfw.SubSurface) = .empty;

        const prompt = self.operationPrompt();
        var navigation_height: u16 = if (max.width >= 2 and max.height >= 8) 3 else 1;
        var panel_height: u16 = 0;
        var show_browsing = true;
        if (prompt) |active_prompt| {
            const preferred_height = try self.promptView(active_prompt).preferredHeight(ctx, 9);
            if (max.height >= navigation_height + preferred_height + 5) {
                panel_height = preferred_height;
            } else {
                // Short terminals give the operation the content area rather
                // than clipping authentication beneath a tiny browsing pane.
                navigation_height = if (max.height >= 11) 3 else 1;
                panel_height = max.height -| (navigation_height + 1);
                show_browsing = false;
            }
        }
        if (self.help_open and !show_browsing) {
            navigation_height = 1;
            panel_height = @min(panel_height, max.height -| 6);
            show_browsing = true;
        }
        const content_offset = navigation_height - 1;

        // Navigation occupies its own rows above every page.
        const tab_bar = try self.drawTabBar(arena);
        try children.append(arena, .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try tab_bar.draw(ctx.withConstraints(
                ctx.min,
                .{ .width = max.width, .height = navigation_height },
            )),
        });

        const content_start = children.items.len;
        const content_ctx = ctx.withConstraints(.{}, .{ .width = max.width, .height = max.height - content_offset - panel_height });
        self.help_panel.context = self.commandContext();
        if (show_browsing and self.help_open and self.active != .packages) {
            try children.append(arena, .{
                .origin = .{ .row = 1, .col = 0 },
                .surface = try self.help_panel.draw(content_ctx.withConstraints(.{}, .{ .width = max.width, .height = content_ctx.max.size().height -| 2 })),
            });
        } else if (show_browsing) switch (self.active) {
            .packages => try self.packagesView().appendContent(content_ctx, &children),
            .aur => try self.aurView().appendContent(content_ctx, &children),
            .upgrade => try self.updatesView().appendContent(content_ctx, &children),
            .flatpak => try self.flatpakView().appendContent(content_ctx, &children),
            .settings => try self.settingsView().appendContent(content_ctx, &children),
        };

        for (children.items[content_start..]) |*child| child.origin.row += @intCast(content_offset);
        if (prompt) |active_prompt| {
            try children.append(arena, .{
                .origin = .{ .row = @intCast(max.height - panel_height - 1), .col = 0 },
                .surface = try active_prompt.panel.draw(self.promptView(active_prompt), ctx.withConstraints(
                    .{},
                    .{ .width = max.width, .height = panel_height },
                )),
            });
        }

        var footer_context = self.commandContext();
        if (self.help_open) {
            footer_context.mode = .help;
            footer_context.selected_count = 0;
        }
        try children.append(arena, .{
            .origin = .{ .row = max.height - 1, .col = 0 },
            .surface = try footer_view.draw(ctx.withConstraints(.{}, .{ .width = max.width, .height = 1 }), footer_context, if (self.help_open) null else try self.footerStatus(arena)),
        });

        // Modal overlay on top of everything
        if (!self.help_open) if (self.overlay) |overlay| {
            const overlay_child: ?vxfw.SubSurface = switch (overlay) {
                .package => null,
                .aur, .flatpak => try self.drawDetailsOverlay(ctx, arena, max, overlay),
                .sudo => null,
                .pkgbuild => try self.pkgbuildView().draw(ctx),
                .flatpak_install => |choice| try flatpak_view.drawInstallChoices(ctx, choice.app, choice.selected),
            };
            if (overlay_child) |child| {
                try children.append(arena, child);
            }
        };

        return .{
            .size = max,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children.items,
        };
    }

    fn drawTabBar(self: *Model, arena: Allocator) Allocator.Error!vxfw.Widget {
        const tabs = self.visibleTabs();
        const spans = try arena.alloc(vxfw.RichText.TextSpan, tabs.len);
        for (tabs, 0..) |tab, i| {
            spans[i] = .{
                .text = try std.fmt.allocPrint(arena, " {d} {s} ", .{ i + 1, tab.title() }),
                .style = if (tab == self.active)
                    .{ .bold = true, .reverse = true, .fg = .{ .index = 7 } }
                else
                    .{ .fg = .{ .index = 250 } },
            };
        }
        const bar = try arena.create(TabBar);
        bar.* = .{
            .model = self,
            .tabs = try arena.dupe(Tab, tabs),
            .rich = .{ .text = spans, .softwrap = false },
        };
        return bar.widget();
    }

    fn commandContext(self: *Model) commands.Context {
        var context: commands.Context = .{ .tab_count = self.visibleTabs().len };
        if (self.operationPrompt()) |prompt| {
            context.mode = switch (prompt.state) {
                .entering => if (prompt.elevated) .authentication else .confirmation,
                .running => .running,
                .succeeded, .failed, .declined => .result,
            };
            context.scrollable = prompt.panel.scroll.scroll.has_more_vertical or
                prompt.panel.scroll.scroll.top > 0 or prompt.panel.scroll.scroll.vertical_offset != 0;
            return context;
        }
        if (self.overlay) |overlay| switch (overlay) {
            .package => context.native_details = true,
            .aur => |pkg| {
                context.mode = .details;
                context.installable = true;
                context.removable = pkg.Installed;
                context.preview = true;
                return context;
            },
            .flatpak => |row| {
                context.mode = .details;
                context.installable = row == .catalog and row.catalog.Remotes.len > 0;
                context.removable = row == .installed;
                return context;
            },
            .pkgbuild => {
                context.mode = if (self.operation_question) |question|
                    if (question.value.question == .select_one or question.value.question == .select_many) .answers else .review
                else
                    .preview_document;
                context.scrollable = self.pkgbuild_document != null;
                return context;
            },
            .flatpak_install => {
                context.mode = .choice;
                return context;
            },
            .sudo => unreachable,
        };
        switch (self.active) {
            .packages => {
                context.mode = if (context.native_details) .details else if (self.package_list_active) .packages else .search;
                context.installed_only = self.installed_only;
                context.selected_count = self.selected_packages.items.len;
                for (self.selected_packages.items) |name| for (self.packages) |pkg| {
                    if (std.mem.eql(u8, name, pkg.Name)) {
                        if (pkg.Installed) context.selected_installed += 1;
                        break;
                    }
                };
                context.installable = !self.loading and !self.load_failed and (self.selectedPackage() != null or context.selected_count > 0);
                context.removable = context.installable and if (context.selected_count > 0) context.selected_installed > 0 else if (self.selectedPackage()) |pkg| pkg.Installed else false;
                context.scrollable = context.native_details and (self.package_details_scroll.scroll.has_more_vertical or
                    self.package_details_scroll.scroll.top > 0 or self.package_details_scroll.scroll.vertical_offset != 0);
            },
            .aur => {
                context.mode = .aur;
                context.installed_only = self.aur_installed_only;
            },
            .flatpak => {
                context.mode = .flatpak;
                context.installed_only = self.flatpak_installed_only;
            },
            .upgrade => {
                const view = self.updatesView();
                context.mode = .updates;
                context.upgrade_all = view.canUpgradeAll();
                context.upgrade_system = view.canUpgrade();
                context.upgrade_aur = view.canUpgradeAur();
                context.upgrade_flatpak = view.canUpgradeFlatpak();
            },
            .settings => context.mode = .settings,
        }
        return context;
    }

    fn footerStatus(self: *Model, _: Allocator) Allocator.Error!?[]const u8 {
        if (self.notice.len > 0) return self.notice;
        if (self.operationPrompt() != null) return null;
        return switch (self.active) {
            .packages => if (self.loading) "Loading packages…" else if (self.load_failed) "Package query failed" else null,
            .aur => if (self.aur_job != null) "Loading AUR results…" else if (self.aur_failed) "AUR query failed" else null,
            .flatpak => if (self.flatpak_probe_job != null) "Checking Flatpak backend…" else if (self.flatpak_job != null) "Loading Flatpaks…" else if (self.flatpak_failure != null) "Flatpak query failed" else null,
            .upgrade => if (self.updates_job != null) "Checking for updates…" else if (self.updates_failed) "Update check failed" else null,
            .settings => null,
        };
    }

    fn statusText(self: *Model, arena: Allocator) Allocator.Error![]const u8 {
        if (self.active == .upgrade) return self.updatesView().statusText(arena);
        if (self.notice.len > 0) return self.notice;
        return switch (self.active) {
            .packages => self.packagesView().statusText(arena),
            .aur => self.aurView().statusText(arena),
            .upgrade => self.updatesView().statusText(arena),
            .flatpak => self.flatpakView().statusText(arena),
            .settings => "Settings — source preferences are saved for future sessions",
        };
    }

    fn drawDetailsOverlay(self: *const Model, ctx: vxfw.DrawContext, arena: Allocator, max: vxfw.Size, overlay: Overlay) Allocator.Error!?vxfw.SubSurface {
        var title: []const u8 = undefined;
        var body: []const u8 = undefined;
        switch (overlay) {
            .package => |pkg| {
                title = try std.fmt.allocPrint(arena, "{s} {s}", .{ pkg.Name, pkg.Version });
                body = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{
                    try packages_view.detailsText(arena, pkg),
                    commands.detailsHint(pkg.Installed),
                });
            },
            .aur => |pkg| {
                title = try std.fmt.allocPrint(arena, "{s} {s} (AUR)", .{ pkg.Name, pkg.Version });
                body = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{
                    try aur_view.detailsText(arena, pkg),
                    commands.aurDetailsHint(pkg.Installed),
                });
            },
            .flatpak => |row| {
                title = try std.fmt.allocPrint(arena, "{f} (Flatpak)", .{diagnostics.safe(row.title())});
                body = try row.details(arena);
            },
            .sudo, .pkgbuild, .flatpak_install => return null,
        }
        if (self.install_job) |job| {
            body = try std.fmt.allocPrint(arena, "{s}\n\n{s} {s}…", .{ body, job.request.action.ongoing(), job.request.name });
        }

        const box_width = @min(max.width -| 2, @as(u16, 80));
        const box_height = @min(max.height -| 2, @as(u16, 28));
        if (box_width < 20 or box_height < 6) return null;

        var text: vxfw.Text = .{ .text = body };
        const labels = [_]Border.BorderLabel{.{ .text = title, .alignment = .top_left }};
        var border: Border = .{
            .child = text.widget(),
            .labels = &labels,
        };
        const surface = try border.widget().draw(ctx.withConstraints(
            .{ .width = 0, .height = 0 },
            .{ .width = box_width, .height = box_height },
        ));
        return .{
            .origin = .{
                .row = @divFloor(@as(i17, max.height) - @as(i17, surface.size.height), 2),
                .col = @divFloor(@as(i17, max.width) - @as(i17, surface.size.width), 2),
            },
            .surface = surface,
            .z_index = 2,
        };
    }

    fn codepointCount(bytes: []const u8) usize {
        var count: usize = 0;
        var i: usize = 0;
        while (i < bytes.len) {
            const seq_len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 1;
            i += @min(@as(usize, seq_len), bytes.len - i);
            count += 1;
        }
        return count;
    }

    // -- list rows ---------------------------------------------------------

    fn selectedPackage(self: *const Model) ?*const Package {
        if (self.list_view.cursor >= self.filtered.items.len) return null;
        return self.filtered.items[self.list_view.cursor];
    }

    fn buildPackageDetails(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
        if (idx != 0) return null;
        const self: *const Model = @ptrCast(@alignCast(ptr));
        const pkg = self.selectedPackage() orelse return null;
        return .{ .userdata = @constCast(pkg), .drawFn = packages_view.drawDetails };
    }

    /// ListView builder: constructs the widget for a single row on demand, so
    /// only visible rows are ever built.
    fn buildRow(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
        const self: *const Model = @ptrCast(@alignCast(ptr));
        if (idx >= self.filtered.items.len) return null;
        const pkg = self.filtered.items[idx];
        return .{
            .userdata = @constCast(pkg),
            .drawFn = if (self.packageMarked(pkg.Name)) packages_view.drawMarkedPackageRow else packages_view.drawPackageRow,
        };
    }

    fn buildSelectedRow(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
        const self: *const Model = @ptrCast(@alignCast(ptr));
        if (idx >= self.selected_packages.items.len) return null;
        return .{ .userdata = @ptrCast(&self.selected_packages.items[idx]), .drawFn = packages_view.drawSelectedRow };
    }

    fn buildAurRow(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
        const self: *const Model = @ptrCast(@alignCast(ptr));
        if (idx >= self.aur_filtered.items.len) return null;
        const pkg = self.aur_filtered.items[idx];
        return .{
            .userdata = @constCast(pkg),
            .drawFn = aur_view.drawAurRow,
        };
    }

    // -- details -----------------------------------------------------------

};

/// A compact centered bar with a filled highlight for the selected tab.
const TabBar = struct {
    model: *Model,
    tabs: []const Tab,
    rich: vxfw.RichText,
    first_visible: usize = 0,
    start_col: i16 = 0,
    label_row: i16 = 0,

    pub fn widget(self: *TabBar) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = handleEvent,
            .drawFn = drawFn,
        };
    }

    fn drawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *TabBar = @ptrCast(@alignCast(ptr));
        const size = ctx.max.size();
        const framed = size.height >= 3 and size.width >= 8;
        const padding: usize = if (framed) 4 else 0;
        const width = size.width -| @as(u16, if (framed) 8 else 0);
        const caps: usize = 0;
        var active: usize = 0;
        for (self.tabs, 0..) |tab, index| {
            if (tab == self.model.active) active = index;
        }
        var first: usize = 0;
        var end = self.tabs.len;
        var total: usize = (self.tabs.len -| 1) + caps;
        for (self.rich.text) |span| total += span.text.len;
        while (total > width and end - first > 1) {
            if (active - first > end - 1 - active) {
                total -= self.rich.text[first].text.len + 1;
                first += 1;
            } else {
                end -= 1;
                total -= self.rich.text[end].text.len + 1;
            }
        }
        const spans = try ctx.arena.dupe(vxfw.RichText.TextSpan, self.rich.text[first..end]);
        if (total > width) {
            const label = std.mem.trim(u8, spans[0].text, " ");
            spans[0].text = label[0..@min(width -| caps, label.len)];
            total = spans[0].text.len + caps;
        }
        self.first_visible = first;
        self.rich.text = spans;
        const island_width: u16 = @intCast(total + padding);
        const island_col = (size.width - island_width) / 2;
        self.start_col = @intCast(island_col + padding / 2);
        self.label_row = if (size.height >= 3) 1 else 0;
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        @memset(surface.buffer, .{});
        if (framed) {
            const edge = island_col + island_width - 1;
            surface.writeCell(island_col, 0, .{ .char = .{ .grapheme = "┌", .width = 1 } });
            surface.writeCell(edge, 0, .{ .char = .{ .grapheme = "┐", .width = 1 } });
            surface.writeCell(island_col, 2, .{ .char = .{ .grapheme = "└", .width = 1 } });
            surface.writeCell(edge, 2, .{ .char = .{ .grapheme = "┘", .width = 1 } });
            surface.writeCell(island_col, 1, .{ .char = .{ .grapheme = "│", .width = 1 } });
            surface.writeCell(edge, 1, .{ .char = .{ .grapheme = "│", .width = 1 } });
            for (island_col + 1..edge) |col| {
                for ([_]u16{ 0, 2 }) |row| surface.writeCell(@intCast(col), row, .{ .char = .{ .grapheme = "─", .width = 1 } });
            }
        }
        var col: u16 = @intCast(self.start_col);
        for (spans) |span| {
            const selected = span.style.reverse;
            const selected_style: vaxis.Style = .{ .bg = .{ .index = 7 }, .fg = .{ .index = 0 }, .bold = true };
            for (span.text, 0..) |_, offset| {
                surface.writeCell(col + @as(u16, @intCast(offset)), @intCast(self.label_row), .{
                    .char = .{ .grapheme = span.text[offset .. offset + 1], .width = 1 },
                    .style = if (selected) selected_style else span.style,
                });
            }
            col += @intCast(span.text.len);
            col +|= 1;
        }
        return surface;
    }

    fn handleEvent(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *TabBar = @ptrCast(@alignCast(ptr));
        switch (event) {
            // Mouse coordinates arrive local to this surface
            .mouse => |mouse| {
                if (mouse.button != .left or mouse.type != .press) return;
                if (mouse.row != self.label_row or mouse.col < self.start_col) return;
                var col = self.start_col;
                for (self.rich.text, 0..) |span, i| {
                    // Labels are ASCII, so byte length == display width
                    const width: i16 = @intCast(span.text.len);
                    if (mouse.col >= col and mouse.col < col + width) {
                        try self.model.setTab(self.tabs[self.first_visible + i], ctx);
                        return ctx.consumeAndRedraw();
                    }
                    col += width + 1;
                }
            },
            else => {},
        }
    }
};

test "tab switching requests focus on a widget in the active page" {
    var model: Model = undefined;
    model.active = .packages;
    model.help_open = false;
    model.overlay = null;
    model.flatpak_available = false;
    model.settings = .{};
    var ctx: vxfw.EventContext = .{
        .io = undefined,
        .alloc = std.testing.allocator,
        .cmds = .empty,
    };
    defer ctx.cmds.deinit(std.testing.allocator);

    for ([_]i32{ 1, 1, 1, -1, -1, -1 }) |direction| {
        ctx.cmds.clearRetainingCapacity();
        model.switchTab(direction);
        try model.focusActiveTab(&ctx);
        try std.testing.expectEqual(@as(usize, 1), ctx.cmds.items.len);
        const expected = switch (model.active) {
            .packages => model.text_field.widget(),
            .aur => model.aur_field.widget(),
            .upgrade, .settings => model.widget(),
            .flatpak => model.flatpak_field.widget(),
        };
        try std.testing.expect(ctx.cmds.items[0].request_focus.eql(expected));
    }
}

test "tab views preserve input widgets and render without background work" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    for ([_]vxfw.Size{ .{ .width = 80, .height = 24 }, .{ .width = 40, .height = 12 } }) |size| {
        for (Tab.all) |tab| {
            model.active = tab;
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const surface = try model.widget().draw(.{
                .arena = arena.allocator(),
                .min = .{},
                .max = .{ .width = size.width, .height = size.height },
                .cell_size = .{ .width = 10, .height = 20 },
            });
            try std.testing.expectEqual(size, surface.size);
            const input = switch (tab) {
                .packages => model.text_field.widget(),
                .aur => model.aur_field.widget(),
                .upgrade, .settings => model.widget(),
                .flatpak => model.flatpak_field.widget(),
            };
            var found = surface.widget.eql(input);
            for (surface.children) |child| {
                found = found or child.surface.widget.eql(input);
                for (child.surface.children) |nested| {
                    found = found or nested.surface.widget.eql(input);
                }
            }
            try std.testing.expect(found);
        }
    }
}

test "updates view renders source rows and distinguishes query states" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.active = .upgrade;
    model.updates_checked = true;
    model.updates_parsed = try std.json.parseFromSlice(CheckUpdates, std.testing.allocator,
        \\{"Packages":[{"Name":"native","CurrentVersion":"1","NewVersion":"2"}],"Aur":[{"Name":"aur","Version":"2","NewVersion":"3"}],"Flatpak":[{"Id":"org.test.App","NewVersion":"4","InstallLevel":1}],"AppImage":[{"Name":"image","Version":"5","IsUpdateAvailable":true}]}
    , .{ .allocate = .alloc_always });
    model.updates_list.item_count = 4;
    try std.testing.expectEqual(@as(usize, 4), model.updates_parsed.?.value.count());
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
            const widget = Model.buildUpdateRow(model, index, 0) orelse return error.MissingUpdateRow;
            _ = try widget.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = 1 }));
        }
        try std.testing.expect(Model.buildUpdateRow(model, 4, 0) == null);
    }
    var view = model.updatesView();
    view.failed = true;
    try std.testing.expectEqualStrings("Update check failed — R: retry", try view.statusText(arena.allocator()));
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
    model.updates_job = job;
    model.updates_thread = try std.Thread.spawn(.{}, Worker.complete, .{job});
    job.done.store(true, .release);
    model.pollUpdates();
    try std.testing.expect(model.updates_job == null);
    try std.testing.expectEqual(@as(?u32, 1), model.updates_list.item_count);
    try std.testing.expectEqualStrings("test", model.updates_parsed.?.value.Packages[0].Name);

    // A failed refresh must remain a failure, retaining the previous owned data.
    const failed = try std.testing.allocator.create(UpdatesJob);
    failed.* = .{ .failed = true };
    model.updates_job = failed;
    model.updates_thread = try std.Thread.spawn(.{}, Worker.complete, .{failed});
    failed.done.store(true, .release);
    model.pollUpdates();
    try std.testing.expect(model.updates_failed);
    try std.testing.expectEqualStrings("test", model.updates_parsed.?.value.Packages[0].Name);

    // deinit owns an unpolled worker and its result.
    const pending = try std.testing.allocator.create(UpdatesJob);
    pending.* = .{ .result = try std.json.parseFromSlice(CheckUpdates, std.testing.allocator, "{}", .{}) };
    model.updates_job = pending;
    model.updates_thread = try std.Thread.spawn(.{}, Worker.complete, .{pending});
}

test "shared commands quit from every tab and modal" {
    const model = try Model.init(std.testing.allocator);
    defer {
        model.overlay = null;
        model.deinit();
    }
    var ctx: vxfw.EventContext = .{
        .io = undefined,
        .alloc = std.testing.allocator,
        .cmds = .empty,
    };
    defer ctx.cmds.deinit(std.testing.allocator);
    for (Tab.all) |tab| {
        model.active = tab;
        ctx.quit = false;
        ctx.consume_event = false;
        try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.escape } });
        try std.testing.expect(ctx.quit and ctx.consume_event);
    }
    var pkg: Package = .{ .Name = "test" };
    model.overlay = .{ .package = &pkg };
    ctx.quit = false;
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.escape } });
    try std.testing.expect(ctx.quit);
    var prompt: SudoPrompt = .{ .name = "test", .backend = .standard, .password = .empty };
    for ([_]SudoPrompt.State{ .entering, .running, .succeeded, .failed }) |state| {
        prompt.state = state;
        model.overlay = .{ .sudo = &prompt };
        ctx.quit = false;
        try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.escape } });
        try std.testing.expect(ctx.quit);
    }
    model.overlay = .pkgbuild;
    ctx.quit = false;
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.escape } });
    try std.testing.expect(ctx.quit);
    model.overlay = null;
    try std.testing.expect(commands.global(.{ .codepoint = vaxis.Key.left }, Tab.all.len) == null);
    try std.testing.expect(commands.global(.{ .codepoint = '1' }, Tab.all.len) == null);
}

test "updates action opens a native-only upgrade prompt" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.updates_checked = true;
    model.updates_parsed = try std.json.parseFromSlice(CheckUpdates, std.testing.allocator,
        \\{"Packages":[{"Name":"native","CurrentVersion":"1","NewVersion":"2"}],"Aur":[{"Name":"foreign"}]}
    , .{ .allocate = .alloc_always });
    const action = model.updatesView().handleKey(.{ .codepoint = 'u' });
    try std.testing.expectEqual(commands.Updates.upgrade_system, action.?);
    try model.upgradeSystemFromUpdates();
    const prompt = model.overlay.?.sudo;
    try std.testing.expectEqual(shelly_operation.Action.upgrade, prompt.action);
    try std.testing.expectEqual(OperationBackend.standard, prompt.backend);
    try std.testing.expectEqualStrings("system packages", prompt.name);
    model.closeOverlay();
    model.updates_failed = true;
    try std.testing.expect(model.updatesView().handleKey(.{ .codepoint = 'u' }) == null);
}

test "package refresh replaces borrowed data and preserves selection" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.parsed = try std.json.parseFromSlice([]Package, std.testing.allocator,
        \\[{"Name":"native","Repository":"repo","Version":"1","Installed":true}]
    , .{ .allocate = .alloc_always });
    model.packages = model.parsed.?.value;
    try model.rebuildFilter();
    try model.selected_packages.append(std.testing.allocator, model.packages[0].Name);
    model.load.result = try std.json.parseFromSlice([]Package, std.testing.allocator,
        \\[{"Name":"native","Repository":"repo","Version":"2","Installed":true}]
    , .{ .allocate = .alloc_always });
    model.load.done.store(true, .release);
    model.loading = true;
    _ = try model.pollLoad();
    try std.testing.expectEqualStrings("2", model.packages[0].Version);
    try std.testing.expectEqualStrings("native", model.selected_packages.items[0]);
    try std.testing.expect(model.selected_packages.items[0].ptr == model.packages[0].Name.ptr);
    try std.testing.expectEqual(@as(u32, 0), model.list_view.cursor);
}

test "PKGBUILD preview renders scrolls and returns to AUR details" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.active = .aur;
    var package = [_]AurPackage{.{ .Name = "demo" }};
    model.aur_packages = &package;
    model.pkgbuild_name = try std.testing.allocator.dupe(u8, "demo");
    const line = "echo a long source line with content and more content and more content and more content\n";
    var source_buffer: [line.len * 80]u8 = undefined;
    for (0..80) |index| @memcpy(source_buffer[index * line.len ..][0..line.len], line);
    const source = &source_buffer;
    model.pkgbuild_document = try pkgbuild_view.Document.init(std.testing.allocator, &.{.{ .Name = "demo", .PkgBuild = source }});
    model.pkgbuild_scroll.item_count = @intCast(model.pkgbuild_document.?.lines.len);
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
        const first = (try model.pkgbuildView().draw(ctx)).?;
        var state_view = model.pkgbuildView();
        state_view.loading = true;
        try std.testing.expectEqual(first.surface.size, (try state_view.draw(ctx)).?.surface.size);
        state_view.loading = false;
        state_view.failure = error.CommandFailed;
        try std.testing.expectEqual(first.surface.size, (try state_view.draw(ctx)).?.surface.size);
        var events: vxfw.EventContext = .{ .io = undefined, .alloc = std.testing.allocator, .cmds = .empty };
        defer events.cmds.deinit(std.testing.allocator);
        for (0..6) |_| {
            try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
            _ = try model.pkgbuildView().draw(ctx);
        }
        try std.testing.expect(model.pkgbuild_scroll.scroll.top > 0);
        const after = (try model.pkgbuildView().draw(ctx)).?;
        try std.testing.expectEqual(first.surface.size, after.surface.size);
    }
    model.closePkgbuild();
    try std.testing.expect(model.overlay.? == .aur);
    try std.testing.expectEqualStrings("demo", model.overlay.?.aur.Name);
}

test "PKGBUILD preview discards stale results and joins unpolled jobs" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.pkgbuild_name = try std.testing.allocator.dupe(u8, "new-target");
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
    model.pkgbuild_job = job;
    model.pkgbuild_thread = try std.Thread.spawn(.{}, Worker.finish, .{job});
    job.done.store(true, .release);
    var ctx: vxfw.EventContext = .{ .io = undefined, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);
    try model.pollPkgbuild(&ctx);
    try std.testing.expect(model.pkgbuild_document == null);
    try std.testing.expect(model.pkgbuild_job == null);
    const pending = try std.testing.allocator.create(PkgbuildJob);
    pending.* = .{
        .name = try std.testing.allocator.dupe(u8, "new-target"),
        .result = try std.json.parseFromSlice([]PkgBuild, std.testing.allocator,
            \\[{"Name":"new-target","PkgBuild":"echo new"}]
        , .{ .allocate = .alloc_always }),
    };
    model.pkgbuild_job = pending;
    model.pkgbuild_thread = try std.Thread.spawn(.{}, Worker.finish, .{pending});
    // Model.deinit joins and frees this unconsumed result.
}

test "AUR updates open a separate AUR upgrade prompt" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.settings.aur_enabled = true;
    model.updates_checked = true;
    model.updates_parsed = try std.json.parseFromSlice(CheckUpdates, std.testing.allocator,
        \\{"Packages":[],"Aur":[{"Name":"foreign","Version":"1","NewVersion":"2"}]}
    , .{ .allocate = .alloc_always });
    try std.testing.expect(model.updatesView().handleKey(.{ .codepoint = 'u' }) == null);
    try std.testing.expectEqual(commands.Updates.upgrade_aur, model.updatesView().handleKey(.{ .codepoint = 'a' }).?);
    try model.upgradeFromUpdates(.aur);
    try std.testing.expectEqual(OperationBackend.aur, model.overlay.?.sudo.backend);
    try std.testing.expectEqual(shelly_operation.Action.upgrade, model.overlay.?.sudo.action);
}

test "operation PKGBUILD review owns each revision and returns to progress" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    const prompt = try std.testing.allocator.create(SudoPrompt);
    prompt.* = .{
        .name = try std.testing.allocator.dupe(u8, "demo"),
        .backend = .aur,
        .password = .empty,
        .state = .running,
    };
    model.overlay = .{ .sudo = prompt };
    const first = try shelly_operation.decodeJson(std.testing.allocator,
        \\{"$kind":"q.pkgbuilddiff","QuestionId":"1","PackageName":"demo","OldPkgbuild":"pkgver=1","NewPkgbuild":"pkgver=2","DiffLines":["-pkgver=1","+pkgver=2"],"SourceFiles":{"demo.install":"post_install() {}"}}
    );
    try model.showOperationQuestion(first);
    try std.testing.expect(model.overlay.? == .pkgbuild);
    try std.testing.expect(model.pkgbuildView().review);
    try std.testing.expectEqual(pkgbuild_view.Action.approve, model.pkgbuildView().handleKey(.{ .codepoint = 'y' }).?);
    const text = try std.mem.join(std.testing.allocator, "\n", model.pkgbuild_document.?.lines);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "pkgver=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pkgver=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "demo.install") != null);
    model.finishOperationQuestion();
    try std.testing.expect(model.overlay.?.sudo == prompt);
    try std.testing.expect(model.operation_question == null);
    const second = try shelly_operation.decodeJson(std.testing.allocator,
        \\{"$kind":"q.pkgbuilddiff","QuestionId":"2","PackageName":"demo","OldPkgbuild":"","NewPkgbuild":"pkgver=3"}
    );
    try model.showOperationQuestion(second);
    try std.testing.expectEqualStrings("2", shelly_operation.questionId(model.operation_question.?.value.question));
    try std.testing.expectEqual(pkgbuild_view.Action.decline, model.pkgbuildView().handleKey(.{ .codepoint = 'n' }).?);
    // Model.deinit owns the suspended progress prompt and outstanding review.
}

test "installed package filters combine local text and installed state" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    var packages = [_]Package{
        .{ .Name = "editor", .Installed = true },
        .{ .Name = "editor-extra", .Installed = false },
        .{ .Name = "shell", .Installed = true },
    };
    model.packages = &packages;
    model.installed_only = true;
    try model.setQuery("editor");
    try std.testing.expectEqual(@as(usize, 1), model.filtered.items.len);
    try std.testing.expectEqualStrings("editor", model.filtered.items[0].Name);
    model.installed_only = false;
    try model.rebuildFilter();
    try std.testing.expectEqual(@as(usize, 2), model.filtered.items.len);
}

test "installed AUR list filters locally and opens the displayed package" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.settings.aur_enabled = true;
    const packages = [_]AurPackage{
        .{ .Name = "first", .Installed = true },
        .{ .Name = "editor-git", .Installed = true },
    };
    model.aur_packages = &packages;
    model.aur_installed_only = true;
    try model.aur_field.buf.insertSliceAtCursor("EDITOR");
    try model.rebuildAurFilter();
    try std.testing.expectEqual(@as(usize, 1), model.aur_filtered.items.len);
    try std.testing.expectEqualStrings("editor-git", model.aur_filtered.items[0].Name);
    var ctx: vxfw.EventContext = .{ .io = undefined, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);
    try Model.onAurSubmit(model, &ctx, "EDITOR");
    try std.testing.expectEqualStrings("editor-git", model.overlay.?.aur.Name);
    model.overlay = null;
    model.aur_field.buf.clearRetainingCapacity();
    try model.rebuildAurFilter();
    try std.testing.expectEqual(@as(usize, 2), model.aur_filtered.items.len);
}

test "settings determine source visibility before backend or native loading finishes" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    try std.testing.expectEqualSlices(Tab, &.{ .packages, .upgrade, .settings }, model.visibleTabs());
    var events: vxfw.EventContext = .{ .io = undefined, .alloc = std.testing.allocator, .cmds = .empty };
    defer events.cmds.deinit(std.testing.allocator);
    try model.setTab(.aur, &events);
    try std.testing.expectEqual(Tab.packages, model.active);
    model.applySettings(.{ .aur_enabled = true, .flatpak_enabled = true });
    try std.testing.expect(!model.flatpak_available);
    try std.testing.expect(model.loading);
    try std.testing.expectEqualSlices(Tab, Tab.all, model.visibleTabs());
    model.active = .flatpak;
    try model.focusActiveTab(&events);
    try std.testing.expect(events.cmds.items[events.cmds.items.len - 1].request_focus.eql(model.flatpak_field.widget()));
    model.applySettings(.{});
    try std.testing.expectEqual(Tab.packages, model.active);
    try std.testing.expectEqualSlices(Tab, Tab.always, model.visibleTabs());
}

test "Flatpak probe publishes independently and failure does not hide an enabled tab" {
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    model.settings.flatpak_enabled = true;
    var events: vxfw.EventContext = .{ .io = undefined, .alloc = allocator, .cmds = .empty };
    defer events.cmds.deinit(allocator);
    const ready = try allocator.create(FlatpakProbeJob);
    ready.* = .{ .done = .init(true) };
    model.flatpak_probe_job = ready;
    try model.pollFlatpakProbe(&events);
    try std.testing.expect(model.loading and !model.load.done.load(.acquire));
    try std.testing.expect(model.flatpak_available);
    model.active = .flatpak;
    const failed = try allocator.create(FlatpakProbeJob);
    failed.* = .{ .done = .init(true), .failure = error.CommandFailed };
    model.flatpak_probe_job = failed;
    try model.pollFlatpakProbe(&events);
    try std.testing.expect(!model.flatpak_available);
    try std.testing.expectEqual(Tab.flatpak, model.active);
    try std.testing.expect(model.tabEnabled(.flatpak));
    try std.testing.expectEqual(error.CommandFailed, model.flatpak_probe_error.?);
}

test "Flatpak browsing preserves scoped identity through refresh and filters locally" {
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    model.settings.flatpak_enabled = true;
    model.flatpak_available = true;
    model.active = .flatpak;
    model.flatpak_installed_only = true;
    model.flatpak_installed = try std.json.parseFromSlice([]flatpak.Flatpak, allocator,
        \\[{"Id":"org.example.Editor","InstallLevel":0,"Arch":"x86_64","Branch":"stable","Remote":"flathub"},{"Id":"org.example.Editor","InstallLevel":1,"Arch":"x86_64","Branch":"stable","Remote":"flathub"}]
    , .{ .allocate = .alloc_always });
    try model.rebuildFlatpakFilter();
    try std.testing.expectEqual(@as(usize, 2), model.flatpak_rows.items.len);
    try std.testing.expect(!model.flatpak_rows.items[0].sameIdentity(model.flatpak_rows.items[1]));
    model.flatpak_list.jumpToItem(1);
    model.overlay = .{ .flatpak = model.flatpak_rows.items[1] };
    const replacement = try allocator.create(FlatpakJob);
    replacement.* = .{ .installed_only = true, .done = .init(true), .installed = try std.json.parseFromSlice([]flatpak.Flatpak, allocator,
        \\[{"Id":"org.example.Editor","InstallLevel":1,"Arch":"x86_64","Branch":"stable","Remote":"flathub"},{"Id":"org.example.Editor","InstallLevel":0,"Arch":"x86_64","Branch":"stable","Remote":"flathub"}]
    , .{ .allocate = .alloc_always }) };
    model.flatpak_job = replacement;
    try model.pollFlatpak();
    try std.testing.expect(model.overlay == null);
    try std.testing.expectEqual(@as(usize, 0), model.flatpak_list.cursor);
    try std.testing.expectEqual(flatpak.InstallLevel.user, model.flatpak_rows.items[0].installed.InstallLevel);
    try model.flatpak_field.buf.insertSliceAtCursor("EDITOR");
    try model.rebuildFlatpakFilter();
    try std.testing.expectEqual(@as(usize, 2), model.flatpak_rows.items.len);
    model.flatpak_field.buf.clearRetainingCapacity();
    try model.flatpak_field.buf.insertSliceAtCursor("missing");
    try model.rebuildFlatpakFilter();
    try std.testing.expectEqual(@as(usize, 0), model.flatpak_rows.items.len);
}

test "Flatpak browsing separates failure empty results and unconsumed job cleanup" {
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    const empty = try allocator.create(FlatpakJob);
    empty.* = .{ .installed_only = false, .done = .init(true), .catalog = try std.json.parseFromSlice([]flatpak.AppstreamApp, allocator, "[]", .{}) };
    model.flatpak_job = empty;
    try model.pollFlatpak();
    try std.testing.expect(model.flatpakView().checked);
    try std.testing.expect(model.flatpakView().failure == null);
    const failed = try allocator.create(FlatpakJob);
    failed.* = .{ .installed_only = false, .done = .init(true), .failure = error.CommandFailed };
    model.flatpak_job = failed;
    try model.pollFlatpak();
    try std.testing.expectEqual(error.CommandFailed, model.flatpakView().failure.?);
    try std.testing.expect(!model.flatpakView().checked);
    const unconsumed = try allocator.create(FlatpakJob);
    unconsumed.* = .{ .installed_only = true, .installed = try std.json.parseFromSlice([]flatpak.Flatpak, allocator, "[{\"Id\":\"org.example.App\"}]", .{ .allocate = .alloc_always }) };
    model.flatpak_job = unconsumed;
    const Worker = struct {
        fn finish(job: *FlatpakJob) void {
            job.done.store(true, .release);
        }
    };
    model.flatpak_thread = try std.Thread.spawn(.{}, Worker.finish, .{unconsumed});
}

test "Flatpak catalog details retain remote scopes and Enter opens the selected app" {
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    model.active = .flatpak;
    model.settings.flatpak_enabled = true;
    model.flatpak_available = true;
    model.flatpak_catalog = try std.json.parseFromSlice([]flatpak.AppstreamApp, allocator,
        \\[{"Id":"org.example.App","Name":"Example","Summary":"An editor","Remotes":[{"Name":"flathub","Scope":0},{"Name":"flathub","Scope":1}]}]
    , .{ .allocate = .alloc_always });
    try model.rebuildFlatpakFilter();
    var events: vxfw.EventContext = .{ .io = undefined, .alloc = allocator, .cmds = .empty };
    defer events.cmds.deinit(allocator);
    try Model.typeErasedEventHandler(model, &events, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try std.testing.expectEqualStrings("org.example.App", model.overlay.?.flatpak.title());
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const details = try model.overlay.?.flatpak.details(arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, details, "flathub (system)") != null);
    try std.testing.expect(std.mem.indexOf(u8, details, "flathub (user)") != null);
    vxfw.DrawContext.init(.unicode);
    for ([_]vxfw.Size{ .{ .width = 80, .height = 24 }, .{ .width = 40, .height = 12 } }) |size| {
        _ = try model.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = size.width, .height = size.height }, .cell_size = .{ .width = 10, .height = 20 } });
    }
}

test "Flatpak install chooses remote scope and owns confirmation target" {
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    model.settings.flatpak_enabled = true;
    model.flatpak_available = true;
    const app: flatpak.AppstreamApp = .{
        .Id = "org.example.App",
        .Name = "Example",
        .Remotes = &.{ .{ .Name = "system-remote", .Scope = .system }, .{ .Name = "user-remote", .Scope = .user } },
    };
    model.overlay = .{ .flatpak = .{ .catalog = &app } };
    var events: vxfw.EventContext = .{ .io = undefined, .alloc = allocator, .cmds = .empty };
    defer events.cmds.deinit(allocator);
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = 'i' } });
    try std.testing.expect(model.overlay.? == .flatpak_install);
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    try std.testing.expectEqual(@as(usize, 1), model.overlay.?.flatpak_install.selected);
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const picker = try flatpak_view.drawInstallChoices(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 24 }, .cell_size = .{ .width = 10, .height = 20 } }, &app, 1);
    try std.testing.expect(picker != null);
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    const prompt = model.overlay.?.sudo;
    try std.testing.expect(!prompt.elevated);
    try std.testing.expectEqual(flatpak.InstallLevel.user, prompt.flatpak_target.?.scope);
    try std.testing.expectEqualStrings("user-remote", prompt.flatpak_target.?.remote);
    try std.testing.expectEqualStrings("org.example.App", prompt.name);
    try std.testing.expect(model.install_job == null);
    model.closeOverlay();
    try model.openFlatpakPrompt(.install, app.Id, .{ .scope = .system, .remote = "system-remote" });
    try std.testing.expect(model.overlay.?.sudo.elevated);
}

test "Flatpak removal copies exact identity and updates require backend availability" {
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    model.settings.flatpak_enabled = true;
    model.flatpak_available = true;
    var apps = try std.json.parseFromSlice([]flatpak.Flatpak, allocator,
        \\[{"Id":"org.example.App","Remote":"flathub","InstallLevel":1,"Kind":0,"Arch":"x86_64","Branch":"beta","FullRef":"app/org.example.App/x86_64/beta"}]
    , .{ .allocate = .alloc_always });
    model.overlay = .{ .flatpak = .{ .installed = &apps.value[0] } };
    var events: vxfw.EventContext = .{ .io = undefined, .alloc = allocator, .cmds = .empty };
    defer events.cmds.deinit(allocator);
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = 'r' } });
    apps.deinit();
    const prompt = model.overlay.?.sudo;
    try std.testing.expectEqual(shelly_operation.Action.remove, prompt.action);
    try std.testing.expectEqualStrings("app/org.example.App/x86_64/beta", prompt.flatpak_target.?.reference);
    try std.testing.expect(!prompt.elevated);
    model.closeOverlay();
    model.updates_parsed = try std.json.parseFromSlice(CheckUpdates, allocator, "{\"Flatpak\":[{\"Id\":\"org.example.App\"}]}", .{ .allocate = .alloc_always });
    try std.testing.expectEqual(commands.Updates.upgrade_flatpak, model.updatesView().handleKey(.{ .codepoint = 'f' }).?);
    try model.upgradeFromUpdates(.flatpak);
    try std.testing.expectEqual(shelly_operation.Action.upgrade, model.overlay.?.sudo.action);
    try std.testing.expect(!model.overlay.?.sudo.elevated);
    model.closeOverlay();
    model.flatpak_available = false;
    try std.testing.expect(model.updatesView().handleKey(.{ .codepoint = 'f' }) == null);
    try model.upgradeFromUpdates(.flatpak);
    try std.testing.expect(model.overlay == null);
}

test "Flatpak operation completion refreshes Flatpak data without changing native flags" {
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    var packages = [_]Package{.{ .Name = "org.example.App", .Installed = false }};
    model.packages = &packages;
    var env: std.process.Environ.Map = .init(allocator);
    defer env.deinit();
    const job = try std.heap.page_allocator.create(shelly_operation.Operation);
    job.* = .{
        .arena = .init(std.heap.page_allocator),
        .done = .init(true),
        .request = .{ .shelly_bin = "unused", .environ_map = &env, .backend = "flatpak", .name = "org.example.App", .password = "" },
    };
    model.install_job = job;
    try std.testing.expect(!try model.pollInstall());
    try std.testing.expect(model.refresh_flatpak_after_operation);
    try std.testing.expect(!model.refresh_after_upgrade);
    try std.testing.expect(!packages[0].Installed);
}

test "combined update shortcut opens an authenticated prompt even for an empty cached check" {
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    model.updates_parsed = try std.json.parseFromSlice(CheckUpdates, allocator, "{}", .{});
    const key: vaxis.Key = .{ .codepoint = 'g' };
    try std.testing.expectEqual(commands.Updates.upgrade_all, model.updatesView().handleKey(key).?);
    try model.upgradeFromUpdates(.all);
    const prompt = model.overlay.?.sudo;
    try std.testing.expectEqual(OperationBackend.all, prompt.backend);
    try std.testing.expect(prompt.elevated);
    try std.testing.expect(!prompt.include_flatpak);
    try std.testing.expectEqualStrings("all enabled package sources", prompt.name);
    model.closeOverlay();
    model.settings.flatpak_enabled = true;
    model.flatpak_available = true;
    try model.upgradeFromUpdates(.all);
    try std.testing.expect(model.overlay.?.sudo.include_flatpak);
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try model.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 24 }, .cell_size = .{ .width = 10, .height = 20 } });
    model.closeOverlay();
    model.updates_failed = true;
    try std.testing.expect(model.updatesView().handleKey(key) == null);
    try model.upgradeFromUpdates(.all);
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
            .request = .{ .action = .upgrade, .shelly_bin = "unused", .environ_map = &env, .backend = "all", .name = "combined upgrade", .password = "", .include_flatpak = include_flatpak, .include_aur = true },
        };
        model.install_job = job;
        try std.testing.expect(!try model.pollInstall());
        try std.testing.expect(model.refresh_after_upgrade);
        try std.testing.expect(model.refresh_aur_after_operation);
        try std.testing.expect(model.refresh_updates_after_operation);
        try std.testing.expectEqual(include_flatpak, model.refresh_flatpak_after_operation);
    }
}

test "settings persist before source visibility changes and failed saves keep the active choice" {
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
    const model = try Model.init(allocator);
    defer model.deinit();
    model.loadSettings(io, &env);
    try std.testing.expect(model.settings.eql(.{}));
    model.active = .settings;
    var ctx: vxfw.EventContext = .{ .io = io, .alloc = allocator, .cmds = .empty };
    defer ctx.cmds.deinit(allocator);
    try model.toggleSetting(&ctx);
    try std.testing.expect(model.settings.aur_enabled);
    const restarted = try Model.init(allocator);
    defer restarted.deinit();
    restarted.loadSettings(io, &env);
    try std.testing.expect(restarted.settings.aur_enabled);
    try std.testing.expect(restarted.tabEnabled(.aur));
    try std.testing.expect(restarted.flatpak_probe_job == null);
    var file = try std.Io.Dir.cwd().createFile(io, model.settings_store.?.path, .{ .truncate = true });
    try file.writeStreamingAll(io, "{\"AurEnabled\":\"invalid\"}");
    file.close(io);
    try model.toggleSetting(&ctx);
    try std.testing.expectEqual(error.InvalidSettings, model.settings_failure.?);
    try std.testing.expect(model.settings.aur_enabled);
}

test "settings changes reject late update results and disabled source data" {
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    model.settings = .{ .aur_enabled = true, .flatpak_enabled = true };
    model.flatpak_available = true;
    model.updates_parsed = try std.json.parseFromSlice(CheckUpdates, allocator, "{\"Packages\":[{\"Name\":\"native\"}],\"Aur\":[{\"Name\":\"aur\"}],\"Flatpak\":[{\"Id\":\"org.example.App\"}]}", .{ .allocate = .alloc_always });
    model.applySettings(.{});
    try std.testing.expectEqual(@as(usize, 1), model.updates_parsed.?.value.count());
    try std.testing.expect(!model.updatesView().canUpgradeAur());
    try std.testing.expect(!model.updatesView().canUpgradeFlatpak());
    const job = try allocator.create(UpdatesJob);
    job.* = .{ .aur_enabled = true, .flatpak_enabled = true, .done = .init(true), .result = try std.json.parseFromSlice(CheckUpdates, allocator, "{\"Aur\":[{\"Name\":\"stale\"}]}", .{ .allocate = .alloc_always }) };
    const Worker = struct {
        fn finish(value: *UpdatesJob) void {
            value.done.store(true, .release);
        }
    };
    model.updates_job = job;
    model.updates_thread = try std.Thread.spawn(.{}, Worker.finish, .{job});
    model.pollUpdates();
    try std.testing.expect(!model.updates_checked);
    try std.testing.expectEqualStrings("native", model.updates_parsed.?.value.Packages[0].Name);
}

test "packages split details follow selection and remain within the page on resize" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    var packages = [_]Package{
        .{ .Name = "first", .Description = "First package", .Repository = "core" },
        .{ .Name = "second", .Description = "Second package", .Repository = "extra", .Installed = true },
    };
    model.packages = &packages;
    try model.rebuildFilter();
    model.loading = false;
    try std.testing.expectEqualStrings("first", model.packagesView().selected.?.Name);
    model.list_view.cursor = 1;
    try std.testing.expectEqualStrings("second", model.packagesView().selected.?.Name);

    var events: vxfw.EventContext = .{ .io = undefined, .alloc = std.testing.allocator, .cmds = .empty };
    defer events.cmds.deinit(std.testing.allocator);
    model.package_list_active = true;
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = vaxis.Key.right } });
    try std.testing.expect(model.packagesView().details_active);
    for ([_]vxfw.Size{ .{ .width = 120, .height = 30 }, .{ .width = 80, .height = 24 }, .{ .width = 40, .height = 12 }, .{ .width = 1, .height = 4 } }) |size| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const ctx: vxfw.DrawContext = .{
            .arena = arena.allocator(),
            .min = .{},
            .max = .{ .width = size.width, .height = size.height },
            .cell_size = .{ .width = 10, .height = 20 },
        };
        var children: std.ArrayList(vxfw.SubSurface) = .empty;
        try model.packagesView().appendContent(ctx, &children);
        var details_on_right = false;
        var list_on_left = false;
        for (children.items) |child| {
            try std.testing.expect(child.origin.col >= 0 and child.origin.row >= 0);
            try std.testing.expect(@as(usize, @intCast(child.origin.col)) + child.surface.size.width <= size.width);
            try std.testing.expect(@as(usize, @intCast(child.origin.row)) + child.surface.size.height <= size.height - 1);
            if (child.origin.col > 0) {
                details_on_right = true;
                try std.testing.expectEqual(@as(i17, 1), child.origin.row);
                try std.testing.expectEqual(size.height - 2, child.surface.size.height);
            }
            const content_row: i17 = if (size.width >= 2 and size.height >= 8) 4 else 2;
            if (child.origin.row == content_row) {
                if (child.surface.widget.eql(model.list_view.widget())) list_on_left = true;
                for (child.surface.children) |nested| {
                    if (nested.surface.widget.eql(model.list_view.widget())) list_on_left = true;
                }
            }
        }
        try std.testing.expectEqual(size.width >= 64, details_on_right);
        try std.testing.expectEqual(size.width >= 64, list_on_left);
    }
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = 'q' } });
    try std.testing.expect(model.overlay == null);
    try std.testing.expectEqual(@as(u32, 1), model.list_view.cursor);
    try model.setQuery("no matches");
    try std.testing.expect(model.packagesView().selected == null);
}

test "packages details scroll and retain the selected install and removal target" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    var packages = [_]Package{.{ .Name = "installed", .Installed = true }};
    model.packages = &packages;
    try model.rebuildFilter();
    model.loading = false;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try model.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 12 }, .cell_size = .{ .width = 10, .height = 20 } });
    var events: vxfw.EventContext = .{ .io = undefined, .alloc = std.testing.allocator, .cmds = .empty };
    defer events.cmds.deinit(std.testing.allocator);
    model.package_list_active = true;
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = vaxis.Key.right } });
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    try std.testing.expect(model.package_details_scroll.scroll.pending_lines > 0);
    try std.testing.expectEqual(@as(u32, 0), model.list_view.cursor);
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = 'r' } });
    try std.testing.expect(model.overlay.? == .sudo);
    try std.testing.expectEqualStrings("installed", model.overlay.?.sudo.name);
    try std.testing.expectEqual(shelly_operation.Action.remove, model.overlay.?.sudo.action);
}

test "package pane arrows preserve search editing and navigate list and details" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    var packages = [_]Package{ .{ .Name = "first" }, .{ .Name = "second" } };
    model.packages = &packages;
    try model.rebuildFilter();
    var ctx: vxfw.EventContext = .{ .io = undefined, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);
    const left: vaxis.Key = .{ .codepoint = vaxis.Key.left };
    const right: vaxis.Key = .{ .codepoint = vaxis.Key.right };
    try std.testing.expect(commands.packageNavigation(left, true) == null);
    try std.testing.expect(commands.packageNavigation(right, true) == null);
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = right });
    try std.testing.expect(model.overlay == null);
    try std.testing.expect(!model.package_list_active);
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    try std.testing.expect(model.package_list_active);
    const selected = model.list_view.cursor;
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = right });
    try std.testing.expect(model.packagesView().details_active);
    try std.testing.expectEqualStrings(model.filtered.items[selected].Name, model.overlay.?.package.Name);
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = left });
    try std.testing.expect(model.overlay == null);
    try std.testing.expect(model.package_list_active);
    try std.testing.expectEqual(selected, model.list_view.cursor);
    model.package_list_active = true;
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = .{ .codepoint = 'a', .text = "a" } });
    try std.testing.expect(model.package_list_active);
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = .{ .codepoint = '/', .text = "/" } });
    try std.testing.expect(!model.package_list_active);
    try std.testing.expectEqual(selected, model.list_view.cursor);
    model.package_list_active = true;
    model.list_view.cursor = 0;
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.up } });
    try std.testing.expect(!model.package_list_active);
    try std.testing.expectEqual(@as(u32, 0), model.list_view.cursor);
}

test "package list actions open prompts while search letters stay editable" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    var packages = [_]Package{ .{ .Name = "available" }, .{ .Name = "installed", .Installed = true } };
    model.packages = &packages;
    try model.rebuildFilter();
    model.loading = false;
    var ctx: vxfw.EventContext = .{ .io = undefined, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);
    for ([_]u21{ 'i', 'r' }) |letter| {
        try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = .{ .codepoint = letter, .text = if (letter == 'i') "i" else "r" } });
        try std.testing.expect(model.overlay == null);
    }
    model.package_list_active = true;
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = .{ .codepoint = 'r' } });
    try std.testing.expect(model.overlay == null);
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = .{ .codepoint = 'i' } });
    try std.testing.expectEqualStrings("available", model.overlay.?.sudo.name);
    try std.testing.expectEqual(shelly_operation.Action.install, model.overlay.?.sudo.action);
    try std.testing.expect(model.install_job == null);
    model.closeOverlay();
    model.list_view.cursor = 1;
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = .{ .codepoint = 'r' } });
    try std.testing.expectEqualStrings("installed", model.overlay.?.sudo.name);
    try std.testing.expectEqual(shelly_operation.Action.remove, model.overlay.?.sudo.action);
    try std.testing.expect(model.install_job == null);
}

test "tab bar centers labels and retains the active tab on narrow terminals" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.settings = .{ .aur_enabled = true, .flatpak_enabled = true };
    model.active = .settings;
    for ([_]u16{ 120, 80, 40, 18, 3 }) |width| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const widget = try model.drawTabBar(arena.allocator());
        const surface = try widget.draw(.{
            .arena = arena.allocator(),
            .min = .{},
            .max = .{ .width = width, .height = 3 },
            .cell_size = .{ .width = 10, .height = 20 },
        });
        try std.testing.expectEqual(width, surface.size.width);
        try std.testing.expectEqual(@as(u16, 3), surface.size.height);
        const bar: *TabBar = @ptrCast(@alignCast(widget.userdata));
        try std.testing.expect(bar.first_visible + bar.rich.text.len > 4);
        var total: usize = bar.rich.text.len -| 1;
        for (bar.rich.text) |span| total += span.text.len;
        const padding: usize = if (width >= 8) 4 else 0;
        try std.testing.expectEqual(@as(i16, @intCast((width - total - padding) / 2 + padding / 2)), bar.start_col);
        try std.testing.expect(bar.rich.text[bar.rich.text.len - 1].style.reverse);
        if (width >= 8) {
            var corners: usize = 0;
            var caps: usize = 0;
            for (surface.buffer) |cell| {
                if (std.mem.eql(u8, cell.char.grapheme, "┌") or std.mem.eql(u8, cell.char.grapheme, "┐")) corners += 1;
                if (std.mem.eql(u8, cell.char.grapheme, "◖") or std.mem.eql(u8, cell.char.grapheme, "◗")) caps += 1;
            }
            try std.testing.expectEqual(@as(usize, 2), corners);
            try std.testing.expectEqual(@as(usize, 0), caps);
        }
    }
}

test "centered tab mouse targets exclude borders and padding" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const widget = try model.drawTabBar(arena.allocator());
    _ = try widget.draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 100, .height = 3 }, .cell_size = .{ .width = 10, .height = 20 } });
    const bar: *TabBar = @ptrCast(@alignCast(widget.userdata));
    var ctx: vxfw.EventContext = .{ .io = undefined, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);
    var col = bar.start_col;
    for (bar.rich.text[0 .. bar.rich.text.len - 1]) |span| col += @intCast(span.text.len + 1);
    try TabBar.handleEvent(bar, &ctx, .{ .mouse = .{ .button = .left, .type = .press, .col = @intCast(col), .row = 0, .mods = .{} } });
    try std.testing.expectEqual(Tab.packages, model.active);
    try TabBar.handleEvent(bar, &ctx, .{ .mouse = .{ .button = .left, .type = .press, .col = 0, .row = 1, .mods = .{} } });
    try std.testing.expectEqual(Tab.packages, model.active);
    try TabBar.handleEvent(bar, &ctx, .{ .mouse = .{ .button = .left, .type = .press, .col = @intCast(col), .row = 1, .mods = .{} } });
    try std.testing.expectEqual(Tab.settings, model.active);
}

test "native batch selection survives filtering and confirms mixed targets" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    var packages = [_]Package{
        .{ .Name = "available" },                            .{ .Name = "installed", .Installed = true },
        .{ .Name = "another-installed", .Installed = true },
    };
    model.packages = &packages;
    model.loading = false;
    try model.rebuildFilter();
    var ctx: vxfw.EventContext = .{ .io = undefined, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);
    const enter: vxfw.Event = .{ .key_press = .{ .codepoint = vaxis.Key.enter } };
    try Model.typeErasedCaptureHandler(model, &ctx, enter);
    try std.testing.expect(model.overlay == null);
    try std.testing.expect(model.packageMarked("available"));
    model.list_view.cursor = 1;
    try Model.typeErasedCaptureHandler(model, &ctx, enter);
    try std.testing.expectEqual(@as(usize, 2), model.selected_packages.items.len);
    try model.setQuery("another");
    try std.testing.expectEqual(@as(usize, 1), model.filtered.items.len);
    try std.testing.expectEqual(@as(usize, 2), model.selected_packages.items.len);
    try std.testing.expectEqual(@as(usize, 1), model.packagesView().selected_installed);
    try model.openNativePrompt(.install);
    var prompt = model.overlay.?.sudo;
    try std.testing.expectEqualStrings("available", prompt.targets[0]);
    try std.testing.expectEqualStrings("installed", prompt.targets[1]);
    try std.testing.expect(std.mem.indexOf(u8, prompt.review_text, "Install 1 available packages; reinstall 1 installed packages.") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt.review_text, "Reinstall: installed") != null);
    // Confirmation owns its targets, independently of the source records.
    packages[0].Name = "changed-source-name";
    try std.testing.expectEqualStrings("available", prompt.targets[0]);
    packages[0].Name = "available";
    model.closeOverlay();
    try model.openNativePrompt(.remove);
    prompt = model.overlay.?.sudo;
    try std.testing.expectEqual(@as(usize, 1), prompt.targets.len);
    try std.testing.expectEqualStrings("installed", prompt.targets[0]);
    try std.testing.expect(std.mem.indexOf(u8, prompt.review_text, "1 uninstalled selections excluded.") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt.review_text, "Remove: installed") != null);
    model.closeOverlay();
    model.clearCompletedSelection(&.{"installed"});
    try std.testing.expectEqual(@as(usize, 1), model.selected_packages.items.len);
    try std.testing.expect(model.packageMarked("available"));
    try model.openNativePrompt(.remove);
    try std.testing.expect(model.overlay == null);
    try std.testing.expect(std.mem.indexOf(u8, model.notice, "No installed packages") != null);
}

test "native batch confirmation scrolls long reviews and keeps password entry visible" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    var packages: [30]Package = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (&packages, 0..) |*pkg, i| pkg.* = .{ .Name = try std.fmt.allocPrint(arena.allocator(), "package-{d}", .{i}) };
    model.packages = &packages;
    model.loading = false;
    try model.rebuildFilter();
    for (packages) |pkg| try model.selected_packages.append(std.testing.allocator, pkg.Name);
    try model.openNativePrompt(.install);
    const prompt = model.overlay.?.sudo;
    const drawn = try model.widget().draw(.{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 80, .height = 24 },
        .cell_size = .{ .width = 10, .height = 20 },
    });
    try std.testing.expectEqual(@as(u16, 24), drawn.size.height);
    try std.testing.expect(prompt.panel.scroll.scroll.has_more_vertical);
    var ctx: vxfw.EventContext = .{ .io = undefined, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    try std.testing.expect(prompt.panel.scroll.scroll.pending_lines > 0);
    try std.testing.expectEqual(@as(usize, 0), prompt.password.items.len);
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = .{ .codepoint = 'q', .mods = .{ .ctrl = true } } });
    try std.testing.expect(model.overlay == null);
    try std.testing.expectEqual(@as(usize, 30), model.selected_packages.items.len);
}

test "native batch completion refreshes actual state and clears only successful targets" {
    for ([_]bool{ false, true }) |failed| {
        const model = try Model.init(std.testing.allocator);
        defer model.deinit();
        var packages = [_]Package{ .{ .Name = "available" }, .{ .Name = "installed", .Installed = true } };
        model.packages = &packages;
        try model.selected_packages.appendSlice(std.testing.allocator, &.{ "available", "installed" });
        var env: std.process.Environ.Map = .init(std.testing.allocator);
        defer env.deinit();
        const job = try std.heap.page_allocator.create(shelly_operation.Operation);
        job.* = .{
            .arena = .init(std.heap.page_allocator),
            .done = .init(true),
            .result = .{ .failed = failed },
            .request = .{ .shelly_bin = "unused", .environ_map = &env, .backend = "standard", .action = .remove, .name = "installed", .targets = &.{"installed"}, .password = "" },
        };
        model.install_job = job;
        try std.testing.expect(!try model.pollInstall());
        try std.testing.expect(model.refresh_after_upgrade);
        try std.testing.expect(model.refresh_updates_after_operation);
        try std.testing.expect(packages[1].Installed); // No optimistic batch result.
        try std.testing.expect(model.packageMarked("available"));
        try std.testing.expectEqual(failed, model.packageMarked("installed"));
    }
}

test "operation panel fits content below browsing across stages" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    var packages = [_]Package{.{ .Name = "example" }};
    model.packages = &packages;
    model.loading = false;
    try model.rebuildFilter();
    try model.openNativePrompt(.install);
    const prompt = model.overlay.?.sudo;
    for ([_]vxfw.Size{ .{ .width = 80, .height = 24 }, .{ .width = 120, .height = 40 }, .{ .width = 40, .height = 12 } }) |size| {
        for ([_]SudoPrompt.State{ .entering, .running, .succeeded, .failed, .declined }) |state| {
            prompt.state = state;
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const drawn = try model.widget().draw(.{
                .arena = arena.allocator(),
                .min = .{},
                .max = .{ .width = size.width, .height = size.height },
                .cell_size = .{ .width = 10, .height = 20 },
            });
            const panel = drawn.children[drawn.children.len - 2];
            try std.testing.expectEqual(@as(i17, 0), panel.origin.col);
            try std.testing.expectEqual(size.width, panel.surface.size.width);
            try std.testing.expectEqual(@as(usize, size.height - 1), @as(usize, @intCast(panel.origin.row)) + panel.surface.size.height);
            try std.testing.expectEqual(@as(u8, 0), panel.z_index);
            for (drawn.children[0 .. drawn.children.len - 2]) |child| {
                try std.testing.expect(child.origin.row + child.surface.size.height <= panel.origin.row);
            }
            try std.testing.expect(panel.surface.size.height <= 9);
        }
    }
}

test "operation completion and dismissal restore the browsing shortcut footer" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    runtime.io = threaded.io();
    defer runtime.io = undefined;
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    var packages = [_]Package{.{ .Name = "example" }};
    model.packages = &packages;
    model.loading = false;
    model.package_list_active = true;
    try model.rebuildFilter();
    try model.openNativePrompt(.install);
    const prompt = model.overlay.?.sudo;
    prompt.state = .running;
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    const job = try std.heap.page_allocator.create(shelly_operation.Operation);
    job.* = .{
        .arena = .init(std.heap.page_allocator),
        .done = .init(true),
        .request = .{ .shelly_bin = "unused", .environ_map = &env, .backend = "standard", .action = .install, .name = "example", .targets = &.{"example"}, .password = "" },
    };
    model.install_job = job;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(std.mem.indexOf(u8, try model.statusText(arena.allocator()), "Enter: select") != null);
    try std.testing.expect(!try model.pollInstall());
    try std.testing.expectEqual(SudoPrompt.State.succeeded, prompt.state);
    try std.testing.expectEqualStrings("", model.notice);
    try std.testing.expect(std.mem.indexOf(u8, try model.statusText(arena.allocator()), "Enter: select") != null);
    try model.setNotice("Stale operation notice");
    var ctx: vxfw.EventContext = .{ .io = undefined, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = .{ .codepoint = 'q' } });
    try std.testing.expect(model.overlay == null);
    try std.testing.expectEqualStrings("", model.notice);
    try std.testing.expect(std.mem.indexOf(u8, try model.statusText(arena.allocator()), "Enter: select") != null);
}

test "F1 help replaces details and restores selection focus and scroll" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    var packages = [_]Package{.{ .Name = "example" }};
    model.packages = &packages;
    model.loading = false;
    try model.rebuildFilter();
    model.package_list_active = true;
    model.package_details_cursor = 0;
    model.package_details_scroll.scroll.vertical_offset = -2;
    model.overlay = .{ .package = &packages[0] };
    var events: vxfw.EventContext = .{ .io = undefined, .alloc = std.testing.allocator, .cmds = .empty };
    defer events.cmds.deinit(std.testing.allocator);
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = vaxis.Key.f1 } });
    try std.testing.expect(model.help_open);
    try std.testing.expect(events.cmds.items[events.cmds.items.len - 1].request_focus.eql(model.widget()));
    for ([_]vxfw.Size{ .{ .width = 80, .height = 24 }, .{ .width = 40, .height = 12 } }) |size| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const surface = try model.widget().draw(.{
            .arena = arena.allocator(),
            .min = .{},
            .max = .{ .width = size.width, .height = size.height },
            .cell_size = .{ .width = 10, .height = 20 },
        });
        var help_found = false;
        for (surface.children) |child| for (child.surface.children) |nested| {
            if (nested.surface.widget.eql(model.help_panel.scroll.widget())) {
                help_found = true;
                try std.testing.expectEqual(size.width >= 64, child.origin.col > 0);
            }
        };
        try std.testing.expect(help_found);
        try std.testing.expectEqual(@as(i17, -2), model.package_details_scroll.scroll.vertical_offset);
    }
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = vaxis.Key.f1 } });
    try std.testing.expect(!model.help_open);
    try std.testing.expect(model.package_list_active);
    try std.testing.expectEqualStrings("example", model.overlay.?.package.Name);
    try std.testing.expectEqual(@as(i17, -2), model.package_details_scroll.scroll.vertical_offset);
}

test "help and footer update live bindings without reopening help" {
    vxfw.DrawContext.init(.unicode);
    const original = commands.bindings;
    defer commands.bindings = original;
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    var packages = [_]Package{.{ .Name = "example" }};
    model.packages = &packages;
    model.loading = false;
    model.package_list_active = true;
    try model.rebuildFilter();
    var events: vxfw.EventContext = .{ .io = undefined, .alloc = std.testing.allocator, .cmds = .empty };
    defer events.cmds.deinit(std.testing.allocator);
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = vaxis.Key.f1 } });
    model.help_panel.context = model.commandContext();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const before = try model.help_panel.text(arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, before, "Enter: Toggle selection") != null);
    commands.bindings.select = .{ .codepoint = 'v' };
    commands.bindings.help = .{ .codepoint = vaxis.Key.f2 };
    const after = try model.help_panel.text(arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, after, "V: Toggle selection") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "F2: Open/close help") != null);
    try std.testing.expect(commands.packageNavigation(.{ .codepoint = 'v' }, false).? == .select);
    try std.testing.expect(commands.packageNavigation(.{ .codepoint = vaxis.Key.enter }, false) == null);
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = vaxis.Key.f2 } });
    try std.testing.expect(!model.help_open);
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = 'v', .text = "v" } });
    try std.testing.expect(model.packageMarked("example"));
    var context = model.commandContext();
    context.selected_count = 0;
    const footer = try footer_view.draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 100, .height = 1 }, .cell_size = .{ .width = 10, .height = 20 } }, context, null);
    var main: std.ArrayList(u8) = .empty;
    for (footer.children[0].surface.buffer) |cell| try main.appendSlice(arena.allocator(), cell.char.grapheme);
    try std.testing.expect(std.mem.indexOf(u8, main.items, "V Select") != null);
    var help: std.ArrayList(u8) = .empty;
    for (footer.children[1].surface.buffer) |cell| try help.appendSlice(arena.allocator(), cell.char.grapheme);
    try std.testing.expectEqualStrings("F2 Help", help.items);
}

test "help preserves authentication input and follows operation stages" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    var packages = [_]Package{.{ .Name = "example" }};
    model.packages = &packages;
    model.loading = false;
    try model.rebuildFilter();
    try model.openNativePrompt(.install);
    const prompt = model.overlay.?.sudo;
    try prompt.password.appendSlice(std.testing.allocator, "fixture-secret");
    var events: vxfw.EventContext = .{ .io = undefined, .alloc = std.testing.allocator, .cmds = .empty };
    defer events.cmds.deinit(std.testing.allocator);
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = vaxis.Key.f1 } });
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = 'x', .text = "x" } });
    try std.testing.expectEqualStrings("fixture-secret", prompt.password.items);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 24 }, .cell_size = .{ .width = 10, .height = 20 } };
    _ = try model.widget().draw(ctx);
    try std.testing.expectEqual(commands.Mode.authentication, model.help_panel.context.mode);
    prompt.state = .running;
    _ = try model.widget().draw(ctx);
    try std.testing.expectEqual(commands.Mode.running, model.help_panel.context.mode);
    prompt.state = .succeeded;
    _ = try model.widget().draw(ctx);
    try std.testing.expectEqual(commands.Mode.result, model.help_panel.context.mode);
    try std.testing.expect(std.mem.indexOf(u8, try model.help_panel.text(arena.allocator()), "Dismiss the operation result") != null);
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = vaxis.Key.f1 } });
    try std.testing.expect(!model.help_open);
    try std.testing.expect(model.overlay.?.sudo == prompt);
    try std.testing.expectEqualStrings("fixture-secret", prompt.password.items);
}
