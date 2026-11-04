const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Border = @This();

pub const BorderLabel = vxfw.Border.BorderLabel;

child: vxfw.Widget,
style: vaxis.Style = .{},
focused: bool = false,
labels: []const BorderLabel = &.{},

pub fn widget(self: *const Border) vxfw.Widget {
    return .{ .userdata = @constCast(self), .drawFn = drawFn };
}

fn drawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *const Border = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

pub fn draw(self: *const Border, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    var border: vxfw.Border = .{ .child = self.child, .style = if (self.focused) .{ .fg = .{ .index = 7 }, .bold = true } else self.style, .labels = self.labels };
    var surface = try border.draw(ctx);
    surface.widget = self.widget();
    // Keep Vaxis sizing, labels and child placement; strengthen only frame cells.
    if (surface.size.width >= 2 and surface.size.height >= 2) {
        const width: usize = surface.size.width;
        const bottom = (surface.size.height - 1) * width;
        const positions = [_]usize{ 0, width - 1, bottom, bottom + width - 1 };
        const corners = if (self.focused) [_][]const u8{ "┏", "┓", "┗", "┛" } else [_][]const u8{ "┌", "┐", "└", "┘" };
        for (positions, corners) |index, corner| surface.buffer[index].char.grapheme = corner;
        if (self.focused) {
            for (1..width - 1) |col| {
                for ([_]usize{ col, bottom + col }) |index| {
                    if (std.mem.eql(u8, surface.buffer[index].char.grapheme, "─"))
                        surface.buffer[index].char.grapheme = "━";
                }
            }
            for (1..surface.size.height - 1) |row| {
                surface.buffer[row * width].char.grapheme = "┃";
                surface.buffer[row * width + width - 1].char.grapheme = "┃";
            }
        }
    }
    return surface;
}
