const styles = @import("styles.zig");
const std = @import("std");
const vxfw = @import("vaxis").vxfw;
const commands = @import("../../commands.zig");
const app = @import("../../model.zig");
const Allocator = std.mem.Allocator;

pub fn append(ctx: vxfw.DrawContext, children: *std.ArrayList(vxfw.SubSurface), row: u16, owner: ?*app.Model, count: usize, removable: bool) Allocator.Error!u16 {
    const model = owner orelse return 0;
    const size = ctx.max.size();
    if (!model.settings_state.settings.expanded_mouse_support or size.width < 9 or size.height < 2 or count == 0 or model.help_open or model.overlay != null or model.operation_state.install_job != null or model.operation_state.review_prompt != null) return 0;
    const header = try ctx.arena.create(Header);
    header.* = .{ .model = model, .tab = model.active, .count = count, .removable = removable };
    const surface = try Header.draw(header, ctx);
    try children.append(ctx.arena, .{ .origin = .{ .row = @intCast(row), .col = 0 }, .surface = surface });
    return surface.size.height;
}

const Header = struct {
    model: *app.Model,
    tab: app.Tab,
    count: usize,
    removable: bool,

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Header = @ptrCast(@alignCast(ptr));
        const size = ctx.max.size();
        var children: std.ArrayList(vxfw.SubSurface) = .empty;
        const caption = try std.fmt.allocPrint(ctx.arena, "{d} selected", .{self.count});
        var label: vxfw.Text = .{ .text = caption, .softwrap = false };
        const actions_width: u16 = if (self.removable) 18 else 9;
        const separate = size.width < caption.len + 1 + actions_width;
        var row: u16 = 0;
        var col: u16 = 0;
        if (!separate or size.height >= 3) {
            try children.append(ctx.arena, .{ .origin = .{ .col = 0, .row = 0 }, .surface = try label.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = 1 })) });
            if (separate) row = 1 else col = size.width - actions_width;
        }
        for ([_]commands.PackageAction{ .install, .remove }) |action| {
            if (action == .remove and !self.removable) continue;
            const button = try ctx.arena.create(Button);
            button.* = .{ .header = self, .action = action };
            const width: u16 = @intCast(button.label().len);
            if (@as(u32, col) + width > size.width) {
                row += 1;
                col = 0;
            }
            if (row >= size.height) break;
            try children.append(ctx.arena, .{ .origin = .{ .col = col, .row = row }, .surface = try Button.draw(button, ctx.withConstraints(.{}, .{ .width = width, .height = 1 })) });
            col += width + 1;
        }
        return .{ .size = .{ .width = size.width, .height = @min(row + 1, size.height) }, .widget = .{ .userdata = ptr, .drawFn = draw }, .buffer = &.{}, .children = children.items };
    }
};

const Button = struct {
    header: *Header,
    action: commands.PackageAction,

    fn label(self: Button) []const u8 {
        return if (self.action == .install) "[Install]" else "[Remove]";
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Button = @ptrCast(@alignCast(ptr));
        var text: vxfw.Text = .{ .text = self.label(), .style = @import("styles.zig").action, .softwrap = false };
        var surface = try text.draw(ctx);
        surface.widget = .{ .userdata = ptr, .drawFn = draw, .eventHandler = click };
        try styles.hoverLabel(ctx.arena, &surface);
        return surface;
    }

    fn click(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        if (event != .mouse or !commands.Mouse.primaryPress(event.mouse)) return;
        const self: *Button = @ptrCast(@alignCast(ptr));

        try commands.Mouse.markedAction(self.header.model, self.header.tab, self.action);
        ctx.consumeAndRedraw();
    }
};

test "marked header clicks open the batch prompt for each package source" {
    const packages = @import("../../models/packages_model.zig");
    const aur = @import("../../models/aur_model.zig");
    const types = @import("../../models/packages.zig");
    vxfw.DrawContext.init(.unicode);
    for ([_]app.Tab{ .packages, .aur }) |tab| {
        for ([_]commands.PackageAction{ .install, .remove }) |action| {
            const model = try app.Model.init(std.testing.allocator);
            defer model.deinit();
            model.settings_state.settings.expanded_mouse_support = true;
            model.active = tab;
            model.settings_state.settings.aur_enabled = true;
            var native = [_]types.Package{.{ .Name = "chosen", .Installed = true }};
            const community = [_]types.AurPackage{.{ .Name = "chosen", .Installed = true }};
            if (tab == .packages) {
                model.packages_state.packages = &native;
                model.packages_state.loading = false;
                try packages.rebuildFilter(model);
                try packages.toggleSelectedList(model);
            } else {
                model.aur_state.aur_packages = &community;
                try aur.rebuildAurFilter(model);
                try aur.toggleAurSelection(model);
            }
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();
            const ctx: vxfw.DrawContext = .{ .arena = alloc, .min = .{}, .max = .{ .width = 32, .height = 6 }, .cell_size = .{ .width = 10, .height = 20 } };
            var children: std.ArrayList(vxfw.SubSurface) = .empty;
            try std.testing.expectEqual(0, try append(ctx, &children, 4, model, 0, false));
            try std.testing.expectEqual(1, try append(ctx, &children, 4, model, 1, true));
            const surface = children.items[0].surface;
            var hits: std.ArrayList(vxfw.HitResult) = .empty;
            try surface.hitTest(alloc, &hits, .{ .row = 0, .col = if (action == .install) 15 else 25 });
            const hit = hits.getLast();
            var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = alloc, .cmds = .empty };
            try hit.widget.handleEvent(&events, .{ .mouse = .{ .row = @intCast(hit.local.row), .col = @intCast(hit.local.col), .button = .left, .type = .press, .mods = .{} } });
            const prompt = model.overlay.?.sudo;
            try std.testing.expectEqualStrings(@tagName(action), @tagName(prompt.action));
            try std.testing.expectEqual(@as(usize, 1), prompt.targets.len);
            try std.testing.expectEqualStrings("chosen", prompt.targets[0]);
        }
    }
}
