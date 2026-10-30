const std = @import("std");
const Border = @import("border.zig");
const commands = @import("../commands.zig");
const diagnostics = @import("diagnostics");
const operation = @import("../services/shelly_operation.zig");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Allocator = std.mem.Allocator;

/// Borrowed operation state. Password contents stay with the coordinator;
/// this component receives only the number of masking characters.
pub const View = struct {
    name: []const u8,
    backend: operation.Backend = .standard,
    elevated: bool = true,
    combined: bool = false,
    include_aur: bool = true,
    include_flatpak: bool = true,
    target: ?operation.FlatpakTarget = null,
    action: operation.Action = .install,
    state: enum { entering, running, succeeded, failed, declined },
    review: []const u8 = "",
    password_length: usize = 0,
    detail: []const u8 = "",
    progress: operation.Progress = .{},
    refresh_pending: bool = false,

    fn footerRows(self: View, width: u16) u16 {
        return if (self.state == .entering) (if (width >= 60) @as(u16, 2) else 3) else 1;
    }

    /// Measure wrapped content up to the panel limit instead of reserving
    /// empty rows. Longer output is still handled by the scroll view.
    pub fn preferredHeight(self: View, ctx: vxfw.DrawContext, limit: u16) Allocator.Error!u16 {
        const width = ctx.max.size().width -| 2;
        const controls = self.footerRows(width) + 2;
        if (limit <= controls) return limit;
        var text: vxfw.Text = .{ .text = try self.body(ctx.arena, width), .softwrap = true };
        const measured = try text.draw(ctx.withConstraints(.{}, .{ .width = width, .height = limit - controls }));
        return @min(limit, @max(@as(u16, 1), measured.size.height) + controls);
    }

    fn confirmation(self: View, arena: Allocator) Allocator.Error![]const u8 {
        if (self.review.len > 0) return std.mem.trim(u8, self.review, "\r\n");
        const target = if (self.target) |value|
            try std.fmt.allocPrint(arena, "\nScope: {s}\nRemote: {f}\nBranch: {f}\nArchitecture: {f}", .{
                @tagName(value.scope),                                                          diagnostics.safe(value.remote),
                diagnostics.safe(if (value.branch.len > 0) value.branch else "remote default"), diagnostics.safe(if (value.arch.len > 0) value.arch else "remote default"),
            })
        else
            "";
        const note: []const u8 = if (self.combined)
            if (self.include_aur)
                if (self.include_flatpak) "System packages, AUR, and system/user Flatpaks. AppImages excluded. PKGBUILDs require review." else "System packages and AUR. Flatpak disabled or unavailable; AppImages excluded. PKGBUILDs require review."
            else if (self.include_flatpak) "System packages and system/user Flatpaks. AUR and AppImages excluded." else "Full system upgrade. AUR, Flatpak, and AppImages excluded."
        else if (self.backend == .flatpak)
            if (self.action == .upgrade) "Updates system and user Flatpaks as the invoking user. System changes may require a Flatpak authorization agent." else if (self.action == .remove) "Configuration and unused dependencies will be kept." else "Uses the selected remote and scope. Shelly handles dependencies and review."
        else if (self.action == .remove) "Unused dependencies and configuration will be kept." else if (self.action == .upgrade)
            if (self.backend == .aur) "Upgrade AUR packages and required dependencies. PKGBUILDs require review." else "Full system upgrade. AUR, Flatpak, and AppImages excluded."
        else if (self.backend == .aur) "PKGBUILDs require review before installation." else "";
        return std.fmt.allocPrint(arena, "{s} {f}?{s}\n\n{s}", .{ self.action.verb(), diagnostics.safe(self.name), target, note });
    }

    fn body(self: View, arena: Allocator, width: u16) Allocator.Error![]const u8 {
        if (self.state == .entering) return self.confirmation(arena);
        const outcome = switch (self.state) {
            .entering => unreachable,
            .running => "",
            .succeeded => try std.fmt.allocPrint(arena, "{s} {f} successfully.{s}", .{ self.action.completed(), diagnostics.safe(self.name), if (self.refresh_pending) "\nRefreshing package state…" else "" }),
            .declined => try std.fmt.allocPrint(arena, "Declined {s} for {f}.\nSome dependency changes may already have completed.", .{ @tagName(self.action), diagnostics.safe(self.name) }),
            .failed => try std.fmt.allocPrint(arena, "Could not {s} {f}.\n\n{f}{s}", .{
                @tagName(self.action),                                                                           diagnostics.safe(self.name),
                diagnostics.safe(if (self.detail.len > 0) self.detail else "Shelly returned no error details."), if (self.combined) "\nSome sources may already have completed. Package state will be refreshed." else "",
            }),
        };
        if (self.state != .running) return outcome;
        const progress = if (self.progress.percent) |reported| blk: {
            const percent = @min(@max(reported, 0), 100);
            const bar_width: usize = width -| 7;
            const bar = try arena.alloc(u8, bar_width);
            const filled = bar_width * @as(usize, @intCast(percent)) / 100;
            @memset(bar[0..filled], '#');
            @memset(bar[filled..], '-');
            break :blk try std.fmt.allocPrint(arena, "[{s}] {d: >3}%", .{ bar, percent });
        } else "";
        var lines: std.ArrayList([]const u8) = .empty;
        const status = std.mem.trim(u8, self.progress.text(), " \t\r\n");
        try lines.append(arena, if (status.len > 0) try diagnostics.sanitizeAlloc(arena, status) else "Waiting for progress…");
        if (progress.len > 0) try lines.append(arena, progress);
        for (self.progress.messages, self.progress.lengths) |line, len| {
            const message = std.mem.trim(u8, line[0..len], " \t\r\n");
            if (message.len == 0 or std.mem.eql(u8, message, status)) continue;
            try lines.append(arena, try diagnostics.sanitizeAlloc(arena, message));
        }
        return std.mem.join(arena, "\n", lines.items);
    }
};

pub const Action = union(enum) { none, close, confirm, erase, text: []const u8 };

/// Persistent local interaction state. The coordinator owns this component and
/// its borrowed View data; builders never retain pointers into the draw arena.
pub const Panel = struct {
    view: View = .{ .name = "", .state = .entering },
    scroll: vxfw.ScrollView = .{ .children = .{ .slice = &.{} } },
    initialized: bool = false,
    ready: bool = false,

    fn update(self: *Panel, view: View) void {
        if (!self.initialized) {
            self.scroll = .{ .item_count = 1, .children = .{ .builder = .{ .userdata = self, .buildFn = buildBody } } };
            self.initialized = true;
        }
        if (self.view.state != view.state) self.scroll.scroll = .{};
        self.view = view;
    }

    pub fn handleKey(self: *Panel, view: View, ctx: *vxfw.EventContext, key: vaxis.Key) !Action {
        self.update(view);
        if (view.state != .entering and view.state != .running and commands.closesResult(key)) return .close;
        if (view.state == .entering) {
            if (key.matches('q', .{ .ctrl = true }) or (!view.elevated and key.matches('q', .{}))) return .close;
            if (key.matches(vaxis.Key.enter, .{})) {
                if (self.ready and (!view.elevated or view.password_length > 0)) return .confirm;
                return .none;
            }
        }
        if (commands.scrollsOperation(key)) {
            try self.scroll.handleEvent(ctx, .{ .key_press = key });
            return .none;
        }
        if (view.state == .entering and view.elevated) {
            if (key.matches(vaxis.Key.backspace, .{})) return .erase;
            if (key.text) |text| return .{ .text = text };
        }
        return .none;
    }

    pub fn draw(self: *Panel, view: View, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        self.update(view);
        const size = ctx.max.size();
        self.ready = size.width >= 24 and size.height >= view.footerRows(size.width -| 2) + 3;
        if (!self.ready) {
            var text: vxfw.Text = .{ .text = "Enlarge the terminal to view the operation." };
            return text.draw(ctx);
        }
        const title = try std.fmt.allocPrint(ctx.arena, "{s} {f} — {s}", .{
            view.action.verb(), diagnostics.safe(view.name),
            switch (view.state) {
                .entering => if (view.elevated) "Authorization" else "Confirmation",
                .running => "Running",
                .succeeded => "Complete",
                .failed => "Failed",
                .declined => "Declined",
            },
        });
        const labels = [_]Border.BorderLabel{.{ .text = title, .alignment = .top_left }};
        var border: Border = .{ .child = .{ .userdata = self, .drawFn = drawContent }, .labels = &labels };
        return border.draw(ctx.withConstraints(size, .{ .width = size.width, .height = size.height }));
    }

    fn buildBody(ptr: *const anyopaque, index: usize, _: usize) ?vxfw.Widget {
        if (index != 0) return null;
        return .{ .userdata = @constCast(ptr), .drawFn = drawBody };
    }

    fn drawBody(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Panel = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse ctx.min.width;
        var text: vxfw.Text = .{ .text = try self.view.body(ctx.arena, width), .softwrap = true };
        return text.draw(ctx.withConstraints(.{ .width = width }, .{ .width = width, .height = null }));
    }

    fn drawContent(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Panel = @ptrCast(@alignCast(ptr));
        const view = self.view;
        const size = ctx.max.size();
        const compact_controls = size.width >= 60;
        const footer_height = view.footerRows(size.width);
        const review_height = size.height -| footer_height;
        const output = try self.scroll.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = review_height }));
        const scrollable = self.scroll.scroll.has_more_vertical or self.scroll.scroll.top > 0 or self.scroll.scroll.vertical_offset != 0;
        const footer = if (view.state == .entering) blk: {
            const mask = try ctx.arena.alloc(u8, @min(view.password_length, size.width -| 10));
            @memset(mask, '*');
            const hints = if (compact_controls)
                if (scrollable) "↑↓: review  Ctrl+Q: back  Enter: run  Esc: quit" else "Ctrl+Q: back  Enter: run  Esc: quit"
            else if (scrollable) "↑↓: review  Ctrl+Q: back\nEnter: run  Esc: quit" else "Ctrl+Q: back\nEnter: run  Esc: quit";
            break :blk try std.fmt.allocPrint(ctx.arena, "{s}{s}\n{s}", .{ if (view.elevated) "Password: " else "No elevation required.", if (view.elevated) mask else "", hints });
        } else if (view.state == .running)
            if (scrollable) "↑↓: output  Esc: quit" else "Esc: quit"
        else if (scrollable) "↑↓: output  Enter/Q: close" else "Enter/Q: close  Esc: quit";
        var text: vxfw.Text = .{ .text = footer, .softwrap = false, .overflow = .ellipsis };
        const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = output };
        children[1] = .{ .origin = .{ .row = @intCast(review_height), .col = 0 }, .surface = try text.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = footer_height })) };
        return .{ .size = size, .widget = .{ .userdata = self, .drawFn = drawContent }, .buffer = &.{}, .children = children };
    }
};

test "operation panel emits authentication actions without handling passwords" {
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var panel: Panel = .{};
    var view: View = .{ .name = "editor", .state = .entering, .review = "Install: editor" };
    const draw_ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 80, .height = 10 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    _ = try panel.draw(view, draw_ctx);
    var events: vxfw.EventContext = .{ .io = undefined, .alloc = std.testing.allocator, .cmds = .empty };
    defer events.cmds.deinit(std.testing.allocator);
    try std.testing.expect((try panel.handleKey(view, &events, .{ .codepoint = vaxis.Key.enter })) == .none);
    const input = try panel.handleKey(view, &events, .{ .codepoint = 'q', .text = "q" });
    try std.testing.expectEqualStrings("q", input.text); // q can be part of a password.
    view.password_length = 3;
    try std.testing.expect((try panel.handleKey(view, &events, .{ .codepoint = vaxis.Key.enter })) == .confirm);
    try std.testing.expect((try panel.handleKey(view, &events, .{ .codepoint = vaxis.Key.backspace })) == .erase);
    try std.testing.expect((try panel.handleKey(view, &events, .{ .codepoint = 'q', .mods = .{ .ctrl = true } })) == .close);
    view.elevated = false;
    view.password_length = 0;
    try std.testing.expect((try panel.handleKey(view, &events, .{ .codepoint = vaxis.Key.enter })) == .confirm);
    view.state = .running;
    try std.testing.expect((try panel.handleKey(view, &events, .{ .codepoint = 'q' })) == .none);
    view.state = .succeeded;
    try std.testing.expect((try panel.handleKey(view, &events, .{ .codepoint = 'q' })) == .close);
    view.state = .entering;
    _ = try panel.draw(view, draw_ctx.withConstraints(.{}, .{ .width = 20, .height = 6 }));
    try std.testing.expect((try panel.handleKey(view, &events, .{ .codepoint = vaxis.Key.enter })) == .none);
}

test "operation panel wraps long results and scrolls output independently" {
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var panel: Panel = .{};
    var view: View = .{
        .name = "packages",
        .state = .failed,
        .detail = "First error\nSecond error\nThird error\nFourth error\nFifth error\nSixth error\nSeventh error",
    };
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 40, .height = 8 }, .cell_size = .{ .width = 10, .height = 20 } };
    const surface = try panel.draw(view, ctx);
    try std.testing.expectEqual(@as(u16, 40), surface.size.width);
    try std.testing.expectEqual(@as(u16, 8), surface.size.height);
    try std.testing.expect(panel.scroll.scroll.has_more_vertical);
    var events: vxfw.EventContext = .{ .io = undefined, .alloc = std.testing.allocator, .cmds = .empty };
    defer events.cmds.deinit(std.testing.allocator);
    _ = try panel.handleKey(view, &events, .{ .codepoint = vaxis.Key.down });
    try std.testing.expect(panel.scroll.scroll.pending_lines > 0);
    view.state = .running;
    view.progress.percent = 150;
    _ = try panel.draw(view, ctx);
    try std.testing.expectEqual(@as(i17, 0), panel.scroll.scroll.pending_lines);
    const body = try view.body(arena.allocator(), 38);
    try std.testing.expect(std.mem.indexOf(u8, body, "100%") != null);
}

test "running output uses pane width without blank placeholder rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var view: View = .{ .name = "packages", .state = .running };
    const status = "Installing editor";
    @memcpy(view.progress.status[0..status.len], status);
    view.progress.status_len = status.len;
    const message = "Preparing transaction";
    @memcpy(view.progress.messages[0][0..message.len], message);
    view.progress.lengths[0] = message.len;
    @memcpy(view.progress.messages[1][0..status.len], status);
    view.progress.lengths[1] = status.len;
    const unknown_percent = try view.body(arena.allocator(), 100);
    try std.testing.expectEqualStrings("Installing editor\nPreparing transaction", unknown_percent);
    for ([_]i64{ 5, 50, 100 }) |percent| {
        view.progress.percent = percent;
        const body = try view.body(arena.allocator(), 100);
        var lines = std.mem.splitScalar(u8, body, '\n');
        try std.testing.expectEqualStrings(status, lines.next().?);
        try std.testing.expectEqual(@as(usize, 100), lines.next().?.len);
        try std.testing.expectEqualStrings(message, lines.next().?);
        try std.testing.expect(lines.next() == null);
    }
}

test "short progress content has no unused rows above the controls" {
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var view: View = .{ .name = "foot", .state = .running };
    const status = "Checking package archive (1/1): foot";
    @memcpy(view.progress.status[0..status.len], status);
    view.progress.status_len = status.len;
    const messages = [_][]const u8{ "Checking package integrity…", "Package integrity check finished.", "Loading packages..." };
    for (messages, 0..) |message, i| {
        @memcpy(view.progress.messages[i][0..message.len], message);
        view.progress.lengths[i] = message.len;
    }
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 100, .height = 24 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const height = try view.preferredHeight(ctx, 9);
    try std.testing.expectEqual(@as(u16, 7), height); // Four content rows, controls, two borders.
    var panel: Panel = .{};
    const surface = try panel.draw(view, ctx.withConstraints(.{}, .{ .width = 100, .height = height }));
    const content = surface.children[0].surface;
    const output = content.children[0];
    const controls = content.children[1];
    try std.testing.expectEqual(@as(u16, 4), output.surface.size.height);
    try std.testing.expectEqual(@as(i17, 4), controls.origin.row);
    try std.testing.expect(panel.ready);
    view.progress.percent = 50;
    try std.testing.expectEqual(@as(u16, 8), try view.preferredHeight(ctx, 9));
    view.state = .succeeded;
    try std.testing.expectEqual(@as(u16, 4), try view.preferredHeight(ctx, 9));
}

test "scroll hints reflect overflow and remain available when scrolled to the end" {
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var panel: Panel = .{};
    var view: View = .{ .name = "editor", .state = .succeeded };
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 4 }, .cell_size = .{ .width = 10, .height = 20 } };
    const short = try panel.draw(view, ctx);
    const short_footer = short.children[0].surface.children[1].surface;
    var short_text: std.ArrayList(u8) = .empty;
    for (short_footer.buffer) |cell| try short_text.appendSlice(arena.allocator(), cell.char.grapheme);
    try std.testing.expect(std.mem.indexOf(u8, short_text.items, "↑↓") == null);
    try std.testing.expect(std.mem.indexOf(u8, short_text.items, "Enter/Q") != null);
    view.state = .failed;
    view.detail = "First line\nSecond line\nThird line\nFourth line\nFifth line\nSixth line\nSeventh line";
    const tall_ctx = ctx.withConstraints(.{}, .{ .width = 80, .height = 8 });
    _ = try panel.draw(view, tall_ctx);
    try std.testing.expect(panel.scroll.scroll.has_more_vertical);
    var events: vxfw.EventContext = .{ .io = undefined, .alloc = std.testing.allocator, .cmds = .empty };
    defer events.cmds.deinit(std.testing.allocator);
    for (0..16) |_| {
        _ = try panel.handleKey(view, &events, .{ .codepoint = vaxis.Key.down });
        _ = try panel.draw(view, tall_ctx);
    }
    try std.testing.expect(panel.scroll.scroll.top > 0 or panel.scroll.scroll.vertical_offset != 0);
    const scrolled = try panel.draw(view, tall_ctx);
    const footer = scrolled.children[0].surface.children[1].surface;
    var text: std.ArrayList(u8) = .empty;
    for (footer.buffer) |cell| try text.appendSlice(arena.allocator(), cell.char.grapheme);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "↑↓") != null);
    _ = try panel.handleKey(view, &events, .{ .codepoint = vaxis.Key.up });
    try std.testing.expect(panel.scroll.scroll.pending_lines < 0);
}
