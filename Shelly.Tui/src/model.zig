const command_context = @import("command_context.zig");
const app_view = @import("views/app_view.zig");
const tab_bar_view = @import("views/tab_bar.zig");
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
const flatpak_view = @import("views/flatpak_view.zig");
const diagnostics = @import("diagnostics");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const runtime = @import("runtime.zig");
const Package = @import("models/packages.zig").Package;
const AurPackage = @import("models/packages.zig").AurPackage;

const flatpak = @import("models/flatpak.zig");

const Allocator = std.mem.Allocator;

pub const Tab = tab_bar_view.Tab;

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
                                try aur_model.ensureAur(self, ctx);
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
                            try aur_model.ensureAur(self, ctx);
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
                _ = try aur_model.pollAurSearch(self);
                const installing = try operation_model.pollInstall(self);
                updates_model.pollUpdates(self);
                try updates_model.ensureUpdates(self, ctx);
                try aur_model.ensureAur(self, ctx);
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
                    if (aur_model.catalogActive(self) or self.aur_state.aur_installed_only or self.aur_state.aur_query.len > 0) try aur_model.startAurSearch(self, ctx, self.aur_state.aur_query);
                    self.aur_state.refresh_aur_after_operation = false;
                }
                if (loading or installing or self.packages_state.loading or self.updates_state.updates_job != null or self.operation_state.pkgbuild_job != null or self.flatpak_state.flatpak_job != null or self.flatpak_state.flatpak_probe_job != null) {
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
                    if (overlay == .pkgbuild and self.operation_state.pkgbuild_document != null and !operation_model.pkgbuildView(self).loading) {
                        return operation_model.handleReviewMouse(self, ctx, event);
                    }
                }
                if (self.active == .upgrade and self.overlay == null)
                    return updates_model.handleScrollEvent(self, ctx, event);
            },
            else => {},
        }
    }

    /// Read frontend preferences and the shared CLI AUR source before the first frame.
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
        try aur_model.ensureAur(self, ctx);
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
        return app_view.draw(self, ctx);
    }

    pub fn drawTabBar(self: *Model, arena: Allocator) Allocator.Error!vxfw.Widget {
        return tab_bar_view.create(arena, .{
            .tabs = self.visibleTabs(),
            .active = self.active,
            .header_icons = self.settings_state.settings.header_icons,
            .userdata = self,
            .on_select = onTabSelected,
        });
    }

    fn onTabSelected(ptr: *anyopaque, ctx: *vxfw.EventContext, tab: Tab) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        try self.setTab(tab, ctx);
    }

    pub fn commandContext(self: *Model) commands.Context {
        return command_context.resolve(self);
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
        const bar: *tab_bar_view.TabBar = @ptrCast(@alignCast(widget.userdata));
        var col = bar.start_col;
        for (bar.label_widths, 0..) |width, index| {
            if (bar.tabs[bar.first_visible + index] == .upgrade) break;
            col += @intCast(width + 1);
        }
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
        defer ctx.cmds.deinit(std.testing.allocator);
        // Padding must not dismiss the current details or modal.
        try tab_bar_view.TabBar.handleEvent(bar, &ctx, .{ .mouse = .{ .button = .left, .type = .press, .col = 0, .row = bar.label_row, .mods = .{} } });
        try std.testing.expect(model.overlay != null);
        try tab_bar_view.TabBar.handleEvent(bar, &ctx, .{ .mouse = .{ .button = .left, .type = .press, .col = col, .row = bar.label_row, .mods = .{} } });
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
