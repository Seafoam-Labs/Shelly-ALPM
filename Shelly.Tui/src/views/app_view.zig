const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Allocator = std.mem.Allocator;
const app = @import("../model.zig");
const Model = app.Model;
const Tab = app.Tab;
const SudoPrompt = app.SudoPrompt;
const Package = @import("../models/packages.zig").Package;
const packages_model = @import("../models/packages_model.zig");
const aur_model = @import("../models/aur_model.zig");
const flatpak_model = @import("../models/flatpak_model.zig");
const updates_model = @import("../models/updates_model.zig");
const settings_model = @import("../models/settings_model.zig");
const operation_model = @import("../models/operation_model.zig");
const flatpak_view = @import("flatpak_view.zig");
const footer_view = @import("footer_view.zig");
const split_layout = @import("split_layout.zig");

pub fn draw(self: *Model, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const arena = ctx.arena;
    const max = ctx.max.size();
    self.viewport_width = max.width;

    // Need room for the tab bar, at least one content row and the status bar
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
    const pane_width = if (max.width >= 64) max.width - split_layout.listWidth(max.width, self.list_percent) else max.width;
    self.flatpak_state.screenshot_layout_available = split_layout.imagesFit(pane_width -| 2, content_size.height -| 4);
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
            try operation_model.showOperationQuestion(model, try @import("../services/shelly_operation.zig").decodeJson(std.testing.allocator, question.json));
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
        try operation_model.showOperationQuestion(model, try @import("../services/shelly_operation.zig").decodeJson(std.testing.allocator,
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
