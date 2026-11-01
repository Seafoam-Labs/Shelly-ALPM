const packages_model = @import("models/packages_model.zig");
const aur_model = @import("models/aur_model.zig");
const flatpak_model = @import("models/flatpak_model.zig");
const updates_model = @import("models/updates_model.zig");
const settings_model = @import("models/settings_model.zig");
const operation_model = @import("models/operation_model.zig");
const std = @import("std");
const Border = @import("views/border.zig");
const commands = @import("commands.zig");
const help_view = @import("views/help_view.zig");
const footer_view = @import("views/footer_view.zig");
const packages_view = @import("views/packages_view.zig");
const flatpak_view = @import("views/flatpak_view.zig");
const aur_view = @import("views/aur_view.zig");
const diagnostics = @import("diagnostics");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const runtime = @import("runtime.zig");
const Package = @import("models/packages.zig").Package;
const AurPackage = @import("models/packages.zig").AurPackage;

const flatpak = @import("models/flatpak.zig");

const Allocator = std.mem.Allocator;

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
            .upgrade => "Updates",
            .flatpak => "Flatpak",
            .settings => "Settings",
        };
    }
    pub fn icon(self: Tab, style: @import("models/settings.zig").HeaderIcons) []const u8 {
        return switch (style) {
            .none => "",
            // Nerd Fonts mappings: Octicons package/sync/gear, Font Logos Arch,
            // and Font Awesome cube. See nerd-fonts/bin/scripts/lib upstream.
            .nerd_font => switch (self) {
                .packages => "\u{f487}",
                .aur => "\u{f303}",
                .flatpak => "\u{f1b2}",
                .upgrade => "\u{f46a}",
                .settings => "\u{f423}",
            },
            .ascii => switch (self) {
                .packages => "[#]",
                .aur => "[*]",
                .flatpak => "[F]",
                .upgrade => "[^]",
                .settings => "[=]",
            },
        };
    }
};

/// Operation state owned by Model and presented by the reusable panel.
pub const SudoPrompt = operation_model.SudoPrompt;

pub const Overlay = union(enum) {
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
    visible_tabs: [5]Tab = undefined,

    /// Modal package details.
    overlay: ?Overlay = null,

    notice: []const u8 = "",
    help_open: bool = false,
    help_panel: help_view.Panel = .{},

    packages_state: packages_model.State,
    aur_state: aur_model.State,
    flatpak_state: flatpak_model.State,
    updates_state: updates_model.State,
    settings_state: settings_model.State = .{},
    operation_state: operation_model.State,

    pub fn init(gpa: Allocator) !*Model {
        const model = try gpa.create(Model);
        errdefer gpa.destroy(model);

        model.* = .{
            .gpa = gpa,
            .packages_state = try packages_model.init(gpa, model),
            .aur_state = aur_model.init(gpa, model),
            .flatpak_state = flatpak_model.init(gpa, model),
            .updates_state = updates_model.init(gpa, model),
            .operation_state = operation_model.init(gpa, model),
        };
        return model;
    }

    pub fn deinit(self: *Model) void {
        // Stop the operation before releasing page data it may reference.
        operation_model.deinit(self);
        flatpak_model.deinit(self);
        updates_model.deinit(self);
        aur_model.deinit(self);
        packages_model.deinit(self);
        settings_model.deinit(self);
        if (self.notice.len > 0) self.gpa.free(self.notice);
        self.gpa.destroy(self);
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
    pub fn typeErasedCaptureHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        const had_operation = operation_model.operationPrompt(self) != null;
        const had_help = self.help_open;
        const had_aur_pane = operation_model.aurPaneFocused(self) or self.flatpak_state.flatpak_category_open;
        try self.captureEvent(ctx, event);
        if (ctx.quit) return;
        try flatpak_model.syncScreenshots(self, ctx);
        if (self.help_open or operation_model.operationPrompt(self) != null or operation_model.aurPaneFocused(self) or self.flatpak_state.flatpak_category_open) {
            // The root remains present when a small terminal temporarily
            // replaces browsing with the operation panel.
            try ctx.requestFocus(self.widget());
        } else if (had_operation or had_help or had_aur_pane) {
            const list_active = self.packages_state.package_list_active;
            const aur_active = self.aur_state.aur_list_active;
            const flatpak_active = self.flatpak_state.flatpak_list_active;
            try self.focusActiveTab(ctx);
            self.packages_state.package_list_active = list_active;
            self.aur_state.aur_list_active = aur_active;
            self.flatpak_state.flatpak_list_active = flatpak_active;
        }
    }

    pub fn captureEvent(self: *Model, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
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
                if (self.active == .flatpak and !self.flatpak_state.flatpak_installed_only and operation_model.operationPrompt(self) == null and self.operation_state.review_prompt == null and (self.overlay == null or self.overlay.? == .flatpak) and commands.matches(key, .categories)) {
                    try flatpak_model.toggleFlatpakCategories(self, ctx);
                    return ctx.consumeAndRedraw();
                }
                if (self.flatpak_state.flatpak_category_open) {
                    if (commands.matches(key, .close) or commands.matches(key, .back)) {
                        self.flatpak_state.flatpak_category_open = false;
                    } else if (commands.matches(key, .confirm)) {
                        const index = self.flatpak_state.flatpak_category_list.cursor;
                        if (index < self.flatpak_state.flatpak_categories.items.len) try flatpak_model.chooseFlatpakCategory(self, self.flatpak_state.flatpak_categories.items[index].name);
                    } else try self.flatpak_state.flatpak_category_list.handleEvent(ctx, .{ .key_press = commands.scrollKey(key) orelse key });
                    return ctx.consumeAndRedraw();
                }
                if (self.overlay) |overlay| {
                    switch (overlay) {
                        .flatpak => |row| {
                            if (self.flatpak_state.screenshot_open) {
                                if (commands.matches(key, .previous_screenshot) or commands.matches(key, .next_screenshot)) {
                                    if (try flatpak_model.moveScreenshot(self, ctx, commands.matches(key, .next_screenshot))) return ctx.consumeAndRedraw();
                                    return ctx.consumeEvent();
                                }
                                if (commands.matches(key, .refresh_list) and self.flatpak_state.screenshot_failure != null and self.flatpak_state.screenshot_job == null) {
                                    try flatpak_model.queueScreenshot(self, ctx);
                                    return ctx.consumeAndRedraw();
                                }
                            }
                            if (commands.matches(key, .back) or commands.matches(key, .search)) {
                                operation_model.closeOverlay(self);
                                self.flatpak_state.flatpak_list_active = !commands.matches(key, .search);
                                return ctx.consumeAndRedraw();
                            }
                            if (commands.detail(key)) |action| {
                                switch (action) {
                                    .close => {
                                        operation_model.closeOverlay(self);
                                        self.flatpak_state.flatpak_list_active = true;
                                    },
                                    .install => if (row == .catalog and self.operation_state.install_job == null) {
                                        try flatpak_model.openFlatpakInstallChoice(self, row.catalog);
                                    },
                                    .remove => if (row == .installed) try flatpak_model.openFlatpakPrompt(self, .remove, row.installed.Id, .{
                                        .scope = row.installed.InstallLevel,
                                        .remote = row.installed.Remote,
                                        .arch = row.installed.Arch,
                                        .branch = row.installed.Branch,
                                        .kind = row.installed.Kind,
                                        .reference = row.installed.FullRef,
                                    }),
                                    .preview => {},
                                }
                            } else try self.flatpak_state.flatpak_details_scroll.handleEvent(ctx, .{ .key_press = commands.scrollKey(key) orelse key });
                            return ctx.consumeAndRedraw();
                        },
                        .flatpak_install => |choice| {
                            if (commands.choice(key)) |action| switch (action) {
                                .close => self.overlay = .{ .flatpak = .{ .catalog = choice.app } },
                                .previous => self.overlay.?.flatpak_install.selected = if (choice.selected == 0) choice.app.Remotes.len - 1 else choice.selected - 1,
                                .next => self.overlay.?.flatpak_install.selected = (choice.selected + 1) % choice.app.Remotes.len,
                                .confirm => {
                                    const remote = choice.app.Remotes[choice.selected];
                                    try flatpak_model.openFlatpakPrompt(self, .install, choice.app.Id, .{
                                        .scope = remote.Scope,
                                        .remote = remote.Name,
                                        .kind = if (std.mem.eql(u8, choice.app.Type, "runtime")) .runtime else .app,
                                    });
                                },
                            };
                            return ctx.consumeAndRedraw();
                        },
                        .package, .aur => {
                            if ((overlay == .package or overlay == .aur) and commands.leavesPackageDetails(key)) {
                                operation_model.closeOverlay(self);
                                if (overlay == .package) self.packages_state.package_list_active = true else self.aur_state.aur_list_active = true;
                                return ctx.consumeAndRedraw();
                            }
                            if (overlay == .aur) {
                                if (commands.matches(key, .confirm) and self.aur_state.aur_preview_button.focused) {
                                    try operation_model.openPkgbuild(self, ctx, overlay.aur.Name);
                                    return ctx.consumeAndRedraw();
                                }
                                if (commands.matches(key, .next) and !self.aur_state.aur_details_scroll.scroll.has_more_vertical) {
                                    self.aur_state.aur_preview_button.focused = true;
                                    self.aur_state.aur_details_scroll.cursor = 1;
                                    self.aur_state.aur_details_scroll.scroll.wants_cursor = true;
                                    return ctx.consumeAndRedraw();
                                }
                                if (commands.matches(key, .previous)) self.aur_state.aur_preview_button.focused = false;
                            }
                            if (commands.detail(key)) |action| {
                                switch (action) {
                                    .close => operation_model.closeOverlay(self),
                                    .install => try operation_model.operationFromOverlay(self, .install),
                                    .remove => try operation_model.operationFromOverlay(self, .remove),
                                    .preview => if (overlay == .aur) try operation_model.openPkgbuild(self, ctx, overlay.aur.Name),
                                }
                                return ctx.consumeAndRedraw();
                            }
                            if (overlay == .package or overlay == .aur) {
                                if (command) |action| {
                                    operation_model.closeOverlay(self);
                                    switch (action) {
                                        .quit => unreachable,
                                        .next_tab, .previous_tab => self.switchTab(if (action == .next_tab) 1 else -1),
                                        .select_tab => |index| try self.setTab(self.visibleTabs()[index], ctx),
                                    }
                                    try self.focusActiveTab(ctx);
                                    try updates_model.ensureUpdates(self, ctx);
                                    try flatpak_model.ensureFlatpak(self, ctx);
                                } else if (overlay == .package) try self.packages_state.package_details_scroll.handleEvent(ctx, .{ .key_press = commands.scrollKey(key) orelse key }) else try self.aur_state.aur_details_scroll.handleEvent(ctx, .{ .key_press = commands.scrollKey(key) orelse key });
                                return ctx.consumeAndRedraw();
                            }
                            return ctx.consumeEvent();
                        },
                        .sudo => |prompt| {
                            return operation_model.handleSudoKey(self, prompt, ctx, key);
                        },
                        .pkgbuild => {
                            const view = operation_model.pkgbuildView(self);
                            if (view.handleKey(key)) |action| {
                                switch (action) {
                                    .toggle_wrap => {
                                        self.operation_state.pkgbuild_wrap = !self.operation_state.pkgbuild_wrap;
                                        self.operation_state.pkgbuild_scroll.scroll.left = 0;
                                        self.operation_state.pkgbuild_scroll.scroll.vertical_offset = 0;
                                    },
                                    .close => operation_model.closePkgbuild(self),
                                    .retry => if (self.operation_state.pkgbuild_job == null) try operation_model.openPkgbuild(self, ctx, self.operation_state.pkgbuild_name),
                                    .approve => try operation_model.answerOperationQuestion(self, true),
                                    .decline => try operation_model.answerOperationQuestion(self, false),
                                }
                                return ctx.consumeAndRedraw();
                            }
                            if (operation_model.choiceOptions(self)) |options| {
                                const cursor = self.operation_state.dependency_choices.cursor;
                                if (commands.matches(key, .mark) and cursor < options.len) {
                                    if (self.operation_state.operation_question.?.value.question == .select_many) options[cursor].is_selected = !options[cursor].is_selected;
                                } else {
                                    try self.operation_state.dependency_choices.handleEvent(ctx, .{ .key_press = commands.scrollKey(key) orelse key });
                                }
                                operation_model.syncProviderSelection(self);
                                self.operation_state.answer_error = "";
                                return ctx.consumeAndRedraw();
                            }
                            if (self.operation_state.pkgbuild_document != null and self.operation_state.pkgbuild_job == null)
                                try self.operation_state.pkgbuild_scroll.handleEvent(ctx, .{ .key_press = commands.scrollKey(key) orelse key });
                            return ctx.consumeAndRedraw();
                        },
                    }
                }
                if (self.active == .flatpak and self.flatpak_state.flatpak_list_active) {
                    if (commands.matches(key, .search)) {
                        self.flatpak_state.flatpak_list_active = false;
                        return ctx.consumeAndRedraw();
                    }
                    if (commands.matches(key, .details) or commands.packageAction(key) != null) {
                        if (self.flatpak_state.flatpak_job == null and self.flatpak_state.flatpak_list.cursor < self.flatpak_state.flatpak_rows.items.len) {
                            self.overlay = .{ .flatpak = self.flatpak_state.flatpak_rows.items[self.flatpak_state.flatpak_list.cursor] };
                            if (commands.packageAction(key) != null) try self.captureEvent(ctx, event);
                        }
                        return ctx.consumeAndRedraw();
                    }
                }
                if (self.active == .aur and self.aur_state.aur_list_active) {
                    if (commands.matches(key, .select) or commands.matches(key, .mark)) {
                        try aur_model.toggleAurSelection(self);
                        return ctx.consumeAndRedraw();
                    }
                    if (commands.matches(key, .clear_selection)) {
                        aur_model.clearAurSelection(self);
                        return ctx.consumeAndRedraw();
                    }
                    if (commands.matches(key, .search)) {
                        self.aur_state.aur_list_active = false;
                        return ctx.consumeAndRedraw();
                    }
                    if (commands.matches(key, .details)) {
                        if (aur_model.selectedAur(self)) |pkg| self.overlay = .{ .aur = pkg };
                        return ctx.consumeAndRedraw();
                    }
                    if (commands.matches(key, .preview)) {
                        if (aur_model.selectedAur(self)) |pkg| try operation_model.openPkgbuild(self, ctx, pkg.Name);
                        return ctx.consumeAndRedraw();
                    }
                    if (commands.packageAction(key)) |action| {
                        try aur_model.openAurPrompt(self, if (action == .install) .install else .remove);
                        return ctx.consumeAndRedraw();
                    }
                }
                if (self.active != .packages and self.active != .settings and
                    (commands.matches(key, .previous) or commands.matches(key, .next)))
                {
                    if (self.active == .aur) {
                        if (self.aur_state.aur_list_active and self.aur_state.aur_list.cursor == 0 and commands.matches(key, .previous)) {
                            self.aur_state.aur_list_active = false;
                            return ctx.consumeAndRedraw();
                        }
                        self.aur_state.aur_list_active = true;
                    }
                    if (self.active == .flatpak) {
                        if (self.flatpak_state.flatpak_list_active and self.flatpak_state.flatpak_list.cursor == 0 and commands.matches(key, .previous)) {
                            self.flatpak_state.flatpak_list_active = false;
                            return ctx.consumeAndRedraw();
                        }
                        self.flatpak_state.flatpak_list_active = true;
                    }
                    const canonical: vxfw.Event = .{ .key_press = .{ .codepoint = if (commands.matches(key, .previous)) vaxis.Key.up else vaxis.Key.down } };
                    switch (self.active) {
                        .aur => try self.aur_state.aur_list.handleEvent(ctx, canonical),
                        .flatpak => try self.flatpak_state.flatpak_list.handleEvent(ctx, canonical),
                        .upgrade => try updates_model.handleScrollEvent(self, ctx, canonical),
                        else => unreachable,
                    }
                    return ctx.consumeAndRedraw();
                }
                if (self.active == .aur and commands.matches(key, .confirm)) {
                    const query = try self.aur_state.aur_field.buf.dupe();
                    defer self.gpa.free(query);
                    try aur_model.onAurSubmit(self, ctx, query);
                    return ctx.consumeAndRedraw();
                }
                if (self.active == .flatpak and commands.matches(key, .confirm)) {
                    if (self.flatpak_state.flatpak_job == null and self.flatpak_state.flatpak_failure == null and self.flatpak_state.flatpak_list.cursor < self.flatpak_state.flatpak_rows.items.len)
                        self.overlay = .{ .flatpak = self.flatpak_state.flatpak_rows.items[self.flatpak_state.flatpak_list.cursor] };
                    return ctx.consumeAndRedraw();
                }
                if (self.active == .settings) {
                    if (commands.settings(key)) |action| {
                        switch (action) {
                            .previous => self.settings_state.settings_selected = (self.settings_state.settings_selected + settings_model.control_count - 1) % settings_model.control_count,
                            .next => self.settings_state.settings_selected = (self.settings_state.settings_selected + 1) % settings_model.control_count,
                            .toggle => if (self.operation_state.install_job == null) try settings_model.toggleSetting(self, ctx),
                            .save => if (self.operation_state.install_job == null) try settings_model.saveSettings(self, ctx),
                            .reload => if (self.operation_state.install_job == null) try settings_model.reloadSettings(self, ctx),
                        }
                        return ctx.consumeAndRedraw();
                    }
                }
                if (self.active == .packages and command == null) {
                    if (self.packages_state.package_list_active) {
                        if (commands.matches(key, .clear_selection)) {
                            self.packages_state.selected_packages.clearRetainingCapacity();
                            self.packages_state.selected_list_view.item_count = 0;
                            try self.setNotice("");
                            return ctx.consumeAndRedraw();
                        }
                        if (commands.packageAction(key)) |action| {
                            try packages_model.openNativePrompt(self, if (action == .install) .install else .remove);
                            return ctx.consumeAndRedraw();
                        }
                    }
                    if (commands.packageNavigation(key, !self.packages_state.package_list_active)) |action| {
                        switch (action) {
                            .previous, .next => {
                                if (action == .previous and self.packages_state.package_list_active and self.packages_state.list_view.cursor == 0) {
                                    self.packages_state.package_list_active = false;
                                } else {
                                    self.packages_state.package_list_active = true;
                                    try self.packages_state.list_view.handleEvent(ctx, .{ .key_press = .{ .codepoint = if (action == .previous) vaxis.Key.up else vaxis.Key.down } });
                                }
                            },
                            .details => if (packages_model.selectedPackage(self)) |pkg| {
                                self.overlay = .{ .package = pkg };
                            },
                            .search => self.packages_state.package_list_active = false,
                            .select => {
                                self.packages_state.package_list_active = true;
                                if (packages_model.selectedPackage(self) != null) try packages_model.toggleSelectedList(self);
                            },
                        }
                        return ctx.consumeAndRedraw();
                    }
                }
                if (self.active == .flatpak) {
                    if (commands.togglesInstalled(key)) {
                        if (self.flatpak_state.flatpak_job == null) {
                            self.flatpak_state.flatpak_installed_only = !self.flatpak_state.flatpak_installed_only;
                            self.flatpak_state.flatpak_rows.clearRetainingCapacity();
                            self.flatpak_state.flatpak_list.item_count = 0;
                            self.flatpak_state.flatpak_list.jumpToItem(0);
                            try flatpak_model.startFlatpak(self, ctx);
                        }
                        return ctx.consumeAndRedraw();
                    }
                    if (commands.refreshesList(key)) {
                        if (!self.flatpak_state.flatpak_available or self.flatpak_state.flatpak_failure != null) try flatpak_model.startFlatpakProbe(self, ctx) else try flatpak_model.startFlatpak(self, ctx);
                        return ctx.consumeAndRedraw();
                    }
                }
                if (self.active == .aur and self.aur_state.aur_installed_only and commands.refreshesList(key)) {
                    if (self.aur_state.aur_job == null) try aur_model.startAurSearch(self, ctx, "");
                    return ctx.consumeAndRedraw();
                }
                if (commands.togglesInstalled(key) and (self.active == .packages or self.active == .aur)) {
                    if (self.active == .packages) {
                        self.packages_state.installed_only = !self.packages_state.installed_only;
                        try packages_model.rebuildFilter(self);
                    } else if (self.aur_state.aur_job == null) {
                        self.aur_state.aur_installed_only = !self.aur_state.aur_installed_only;
                        try aur_model.startAurSearch(self, ctx, "");
                        self.aur_state.aur_filtered.clearRetainingCapacity();
                        self.aur_state.aur_list.item_count = 0;
                        self.aur_state.aur_list.jumpToItem(0);
                    }
                    return ctx.consumeAndRedraw();
                }
                if (self.active == .upgrade) {
                    if (updates_model.updatesView(self).handleKey(key)) |action| {
                        switch (action) {
                            .refresh => try updates_model.startUpdates(self, ctx),
                            .upgrade_all => try updates_model.upgradeFromUpdates(self, .all),
                            .upgrade_system => try updates_model.upgradeSystemFromUpdates(self),
                            .upgrade_aur => try updates_model.upgradeFromUpdates(self, .aur),
                            .upgrade_flatpak => try updates_model.upgradeFromUpdates(self, .flatpak),
                        }
                        return ctx.consumeAndRedraw();
                    }
                }
                if (self.active == .packages and self.packages_state.package_list_active and commands.matches(key, .mark)) {
                    if (self.packages_state.list_view.cursor < self.packages_state.filtered.items.len) try packages_model.toggleSelectedList(self);
                    return ctx.consumeAndRedraw();
                }
                // Search editing is explicit while browsing: Up at the first
                // package or / returns to the text field.
                if (((self.active == .packages and self.packages_state.package_list_active) or (self.active == .aur and self.aur_state.aur_list_active) or (self.active == .flatpak and self.flatpak_state.flatpak_list_active)) and command == null)
                    return ctx.consumeEvent();

                if (command) |action| {
                    switch (action) {
                        .quit => unreachable,
                        .next_tab, .previous_tab => {
                            self.switchTab(if (action == .next_tab) 1 else -1);
                            try self.focusActiveTab(ctx);
                            try updates_model.ensureUpdates(self, ctx);
                            try flatpak_model.ensureFlatpak(self, ctx);
                        },
                        .select_tab => |index| try self.setTab(self.visibleTabs()[index], ctx),
                    }
                    return ctx.consumeAndRedraw();
                }
            },
            .mouse => {
                if (self.help_open) {
                    try self.help_panel.scroll.handleEvent(ctx, event);
                    return ctx.consumeAndRedraw();
                }
                if (self.active == .aur and self.overlay != null and self.overlay.? == .pkgbuild and self.operation_state.operation_question == null) {
                    if (operation_model.choiceOptions(self) != null) {
                        try self.operation_state.dependency_choices.handleEvent(ctx, event);
                        operation_model.syncProviderSelection(self);
                    } else try self.operation_state.pkgbuild_scroll.handleEvent(ctx, event);
                    return ctx.consumeAndRedraw();
                }
            },
            else => {},
        }
    }

    pub fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => {
                self.flatpak_state.screenshots_supported = runtime.supportsImages();
                try packages_model.startLoad(self, ctx);
                if (self.settings_state.settings.flatpak_enabled) try flatpak_model.startFlatpakProbe(self, ctx);
                ctx.redraw = true;
                return self.focusActiveTab(ctx);
            },
            .focus_in => {
                return self.focusActiveTab(ctx);
            },
            .tick => {
                const loading = try packages_model.pollLoad(self);
                try flatpak_model.pollFlatpakProbe(self, ctx);
                const searching = try aur_model.pollAurSearch(self);
                const installing = try operation_model.pollInstall(self);
                updates_model.pollUpdates(self);
                try updates_model.ensureUpdates(self, ctx);
                try flatpak_model.pollFlatpak(self);
                try operation_model.pollPkgbuild(self, ctx);
                try flatpak_model.syncScreenshots(self, ctx);
                if (self.updates_state.refresh_after_upgrade and !self.packages_state.loading) {
                    try packages_model.reloadPackages(self, ctx);
                    self.updates_state.refresh_after_upgrade = false;
                }
                if (self.flatpak_state.refresh_flatpak_after_operation and self.flatpak_state.flatpak_job == null) {
                    if (self.flatpak_state.flatpak_installed_only) {
                        if (self.flatpak_state.flatpak_catalog) |*parsed| parsed.deinit();
                        self.flatpak_state.flatpak_catalog = null;
                    } else {
                        if (self.flatpak_state.flatpak_installed) |*parsed| parsed.deinit();
                        self.flatpak_state.flatpak_installed = null;
                    }
                    try flatpak_model.startFlatpak(self, ctx);
                    self.flatpak_state.refresh_flatpak_after_operation = false;
                }
                if (self.updates_state.refresh_updates_after_operation and self.updates_state.updates_job == null) {
                    try updates_model.startUpdates(self, ctx);
                    self.updates_state.refresh_updates_after_operation = false;
                }
                if (self.aur_state.refresh_aur_after_operation and self.aur_state.aur_job == null) {
                    if (self.aur_state.aur_installed_only or self.aur_state.aur_query.len > 0) try aur_model.startAurSearch(self, ctx, self.aur_state.aur_query);
                    self.aur_state.refresh_aur_after_operation = false;
                }
                if (loading or searching or installing or self.packages_state.loading or self.updates_state.updates_job != null or self.operation_state.pkgbuild_job != null or self.aur_state.aur_job != null or self.flatpak_state.flatpak_job != null or self.flatpak_state.flatpak_probe_job != null) {
                    try ctx.tick(100, self.widget());
                }
                return ctx.consumeAndRedraw();
            },
            .key_press => |key| {
                // Enter opens the details of the selected package. On the
                // AUR tab Enter is consumed by the search field instead.
                if (commands.matches(key, .confirm) or (self.active == .packages and commands.matches(key, .select))) {
                    if (self.active == .flatpak and self.flatpak_state.flatpak_job == null and self.flatpak_state.flatpak_failure == null and self.flatpak_state.flatpak_list.cursor < self.flatpak_state.flatpak_rows.items.len) {
                        self.overlay = .{ .flatpak = self.flatpak_state.flatpak_rows.items[self.flatpak_state.flatpak_list.cursor] };
                        return ctx.consumeAndRedraw();
                    }
                    if (self.active == .packages and commands.matches(key, .select) and
                        self.packages_state.filtered.items.len > 0 and
                        @as(usize, self.packages_state.list_view.cursor) < self.packages_state.filtered.items.len)
                    {
                        self.packages_state.package_list_active = true;
                        try packages_model.toggleSelectedList(self);
                        return ctx.consumeAndRedraw();
                    }
                }
                // Let the active list handle whatever the search field
                // ignored (arrow keys, mouse wheel, ...)
                return switch (self.active) {
                    .packages => {
                        const previous = self.packages_state.list_view.cursor;
                        try self.packages_state.list_view.handleEvent(ctx, event);
                        if (previous != self.packages_state.list_view.cursor) self.packages_state.package_details_scroll.scroll = .{};
                    },
                    .aur => self.aur_state.aur_list.handleEvent(ctx, event),
                    .upgrade => updates_model.handleScrollEvent(self, ctx, event),
                    .flatpak => self.flatpak_state.flatpak_list.handleEvent(ctx, event),
                    .settings => {},
                };
            },
            .mouse => {
                if (self.overlay) |overlay| {
                    if (overlay == .pkgbuild and self.operation_state.pkgbuild_document != null and self.operation_state.pkgbuild_job == null) {
                        if (operation_model.choiceOptions(self) != null) {
                            try self.operation_state.dependency_choices.handleEvent(ctx, event);
                            operation_model.syncProviderSelection(self);
                            return;
                        }
                        return self.operation_state.pkgbuild_scroll.handleEvent(ctx, event);
                    }
                }
                if (self.active == .upgrade and self.overlay == null)
                    return updates_model.handleScrollEvent(self, ctx, event);
            },
            else => {},
        }
    }

    /// Read the small preference file before the first frame, never CLI/catalog data.
    pub const loadSettings = settings_model.loadSettings;

    // -- tabs --------------------------------------------------------------

    pub fn tabEnabled(self: *const Model, tab: Tab) bool {
        return switch (tab) {
            .aur => self.settings_state.settings.aur_enabled,
            .flatpak => self.settings_state.settings.flatpak_enabled,
            else => true,
        };
    }

    pub fn visibleTabs(self: *Model) []const Tab {
        var count: usize = 0;
        for (Tab.all) |tab| {
            if (!self.tabEnabled(tab)) continue;
            self.visible_tabs[count] = tab;
            count += 1;
        }
        return self.visible_tabs[0..count];
    }

    pub fn switchTab(self: *Model, delta: i32) void {
        const tabs = self.visibleTabs();
        const count: i32 = @intCast(tabs.len);
        const current: i32 = for (tabs, 0..) |tab, index| {
            if (tab == self.active) break @intCast(index);
        } else unreachable;
        var next = @rem(current + delta, count);
        if (next < 0) next += count;
        self.active = tabs[@intCast(next)];
    }

    pub fn setTab(self: *Model, tab: Tab, ctx: *vxfw.EventContext) !void {
        if (!self.tabEnabled(tab)) return;
        if (tab == self.active) return;
        flatpak_model.closeScreenshots(self);
        self.flatpak_state.flatpak_category_open = false;
        self.active = tab;
        try self.focusActiveTab(ctx);
        try updates_model.ensureUpdates(self, ctx);
        try flatpak_model.ensureFlatpak(self, ctx);
    }

    pub fn focusActiveTab(self: *Model, ctx: *vxfw.EventContext) !void {
        if (self.help_open or operation_model.operationPrompt(self) != null or operation_model.aurPaneFocused(self) or self.flatpak_state.flatpak_category_open) return ctx.requestFocus(self.widget());
        self.packages_state.package_list_active = false;
        self.aur_state.aur_list_active = false;
        self.flatpak_state.flatpak_list_active = false;
        switch (self.active) {
            .packages => try ctx.requestFocus(self.packages_state.text_field.widget()),
            .aur => try ctx.requestFocus(self.aur_state.aur_field.widget()),
            .upgrade, .settings => try ctx.requestFocus(self.widget()),
            .flatpak => try ctx.requestFocus(self.flatpak_state.flatpak_field.widget()),
        }
    }

    // -- background jobs ---------------------------------------------------

    pub fn setNotice(self: *Model, message: []const u8) Allocator.Error!void {
        if (self.notice.len > 0) self.gpa.free(self.notice);
        self.notice = if (message.len > 0) try self.gpa.dupe(u8, message) else "";
    }

    // -- filtering ---------------------------------------------------------

    /// Case-insensitive substring match (ASCII folding only, which is all
    /// that package names need).
    pub fn containsFold(haystack: []const u8, needle: []const u8) bool {
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

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
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

        const reviewing = self.overlay != null and self.overlay.? == .pkgbuild and self.operation_state.operation_question != null;
        const prompt = operation_model.operationPrompt(self) orelse self.operation_state.review_prompt;
        const choosing_flatpak = self.overlay != null and self.overlay.? == .flatpak_install;
        var navigation_height: u16 = if (max.width >= 2 and max.height >= 8) 3 else 1;
        var panel_height: u16 = 0;
        var show_browsing = true;
        if (prompt != null or choosing_flatpak) {
            // Keep the operation area stable across authentication, progress,
            // and results; long content scrolls within this reserved third.
            const preferred_height = @max(@as(u16, 4), max.height / 3 + @intFromBool(max.height % 3 != 0));
            if (reviewing) {
                // Keep the review readable above the same operation panel.
                // Tiny terminals give priority to answering the CLI question.
                panel_height = if (max.height >= navigation_height + preferred_height + 7) preferred_height else 0;
            } else if (max.height >= navigation_height + preferred_height + 5) {
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
        if (show_browsing and self.help_open and self.active != .packages and self.active != .aur and self.active != .flatpak) {
            try children.append(arena, .{
                .origin = .{ .row = 1, .col = 0 },
                .surface = try self.help_panel.draw(content_ctx.withConstraints(.{}, .{ .width = max.width, .height = content_ctx.max.size().height -| 2 })),
            });
        } else if (reviewing and !self.help_open and self.active != .aur) {
            try children.append(arena, .{
                .origin = .{ .row = 1, .col = 0 },
                .surface = try operation_model.pkgbuildView(self).drawInPane(content_ctx.withConstraints(.{}, .{ .width = max.width, .height = content_ctx.max.size().height -| 2 })),
            });
        } else if (show_browsing) switch (self.active) {
            .packages => try packages_model.packagesView(self).appendContent(content_ctx, &children),
            .aur => try aur_model.aurView(self).appendContent(content_ctx, &children),
            .upgrade => try updates_model.updatesView(self).appendContent(content_ctx, &children),
            .flatpak => try flatpak_model.flatpakView(self).appendContent(content_ctx, &children),
            .settings => try settings_model.settingsView(self).appendContent(content_ctx, &children),
        };

        for (children.items[content_start..]) |*child| child.origin.row += @intCast(content_offset);
        if (panel_height > 0) if (prompt) |active_prompt| {
            try children.append(arena, .{
                .origin = .{ .row = @intCast(max.height - panel_height - 1), .col = 0 },
                .surface = try active_prompt.panel.draw(operation_model.promptView(self, active_prompt), ctx.withConstraints(
                    .{},
                    .{ .width = max.width, .height = panel_height },
                )),
            });
        };

        if (panel_height > 0 and choosing_flatpak) {
            const choice = self.overlay.?.flatpak_install;
            try children.append(arena, .{
                .origin = .{ .row = @intCast(max.height - panel_height - 1), .col = 0 },
                .surface = try flatpak_view.drawInstallChoices(ctx.withConstraints(.{}, .{ .width = max.width, .height = panel_height }), choice.app, choice.selected),
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
                .aur => null,
                .flatpak => null,
                .sudo => null,
                .pkgbuild => if (self.active == .aur or reviewing) null else try operation_model.pkgbuildView(self).draw(ctx),
                .flatpak_install => null,
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

    pub fn drawTabBar(self: *Model, arena: Allocator) Allocator.Error!vxfw.Widget {
        const tabs = self.visibleTabs();
        const spans = try arena.alloc(vxfw.RichText.TextSpan, tabs.len);
        for (tabs, 0..) |tab, i| {
            const icon = tab.icon(self.settings_state.settings.header_icons);
            spans[i] = .{
                .text = if (icon.len > 0) try std.fmt.allocPrint(arena, " {s} {s} ", .{ icon, tab.title() }) else try std.fmt.allocPrint(arena, " {s} ", .{tab.title()}),
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

    pub fn commandContext(self: *Model) commands.Context {
        var context: commands.Context = .{ .tab_count = self.visibleTabs().len };
        if (operation_model.operationPrompt(self)) |prompt| {
            context.mode = switch (prompt.state) {
                .entering => if (prompt.elevated) .authentication else .confirmation,
                .running => .running,
                .succeeded, .failed, .declined => .result,
            };
            context.scrollable = prompt.panel.scroll.scroll.has_more_vertical or
                prompt.panel.scroll.scroll.top > 0 or prompt.panel.scroll.scroll.vertical_offset != 0;
            return context;
        }
        context.categories_available = self.active == .flatpak and !self.flatpak_state.flatpak_installed_only and (self.overlay == null or self.overlay.? == .flatpak);
        if (self.flatpak_state.flatpak_category_open) {
            context.mode = .choice;
            context.category_choice = true;
            return context;
        }
        if (self.overlay) |overlay| switch (overlay) {
            .package => context.split_details = true,
            .aur => |pkg| {
                context.mode = .details;
                context.selected_count = self.aur_state.aur_selection.items.len;
                for (self.aur_state.aur_selection.items) |selected| if (selected.installed) {
                    context.selected_installed += 1;
                };
                context.installable = true;
                context.removable = if (context.selected_count > 0) context.selected_installed > 0 else pkg.Installed;
                context.preview = true;
                context.preview_button = self.aur_state.aur_preview_button.focused;
                context.split_details = true;
                context.scrollable = self.aur_state.aur_details_scroll.scroll.has_more_vertical or self.aur_state.aur_details_scroll.scroll.top > 0 or self.aur_state.aur_details_scroll.scroll.vertical_offset != 0;
                return context;
            },
            .flatpak => |row| {
                context.mode = .details;
                context.screenshots_navigable = self.flatpak_state.screenshots_supported and self.flatpak_state.screenshot_open and self.flatpak_state.screenshot_items.len > 1;
                context.screenshot_retry = self.flatpak_state.screenshots_supported and self.flatpak_state.screenshot_open and self.flatpak_state.screenshot_failure != null;
                context.installable = row == .catalog and row.catalog.Remotes.len > 0;
                context.removable = row == .installed;
                context.split_details = true;
                context.scrollable = true;
                return context;
            },
            .pkgbuild => {
                context.mode = if (self.operation_state.operation_question) |question|
                    if (question.value.question == .select_one or question.value.question == .select_many) .answers else .review
                else
                    .preview_document;
                context.scrollable = self.operation_state.pkgbuild_document != null;
                context.source_wrap = self.operation_state.pkgbuild_wrap;
                context.multiple_choices = if (self.operation_state.operation_question) |q| q.value.question == .select_many else false;
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
                context.mode = if (context.split_details) .details else if (self.packages_state.package_list_active) .packages else .search;
                context.installed_only = self.packages_state.installed_only;
                context.selected_count = self.packages_state.selected_packages.items.len;
                for (self.packages_state.selected_packages.items) |name| for (self.packages_state.packages) |pkg| {
                    if (std.mem.eql(u8, name, pkg.Name)) {
                        if (pkg.Installed) context.selected_installed += 1;
                        break;
                    }
                };
                context.installable = !self.packages_state.loading and !self.packages_state.load_failed and (packages_model.selectedPackage(self) != null or context.selected_count > 0);
                context.removable = context.installable and if (context.selected_count > 0) context.selected_installed > 0 else if (packages_model.selectedPackage(self)) |pkg| pkg.Installed else false;
                context.scrollable = context.split_details and (self.packages_state.package_details_scroll.scroll.has_more_vertical or
                    self.packages_state.package_details_scroll.scroll.top > 0 or self.packages_state.package_details_scroll.scroll.vertical_offset != 0);
            },
            .aur => {
                context.mode = .aur;
                context.installed_only = self.aur_state.aur_installed_only;
                context.browsing_list = self.aur_state.aur_list_active;
                context.selected_count = self.aur_state.aur_selection.items.len;
                for (self.aur_state.aur_selection.items) |selected| if (selected.installed) {
                    context.selected_installed += 1;
                };
                context.installable = self.aur_state.aur_list_active and (aur_model.selectedAur(self) != null or self.aur_state.aur_selection.items.len > 0);
                context.removable = self.aur_state.aur_list_active and if (context.selected_count > 0) context.selected_installed > 0 else if (aur_model.selectedAur(self)) |pkg| pkg.Installed else false;
                context.preview = self.aur_state.aur_list_active and aur_model.selectedAur(self) != null;
            },
            .flatpak => {
                context.mode = .flatpak;
                context.browsing_list = self.flatpak_state.flatpak_list_active;
                if (self.flatpak_state.flatpak_list_active and self.flatpak_state.flatpak_job == null and self.flatpak_state.flatpak_list.cursor < self.flatpak_state.flatpak_rows.items.len) {
                    const row = self.flatpak_state.flatpak_rows.items[self.flatpak_state.flatpak_list.cursor];
                    context.installable = row == .catalog and row.catalog.Remotes.len > 0;
                    context.removable = row == .installed;
                }
                context.installed_only = self.flatpak_state.flatpak_installed_only;
            },
            .upgrade => {
                const view = updates_model.updatesView(self);
                context.mode = .updates;
                context.upgrade_all = view.canUpgradeAll();
                context.upgrade_system = view.canUpgrade();
                context.upgrade_aur = view.canUpgradeAur();
                context.upgrade_flatpak = view.canUpgradeFlatpak();
            },
            .settings => {
                context.mode = .settings;
                context.settings_save_selected = self.settings_state.settings_selected == settings_model.save_index;
                context.settings_cycle_selected = self.settings_state.settings_selected == 2;
            },
        }
        return context;
    }

    pub fn footerStatus(self: *Model, _: Allocator) Allocator.Error!?[]const u8 {
        if (self.notice.len > 0) return self.notice;
        if (operation_model.operationPrompt(self) != null) return null;
        return switch (self.active) {
            .packages => if (self.packages_state.loading) "Loading packages…" else if (self.packages_state.load_failed) "Package query failed" else null,
            .aur => if (self.aur_state.aur_job != null) "Loading AUR results…" else if (self.aur_state.aur_failed) "AUR query failed" else null,
            .flatpak => if (self.flatpak_state.flatpak_probe_job != null) "Checking Flatpak backend…" else if (self.flatpak_state.flatpak_job != null) "Loading Flatpaks…" else if (self.flatpak_state.flatpak_failure != null) "Flatpak query failed" else null,
            .upgrade => if (self.updates_state.updates_job != null) "Checking for updates…" else if (self.updates_state.updates_failed) "Update check failed" else null,
            .settings => null,
        };
    }

    pub fn statusText(self: *Model, arena: Allocator) Allocator.Error![]const u8 {
        if (self.active == .upgrade) return updates_model.updatesView(self).statusText(arena);
        if (self.notice.len > 0) return self.notice;
        return switch (self.active) {
            .packages => packages_model.packagesView(self).statusText(arena),
            .aur => aur_model.aurView(self).statusText(arena),
            .upgrade => updates_model.updatesView(self).statusText(arena),
            .flatpak => flatpak_model.flatpakView(self).statusText(arena),
            .settings => "Settings — source preferences are saved for future sessions",
        };
    }

    pub fn drawDetailsOverlay(self: *const Model, ctx: vxfw.DrawContext, arena: Allocator, max: vxfw.Size, overlay: Overlay) Allocator.Error!?vxfw.SubSurface {
        var title: []const u8 = undefined;
        var body: []const u8 = undefined;
        switch (overlay) {
            .package => |pkg| {
                title = try std.fmt.allocPrint(arena, "{s} {s}", .{ pkg.Name, pkg.Version });
                body = try packages_view.detailsText(arena, pkg);
            },
            .aur => |pkg| {
                title = try std.fmt.allocPrint(arena, "{s} {s} (AUR)", .{ pkg.Name, pkg.Version });
                body = try aur_view.detailsText(arena, pkg);
            },
            .flatpak => |row| {
                title = try std.fmt.allocPrint(arena, "{f} (Flatpak)", .{diagnostics.safe(row.title())});
                body = try row.details(arena);
            },
            .sudo, .pkgbuild, .flatpak_install => return null,
        }
        if (self.operation_state.install_job) |job| {
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
};

/// A compact centered bar with a filled highlight for the selected tab.
pub const TabBar = struct {
    model: *Model,
    tabs: []const Tab,
    rich: vxfw.RichText,
    first_visible: usize = 0,
    start_col: i16 = 0,
    label_row: i16 = 0,
    label_widths: []const u16 = &.{},

    pub fn widget(self: *TabBar) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = handleEvent,
            .drawFn = drawFn,
        };
    }

    pub fn drawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
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
        for (self.rich.text) |span| total += ctx.stringWidth(span.text);
        while (total > width and end - first > 1) {
            if (active - first > end - 1 - active) {
                total -= ctx.stringWidth(self.rich.text[first].text) + 1;
                first += 1;
            } else {
                end -= 1;
                total -= ctx.stringWidth(self.rich.text[end].text) + 1;
            }
        }
        const spans = try ctx.arena.dupe(vxfw.RichText.TextSpan, self.rich.text[first..end]);
        const truncated = total > width;
        if (truncated) {
            const label = std.mem.trim(u8, spans[0].text, " ");
            var iterator = ctx.graphemeIterator(label);
            var bytes: usize = 0;
            var columns: usize = 0;
            while (iterator.next()) |grapheme| {
                const text = grapheme.bytes(label);
                const cells = ctx.stringWidth(text);
                if (columns + cells > width -| caps) break;
                bytes += text.len;
                columns += cells;
            }
            spans[0].text = label[0..bytes];
            total = columns + caps;
        }
        self.first_visible = first;
        self.rich.text = spans;
        const label_widths = try ctx.arena.alloc(u16, spans.len);
        for (spans, label_widths) |span, *label_width| label_width.* = @intCast(ctx.stringWidth(span.text));
        self.label_widths = label_widths;
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
            var iterator = ctx.graphemeIterator(span.text);
            while (iterator.next()) |grapheme| {
                const text = grapheme.bytes(span.text);
                const cells: u8 = @intCast(ctx.stringWidth(text));
                surface.writeCell(col, @intCast(self.label_row), .{
                    .char = .{ .grapheme = text, .width = cells },
                    .style = if (selected) selected_style else span.style,
                });
                col += cells;
            }
            col +|= 1;
        }
        return surface;
    }

    pub fn handleEvent(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *TabBar = @ptrCast(@alignCast(ptr));
        switch (event) {
            // Mouse coordinates arrive local to this surface
            .mouse => |mouse| {
                if (mouse.button != .left or mouse.type != .press) return;
                if (mouse.row != self.label_row or mouse.col < self.start_col) return;
                var col = self.start_col;
                for (self.label_widths, 0..) |label_width, i| {
                    const width: i16 = @intCast(label_width);
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
    model.aur_state.aur_list_active = false;
    model.overlay = null;
    model.flatpak_state.flatpak_available = false;
    model.settings_state.settings = .{};
    var ctx: vxfw.EventContext = .{
        .io = std.testing.io,
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
            .packages => model.packages_state.text_field.widget(),
            .aur => model.aur_state.aur_field.widget(),
            .upgrade, .settings => model.widget(),
            .flatpak => model.flatpak_state.flatpak_field.widget(),
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
                .packages => model.packages_state.text_field.widget(),
                .aur => model.aur_state.aur_field.widget(),
                .upgrade, .settings => model.widget(),
                .flatpak => model.flatpak_state.flatpak_field.widget(),
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

test "shared commands quit from every tab and modal" {
    const model = try Model.init(std.testing.allocator);
    defer {
        model.overlay = null;
        model.deinit();
    }
    var ctx: vxfw.EventContext = .{
        .io = std.testing.io,
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

test "tab bar centers labels and retains the active tab on narrow terminals" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.settings_state.settings = .{ .aur_enabled = true, .flatpak_enabled = true };
    model.active = .settings;
    for ([_]@import("models/settings.zig").HeaderIcons{ .none, .nerd_font, .ascii }) |style| {
        model.settings_state.settings.header_icons = style;
        for ([_]u16{ 120, 80, 40, 18, 3, 1 }) |width| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const widget = try model.drawTabBar(arena.allocator());
            const surface = try widget.draw(.{
                .arena = arena.allocator(),
                .min = .{},
                .max = .{ .width = width, .height = 3 },
                .cell_size = .{ .width = 10, .height = 20 },
            });
            for (surface.buffer) |cell| {
                try std.testing.expect(std.unicode.utf8ValidateSlice(cell.char.grapheme));
                try std.testing.expect(cell.image == null);
            }
            try std.testing.expectEqual(width, surface.size.width);
            try std.testing.expectEqual(@as(u16, 3), surface.size.height);
            const bar: *TabBar = @ptrCast(@alignCast(widget.userdata));
            try std.testing.expect(bar.first_visible + bar.rich.text.len > 4);
            var total: usize = bar.rich.text.len -| 1;
            for (bar.label_widths) |label_width| total += label_width;
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
}

test "centered tab mouse targets exclude borders and padding" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    for ([_]@import("models/settings.zig").HeaderIcons{ .none, .nerd_font, .ascii }) |style| {
        model.active = .packages;
        model.settings_state.settings.header_icons = style;
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const widget = try model.drawTabBar(arena.allocator());
        _ = try widget.draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 100, .height = 3 }, .cell_size = .{ .width = 10, .height = 20 } });
        const bar: *TabBar = @ptrCast(@alignCast(widget.userdata));
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
        defer ctx.cmds.deinit(std.testing.allocator);
        var col = bar.start_col;
        for (bar.label_widths[0 .. bar.label_widths.len - 1]) |label_width| col += @intCast(label_width + 1);
        try TabBar.handleEvent(bar, &ctx, .{ .mouse = .{ .button = .left, .type = .press, .col = @intCast(col), .row = 0, .mods = .{} } });
        try std.testing.expectEqual(Tab.packages, model.active);
        try TabBar.handleEvent(bar, &ctx, .{ .mouse = .{ .button = .left, .type = .press, .col = 0, .row = 1, .mods = .{} } });
        try std.testing.expectEqual(Tab.packages, model.active);
        try TabBar.handleEvent(bar, &ctx, .{ .mouse = .{ .button = .left, .type = .press, .col = @intCast(col), .row = 1, .mods = .{} } });
        try std.testing.expectEqual(Tab.settings, model.active);
    }
}

test "F1 help replaces details and restores selection focus and scroll" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    var packages = [_]Package{.{ .Name = "example" }};
    model.packages_state.packages = &packages;
    model.packages_state.loading = false;
    try packages_model.rebuildFilter(model);
    model.packages_state.package_list_active = true;
    model.packages_state.package_details_cursor = 0;
    model.packages_state.package_details_scroll.scroll.vertical_offset = -2;
    model.overlay = .{ .package = &packages[0] };
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
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
        try std.testing.expectEqual(@as(i17, -2), model.packages_state.package_details_scroll.scroll.vertical_offset);
    }
    try Model.typeErasedCaptureHandler(model, &events, .{ .key_press = .{ .codepoint = vaxis.Key.f1 } });
    try std.testing.expect(!model.help_open);
    try std.testing.expect(model.packages_state.package_list_active);
    try std.testing.expectEqualStrings("example", model.overlay.?.package.Name);
    try std.testing.expectEqual(@as(i17, -2), model.packages_state.package_details_scroll.scroll.vertical_offset);
}

test "help and footer update live bindings without reopening help" {
    vxfw.DrawContext.init(.unicode);
    const original = commands.bindings;
    defer commands.bindings = original;
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    var packages = [_]Package{.{ .Name = "example" }};
    model.packages_state.packages = &packages;
    model.packages_state.loading = false;
    model.packages_state.package_list_active = true;
    try packages_model.rebuildFilter(model);
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
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
    try std.testing.expect(packages_model.packageMarked(model, "example"));
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

test {
    std.testing.refAllDecls(packages_model);
    std.testing.refAllDecls(aur_model);
    std.testing.refAllDecls(flatpak_model);
    std.testing.refAllDecls(updates_model);
    std.testing.refAllDecls(settings_model);
    std.testing.refAllDecls(operation_model);
}

test "header labels default to raw text and use Nerd Font glyphs only when enabled" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const widget = try model.drawTabBar(arena.allocator());
    const bar: *TabBar = @ptrCast(@alignCast(widget.userdata));
    try std.testing.expectEqualStrings(" Packages ", bar.rich.text[0].text);
    try std.testing.expectEqualStrings(" Updates ", bar.rich.text[1].text);
    try std.testing.expectEqualStrings(" Settings ", bar.rich.text[2].text);
    model.settings_state.settings.header_icons = .nerd_font;
    const icons_widget = try model.drawTabBar(arena.allocator());
    const icons_bar: *TabBar = @ptrCast(@alignCast(icons_widget.userdata));
    try std.testing.expect(std.mem.indexOf(u8, icons_bar.rich.text[0].text, "\u{f487}") != null);
    try std.testing.expect(std.mem.indexOf(u8, icons_bar.rich.text[1].text, "\u{f46a}") != null);
    try std.testing.expect(std.mem.indexOf(u8, icons_bar.rich.text[2].text, "\u{f423}") != null);
}
