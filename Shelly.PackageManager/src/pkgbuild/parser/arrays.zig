//! PKGBUILD array parsing, including brace expansion and scoped
//! (package_-local) arrays.
const std = @import("std");
const shell_scan = @import("shell_scan.zig");
const PkgbuildParser = @import("parser.zig").PkgbuildParser;

pub fn parse_array(self: PkgbuildParser, content: []const u8, variable_name: []const u8) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (result.items) |it| self.allocator.free(it);
        result.deinit(self.allocator);
    }

    var search_from: usize = 0;
    while (find_next_array_start(content, variable_name, search_from)) |m| {
        search_from = m.after_paren;

        if (shell_scan.is_inside_conditional_block(content, m.start)) {
            std.debug.print("[Shelly] Skipping conditional {s}+=() at offset {d}\n", .{ variable_name, m.start });
            continue;
        }

        const scanned = try scan_array_body(self.allocator, content, m.after_paren);
        defer self.allocator.free(scanned.body);

        if (!m.append) {
            for (result.items) |item| self.allocator.free(item);
            result.clearRetainingCapacity();
        }

        var cleaned: std.ArrayList(u8) = .empty;
        defer cleaned.deinit(self.allocator);

        var line_iter = std.mem.splitScalar(u8, scanned.body, '\n');
        var first_line = true;
        while (line_iter.next()) |line| {
            if (!first_line) try cleaned.append(self.allocator, '\n');
            first_line = false;
            const stripped = try shell_scan.strip_comment(line);
            try cleaned.appendSlice(self.allocator, stripped);
        }

        const items = try scan_array_items(self.allocator, cleaned.items);
        defer self.allocator.free(items);
        for (items) |item| {
            try result.append(self.allocator, item);
        }
    }

    return result.toOwnedSlice(self.allocator);
}

pub fn find_next_array_start(content: []const u8, variable_name: []const u8, search_from: usize) ?struct { start: usize, after_paren: usize, append: bool } {
    var i = search_from;
    while (i < content.len) : (i += 1) {
        const at_line_start = (i == 0) or (content[i - 1] == '\n');
        if (!at_line_start) continue;
        if (!std.mem.startsWith(u8, content[i..], variable_name)) continue;

        var cursor = i + variable_name.len;
        const append = cursor < content.len and content[cursor] == '+';
        if (append) cursor += 1;
        if (cursor >= content.len or content[cursor] != '=') continue;
        cursor += 1;
        if (cursor >= content.len or content[cursor] != '(') continue;
        cursor += 1;

        return .{ .start = i, .after_paren = cursor, .append = append };
    }
    return null;
}

pub const ScopedArrayStart = struct {
    after_paren: usize,
    append: bool,
};

pub fn find_next_scoped_array_start(
    content: []const u8,
    variable_name: []const u8,
    search_from: usize,
) ?ScopedArrayStart {
    var line_start = search_from;
    while (line_start < content.len) {
        var cursor = line_start;
        while (cursor < content.len and (content[cursor] == ' ' or content[cursor] == '\t'))
            cursor += 1;
        if (std.mem.startsWith(u8, content[cursor..], variable_name)) {
            cursor += variable_name.len;
            if (cursor == content.len or !shell_scan.is_word(content[cursor])) {
                const append = cursor < content.len and content[cursor] == '+';
                if (append) cursor += 1;
                if (cursor < content.len and content[cursor] == '=') {
                    cursor += 1;
                    if (cursor < content.len and content[cursor] == '(')
                        return .{ .after_paren = cursor + 1, .append = append };
                }
            }
        }
        line_start = (std.mem.indexOfScalarPos(u8, content, line_start, '\n') orelse return null) + 1;
    }
    return null;
}

pub fn parse_array_body_items(allocator: std.mem.Allocator, body: []const u8) ![][]const u8 {
    var cleaned: std.ArrayList(u8) = .empty;
    defer cleaned.deinit(allocator);
    var lines = std.mem.splitScalar(u8, body, '\n');
    var first_line = true;
    while (lines.next()) |line| {
        if (!first_line) try cleaned.append(allocator, '\n');
        first_line = false;
        try cleaned.appendSlice(allocator, try shell_scan.strip_comment(line));
    }
    return scan_array_items(allocator, cleaned.items);
}

pub fn scan_array_body(allocator: std.mem.Allocator, content: []const u8, start: usize) !struct { body: []u8, end: usize } {
    var sb: std.ArrayList(u8) = .empty;
    errdefer sb.deinit(allocator);

    var in_single = false;
    var in_double = false;
    // Bash starts a comment only at a word boundary; tracking it keeps
    // quote characters inside comments (e.g. "Don't") from corrupting the
    // scan so the closing paren of the array is still recognized.
    var word_start = true;
    var i = start;
    while (i < content.len) {
        const c = content[i];
        if (c == '\\' and i + 1 < content.len) {
            try sb.append(allocator, c);
            try sb.append(allocator, content[i + 1]);
            i += 2;
            word_start = false;
            continue;
        }
        if (c == '\'' and !in_double) {
            in_single = !in_single;
            try sb.append(allocator, c);
            i += 1;
            word_start = false;
            continue;
        }
        if (c == '"' and !in_single) {
            in_double = !in_double;
            try sb.append(allocator, c);
            i += 1;
            word_start = false;
            continue;
        }
        if (c == '#' and !in_single and !in_double and word_start) {
            while (i < content.len and content[i] != '\n') i += 1;
            continue;
        }
        if (c == ')' and !in_single and !in_double) {
            i += 1;
            break;
        }
        try sb.append(allocator, c);
        word_start = (c == ' ' or c == '\t' or c == '\n') and !in_single and !in_double;
        i += 1;
    }

    return .{ .body = try sb.toOwnedSlice(allocator), .end = i };
}

const ArrayWordQuote = enum {
    none,
    single,
    double,
};

const BraceGroup = struct {
    open: usize,
    close: usize,
};

const max_brace_expansions = 256;

const max_brace_expansion_depth = 32;

fn find_expandable_brace_group(word: []const u8, expandable: []const bool) ?BraceGroup {
    std.debug.assert(word.len == expandable.len);

    var parameter_brace_depth: usize = 0;
    var open: usize = 0;
    while (open < word.len) : (open += 1) {
        if (parameter_brace_depth == 0 and
            open + 1 < word.len and
            word[open] == '$' and
            word[open + 1] == '{' and
            expandable[open] and
            expandable[open + 1])
        {
            parameter_brace_depth = 1;
            open += 1;
            continue;
        }
        if (parameter_brace_depth > 0) {
            if (expandable[open]) switch (word[open]) {
                '{' => parameter_brace_depth += 1,
                '}' => parameter_brace_depth -= 1,
                else => {},
            };
            continue;
        }
        if (word[open] != '{' or !expandable[open]) continue;

        var depth: usize = 1;
        var has_alternative = false;
        var cursor = open + 1;
        while (cursor < word.len) : (cursor += 1) {
            if (!expandable[cursor]) continue;
            switch (word[cursor]) {
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) {
                        if (has_alternative) return .{ .open = open, .close = cursor };
                        break;
                    }
                },
                ',' => if (depth == 1) {
                    has_alternative = true;
                },
                else => {},
            }
        }
    }
    return null;
}

fn append_expanded_array_word(
    allocator: std.mem.Allocator,
    items: *std.ArrayList([]const u8),
    word: []const u8,
    expandable: []const bool,
    depth: usize,
    expansion_count: *usize,
) !void {
    if (depth > max_brace_expansion_depth) return error.BraceExpansionTooDeep;
    const group = find_expandable_brace_group(word, expandable) orelse {
        if (expansion_count.* >= max_brace_expansions) return error.TooManyBraceExpansions;
        const owned = try allocator.dupe(u8, word);
        errdefer allocator.free(owned);
        try items.append(allocator, owned);
        expansion_count.* += 1;
        return;
    };

    var alternative_start = group.open + 1;
    var nested_depth: usize = 0;
    var cursor = alternative_start;
    while (cursor <= group.close) : (cursor += 1) {
        var is_separator = cursor == group.close;
        if (!is_separator and expandable[cursor]) {
            switch (word[cursor]) {
                '{' => nested_depth += 1,
                '}' => if (nested_depth > 0) {
                    nested_depth -= 1;
                },
                ',' => is_separator = nested_depth == 0,
                else => {},
            }
        }
        if (!is_separator) continue;

        var candidate: std.ArrayList(u8) = .empty;
        defer candidate.deinit(allocator);
        var candidate_expandable: std.ArrayList(bool) = .empty;
        defer candidate_expandable.deinit(allocator);

        try candidate.appendSlice(allocator, word[0..group.open]);
        try candidate_expandable.appendSlice(allocator, expandable[0..group.open]);
        try candidate.appendSlice(allocator, word[alternative_start..cursor]);
        try candidate_expandable.appendSlice(allocator, expandable[alternative_start..cursor]);
        try candidate.appendSlice(allocator, word[group.close + 1 ..]);
        try candidate_expandable.appendSlice(allocator, expandable[group.close + 1 ..]);

        try append_expanded_array_word(
            allocator,
            items,
            candidate.items,
            candidate_expandable.items,
            depth + 1,
            expansion_count,
        );
        alternative_start = cursor + 1;
    }
}

fn scan_array_items(allocator: std.mem.Allocator, cleaned: []const u8) ![][]const u8 {
    var items: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (items.items) |it| allocator.free(it);
        items.deinit(allocator);
    }

    var i: usize = 0;
    while (i < cleaned.len) {
        while (i < cleaned.len and std.ascii.isWhitespace(cleaned[i])) : (i += 1) {}
        if (i >= cleaned.len) break;

        var word: std.ArrayList(u8) = .empty;
        defer word.deinit(allocator);
        var expandable: std.ArrayList(bool) = .empty;
        defer expandable.deinit(allocator);
        var quote: ArrayWordQuote = .none;
        var word_started = false;

        while (i < cleaned.len) {
            const c = cleaned[i];
            if (quote == .none and std.ascii.isWhitespace(c)) break;

            if (c == '\'' and quote != .double) {
                word_started = true;
                quote = if (quote == .single) .none else .single;
                i += 1;
                continue;
            }
            if (c == '"' and quote != .single) {
                word_started = true;
                quote = if (quote == .double) .none else .double;
                i += 1;
                continue;
            }
            if (c == '\\' and quote != .single) {
                word_started = true;
                if (i + 1 >= cleaned.len) {
                    try word.append(allocator, c);
                    try expandable.append(allocator, false);
                    i += 1;
                    continue;
                }
                const escaped = cleaned[i + 1];
                if (escaped == '\n') {
                    i += 2;
                    continue;
                }
                if (quote == .double and escaped != '$' and escaped != '`' and escaped != '"' and escaped != '\\') {
                    try word.append(allocator, c);
                    try expandable.append(allocator, false);
                    i += 1;
                    continue;
                }
                try word.append(allocator, escaped);
                try expandable.append(allocator, false);
                i += 2;
                continue;
            }

            word_started = true;
            try word.append(allocator, c);
            try expandable.append(allocator, quote == .none);
            i += 1;
        }

        if (word_started) {
            var expansion_count: usize = 0;
            try append_expanded_array_word(
                allocator,
                &items,
                word.items,
                expandable.items,
                0,
                &expansion_count,
            );
        }
    }

    return items.toOwnedSlice(allocator);
}

test "parse_array: simple bare items" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parse_array(parser, "depends=(foo bar baz)\n", "depends");
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("foo", items[0]);
    try std.testing.expectEqualStrings("bar", items[1]);
    try std.testing.expectEqualStrings("baz", items[2]);
}

test "parse_array: double and single quoted items" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parse_array(parser, "depends=(\"foo bar\" 'baz qux')\n", "depends");
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("foo bar", items[0]);
    try std.testing.expectEqualStrings("baz qux", items[1]);
}

test "parse_array: multiline array" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parse_array(
        parser,
        "depends=(\n  foo\n  bar\n  baz\n)\n",
        "depends",
    );
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("foo", items[0]);
    try std.testing.expectEqualStrings("bar", items[1]);
    try std.testing.expectEqualStrings("baz", items[2]);
}

test "parse_array: strips inline comments per line" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parse_array(
        parser,
        "depends=(\n  foo # needed for x\n  bar\n)\n",
        "depends",
    );
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("foo", items[0]);
    try std.testing.expectEqualStrings("bar", items[1]);
}

test "parse_array: closing paren inside quotes is not treated as array end" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parse_array(parser, "depends=(\"has (paren) inside\" bar)\n", "depends");
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("has (paren) inside", items[0]);
    try std.testing.expectEqualStrings("bar", items[1]);
}

test "parse_array: escaped whitespace remains in the same word" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parse_array(parser, "depends=(foo\\ bar baz)\n", "depends");
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("foo bar", items[0]);
    try std.testing.expectEqualStrings("baz", items[1]);
}

test "parse_array: adjacent quoted and unquoted segments form one word" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parse_array(
        parser,
        "source=(\"archive-\"$pkgver'.tar.gz' plain\"-suffix\")\n",
        "source",
    );
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("archive-$pkgver.tar.gz", items[0]);
    try std.testing.expectEqualStrings("plain-suffix", items[1]);
}

test "parse_array: unquoted brace alternatives expand with empty alternatives" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parse_array(
        parser,
        "source=(\"https://example.invalid/archive-$pkgver.tar.gz\"{,.asc})\n",
        "source",
    );
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("https://example.invalid/archive-$pkgver.tar.gz", items[0]);
    try std.testing.expectEqualStrings("https://example.invalid/archive-$pkgver.tar.gz.asc", items[1]);
}

test "parse_array: quoted and escaped braces remain literal" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parse_array(
        parser,
        "source=(\"quoted{a,b}\" 'single{c,d}' escaped\\{e,f\\})\n",
        "source",
    );
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("quoted{a,b}", items[0]);
    try std.testing.expectEqualStrings("single{c,d}", items[1]);
    try std.testing.expectEqualStrings("escaped{e,f}", items[2]);
}

test "parse_array: parameter braces are not alternatives but an escaped dollar permits them" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parse_array(
        parser,
        "source=(${value:-a,b} ${value:-{a,b}} \\${a,b})\n",
        "source",
    );
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 4), items.len);
    try std.testing.expectEqualStrings("${value:-a,b}", items[0]);
    try std.testing.expectEqualStrings("${value:-{a,b}}", items[1]);
    try std.testing.expectEqualStrings("$a", items[2]);
    try std.testing.expectEqualStrings("$b", items[3]);
}

test "parse_array: malformed brace groups remain literal" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parse_array(parser, "source=(missing{ab}comma unclosed{a,b)\n", "source");
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("missing{ab}comma", items[0]);
    try std.testing.expectEqualStrings("unclosed{a,b", items[1]);
}

test "parse_array: multiple brace groups expand as a cartesian product" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parse_array(parser, "source=(pkg-{one,two}.{sig,txt})\n", "source");
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 4), items.len);
    try std.testing.expectEqualStrings("pkg-one.sig", items[0]);
    try std.testing.expectEqualStrings("pkg-one.txt", items[1]);
    try std.testing.expectEqualStrings("pkg-two.sig", items[2]);
    try std.testing.expectEqualStrings("pkg-two.txt", items[3]);
}

test "parse_array: brace expansion count is bounded" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    try std.testing.expectError(
        error.TooManyBraceExpansions,
        parse_array(parser, "source=({a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b})\n", "source"),
    );
}

test "parse_array: += appends to an existing declaration across matches" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parse_array(
        parser,
        "depends=(foo)\ndepends+=(bar)\n",
        "depends",
    );
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("foo", items[0]);
    try std.testing.expectEqualStrings("bar", items[1]);
}

test "parse_array: a later plain assignment replaces the earlier array" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parse_array(
        parser,
        "depends=(one two)\ndepends=(three)\ndepends+=(four)\n",
        "depends",
    );
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("three", items[0]);
    try std.testing.expectEqualStrings("four", items[1]);
}

test "parse_array: empty array returns no items" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parse_array(parser, "depends=()\n", "depends");
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "parse_array: variable name not present returns no items" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parse_array(parser, "pkgname=app\n", "depends");
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "parse_array: does not match variable name as a substring of another" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    // "makedepends" contains "depends" as a substring but shouldn't match
    // a search for "depends" specifically, since the regex requires the
    // full identifier to start right at the line start.
    const items = try parse_array(parser, "makedepends=(foo)\n", "depends");
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "parse_array: unterminated array consumes to end of content" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parse_array(parser, "depends=(foo bar", "depends");
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("foo", items[0]);
    try std.testing.expectEqualStrings("bar", items[1]);
}

test "parse_array: conditional block is skipped" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const items = try parse_array(
        parser,
        "if [ \"$CARCH\" = \"x86_64\" ]; then\ndepends=(foo)\nfi\n",
        "depends",
    );
    defer {
        for (items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 0), items.len);
}
