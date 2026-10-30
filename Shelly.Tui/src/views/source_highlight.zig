//! Lightweight display-only Bash and unified-diff highlighting. Source is
//! sanitized by the document builder first; no shell or external tools run.
const std = @import("std");
const vaxis = @import("vaxis");
const Span = vaxis.vxfw.RichText.TextSpan;
const Allocator = std.mem.Allocator;

pub const Kind = enum { plain, heading, shell, diff };
pub const State = struct {
    quote: enum { none, single, double } = .none,
    heredoc: ?[]const u8 = null,
};

const string_style: vaxis.Style = .{ .fg = .{ .index = 2 } };
const variable_style: vaxis.Style = .{ .fg = .{ .index = 6 } };
const keyword_style: vaxis.Style = .{ .fg = .{ .index = 5 }, .bold = true };
const comment_style: vaxis.Style = .{ .fg = .{ .index = 8 } };

pub fn fileKind(name: []const u8) Kind {
    if (std.mem.endsWith(u8, name, "PKGBUILD") or std.mem.endsWith(u8, name, ".sh") or std.mem.endsWith(u8, name, ".install")) return .shell;
    if (std.mem.endsWith(u8, name, ".patch") or std.mem.endsWith(u8, name, ".diff")) return .diff;
    return .plain;
}

fn emit(alloc: Allocator, spans: *std.ArrayList(Span), text: []const u8, style: vaxis.Style) !void {
    if (text.len > 0) try spans.append(alloc, .{ .text = text, .style = style });
}

pub fn highlight(alloc: Allocator, text: []const u8, prefix: usize, kind: Kind, state: *State, budget: *usize) ![]const Span {
    var spans: std.ArrayList(Span) = .empty;
    try emit(alloc, &spans, text[0..prefix], .{ .fg = .{ .index = 245 } });
    const source = text[prefix..];
    switch (kind) {
        .heading => try emit(alloc, &spans, source, .{ .fg = .{ .index = 7 }, .bold = true }),
        .plain => try emit(alloc, &spans, source, .{}),
        .diff => {
            const style: vaxis.Style = if (std.mem.startsWith(u8, source, "---") or std.mem.startsWith(u8, source, "+++"))
                .{ .bold = true, .fg = .{ .index = 250 } }
            else if (std.mem.startsWith(u8, source, "+")) .{ .fg = .{ .index = 2 } } else if (std.mem.startsWith(u8, source, "-")) .{ .fg = .{ .index = 1 } } else if (std.mem.startsWith(u8, source, "@@")) .{ .fg = .{ .index = 6 }, .bold = true } else .{};
            try emit(alloc, &spans, source, style);
        },
        .shell => try shell(alloc, &spans, source, state, budget),
    }
    return spans.toOwnedSlice(alloc);
}

fn identifierStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}
fn identifier(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}
fn boundary(c: u8) bool {
    return std.ascii.isWhitespace(c) or std.mem.indexOfScalar(u8, ";|&(){}", c) != null;
}
fn keyword(word: []const u8) bool {
    for ([_][]const u8{ "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac", "function", "select", "return", "local", "export", "readonly", "declare", "unset", "break", "continue", "source" }) |item| {
        if (std.mem.eql(u8, word, item)) return true;
    }
    return false;
}
fn escapedEnd(text: []const u8, start: usize) usize {
    if (start + 1 >= text.len) return text.len;
    const bytes = std.unicode.utf8ByteSequenceLength(text[start + 1]) catch 1;
    return @min(text.len, start + 1 + bytes);
}

fn shell(alloc: Allocator, spans: *std.ArrayList(Span), text: []const u8, state: *State, budget: *usize) !void {
    if (state.heredoc) |delimiter| {
        try emit(alloc, spans, text, string_style);
        if (std.mem.eql(u8, std.mem.trim(u8, text, " \t"), delimiter)) state.heredoc = null;
        return;
    }
    var i: usize = 0;
    while (i < text.len) {
        // Bound highlighting work, never source visibility. Exhausted styling
        // budgets leave the rest of the text present and readable.
        if (budget.* == 0 or spans.items.len >= 256) {
            try emit(alloc, spans, text[i..], .{});
            break;
        }
        budget.* -= 1;
        const start = i;
        if (state.quote != .none or text[i] == '\'' or text[i] == '"') {
            if (state.quote == .none) {
                state.quote = if (text[i] == '\'') .single else .double;
                i += 1;
            }
            const quote: u8 = if (state.quote == .single) '\'' else '"';
            while (i < text.len) {
                if (text[i] == '\\' and state.quote == .double) {
                    i = escapedEnd(text, i);
                    continue;
                }
                if (text[i] == quote) {
                    i += 1;
                    state.quote = .none;
                    break;
                }
                i += 1;
            }
            try emit(alloc, spans, text[start..i], string_style);
        } else if (text[i] == '#' and (i == 0 or boundary(text[i - 1]))) {
            try emit(alloc, spans, text[i..], comment_style);
            break;
        } else if (text[i] == '\\') {
            i = escapedEnd(text, i);
            try emit(alloc, spans, text[start..i], .{});
        } else if (text[i] == '$') {
            i += 1;
            if (i < text.len and text[i] == '{') {
                i = if (std.mem.indexOfScalarPos(u8, text, i, '}')) |end| end + 1 else text.len;
            } else {
                while (i < text.len and identifier(text[i])) : (i += 1) {}
                if (i == start + 1 and i < text.len) i += std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            }
            try emit(alloc, spans, text[start..i], variable_style);
        } else if (std.mem.startsWith(u8, text[i..], "<<") and !std.mem.startsWith(u8, text[i..], "<<<")) {
            i += 2;
            if (i < text.len and text[i] == '-') i += 1;
            while (i < text.len and std.ascii.isWhitespace(text[i])) : (i += 1) {}
            var quote: ?u8 = null;
            if (i < text.len and (text[i] == '\'' or text[i] == '"')) {
                quote = text[i];
                i += 1;
            }
            const delimiter = i;
            while (i < text.len and identifier(text[i])) : (i += 1) {}
            if (i > delimiter) state.heredoc = text[delimiter..i];
            if (quote) |q| {
                if (i < text.len and text[i] == q) i += 1;
            }
            try emit(alloc, spans, text[start..i], string_style);
        } else if (identifierStart(text[i])) {
            i += 1;
            while (i < text.len and identifier(text[i])) : (i += 1) {}
            var after = i;
            while (after < text.len and std.ascii.isWhitespace(text[after])) : (after += 1) {}
            const style: vaxis.Style = if (i < text.len and (text[i] == '=' or std.mem.startsWith(u8, text[i..], "+="))) variable_style else if (keyword(text[start..i])) keyword_style else if (std.mem.startsWith(u8, text[after..], "()")) .{ .fg = .{ .index = 4 }, .bold = true } else .{};
            try emit(alloc, spans, text[start..i], style);
        } else if (std.ascii.isDigit(text[i]) and (i == 0 or !identifier(text[i - 1]))) {
            i += 1;
            while (i < text.len and (std.ascii.isDigit(text[i]) or text[i] == '.')) : (i += 1) {}
            try emit(alloc, spans, text[start..i], .{ .fg = .{ .index = 3 } });
        } else {
            i += 1;
            while (i < text.len and !identifierStart(text[i]) and !std.ascii.isDigit(text[i]) and std.mem.indexOfScalar(u8, "#'$\"\\<", text[i]) == null) : (i += 1) {}
            try emit(alloc, spans, text[start..i], .{});
        }
    }
}

test "Bash highlighting preserves quotes comments variables functions and heredocs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var state: State = .{};
    var budget: usize = 200;
    const source = "pkgdesc='a # literal' # comment";
    const spans = try highlight(alloc, source, 0, .shell, &state, &budget);
    var joined: std.ArrayList(u8) = .empty;
    var assignment = false;
    var quoted = false;
    var comment = false;
    for (spans) |span| {
        try joined.appendSlice(alloc, span.text);
        if (std.mem.eql(u8, span.text, "pkgdesc")) assignment = span.style.fg.index == 6;
        if (std.mem.eql(u8, span.text, "'a # literal'")) quoted = span.style.fg.index == 2;
        if (std.mem.eql(u8, span.text, "# comment")) comment = span.style.fg.index == 8;
    }
    try std.testing.expectEqualStrings(source, joined.items);
    try std.testing.expect(assignment and quoted and comment);
    const function = try highlight(alloc, "build() {", 0, .shell, &state, &budget);
    try std.testing.expect(function[0].style.bold);
    const variable = try highlight(alloc, "$srcdir", 0, .shell, &state, &budget);
    try std.testing.expectEqual(@as(u8, 6), variable[0].style.fg.index);
    _ = try highlight(alloc, "pkgdesc='first line", 0, .shell, &state, &budget);
    const continuation = try highlight(alloc, "# still quoted'", 0, .shell, &state, &budget);
    try std.testing.expectEqual(@as(u8, 2), continuation[0].style.fg.index);
    _ = try highlight(alloc, "cat <<'EOF'", 0, .shell, &state, &budget);
    const heredoc = try highlight(alloc, "# literal document", 0, .shell, &state, &budget);
    try std.testing.expectEqual(@as(u8, 2), heredoc[0].style.fg.index);
    _ = try highlight(alloc, "EOF", 0, .shell, &state, &budget);
    try std.testing.expect(state.heredoc == null);
    budget = 0;
    const fallback = try highlight(alloc, source, 0, .shell, &state, &budget);
    try std.testing.expectEqualStrings(source, fallback[0].text);
}

test "diff highlighting keeps markers and treats file and hunk headers separately" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state: State = .{};
    var budget: usize = 100;
    const added = try highlight(arena.allocator(), "+pkgver=2", 0, .diff, &state, &budget);
    const removed = try highlight(arena.allocator(), "-pkgver=1", 0, .diff, &state, &budget);
    const header = try highlight(arena.allocator(), "+++ PKGBUILD", 0, .diff, &state, &budget);
    const hunk = try highlight(arena.allocator(), "@@ -1 +1 @@", 0, .diff, &state, &budget);
    try std.testing.expectEqual(@as(u8, 2), added[0].style.fg.index);
    try std.testing.expectEqual(@as(u8, 1), removed[0].style.fg.index);
    try std.testing.expect(header[0].style.bold);
    try std.testing.expectEqual(@as(u8, 6), hunk[0].style.fg.index);
    try std.testing.expectEqualStrings("+pkgver=2", added[0].text);
    try std.testing.expectEqualStrings("-pkgver=1", removed[0].text);
}
