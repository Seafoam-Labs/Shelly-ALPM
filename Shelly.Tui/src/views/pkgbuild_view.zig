const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const commands = @import("../commands.zig");
const PkgBuild = @import("../models/pkgbuild.zig").PkgBuild;

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    lines: []const []const u8,

    pub fn init(allocator: std.mem.Allocator, builds: []const PkgBuild) !Document {
        if (builds.len == 0) return error.NoPkgbuildData;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        var lines: std.ArrayList([]const u8) = .empty;
        var remaining: usize = 2 * 1024 * 1024;
        for (builds) |build| {
            try section(alloc, &lines, build.Name, &remaining);
            try section(alloc, &lines, "PKGBUILD", &remaining);
            try source(alloc, &lines, build.PkgBuild, &remaining);
            if (build.Scan) |scan| {
                try section(alloc, &lines, "Scan findings", &remaining);
                if (scan.findings.len == 0) try section(alloc, &lines, "No findings reported by this scan.", &remaining);
                for (scan.findings) |finding| {
                    const text = try std.fmt.allocPrint(alloc, "[{s}] {s} / {s}: {s}\n{s}", .{
                        finding.severity, finding.tool, finding.hook, finding.message, finding.matched_line,
                    });
                    try source(alloc, &lines, text, &remaining);
                }
                for (scan.related_files) |file| {
                    try section(alloc, &lines, file.name, &remaining);
                    try source(alloc, &lines, file.content, &remaining);
                }
            } else {
                try section(alloc, &lines, "Scan findings and related files were not supplied.", &remaining);
            }
        }
        return .{ .arena = arena, .lines = try lines.toOwnedSlice(alloc) };
    }

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn section(alloc: std.mem.Allocator, lines: *std.ArrayList([]const u8), title: []const u8, remaining: *usize) !void {
        try lines.append(alloc, "");
        const safe = try displayText(alloc, title, remaining);
        try lines.append(alloc, try std.fmt.allocPrint(alloc, "── {s} ──", .{safe}));
    }

    fn source(alloc: std.mem.Allocator, lines: *std.ArrayList([]const u8), text: []const u8, remaining: *usize) !void {
        if (text.len > remaining.*) return error.PreviewTooLarge;
        var iterator = std.mem.splitScalar(u8, text, '\n');
        var number: usize = 1;
        while (iterator.next()) |line| : (number += 1) {
            if (lines.items.len >= 100_000) return error.PreviewTooLarge;
            const safe = try displayText(alloc, line, remaining);
            try lines.append(alloc, try std.fmt.allocPrint(alloc, "{d: >5} │ {s}", .{ number, safe }));
        }
    }

    fn displayText(alloc: std.mem.Allocator, text: []const u8, remaining: *usize) ![]const u8 {
        if (text.len > remaining.*) return error.PreviewTooLarge;
        remaining.* -= text.len;
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidSourceEncoding;
        var out: std.ArrayList(u8) = .empty;
        for (text) |byte| {
            if (byte == '\t') {
                try out.appendSlice(alloc, "    ");
            } else if (byte < 0x20 or byte == 0x7f) {
                const hex = "0123456789abcdef";
                try out.appendSlice(alloc, &.{ '\\', 'x', hex[byte >> 4], hex[byte & 15] });
            } else try out.append(alloc, byte);
            if (out.items.len > 8192) return error.SourceLineTooLong;
        }
        return out.toOwnedSlice(alloc);
    }
};

pub const Action = enum { close, retry };

pub const View = struct {
    name: []const u8,
    scroll: *vxfw.ScrollView,
    loading: bool,
    failure: ?anyerror,

    pub fn handleKey(_: View, key: vaxis.Key) ?Action {
        if (commands.closesPreview(key)) return .close;
        if (commands.refreshes(key)) return .retry;
        return null;
    }

    pub fn draw(self: View, ctx: vxfw.DrawContext) std.mem.Allocator.Error!?vxfw.SubSurface {
        const max = ctx.max.size();
        const width = @min(max.width -| 2, @as(u16, 100));
        const height = @min(max.height -| 2, @as(u16, 36));
        if (width < 20 or height < 6) return null;
        const inner_width = width - 2;
        const inner_height = height - 2;
        var children: std.ArrayList(vxfw.SubSurface) = .empty;
        if (self.loading or self.failure != null) {
            var text: vxfw.Text = .{ .text = if (self.failure) |err|
                try std.fmt.allocPrint(ctx.arena, "Could not load PKGBUILD preview ({s}). R: retry", .{@errorName(err)})
            else
                try std.fmt.allocPrint(ctx.arena, "Fetching PKGBUILD for {f}…", .{@import("diagnostics").safe(self.name)}) };
            try children.append(ctx.arena, .{
                .origin = .{ .row = 0, .col = 0 },
                .surface = try text.draw(ctx.withConstraints(.{}, .{ .width = inner_width, .height = inner_height - 2 })),
            });
        } else {
            try children.append(ctx.arena, .{
                .origin = .{ .row = 0, .col = 0 },
                .surface = try self.scroll.draw(ctx.withConstraints(.{}, .{ .width = inner_width, .height = inner_height - 2 })),
            });
        }
        var hint: vxfw.Text = .{ .text = commands.preview_hint, .softwrap = false };
        try children.append(ctx.arena, .{
            .origin = .{ .row = inner_height - 2, .col = 0 },
            .surface = try hint.draw(ctx.withConstraints(.{}, .{ .width = inner_width, .height = 1 })),
        });
        var note: vxfw.Text = .{ .text = "Browsing preview; install-time review is separate.", .softwrap = false };
        try children.append(ctx.arena, .{
            .origin = .{ .row = inner_height - 1, .col = 0 },
            .surface = try note.draw(ctx.withConstraints(.{}, .{ .width = inner_width, .height = 1 })),
        });
        const content: vxfw.Surface = .{
            .widget = self.scroll.widget(),
            .size = .{ .width = inner_width, .height = inner_height },
            .buffer = &.{},
            .children = children.items,
        };
        const holder = try ctx.arena.create(FixedContent);
        holder.* = .{ .surface = content };
        const labels = [_]vxfw.Border.BorderLabel{.{
            .text = "PKGBUILD preview",
            .alignment = .top_left,
        }};
        const border = try ctx.arena.create(vxfw.Border);
        border.* = .{ .child = holder.widget(), .labels = &labels };
        const surface = try border.draw(ctx.withConstraints(
            .{ .width = width, .height = height },
            .{ .width = width, .height = height },
        ));
        return .{
            .origin = .{
                .row = @intCast((max.height - height) / 2),
                .col = @intCast((max.width - width) / 2),
            },
            .surface = surface,
            .z_index = 3,
        };
    }
};

const FixedContent = struct {
    surface: vxfw.Surface,
    fn widget(self: *FixedContent) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }
    fn draw(ptr: *anyopaque, _: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *FixedContent = @ptrCast(@alignCast(ptr));
        return self.surface;
    }
};

pub fn row(document: *const Document, index: usize) ?vxfw.Widget {
    if (index >= document.lines.len) return null;
    return .{ .userdata = @ptrCast(@constCast(&document.lines[index])), .drawFn = drawLine };
}

fn drawLine(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const text: *const []const u8 = @ptrCast(@alignCast(ptr));
    const label = try ctx.arena.create(vxfw.Text);
    label.* = .{ .text = text.*, .softwrap = false, .overflow = .clip };
    return label.draw(ctx);
}

test "PKGBUILD document owns source and preserves URLs and related files" {
    const json = try std.testing.allocator.dupe(u8,
        \\[{"Name":"demo","PkgBuild":"source=(https://example.org/full/path?value=1)\n\techo hello","Scan":{"findings":[{"tool":"scanner","hook":"build","severity":"warning","message":"Inspect this","matched_line":"curl"}],"related_files":[{"name":"demo.install","content":"post_install() {}\n\u001b[31m"}]}}]
    );
    const parsed = try std.json.parseFromSlice([]PkgBuild, std.testing.allocator, json, .{ .allocate = .alloc_always });
    var document = try Document.init(std.testing.allocator, parsed.value);
    defer document.deinit();
    parsed.deinit();
    std.testing.allocator.free(json);
    const text = try std.mem.join(std.testing.allocator, "\n", document.lines);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "https://example.org/full/path?value=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "demo.install") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[warning]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\\x1b[31m") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, text, 0x1b) == null);
}

test "PKGBUILD document rejects empty invalid and oversized source" {
    try std.testing.expectError(error.NoPkgbuildData, Document.init(std.testing.allocator, &.{}));
    try std.testing.expectError(error.InvalidSourceEncoding, Document.init(std.testing.allocator, &.{
        .{ .Name = "test", .PkgBuild = "\xff" },
    }));
    const long = try std.testing.allocator.alloc(u8, 8193);
    defer std.testing.allocator.free(long);
    @memset(long, 'x');
    try std.testing.expectError(error.SourceLineTooLong, Document.init(std.testing.allocator, &.{
        .{ .Name = "test", .PkgBuild = long },
    }));
}
