const std = @import("std");
const diagnostics = @import("diagnostics");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

pub const View = struct {
    name: []const u8,
    action: @import("shelly_operation.zig").Action = .install,
    state: enum { running, succeeded, failed },
    detail: []const u8 = "",
    progress: @import("shelly_operation.zig").Progress = .{},

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
        const outcome = switch (self.state) {
            .running => try std.fmt.allocPrint(arena, "{s} '{f}' as root…", .{ self.action.ongoing(), diagnostics.safe(self.name) }),
            .succeeded => try std.fmt.allocPrint(arena, "✔ {s} '{f}' successfully.\n\nEsc: close", .{ self.action.completed(), diagnostics.safe(self.name) }),
            .failed => try std.fmt.allocPrint(arena, "Could not {s} {f}.\n\n{f}\n\nEsc: close", .{ @tagName(self.action), diagnostics.safe(self.name), diagnostics.safe(if (self.detail.len > 0) self.detail else "Shelly returned no error details.") }),
        };
        const percentage = if (self.progress.percent) |percent|
            try std.fmt.allocPrint(arena, " ({d}%)", .{percent})
        else
            "";
        var recent: std.ArrayList(u8) = .empty;
        for (self.progress.messages, self.progress.lengths) |line, len| {
            if (len == 0) continue;
            const safe_line = try diagnostics.sanitizeAlloc(arena, line[0..len]);
            try recent.appendSlice(arena, safe_line);
            try recent.append(arena, '\n');
        }
        const body = try std.fmt.allocPrint(arena, "{s}\n\n{f}{s}\n\n{s}", .{
            outcome, diagnostics.safe(self.progress.text()), percentage, recent.items,
        });
        const box_width = @min(max.width -| 2, @as(u16, 70));
        const box_height = @min(max.height -| 2, @as(u16, 20));
        if (box_width < 30 or box_height < 8) return null;

        var text: vxfw.Text = .{ .text = body };
        const labels = [_]vxfw.Border.BorderLabel{.{ .text = if (self.action == .install) "Installation" else "Removal", .alignment = .top_left }};
        var border: vxfw.Border = .{
            .child = text.widget(),
            .labels = &labels,
        };
        // Keep the dialog stable as messages wrap or progress changes.
        // Its dimensions depend only on the available terminal size.
        const surface = try border.widget().draw(ctx.withConstraints(
            .{ .width = box_width, .height = box_height },
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
