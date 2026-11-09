const std = @import("std");
const Border = @import("border.zig");
const commands = @import("../commands.zig");
const diagnostics = @import("diagnostics");
const operation = @import("../services/shelly_operation.zig");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Allocator = std.mem.Allocator;

/// Borrowed operation state. Password input goes directly to sudo's terminal.
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
    detail: []const u8 = "",
    progress: operation.Progress = .{},
    refresh_pending: bool = false,

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
                if (self.include_flatpak) "System packages, AUR, and system/user Flatpaks. PKGBUILDs require review. AppImage updates are detected but not managed by the TUI." else "System packages and AUR. Flatpak disabled or unavailable. PKGBUILDs require review. AppImage updates are detected but not managed by the TUI."
            else if (self.include_flatpak) "System packages and system/user Flatpaks. AUR excluded. AppImage updates are detected but not managed by the TUI." else "Full system upgrade. AUR and Flatpak excluded. AppImage updates are detected but not managed by the TUI."
        else if (self.backend == .flatpak)
            if (self.action == .upgrade) "Updates system and user Flatpaks as the invoking user. System changes may require a Flatpak authorization agent." else if (self.action == .remove) "Configuration and unused dependencies will be kept." else "Uses the selected remote and scope. Shelly handles dependencies and review."
        else if (self.action == .remove) "Unused dependencies and configuration will be kept." else if (self.action == .upgrade)
            if (self.backend == .aur) "Upgrade AUR packages and required dependencies. PKGBUILDs require review." else "Full system upgrade. AUR and Flatpak excluded. AppImage updates are detected but not managed by the TUI."
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
        const progress = if (if (self.state == .running) self.progress.percent else null) |reported| blk: {
            const percent = @min(@max(reported, 0), 100);
            const bar_width: usize = width -| 7;
            const bar = try arena.alloc(u8, bar_width);
            const filled = bar_width * @as(usize, @intCast(percent)) / 100;
            @memset(bar[0..filled], '#');
            @memset(bar[filled..], '-');
            break :blk try std.fmt.allocPrint(arena, "[{s}] {d: >3}%", .{ bar, percent });
        } else "";
        var lines: std.ArrayList([]const u8) = .empty;
        if (self.progress.authenticating) {
            if (self.progress.authentication_len > 0)
                try lines.append(arena, try authenticationText(arena, self.progress.authentication[0..self.progress.authentication_len]));
        }
        var last: []const u8 = "";
        for (&self.progress.messages, self.progress.lengths) |*message, len| {
            const text = std.mem.trim(u8, message[0..len], " \t\r\n");
            if (text.len == 0) continue;
            try lines.append(arena, try diagnostics.sanitizeAlloc(arena, text));
            last = text;
        }
        const status = std.mem.trim(u8, self.progress.text(), " \t\r\n");
        if (status.len > 0 and !std.mem.eql(u8, status, last))
            try lines.append(arena, try diagnostics.sanitizeAlloc(arena, status));
        if (lines.items.len == 0 and self.state == .running)
            try lines.append(arena, if (self.progress.authenticating) "Waiting for authentication…" else "Waiting for progress…");
        if (progress.len > 0) try lines.append(arena, progress);
        if (outcome.len > 0) try lines.append(arena, outcome);
        return std.mem.join(arena, "\n", lines.items);
    }
};

// PTYs emit CRLF and PAM can emit standalone carriage returns. Rendering both as line breaks before sanitizing.
fn authenticationText(allocator: Allocator, bytes: []const u8) Allocator.Error![]const u8 {
    const normalized = try allocator.alloc(u8, bytes.len);
    defer allocator.free(normalized);
    var len: usize = 0;
    for (bytes, 0..) |byte, index| {
        if (byte == '\n' and index > 0 and bytes[index - 1] == '\r') continue;
        normalized[len] = if (byte == '\r') '\n' else byte;
        len += 1;
    }
    return diagnostics.sanitizeAlloc(allocator, normalized[0..len]);
}

pub const Action = enum { none, close, confirm };

/// Persistent local interaction state. The coordinator owns this component and
/// its borrowed View data; builders never retain pointers into the draw arena.
pub const Panel = struct {
    view: View = .{ .name = "", .state = .entering },
    scroll: vxfw.ScrollView = .{ .children = .{ .slice = &.{} } },
    initialized: bool = false,
    ready: bool = false,
    follow_output: bool = true,

    fn update(self: *Panel, view: View) void {
        if (!self.initialized) {
            self.scroll = .{ .item_count = 1, .children = .{ .builder = .{ .userdata = self, .buildFn = buildBody } } };
            self.initialized = true;
        }
        if (self.view.state == .entering and view.state != .entering) {
            self.scroll.scroll = .{};
            self.follow_output = true;
        }
        self.view = view;
    }

    pub fn handleKey(self: *Panel, view: View, ctx: *vxfw.EventContext, key: vaxis.Key) !Action {
        self.update(view);
        if (view.state != .entering and view.state != .running and commands.closesResult(key)) return .close;
        if (view.state == .entering) {
            if (commands.matches(key, .cancel) or (!view.elevated and commands.matches(key, .close))) return .close;
            if (commands.matches(key, .confirm)) {
                if (self.ready) return .confirm;
                return .none;
            }
        }
        if (commands.scrollsOperation(key)) {
            const scroll_key = commands.scrollKey(key).?;
            if (scroll_key.matches(vaxis.Key.page_down, .{})) {
                if (self.scroll.scroll.linesDown(@max(self.scroll.last_height, 1))) ctx.consumeAndRedraw();
            } else if (scroll_key.matches(vaxis.Key.page_up, .{})) {
                if (self.scroll.scroll.linesUp(@max(self.scroll.last_height, 1))) ctx.consumeAndRedraw();
            } else try self.scroll.handleEvent(ctx, .{ .key_press = scroll_key });
            return .none;
        }
        return .none;
    }

    pub fn draw(self: *Panel, view: View, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        self.update(view);
        const size = ctx.max.size();
        self.ready = size.width >= 24 and size.height >= 3;
        if (!self.ready) {
            var text: vxfw.Text = .{ .text = "Enlarge the terminal to view the operation." };
            return text.draw(ctx);
        }
        const title = if (view.progress.authenticating)
            "Authentication"
        else if (view.state == .entering)
            (if (view.elevated) "Authentication" else "Confirmation")
        else
            try std.fmt.allocPrint(ctx.arena, "{s} {f} — {s}", .{
                view.action.verb(), diagnostics.safe(view.name),
                switch (view.state) {
                    .entering => if (view.elevated) "Authentication" else "Confirmation",
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
        const review_height = size.height;
        if (view.state != .entering) {
            // Upward keyboard or wheel navigation pauses following.
            if (self.scroll.scroll.pending_lines < 0) self.follow_output = false;
            if (self.follow_output) {
                const document = try drawBody(self, ctx);
                self.scroll.scroll.top = 0;
                self.scroll.scroll.vertical_offset = @intCast(document.size.height -| review_height);
                self.scroll.scroll.pending_lines = 0;
            }
        }
        const output = try self.scroll.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = review_height }));
        if (view.state != .entering and !self.scroll.scroll.has_more_vertical) self.follow_output = true;
        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = output };
        return .{ .size = size, .widget = .{ .userdata = self, .drawFn = drawContent }, .buffer = &.{}, .children = children };
    }
};

test "direct sudo authentication has no password field and sanitizes terminal output" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var view: View = .{ .name = "editor", .state = .entering };
    var panel: Panel = .{ .ready = true };
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);
    try std.testing.expect((try panel.handleKey(view, &ctx, .{ .codepoint = vaxis.Key.enter })) == .confirm);
    try std.testing.expect((try panel.handleKey(view, &ctx, .{ .codepoint = 's', .text = "secret" })) == .none);
    view.state = .running;
    view.progress.authenticating = true;
    const output = "Fingerprint: touch sensor\n\x1b[2JPassword: ";
    @memcpy(view.progress.authentication[0..output.len], output);
    view.progress.authentication_len = output.len;
    const body = try view.body(arena.allocator(), 80);
    try std.testing.expect(std.mem.indexOf(u8, body, "Fingerprint:") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, body, 0x1b) == null);
}

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
    try std.testing.expect((try panel.handleKey(view, &events, .{ .codepoint = vaxis.Key.enter })) == .confirm);
    const input = try panel.handleKey(view, &events, .{ .codepoint = 'q', .text = "q" });
    try std.testing.expect(input == .none);
    try std.testing.expect((try panel.handleKey(view, &events, .{ .codepoint = vaxis.Key.enter })) == .confirm);
    try std.testing.expect((try panel.handleKey(view, &events, .{ .codepoint = vaxis.Key.backspace })) == .none);
    try std.testing.expect((try panel.handleKey(view, &events, .{ .codepoint = 'q', .mods = .{ .ctrl = true } })) == .close);
    view.elevated = false;
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
    try std.testing.expect(!panel.scroll.scroll.has_more_vertical);
    var events: vxfw.EventContext = .{ .io = undefined, .alloc = std.testing.allocator, .cmds = .empty };
    defer events.cmds.deinit(std.testing.allocator);
    _ = try panel.handleKey(view, &events, .{ .codepoint = vaxis.Key.up });
    try std.testing.expect(panel.scroll.scroll.pending_lines < 0);
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
    try std.testing.expectEqualStrings("Preparing transaction\nInstalling editor", unknown_percent);
    for ([_]i64{ 5, 50, 100 }) |percent| {
        view.progress.percent = percent;
        const body = try view.body(arena.allocator(), 100);
        var lines = std.mem.splitScalar(u8, body, '\n');
        try std.testing.expectEqualStrings(message, lines.next().?);
        try std.testing.expectEqualStrings(status, lines.next().?);
        try std.testing.expectEqual(@as(usize, 100), lines.next().?.len);
        try std.testing.expect(lines.next() == null);
    }
}

test "progress panels fit output without duplicated controls" {
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
    const height: u16 = 6; // Four content rows and two borders.
    var panel: Panel = .{};
    const surface = try panel.draw(view, ctx.withConstraints(.{}, .{ .width = 100, .height = height }));
    const content = surface.children[0].surface;
    const output = content.children[0];
    try std.testing.expectEqual(@as(usize, 1), content.children.len);
    try std.testing.expectEqual(@as(u16, 4), output.surface.size.height);
    try std.testing.expect(panel.ready);
    view.progress.percent = 50;
    try std.testing.expectEqual(height, (try panel.draw(view, ctx.withConstraints(.{}, .{ .width = 100, .height = height }))).size.height);
    view.state = .succeeded;
    try std.testing.expectEqual(height, (try panel.draw(view, ctx.withConstraints(.{}, .{ .width = 100, .height = height }))).size.height);
}

test "output remains scrollable without in-panel shortcut hints" {
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var panel: Panel = .{};
    var view: View = .{ .name = "editor", .state = .succeeded };
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 4 }, .cell_size = .{ .width = 10, .height = 20 } };
    const short = try panel.draw(view, ctx);
    try std.testing.expectEqual(@as(usize, 1), short.children[0].surface.children.len);
    view.state = .failed;
    panel.follow_output = false;
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
    try std.testing.expectEqual(@as(usize, 1), scrolled.children[0].surface.children.len);
    _ = try panel.handleKey(view, &events, .{ .codepoint = vaxis.Key.up });
    try std.testing.expect(panel.scroll.scroll.pending_lines < 0);
}

test "expanded operation panels retain chronological output and follow the latest line" {
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var view: View = .{ .name = "packages", .state = .running };
    const status = "Current operation status";
    @memcpy(view.progress.status[0..status.len], status);
    view.progress.status_len = status.len;
    for (0..20) |index| {
        const line = try std.fmt.bufPrint(&view.progress.messages[index], "Operation message {d}", .{index});
        view.progress.lengths[index] = line.len;
    }
    var panel: Panel = .{};
    const surface = try panel.draw(view, .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 100, .height = 14 }, .cell_size = .{ .width = 10, .height = 20 } });
    const output = surface.children[0].surface.children[0].surface;
    try std.testing.expectEqual(@as(u16, 12), output.size.height);
    const body = try view.body(arena.allocator(), 98);
    var lines = std.mem.splitScalar(u8, body, '\n');
    try std.testing.expectEqualStrings("Operation message 0", lines.next().?);
    try std.testing.expectEqualStrings("Operation message 1", lines.next().?);
    try std.testing.expectEqualStrings("Operation message 2", lines.next().?);
    try std.testing.expect(!panel.scroll.scroll.has_more_vertical);
    try std.testing.expect(panel.scroll.scroll.vertical_offset > 0);
    const document = output.children[0].surface;
    try std.testing.expectEqual(@as(u16, 21), document.size.height);
    var ctx: vxfw.EventContext = .{ .io = undefined, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);
    _ = try panel.handleKey(view, &ctx, commands.bindings.page_up);
    try std.testing.expect(panel.scroll.scroll.pending_lines < 0);
}

test "completion preserves history and scrolling without forcing the reader to the bottom" {
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var view: View = .{ .name = "demo", .state = .running };
    for (0..20) |index| {
        const line = try std.fmt.bufPrint(&view.progress.messages[index], "Event {d}", .{index});
        view.progress.lengths[index] = line.len;
    }
    var panel: Panel = .{};
    const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 8 }, .cell_size = .{ .width = 10, .height = 20 } };
    _ = try panel.draw(view, draw_ctx);
    try std.testing.expect(panel.follow_output);
    try std.testing.expect(panel.scroll.scroll.vertical_offset > 0);
    var ctx: vxfw.EventContext = .{ .io = undefined, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);
    _ = try panel.handleKey(view, &ctx, commands.bindings.page_up);
    _ = try panel.draw(view, draw_ctx);
    try std.testing.expect(!panel.follow_output);
    const position = panel.scroll.scroll.vertical_offset;
    const newest = "Event 20";
    @memcpy(view.progress.messages[20][0..newest.len], newest);
    view.progress.lengths[20] = newest.len;
    _ = try panel.draw(view, draw_ctx);
    try std.testing.expectEqual(position, panel.scroll.scroll.vertical_offset);
    for ([_]@TypeOf(view.state){ .succeeded, .failed, .declined }) |state| {
        view.state = state;
        _ = try panel.draw(view, draw_ctx);
        try std.testing.expectEqual(position, panel.scroll.scroll.vertical_offset);
        const body = try view.body(arena.allocator(), 78);
        try std.testing.expect(std.mem.startsWith(u8, body, "Event 0\nEvent 1\n"));
        try std.testing.expect(std.mem.indexOf(u8, body, "Event 20") != null);
        try std.testing.expect(panel.scroll.scroll.has_more_vertical);
    }
    _ = try panel.handleKey(view, &ctx, commands.bindings.page_down);
    _ = try panel.draw(view, draw_ctx);
    try std.testing.expect(panel.follow_output);
    try std.testing.expect(!panel.scroll.scroll.has_more_vertical);
    _ = try panel.handleKey(view, &ctx, commands.bindings.previous);
    _ = try panel.draw(view, draw_ctx);
    try std.testing.expect(!panel.follow_output);
    try std.testing.expectEqual(Action.close, try panel.handleKey(view, &ctx, commands.bindings.close));
}

test "authentication normalizes PTY line endings while escaping other controls" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var view: View = .{ .name = "demo", .state = .running };
    view.progress.authenticating = true;
    const output = "Touch sensor\r\nTry again\rPassword: \x1b[2J\x00";
    @memcpy(view.progress.authentication[0..output.len], output);
    view.progress.authentication_len = output.len;
    const body = try view.body(allocator, 80);
    try std.testing.expectEqualStrings("Touch sensor\nTry again\nPassword: \\x1b[2J\\x00", body);
    const split = "Touch sensor\r";
    @memcpy(view.progress.authentication[0..split.len], split);
    view.progress.authentication_len = split.len;
    const before = try view.body(allocator, 80);
    view.progress.authentication[split.len] = '\n';
    view.progress.authentication_len += 1;
    const after = try view.body(allocator, 80);
    try std.testing.expectEqualStrings("Touch sensor\n", before);
    try std.testing.expectEqualStrings(before, after);
}
