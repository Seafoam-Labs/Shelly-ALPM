const std = @import("std");
const diagnostics = @import("diagnostics");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

pub const View = struct {
    name: []const u8,
    state: enum { running, succeeded, failed },
    detail: []const u8 = "",

    pub const Action = enum { none, close };

    pub fn handleKey(self: View, key: vaxis.Key) Action {
        if (self.state == .running) return .none;
        if (key.matches(vaxis.Key.escape, .{}) or
            key.matches(vaxis.Key.enter, .{}) or
            key.matches('q', .{})) return .close;
        return .none;
    }

    pub fn draw(self: View, ctx: vxfw.DrawContext) std.mem.Allocator.Error!?vxfw.SubSurface {
        const arena = ctx.arena;
        const max = ctx.max.size();
        const body = switch (self.state) {
            .running => try std.fmt.allocPrint(arena, "Installing '{0f}' as root…", .{diagnostics.safe(self.name)}),
            .succeeded => try std.fmt.allocPrint(arena, "✔ '{0f}' was installed successfully.\n\nEsc: close", .{diagnostics.safe(self.name)}),
            .failed => try std.fmt.allocPrint(arena, "Could not install {0f}.\n\n{1f}\n\nEsc: close", .{ diagnostics.safe(self.name), diagnostics.safe(if (self.detail.len > 0) self.detail else "Shelly returned no error details.") }),
        };
        const box_width = @min(max.width -| 2, @as(u16, 70));
        const box_height = @min(max.height -| 2, @as(u16, 20));
        if (box_width < 30 or box_height < 8) return null;

        var text: vxfw.Text = .{ .text = body };
        const labels = [_]vxfw.Border.BorderLabel{.{ .text = "Installation", .alignment = .top_left }};
        var border: vxfw.Border = .{
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
