const styles = @import("styles.zig");
const std = @import("std");
const Border = @import("border.zig");
const diagnostics = @import("diagnostics");
const vxfw = @import("vaxis").vxfw;
const Allocator = std.mem.Allocator;
const AppImage = @import("../models/appimage.zig").AppImage;
const detail_fields = @import("detail_fields.zig");
const formatSize = @import("detail_format.zig").formatSize;

pub fn drawRow(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const app: *const AppImage = @ptrCast(@alignCast(ptr));
    var spans = [_]vxfw.RichText.TextSpan{
        .{ .text = try std.fmt.allocPrint(ctx.arena, "{f}", .{diagnostics.safe(app.Name)}), .style = .{ .bold = true } },
    };
    var label: vxfw.RichText = .{ .text = &spans, .softwrap = false, .overflow = .ellipsis };
    return label.draw(ctx);
}

pub fn drawDetails(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const app: *const AppImage = @ptrCast(@alignCast(ptr));
    const arena = ctx.arena;
    var fields: std.ArrayList(detail_fields.Field) = .empty;

    try fields.appendSlice(arena, &.{
        .{ .label = "Name", .value = app.Name },
        .{ .label = "Version", .value = app.Version, .gap = true },
        .{ .label = "Description", .value = if (app.Description.len > 0) app.Description else "No description." },
        .{ .label = "Update source", .value = app.UpdateType.toCliString() },
    });

    const hosted = switch (app.UpdateType) {
        .GitHub, .GitLab, .Codeberg => true,
        .None, .StaticUrl, .Forgejo, .Zsync => false,
    };
    if (hosted) {
        if (app.RepoOwner != null and app.RepoName != null and app.RepoOwner.?.len > 0 and app.RepoName.?.len > 0) {
            const owner = app.RepoOwner.?;
            const repo = app.RepoName.?;
            try fields.append(arena, .{ .label = "Repository", .value = try std.fmt.allocPrint(arena, "{s}/{s}", .{ owner, repo }) });
        } else if (app.UpdateURl.len > 0) {
            try fields.append(arena, .{ .label = "Update URL", .value = app.UpdateURl, .preserve_url = true });
        }
    } else if (app.UpdateURl.len > 0) {
        try fields.append(arena, .{ .label = "Update URL", .value = app.UpdateURl, .preserve_url = true });
    }

    if (hosted or app.UpdateType == .Forgejo)
        try fields.append(arena, .{ .label = "Prerelease updates", .value = if (app.AllowPrerelease) "Yes" else "No" });

    if (app.Path) |path| if (path.len > 0)
        try fields.append(arena, .{ .label = "Installation path", .value = path });

    try fields.appendSlice(arena, &.{
        .{ .label = "Size on disk", .value = try formatSize(arena, app.SizeOnDisk), .gap = true },
    });

    return detail_fields.draw(.{ .userdata = ptr, .drawFn = drawDetails }, ctx, fields.items);
}

test "details render representative and sparse metadata at normal and narrow widths" {
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var representative = AppImage{
        .Name = "Blender",
        .Version = "4.2.0",
        .Description = "3D modeling and rendering suite.",
        .SizeOnDisk = 268435456,
        .UpdateURl = "seafoam-labs/blender",
        .RepoOwner = "seafoam-labs",
        .RepoName = "blender",
        .UpdateType = .GitHub,
        .AllowPrerelease = false,
        .Path = "/home/user/.local/bin/blender.AppImage",
    };
    var sparse = AppImage{ .Name = "Editor", .UpdateType = .Zsync, .UpdateURl = "zsync|https://nightly.example.dev/latest/Editor.AppImage.zsync" };

    const collect = struct {
        fn text(alloc: Allocator, output: *std.ArrayList(u8), surface: vxfw.Surface) Allocator.Error!void {
            for (surface.buffer) |cell| try output.appendSlice(alloc, cell.char.grapheme);
            for (surface.children) |child| try text(alloc, output, child.surface);
        }
    };

    for ([_]u16{ 64, 24 }) |width| {
        var rendered: std.ArrayList(u8) = .empty;

        const representative_surface = try drawDetails(&representative, .{
            .arena = arena.allocator(),
            .min = .{ .width = width },
            .max = .{},
            .cell_size = .{ .width = 10, .height = 20 },
        });
        try collect.text(arena.allocator(), &rendered, representative_surface);

        try std.testing.expect(std.mem.indexOf(u8, rendered.items, "Blender") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered.items, "4.2.0") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered.items, "3D modeling") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered.items, "seafoam-labs/blender") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered.items, "AppImage") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered.items, "256.0 MiB") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered.items, "GitHub") != null);

        rendered.clearRetainingCapacity();
        const sparse_surface = try drawDetails(&sparse, .{
            .arena = arena.allocator(),
            .min = .{ .width = width },
            .max = .{},
            .cell_size = .{ .width = 10, .height = 20 },
        });
        try collect.text(arena.allocator(), &rendered, sparse_surface);

        try std.testing.expect(std.mem.indexOf(u8, rendered.items, "Editor") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered.items, "Zsync") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered.items, "nightly") != null);
    }
}

test "row renders the name and clips long names to the available width" {
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const short = AppImage{ .Name = "Kate" };
    const long = AppImage{ .Name = "A-Very-Long-Application-Name-That-Exceeds-The-Cell-Width-Many-Times" };

    const collect = struct {
        fn text(alloc: Allocator, output: *std.ArrayList(u8), surface: vxfw.Surface) Allocator.Error!void {
            for (surface.buffer) |cell| try output.appendSlice(alloc, cell.char.grapheme);
            for (surface.children) |child| try text(alloc, output, child.surface);
        }
    };

    const short_surface = try drawRow(@constCast(&short), .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 20 },
        .cell_size = .{ .width = 10, .height = 20 },
    });
    var rendered: std.ArrayList(u8) = .empty;
    try collect.text(arena.allocator(), &rendered, short_surface);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "Kate") != null);

    const clipped = try drawRow(@constCast(&long), .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 12 },
        .cell_size = .{ .width = 10, .height = 20 },
    });
    try std.testing.expect(clipped.size.width <= 12);
    rendered.clearRetainingCapacity();
    try collect.text(arena.allocator(), &rendered, clipped);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "Many-Times") == null);
}

const DetailsBody = struct {
    scroll: *vxfw.ScrollView,
    fn widget(self: *DetailsBody) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }
    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *DetailsBody = @ptrCast(@alignCast(ptr));
        const size = ctx.max.size();
        var children: std.ArrayList(vxfw.SubSurface) = .empty;
        try children.append(ctx.arena, .{ .origin = .{ .row = 0, .col = 0 }, .surface = try self.scroll.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height })) });
        return .{ .size = size, .widget = self.widget(), .buffer = &.{}, .children = children.items };
    }
};

pub const View = struct {
    state: *@import("../models/appimage_model.zig").State,
    list_percent: u8 = 40,
    help: ?*@import("help_view.zig").Panel = null,

    pub fn contentMessage(self: View) ?[]const u8 {
        return if (self.state.items().len > 0) null else if (self.state.failure != null) "Could not load AppImages." else if (self.state.load != null and self.state.items().len == 0) "Loading AppImages…" else if (self.state.items().len == 0) "No installed AppImages." else null;
    }

    pub fn appendContent(self: View, ctx: vxfw.DrawContext, children: *std.ArrayList(vxfw.SubSurface)) Allocator.Error!void {
        const arena = ctx.arena;
        const size = ctx.max.size();
        if (size.width < 2 or size.height < 4) return;
        const split = size.width >= 64;
        const left_w: u16 = if (split) @import("split_layout.zig").listWidth(size.width, self.list_percent) else size.width;
        const right_w = if (split) size.width - left_w else size.width;
        const list_width = left_w -| @as(u16, if (split) 1 else 0);
        const pane_height = size.height -| 2;
        const show_pane = split or self.state.details_active or self.help != null;
        if (split or !show_pane) {
            const message = self.contentMessage();
            var label: vxfw.Text = .{ .text = message orelse "", .style = styles.secondary };
            const labels = [_]Border.BorderLabel{.{ .text = "Installed AppImages", .alignment = .top_left }};
            const content = if (message != null) label.widget() else self.state.list_view.widget();
            var border: Border = .{ .child = content, .labels = &labels, .focused = self.state.list_active and !self.state.details_active and self.help == null };
            if (list_width >= 2 and pane_height >= 2)
                try children.append(arena, .{ .origin = .{ .row = 1, .col = 0 }, .surface = try border.draw(ctx.withConstraints(.{ .width = list_width, .height = pane_height }, .{ .width = list_width, .height = pane_height })) })
            else
                try children.append(arena, .{ .origin = .{ .row = 1, .col = 0 }, .surface = try content.draw(ctx.withConstraints(.{}, .{ .width = list_width, .height = pane_height })) });
        }
        if (show_pane and pane_height >= 2 and right_w >= 2) {
            const pane_ctx = ctx.withConstraints(.{}, .{ .width = right_w, .height = pane_height });
            const surface = if (self.help) |panel|
                try panel.draw(pane_ctx)
            else blk: {
                const labels = [_]Border.BorderLabel{.{ .text = "AppImage details", .alignment = .top_left }};
                const loading = self.state.load != null and self.state.items().len == 0;
                var empty: vxfw.Text = .{ .text = if (loading) (if (split) "" else "Loading AppImages…") else "Select an AppImage to see details." };
                const details = try arena.create(DetailsBody);
                details.* = .{ .scroll = &self.state.details_scroll };
                var border: Border = .{
                    .child = if (self.state.selected() != null and !loading) details.widget() else empty.widget(),
                    .labels = &labels,
                    .focused = self.state.details_active,
                };
                break :blk try border.draw(pane_ctx.withConstraints(.{ .width = right_w, .height = pane_height }, .{ .width = right_w, .height = pane_height }));
            };
            try children.append(arena, .{ .origin = .{ .row = 1, .col = if (split) @intCast(left_w) else 0 }, .surface = surface });
        }
    }
};

const PathRow = struct {
    form: *@import("../models/appimage_model.zig").Form,
    index: usize,

    fn widget(self: *PathRow) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw, .eventHandler = event };
    }
    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *PathRow = @ptrCast(@alignCast(ptr));
        const candidate = self.form.completion.?.candidates[self.index];
        const selected = self.form.completion_index == self.index + 1;
        var text: vxfw.Text = .{ .text = try std.fmt.allocPrint(ctx.arena, "{s}{f}", .{ if (candidate.is_directory) "[Directory] " else "", diagnostics.safe(if (self.form.has_parent and self.index == 0) ".." else std.fs.path.basename(std.mem.trimEnd(u8, candidate.path, "/"))) }), .style = if (selected) styles.selected else styles.secondary, .softwrap = false, .overflow = .ellipsis, .width_basis = .parent };
        var surface = try text.draw(ctx);
        surface.widget = self.widget();
        return surface;
    }
    fn event(ptr: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
        const self: *PathRow = @ptrCast(@alignCast(ptr));
        if (input == .mouse and input.mouse.button == .left and input.mouse.type == .press) {
            self.form.editing_path = false;
            try @import("../models/appimage_model.zig").selectInstallPath(self.form, self.index);
            ctx.consumeAndRedraw();
        }
    }
};

pub fn drawInstall(form: *@import("../models/appimage_model.zig").Form, ctx: vxfw.DrawContext, children: *std.ArrayList(vxfw.SubSurface)) !void {
    const size = ctx.max.size();
    if (size.width < 2 or size.height < 4) return;
    var border: Border = .{ .child = form.field.widget(), .labels = &.{.{ .text = "Install AppImage · File browser", .alignment = .top_left }}, .focused = form.editing_path };
    try children.append(ctx.arena, .{ .origin = .{ .row = 1, .col = 0 }, .surface = try border.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = 3 })) });
    if (size.height <= 4) return;
    const status = if (form.failure) |err| try std.fmt.allocPrint(ctx.arena, "Could not use this path: {s}", .{@errorName(err)}) else if (form.job != null) "Checking path…" else if (form.editing_path) "Edit path · Tab: complete · Enter: open/review · Esc: browse" else "↑/↓ j/k: select · ←/h: parent · →/l: open · Enter: install/open · /: path · Esc: cancel";
    var hint: vxfw.Text = .{ .text = status, .softwrap = false, .overflow = .ellipsis };
    try children.append(ctx.arena, .{ .origin = .{ .row = 4, .col = 0 }, .surface = try hint.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = 1 })) });
    if (form.completion) |completion| {
        const visible = @min(completion.candidates.len, size.height -| 6);
        const selected = form.completion_index -| 1;
        if (selected < form.first_visible) form.first_visible = selected;
        if (visible > 0 and selected >= form.first_visible + visible) form.first_visible = selected - visible + 1;
        form.first_visible = @min(form.first_visible, completion.candidates.len - visible);
        const first = form.first_visible;
        for (first..first + visible) |index| {
            const row = try ctx.arena.create(PathRow);
            row.* = .{ .form = form, .index = index };
            try children.append(ctx.arena, .{ .origin = .{ .row = @intCast(5 + index - first), .col = 0 }, .surface = try row.widget().draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = 1 })) });
        }
        if (size.height > 5) {
            var note: vxfw.Text = .{ .text = if (completion.candidates.len == 0) "No matching AppImages or folders." else if (completion.truncated) "Suggestions limited; type a longer path." else try std.fmt.allocPrint(ctx.arena, "{d} suggestions", .{completion.candidates.len}), .softwrap = false };
            try children.append(ctx.arena, .{ .origin = .{ .row = @intCast(size.height - 1), .col = 0 }, .surface = try note.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = 1 })) });
        }
    }
}
