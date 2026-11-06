const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const diagnostics = @import("diagnostics");

pub const View = struct {
    previous: ?*vxfw.Button = null,
    next: ?*vxfw.Button = null,
    index: usize,
    count: usize,
    caption: []const u8,
    image: ?vaxis.Image = null,
    failure: ?anyerror = null,

    pub fn draw(self: View, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const body = try ctx.arena.create(View);
        body.* = self;
        const size = ctx.max.size();
        if (size.height < 2 or size.width < 8) return drawBody(body, ctx);
        var children: std.ArrayList(vxfw.SubSurface) = .empty;
        const controls = self.count > 1 and self.previous != null and self.next != null and size.width >= 16;
        const control_width: u16 = if (controls) 8 else 0;
        var heading: vxfw.Text = .{ .text = try std.fmt.allocPrint(ctx.arena, "Screenshot {d}/{d}", .{ self.index + 1, self.count }), .softwrap = false, .overflow = .ellipsis, .style = .{ .bold = true } };
        try children.append(ctx.arena, .{ .origin = .{ .row = 0, .col = 0 }, .surface = try heading.draw(ctx.withConstraints(.{}, .{ .width = size.width - control_width, .height = 1 })) });
        if (controls) {
            try children.append(ctx.arena, .{ .origin = .{ .row = 0, .col = @intCast(size.width - 7) }, .surface = try buttonWidget(self.previous.?).draw(ctx.withConstraints(.{}, .{ .width = 3, .height = 1 })) });
            try children.append(ctx.arena, .{ .origin = .{ .row = 0, .col = @intCast(size.width - 3) }, .surface = try buttonWidget(self.next.?).draw(ctx.withConstraints(.{}, .{ .width = 3, .height = 1 })) });
        }
        try children.append(ctx.arena, .{ .origin = .{ .row = 1, .col = 0 }, .surface = try drawBody(body, ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height - 1 })) });
        return .{ .size = size, .widget = .{ .userdata = body, .drawFn = drawBody }, .buffer = &.{}, .children = children.items };
    }
    fn drawBody(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const View = @ptrCast(@alignCast(ptr));
        const size = ctx.max.size();
        var surface = try vxfw.Surface.init(ctx.arena, .{ .userdata = ptr, .drawFn = drawBody }, size);
        @memset(surface.buffer, .{});
        var caption: vxfw.Text = .{ .text = try std.fmt.allocPrint(ctx.arena, "{f}", .{diagnostics.safe(self.caption)}), .softwrap = false, .overflow = .ellipsis };
        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try caption.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = 1 })) };
        const caption_height: u16 = if (self.caption.len > 0) 1 else 0;
        surface.children = if (caption_height > 0) children else &.{};
        if (size.height <= caption_height or size.width == 0) return surface;
        if (self.image) |img| {
            const cell_w = @max(@as(u16, 1), ctx.cell_size.width);
            const cell_h = @max(@as(u16, 1), ctx.cell_size.height);
            const max_w: u64 = @as(u64, size.width) * cell_w;
            const max_h: u64 = @as(u64, size.height - caption_height) * cell_h;
            var cols: u16 = size.width;
            var rows: u16 = size.height - caption_height;
            if (max_w * img.height > max_h * img.width) cols = @intCast(@max(1, @min(size.width, max_h * img.width / img.height / cell_w))) else rows = @intCast(@max(1, @min(size.height - caption_height, max_w * img.height / img.width / cell_h)));
            const row = caption_height + (size.height - caption_height - rows) / 2;
            const col = (size.width - cols) / 2;
            surface.buffer[@as(usize, row) * size.width + col].image = .{ .img_id = img.imageId(), .options = .{ .size = .{ .rows = rows, .cols = cols } } };
        } else {
            var message: vxfw.Text = .{ .text = if (self.failure) |err| try std.fmt.allocPrint(ctx.arena, "Could not load screenshot: {s}", .{@errorName(err)}) else "Loading screenshot…" };
            const extra = try ctx.arena.alloc(vxfw.SubSurface, 1 + caption_height);
            if (caption_height > 0) extra[0] = children[0];
            extra[caption_height] = .{ .origin = .{ .row = @intCast(caption_height), .col = 0 }, .surface = try message.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height - caption_height })) };
            surface.children = extra;
        }
        return surface;
    }
};

test "screenshot placement fits its pane on resize and preserves caption" {
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const view: View = .{ .index = 1, .count = 3, .caption = "Application window", .image = vaxis.Image.init(42, 1920, 1080) };
    for ([_]vxfw.Size{ .{ .width = 60, .height = 20 }, .{ .width = 20, .height = 8 }, .{ .width = 2, .height = 2 } }) |size| {
        const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = size.width, .height = size.height }, .cell_size = .{ .width = 10, .height = 20 } };
        const surface = try view.draw(ctx);
        try std.testing.expect(surface.size.width <= size.width and surface.size.height <= size.height);
        const body = if (size.height >= 2 and size.width >= 8) surface.children[surface.children.len - 1].surface else surface;
        var placements: usize = 0;
        for (body.buffer, 0..) |cell, i| if (cell.image) |img| {
            placements += 1;
            try std.testing.expectEqual(@as(u32, 42), img.img_id);
            try std.testing.expect(i / body.size.width + img.options.size.?.rows.? <= body.size.height);
            try std.testing.expect(i % body.size.width + img.options.size.?.cols.? <= body.size.width);
        };
        try std.testing.expectEqual(@as(usize, 1), placements);
    }
}

fn buttonWidget(button: *vxfw.Button) vxfw.Widget {
    return .{ .userdata = button, .drawFn = drawButton, .eventHandler = buttonEvent };
}
fn drawButton(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const button: *vxfw.Button = @ptrCast(@alignCast(ptr));
    var surface = try button.draw(ctx);
    surface.widget = buttonWidget(button);
    return surface;
}
fn buttonEvent(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const button: *vxfw.Button = @ptrCast(@alignCast(ptr));
    const consumed = ctx.consume_event;
    try button.handleEvent(ctx, event);
    if (event == .mouse_enter) ctx.consume_event = consumed;
}

pub fn transmitPng(writer: *std.Io.Writer, encoded: []const u8, id: u32, width: u16, height: u16) !void {
    if (encoded.len == 0) return error.InvalidImage;
    var offset: usize = 0;
    while (offset < encoded.len) {
        const end = @min(encoded.len, offset + 4096);
        const more: u8 = @intFromBool(end < encoded.len);
        if (offset == 0) try writer.print("\x1b_Gf=100,s={d},v={d},i={d},q=2,m={d};", .{ width, height, id, more }) else try writer.print("\x1b_Gm={d};", .{more});
        try writer.writeAll(encoded[offset..end]);
        try writer.writeAll("\x1b\\");
        offset = end;
    }
    try writer.flush();
}

test "PNG uploads terminate exactly once at protocol chunk boundaries" {
    const allocator = std.testing.allocator;
    for ([_]usize{ 4, 4092, 4096, 4100, 8192 }) |len| {
        const encoded = try allocator.alloc(u8, len);
        defer allocator.free(encoded);
        @memset(encoded, 'A');
        var writer: std.Io.Writer.Allocating = .init(allocator);
        defer writer.deinit();
        try transmitPng(&writer.writer, encoded, 7, 800, 600);
        const output = writer.written();
        try std.testing.expect(std.mem.indexOf(u8, output, "q=2") != null);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "m=0;"));
        try std.testing.expectEqual((len - 1) / 4096, std.mem.count(u8, output, "m=1;"));
        try std.testing.expect(std.mem.endsWith(u8, output, "\x1b\\"));
    }
}
