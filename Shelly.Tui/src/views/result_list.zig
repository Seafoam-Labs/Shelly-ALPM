const vxfw = @import("vaxis").vxfw;
const Allocator = @import("std").mem.Allocator;
const commands = @import("../commands.zig");
const Model = @import("../model.zig").Model;

const Kind = enum { packages, aur, flatpak, appimage };

pub fn widget(model: *Model, comptime kind: Kind) vxfw.Widget {
    return .{ .userdata = model, .drawFn = ResultList(kind).draw };
}

fn ResultList(comptime kind: Kind) type {
    const Identity = switch (kind) {
        .packages => *const @import("../models/packages.zig").Package,
        .aur => *const @import("../models/packages.zig").AurPackage,
        .flatpak => @import("flatpak_view.zig").Row,
        .appimage => *const @import("../models/appimage.zig").AppImage,
    };
    return struct {
        model: *Model,
        identities: []const Identity,

        fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
            const model: *Model = @ptrCast(@alignCast(ptr));
            const list = switch (kind) {
                .packages => &model.packages_state.list_view,
                .aur => &model.aur_state.aur_list,
                .flatpak => &model.flatpak_state.flatpak_list,
                .appimage => &model.appimage_state.list_view,
            };
            const surface = try list.draw(ctx);
            // Each result occupies one line. Capture only the visible identities
            // after ListView has adjusted its viewport for scrolling or resizing.
            const items = switch (kind) {
                .packages => model.packages_state.filtered.items,
                .aur => model.aur_state.aur_filtered.items,
                .flatpak => model.flatpak_state.flatpak_rows.items,
                .appimage => model.appimage_state.items(),
            };
            const top = @min(items.len, list.scroll.top);
            const visible = items[top..][0..@min(items.len - top, surface.size.height)];
            const ids = try ctx.arena.alloc(Identity, visible.len);
            for (visible, ids) |*item, *id| id.* = switch (kind) {
                .packages, .aur, .flatpak => item.*,
                .appimage => item,
            };
            const rows = try ctx.arena.create(@This());
            rows.* = .{ .model = model, .identities = ids };
            const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
            children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = surface };
            return .{ .size = surface.size, .children = children, .buffer = &.{}, .widget = .{ .userdata = rows, .drawFn = redraw, .eventHandler = click } };
        }

        fn redraw(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
            const rows: *@This() = @ptrCast(@alignCast(ptr));
            return draw(rows.model, ctx);
        }

        fn click(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
            const rows: *@This() = @ptrCast(@alignCast(ptr));
            if (event != .mouse or !commands.Mouse.primaryPress(event.mouse) or event.mouse.row < 0) return;
            const index: usize = @intCast(event.mouse.row);
            if (index >= rows.identities.len) return;
            const id = rows.identities[index];
            switch (kind) {
                .packages => try commands.Mouse.selectPackageRow(rows.model, ctx, id),
                .aur => try commands.Mouse.selectAurRow(rows.model, ctx, id),
                .flatpak => try commands.Mouse.selectFlatpakRow(rows.model, ctx, id),
                .appimage => try commands.Mouse.selectAppImageRow(rows.model, ctx, id),
            }
        }
    };
}

test "AUR Flatpak and AppImage result clicks select the rendered package" {
    const std = @import("std");
    const aur = @import("../models/aur_model.zig");
    const flatpak = @import("../models/flatpak_model.zig");
    const appimage = @import("../models/appimage_model.zig");
    const allocator = std.testing.allocator;
    const model = try Model.init(allocator);
    defer model.deinit();
    const aur_items = [_]@import("../models/packages.zig").AurPackage{ .{ .Name = "a" }, .{ .Name = "b" } };
    model.aur_state.aur_packages = &aur_items;
    try aur.rebuildAurFilter(model);
    model.flatpak_state.flatpak_installed_only = true;
    model.flatpak_state.flatpak_installed = try std.json.parseFromSlice([]@import("../models/flatpak.zig").Flatpak, allocator,
        \\[{"Id":"editor","InstallLevel":0},{"Id":"editor","InstallLevel":1}]
    , .{ .allocate = .alloc_always });
    try flatpak.rebuildFlatpakFilter(model);
    model.appimage_state.parsed = try std.json.parseFromSlice([]@import("../models/appimage.zig").AppImage, allocator,
        \\[{"Name":"a","Path":"/a"},{"Name":"b","Path":"/b"}]
    , .{ .allocate = .alloc_always });
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 40, .height = 8 }, .cell_size = .{ .width = 10, .height = 20 } };
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    inline for (.{ Kind.aur, Kind.flatpak, Kind.appimage }) |kind| {
        model.active = @field(@import("../model.zig").Tab, @tagName(kind));
        if (kind == .appimage) {
            var children: std.ArrayList(vxfw.SubSurface) = .empty;
            try appimage.appendContent(model, ctx, &children);
        }
        const view = switch (kind) {
            .aur => aur.aurView(model).result_list.?,
            .flatpak => flatpak.flatpakView(model).result_list.?,
            .appimage => appimage.appImageView(model).result_list.?,
            else => unreachable,
        };
        const surface = try view.draw(ctx);
        try surface.widget.handleEvent(&events, .{ .mouse = .{ .row = 1, .col = 0, .button = .left, .type = .press, .mods = .{} } });
        switch (kind) {
            .aur => try std.testing.expectEqual(&aur_items[1], aur.selectedAur(model).?),
            .flatpak => try std.testing.expectEqual(@as(u32, 1), model.flatpak_state.flatpak_list.cursor),
            .appimage => try std.testing.expectEqualStrings("/b", model.appimage_state.selected().?.Path.?),
            else => unreachable,
        }
    }
}
