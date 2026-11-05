const packages_model = @import("models/packages_model.zig");
const aur_model = @import("models/aur_model.zig");
const flatpak_model = @import("models/flatpak_model.zig");
const updates_model = @import("models/updates_model.zig");
const settings_model = @import("models/settings_model.zig");
const operation_model = @import("models/operation_model.zig");
const std = @import("std");
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
    list_percent: u8 = 40,
    viewport_width: ?u16 = null,

    active: Tab = .packages,
    visible_tabs: [5]Tab = undefined,

    /// Modal package details.
    overlay: ?Overlay = null,

    notice: []const u8 = "",
    quit_blocked_notice: bool = false,
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
                        if (!self.help_open) if (self.operation_state.install_job) |job| {
                            if (job.snapshot(runtime.io).authenticating) {
                                job.sendAuthentication(runtime.io, "\x03") catch {
                                    try self.setNotice("Could not interrupt sudo authentication.");
                                };
                                return ctx.consumeAndRedraw();
                            }
                        };
                        if (self.operation_state.install_job != null) {
                            self.quit_blocked_notice = true;
                            return ctx.consumeAndRedraw();
                        }
                        ctx.quit = true;
                        return ctx.consumeEvent();
                    }
                }
                if (commands.matches(key, .help)) {
                    self.help_open = !self.help_open;
                    return ctx.consumeAndRedraw();
                }
                if (!self.help_open and operation_model.operationPrompt(self) == null and self.operation_state.review_prompt == null and (self.active == .packages or self.active == .aur or self.active == .flatpak) and (self.overlay == null or self.overlay.? == .package or self.overlay.? == .aur or self.overlay.? == .flatpak)) {
                    if (commands.matches(key, .narrow_view) or commands.matches(key, .widen_view)) {
                        const next_percent = @import("views/split_layout.zig").resize(self.viewport_width, self.list_percent, commands.matches(key, .widen_view)) orelse return ctx.consumeEvent();
                        self.list_percent = next_percent;
                        return ctx.consumeAndRedraw();
                    }
                }
                if (self.help_open) {
                    try self.help_panel.handleKey(ctx, key);
                    return ctx.consumeAndRedraw();
                }
                if (self.active == .flatpak and try flatpak_model.handleCategoryShortcut(self, ctx, key)) return;
                if (self.flatpak_state.flatpak_category_open) return flatpak_model.handleCategoryKey(self, ctx, key);
                if (self.overlay) |overlay| {
                    switch (overlay) {
                        .flatpak => |row| {
                            return flatpak_model.handleDetailsKey(self, ctx, key, row);
                        },
                        .flatpak_install => |choice| {
                            return flatpak_model.handleInstallChoiceKey(self, ctx, key, choice.app, choice.selected);
                        },
                        .package, .aur => {
                            const handled = if (overlay == .package)
                                try packages_model.handleDetailsKey(self, ctx, key, command != null)
                            else
                                try aur_model.handleDetailsKey(self, ctx, key, command != null);
                            if (handled) return;
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
                            }
                            return ctx.consumeAndRedraw();
                        },
                        .sudo => |prompt| {
                            return operation_model.handleSudoKey(self, prompt, ctx, key);
                        },
                        .pkgbuild => return operation_model.handleReviewKey(self, ctx, key),
                    }
                }
                const handled = switch (self.active) {
                    .packages => try packages_model.handleKey(self, ctx, key, command != null),
                    .aur => try aur_model.handleKey(self, ctx, key, command != null),
                    .flatpak => try flatpak_model.handleKey(self, ctx, key, command != null),
                    .upgrade => try updates_model.handleKey(self, ctx, key),
                    .settings => try settings_model.handleKey(self, ctx, key),
                };
                if (handled) return;

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
                    try operation_model.handleReviewMouse(self, ctx, event);
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
            .key_press => |key| return switch (self.active) {
                .packages => packages_model.handleUnhandledKey(self, ctx, key),
                .aur => aur_model.handleUnhandledKey(self, ctx, key),
                .flatpak => flatpak_model.handleUnhandledKey(self, ctx, key),
                .upgrade => updates_model.handleScrollEvent(self, ctx, event),
                .settings => {},
            },
            .mouse => {
                if (self.overlay) |overlay| {
                    if (overlay == .pkgbuild and self.operation_state.pkgbuild_document != null and self.operation_state.pkgbuild_job == null) {
                        return operation_model.handleReviewMouse(self, ctx, event);
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
        if (self.overlay) |overlay| switch (overlay) {
            .package, .aur, .flatpak => operation_model.closeOverlay(self),
            .sudo, .pkgbuild, .flatpak_install => return,
        };
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
        self.viewport_width = max.width;

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
        const fullscreen_review = reviewing and self.operation_state.operation_question.?.value.question == .pkgbuild;
        const panel_review = reviewing and !fullscreen_review;
        const prompt = operation_model.operationPrompt(self) orelse self.operation_state.review_prompt;
        const choosing_flatpak = self.overlay != null and self.overlay.? == .flatpak_install;
        var navigation_height: u16 = if (max.width >= 2 and max.height >= 8) 3 else 1;
        var panel_height: u16 = 0;
        var show_browsing = true;
        if (!fullscreen_review and (prompt != null or choosing_flatpak)) {
            // Keep the operation area stable across authentication, progress,
            // and results; long content scrolls within this reserved third.
            const preferred_height = @max(@as(u16, 4), max.height / 3 + @intFromBool(max.height % 3 != 0));
            if (panel_review) {
                panel_height = @max(preferred_height, max.height / 2);
                if (max.height < navigation_height + panel_height + 5) {
                    panel_height = max.height -| (navigation_height + 1);
                    show_browsing = false;
                }
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
        const content_size = content_ctx.max.size();
        const pane_width = if (max.width >= 64) max.width - @import("views/split_layout.zig").listWidth(max.width, self.list_percent) else max.width;
        self.flatpak_state.screenshot_layout_available = @import("views/split_layout.zig").imagesFit(pane_width -| 2, content_size.height -| 4);
        self.help_panel.context = self.commandContext();
        if (show_browsing and self.help_open and self.active != .packages and self.active != .aur and self.active != .flatpak) {
            try children.append(arena, .{
                .origin = .{ .row = 1, .col = 0 },
                .surface = try self.help_panel.draw(content_ctx.withConstraints(.{}, .{ .width = max.width, .height = content_ctx.max.size().height -| 2 })),
            });
        } else if (fullscreen_review and !self.help_open) {
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
                .surface = if (panel_review and !self.help_open)
                    try operation_model.pkgbuildView(self).drawInPane(ctx.withConstraints(.{}, .{ .width = max.width, .height = panel_height }))
                else
                    try active_prompt.panel.draw(operation_model.promptView(self, active_prompt), ctx.withConstraints(
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
            .surface = try footer_view.draw(ctx.withConstraints(.{}, .{ .width = max.width, .height = 1 }), footer_context, if (self.help_open) null else self.footerStatus()),
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
        var context: commands.Context = .{ .tab_count = self.visibleTabs().len, .quit_blocked = self.operation_state.install_job != null };
        if (operation_model.operationPrompt(self)) |prompt| {
            context.mode = switch (prompt.state) {
                .entering => if (prompt.elevated) .authentication else .confirmation,
                .running => .running,
                .succeeded, .failed, .declined => .result,
            };
            context.scrollable = prompt.panel.scroll.scroll.has_more_vertical or
                prompt.panel.scroll.scroll.top > 0 or prompt.panel.scroll.scroll.vertical_offset != 0;
            context.authenticating = prompt.progress.authenticating;
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
                context.screenshots_navigable = flatpak_model.screenshotsEnabled(self) and self.flatpak_state.screenshot_open and self.flatpak_state.screenshot_items.len > 1;
                context.screenshot_retry = flatpak_model.screenshotsEnabled(self) and self.flatpak_state.screenshot_open and self.flatpak_state.screenshot_failure != null;
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
                context.settings_cycle_selected = self.settings_state.settings_selected >= 2 and self.settings_state.settings_selected < settings_model.screenshots_index;
            },
        }
        return context;
    }

    /// Source loading and query errors belong to their page, not shortcut hints.
    pub fn footerStatus(self: *const Model) ?[]const u8 {
        if (self.quit_blocked_notice and self.operation_state.install_job != null) return "Operation in progress. Wait for it to finish before quitting.  ";
        return if (self.notice.len > 0) self.notice else null;
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

test "ordinary operation questions use the full-width bottom panel on every package page" {
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
    for ([_]Tab{ .packages, .aur, .flatpak, .upgrade }) |tab| {
        const model = try Model.init(std.testing.allocator);
        defer model.deinit();
        model.active = tab;
        const prompt = try std.testing.allocator.create(SudoPrompt);
        prompt.* = .{ .name = try std.testing.allocator.dupe(u8, "demo"), .backend = .aur, .state = .running };
        model.overlay = .{ .sudo = prompt };
        for ([_]struct { json: []const u8, title: []const u8 }{
            .{ .json = "{\"$kind\":\"q.yesno\",\"QuestionId\":\"1\",\"QuestionText\":\"Proceed?\"}", .title = "Operation review" },
            .{ .json = "{\"$kind\":\"q.optdeps\",\"QuestionId\":\"2\",\"QuestionText\":\"Choose dependencies\",\"Options\":[{\"Index\":0,\"Name\":\"docs\"}]}", .title = "Optional dependencies" },
            .{ .json = "{\"$kind\":\"q.provider\",\"QuestionId\":\"3\",\"DependencyName\":\"java\",\"Options\":[{\"Index\":0,\"Name\":\"jdk\"}]}", .title = "Dependency selection" },
            .{ .json = "{\"$kind\":\"q.transaction\",\"QuestionId\":\"4\",\"Action\":\"install\",\"Packages\":[{\"Name\":\"demo\",\"Repository\":\"aur\",\"Source\":\"aur\",\"Role\":\"requested\"}]}", .title = "Transaction review" },
        }) |question| {
            try operation_model.showOperationQuestion(model, try @import("services/shelly_operation.zig").decodeJson(std.testing.allocator, question.json));
            defer operation_model.finishOperationQuestion(model);
            if (tab == .aur) try std.testing.expect(aur_model.aurView(model).preview == null);
            for ([_]vxfw.Size{ .{ .width = 100, .height = 30 }, .{ .width = 50, .height = 18 }, .{ .width = 30, .height = 8 } }) |size| {
                var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
                defer arena.deinit();
                const surface = try model.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = size.width, .height = size.height }, .cell_size = .{ .width = 10, .height = 20 } });
                const review = surface.children[surface.children.len - 2];
                try std.testing.expectEqual(@as(i17, 0), review.origin.col);
                try std.testing.expect(review.surface.size.width <= size.width);
                try std.testing.expect(@as(u16, @intCast(review.origin.row)) + review.surface.size.height <= size.height - 1);
                if (size.height >= 18) {
                    try std.testing.expectEqual(size.width, review.surface.size.width);
                    try std.testing.expect(try contains(review.surface, question.title, std.testing.allocator));
                } else try std.testing.expect(try contains(review.surface, "Enlarge", std.testing.allocator));
                for (surface.children[0 .. surface.children.len - 2]) |child| {
                    try std.testing.expect(!try contains(child.surface, question.title, std.testing.allocator));
                    try std.testing.expect(child.origin.row + child.surface.size.height <= review.origin.row);
                }
            }
        }
        try std.testing.expect(model.overlay.?.sudo == prompt);
        try operation_model.showOperationQuestion(model, try @import("services/shelly_operation.zig").decodeJson(std.testing.allocator,
            \\{"$kind":"q.pkgbuilddiff","QuestionId":"5","PackageName":"demo","OldPkgbuild":"pkgver=1","NewPkgbuild":"pkgver=2"}
        ));
        defer operation_model.finishOperationQuestion(model);
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const fullscreen = try model.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 100, .height = 30 }, .cell_size = .{ .width = 10, .height = 20 } });
        try std.testing.expectEqual(@as(usize, 3), fullscreen.children.len);
        try std.testing.expectEqual(@as(u16, 26), fullscreen.children[1].surface.size.height);
        try std.testing.expect(try contains(fullscreen.children[1].surface, "PKGBUILD review", std.testing.allocator));
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
        try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = commands.bindings.quit });
        try std.testing.expect(ctx.quit and ctx.consume_event);
    }
    var pkg: Package = .{ .Name = "test" };
    model.overlay = .{ .package = &pkg };
    ctx.quit = false;
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = commands.bindings.quit });
    try std.testing.expect(ctx.quit);
    var prompt: SudoPrompt = .{ .name = "test", .backend = .standard };
    for ([_]SudoPrompt.State{ .entering, .running, .succeeded, .failed }) |state| {
        prompt.state = state;
        model.overlay = .{ .sudo = &prompt };
        ctx.quit = false;
        try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = commands.bindings.quit });
        try std.testing.expect(ctx.quit);
    }
    model.overlay = .pkgbuild;
    ctx.quit = false;
    try Model.typeErasedCaptureHandler(model, &ctx, .{ .key_press = commands.bindings.quit });
    try std.testing.expect(ctx.quit);
    model.overlay = null;
    try std.testing.expect(commands.global(.{ .codepoint = vaxis.Key.left }, Tab.all.len) == null);
    try std.testing.expect(commands.global(.{ .codepoint = '1' }, Tab.all.len) == null);
}

test "Escape leaves search without quitting on every package source" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);
    _ = try packages_model.handleKey(model, &ctx, .{ .codepoint = vaxis.Key.escape }, false);
    _ = try aur_model.handleKey(model, &ctx, .{ .codepoint = vaxis.Key.escape }, false);
    _ = try flatpak_model.handleKey(model, &ctx, .{ .codepoint = vaxis.Key.escape }, false);
    try std.testing.expect(model.packages_state.package_list_active);
    try std.testing.expect(model.aur_state.aur_list_active);
    try std.testing.expect(model.flatpak_state.flatpak_list_active);
    try std.testing.expectEqual(@as(u32, 0), model.packages_state.list_view.cursor);
    try std.testing.expectEqual(@as(u32, 0), model.aur_state.aur_list.cursor);
    try std.testing.expectEqual(@as(u32, 0), model.flatpak_state.flatpak_list.cursor);
    try std.testing.expect(!ctx.quit);
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

test "list resizing is shared bounded and does not change settings navigation" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer events.cmds.deinit(std.testing.allocator);
    for ([_]Tab{ .packages, .aur, .flatpak }) |tab| {
        model.active = tab;
        model.list_percent = 40;
        try model.captureEvent(&events, .{ .key_press = commands.bindings.widen_view });
        try std.testing.expectEqual(@as(u8, 45), model.list_percent);
        try model.captureEvent(&events, .{ .key_press = commands.bindings.narrow_view });
        try std.testing.expectEqual(@as(u8, 40), model.list_percent);
    }
    for (0..100) |_| try model.captureEvent(&events, .{ .key_press = commands.bindings.widen_view });
    try std.testing.expectEqual(@as(u8, 80), model.list_percent);
    for (0..100) |_| try model.captureEvent(&events, .{ .key_press = commands.bindings.narrow_view });
    try std.testing.expectEqual(@as(u8, 20), model.list_percent);
    model.active = .settings;
    try model.captureEvent(&events, .{ .key_press = commands.bindings.widen_view });
    try std.testing.expectEqual(@as(u8, 20), model.list_percent);
}

test "package pages tolerate tiny terminals and repeated minimum splits" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    model.packages_state.parsed = try std.json.parseFromSlice([]Package, std.testing.allocator, "[{\"Name\":\"editor\",\"Description\":\"A long description with wide characters 界界 and dependencies\"}]", .{ .allocate = .alloc_always });
    model.packages_state.packages = model.packages_state.parsed.?.value;
    try packages_model.rebuildFilter(model);
    model.overlay = .{ .package = &model.packages_state.packages[0] };
    for ([_]Tab{ .packages, .aur, .flatpak }) |tab| {
        model.active = tab;
        for ([_]vxfw.Size{ .{ .width = 1, .height = 4 }, .{ .width = 2, .height = 8 }, .{ .width = 27, .height = 5 }, .{ .width = 63, .height = 12 }, .{ .width = 64, .height = 24 }, .{ .width = 80, .height = 24 } }) |size| {
            for ([_]u8{ 0, 20, 40, 80, 255 }) |percent| {
                model.list_percent = percent;
                var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
                defer arena.deinit();
                const surface = try model.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = size.width, .height = size.height }, .cell_size = .{ .width = 10, .height = 20 } });
                try std.testing.expectEqual(size, surface.size);
            }
        }
    }
}

test "quit is blocked across pages and help until the operation is collected" {
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    var job: @import("services/shelly_operation.zig").Operation = .{ .arena = .init(std.testing.allocator), .request = undefined };
    defer job.arena.deinit();
    model.operation_state.install_job = &job;
    defer model.operation_state.install_job = null;
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);
    for (Tab.all) |tab| {
        model.active = tab;
        for ([_]bool{ false, true }) |help_open| {
            model.help_open = help_open;
            for ([_]vaxis.Key{ commands.bindings.quit, commands.bindings.interrupt }) |key| {
                ctx.consume_event = false;
                ctx.redraw = false;
                try model.captureEvent(&ctx, .{ .key_press = key });
                try std.testing.expect(!ctx.quit and ctx.consume_event and ctx.redraw);
                try std.testing.expect(model.commandContext().quit_blocked);
                try std.testing.expect(model.footerStatus() != null);
            }
        }
    }
    // Even a finished worker remains protected until its result is collected.
    job.done.store(true, .release);
    try model.captureEvent(&ctx, .{ .key_press = commands.bindings.quit });
    try std.testing.expect(!ctx.quit);
    model.operation_state.install_job = null;
    try std.testing.expect(!model.commandContext().quit_blocked);
    try std.testing.expect(model.footerStatus() == null);
    try model.captureEvent(&ctx, .{ .key_press = commands.bindings.quit });
    try std.testing.expect(ctx.quit);
}

test "mouse tab changes dismiss details but preserve operation modals" {
    vxfw.DrawContext.init(.unicode);
    const model = try Model.init(std.testing.allocator);
    defer model.deinit();
    defer model.overlay = null;
    model.settings_state.settings = .{ .aur_enabled = true, .flatpak_enabled = true };
    model.updates_state.updates_checked = true;
    var native: Package = .{ .Name = "installed", .Installed = true };
    var aur: AurPackage = .{ .Name = "installed-git", .Installed = true };
    const app: flatpak.AppstreamApp = .{ .Id = "org.example.App" };
    var prompt: SudoPrompt = undefined; // Modal routing must not inspect its contents.
    const cases = [_]struct { from: Tab, overlay: Overlay, allowed: bool }{
        .{ .from = .packages, .overlay = .{ .package = &native }, .allowed = true },
        .{ .from = .aur, .overlay = .{ .aur = &aur }, .allowed = true },
        .{ .from = .flatpak, .overlay = .{ .flatpak = .{ .catalog = &app } }, .allowed = true },
        .{ .from = .packages, .overlay = .{ .sudo = &prompt }, .allowed = false },
        .{ .from = .aur, .overlay = .pkgbuild, .allowed = false },
        .{ .from = .flatpak, .overlay = .{ .flatpak_install = .{ .app = &app, .selected = 0 } }, .allowed = false },
    };
    for (cases) |case| {
        model.active = case.from;
        model.overlay = case.overlay;
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const widget = try model.drawTabBar(arena.allocator());
        _ = try widget.draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 140, .height = 3 }, .cell_size = .{ .width = 10, .height = 20 } });
        const bar: *TabBar = @ptrCast(@alignCast(widget.userdata));
        var col = bar.start_col;
        for (bar.label_widths, 0..) |width, index| {
            if (bar.tabs[bar.first_visible + index] == .upgrade) break;
            col += @intCast(width + 1);
        }
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
        defer ctx.cmds.deinit(std.testing.allocator);
        // Padding must not dismiss the current details or modal.
        try TabBar.handleEvent(bar, &ctx, .{ .mouse = .{ .button = .left, .type = .press, .col = 0, .row = bar.label_row, .mods = .{} } });
        try std.testing.expect(model.overlay != null);
        try TabBar.handleEvent(bar, &ctx, .{ .mouse = .{ .button = .left, .type = .press, .col = col, .row = bar.label_row, .mods = .{} } });
        try std.testing.expectEqual(if (case.allowed) Tab.upgrade else case.from, model.active);
        if (case.allowed) {
            try std.testing.expect(model.overlay == null);
            try std.testing.expectEqual(commands.Mode.updates, model.commandContext().mode);
            // Refresh must route to Updates, never reopen the old removal prompt.
            var pending: updates_model.UpdatesJob = .{};
            model.updates_state.updates_job = &pending;
            defer model.updates_state.updates_job = null;
            try model.captureEvent(&ctx, .{ .key_press = commands.bindings.refresh });
            try std.testing.expect(model.overlay == null);
        } else {
            try std.testing.expect(model.overlay != null);
            try std.testing.expectEqualStrings(@tagName(case.overlay), @tagName(model.overlay.?));
        }
    }
}
