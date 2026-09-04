//! Low-level shell text scanning: quoting, comments, heredocs, segments,
//! and command-substitution detection.
const std = @import("std");
const PkgbuildParser = @import("parser.zig").PkgbuildParser;

/// A contiguous slice of a shell snippet tagged with whether bash performs
/// parameter expansion inside it (everything except single-quoted runs and
/// backslash-escaped pairs).
pub const shell_segment = struct {
    start: usize,
    end: usize,
    expandable: bool,
};

pub fn is_word(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

pub fn skip_ws(content: []const u8, start: usize) usize {
    var i = start;
    while (i < content.len and std.ascii.isWhitespace(content[i])) : (i += 1) {}
    return i;
}

pub fn scan_whitespace(input: []const u8, start: usize) usize {
    var pos = start;
    while (pos < input.len and std.ascii.isWhitespace(input[pos])) : (pos += 1) {}
    return pos;
}

pub fn scan_digits(input: []const u8, start: usize) usize {
    var pos = start;
    while (pos < input.len and std.ascii.isDigit(input[pos])) : (pos += 1) {}
    return pos;
}

pub fn scan_word_chars(input: []const u8, start: usize) usize {
    var pos = start;
    while (pos < input.len and is_word(input[pos])) : (pos += 1) {}
    return pos;
}

pub fn strip_comment(line: []const u8) ![]const u8 {
    var single_q = false;
    var double_q = false;
    for (line, 0..) |l, i| {
        if (l == '"' and !single_q) {
            double_q = !double_q;
        } else if (l == '\'' and !double_q) {
            single_q = !single_q;
        } else if (l == '#' and !single_q and !double_q) {
            return line[0..i];
        }
    }
    return line;
}

fn is_shell_word_delimiter(c: u8) bool {
    return std.ascii.isWhitespace(c) or std.mem.indexOfScalar(u8, ";&|()<>\"'`", c) != null;
}

fn keyword_at(input: []const u8, start: usize, keyword: []const u8) bool {
    if (!std.mem.startsWith(u8, input[start..], keyword)) return false;
    const end = start + keyword.len;
    return end == input.len or is_shell_word_delimiter(input[end]);
}

fn is_assignment_word(word: []const u8) bool {
    const equals = std.mem.indexOfScalar(u8, word, '=') orelse return false;
    if (equals == 0 or !(std.ascii.isAlphabetic(word[0]) or word[0] == '_')) return false;
    for (word[1..equals]) |c| if (!is_word(c)) return false;
    return true;
}

/// Returns the first byte after a command substitution, or the end of the
/// input when it is unterminated. The contents are deliberately opaque to the
/// outer conditional scanner: an `if` executed by $(...) cannot contain the
/// top-level assignment being classified.
fn skip_command_substitution(input: []const u8, start: usize) usize {
    var depth: usize = 1;
    var in_single = false;
    var in_double = false;
    var in_backtick = false;
    var in_comment = false;
    var word_start = true;
    var i = start;
    while (i < input.len) {
        const c = input[i];
        if (in_comment) {
            i += 1;
            if (c == '\n') {
                in_comment = false;
                word_start = true;
            }
            continue;
        }
        if (c == '\\' and !in_single and i + 1 < input.len) {
            i += 2;
            word_start = false;
            continue;
        }
        if (c == '\'' and !in_double and !in_backtick) {
            in_single = !in_single;
            i += 1;
            word_start = false;
            continue;
        }
        if (c == '"' and !in_single and !in_backtick) {
            in_double = !in_double;
            i += 1;
            word_start = false;
            continue;
        }
        if (c == '`' and !in_single) {
            in_backtick = !in_backtick;
            i += 1;
            word_start = false;
            continue;
        }
        if (in_single or in_double or in_backtick) {
            i += 1;
            continue;
        }
        if (c == '#' and word_start) {
            in_comment = true;
            i += 1;
            continue;
        }
        if (c == '$' and i + 1 < input.len and input[i + 1] == '(') {
            depth += 1;
            i += 2;
            word_start = false;
            continue;
        }
        if (c == '(') {
            depth += 1;
        } else if (c == ')') {
            depth -= 1;
            i += 1;
            if (depth == 0) return i;
            word_start = false;
            continue;
        }
        word_start = std.ascii.isWhitespace(c) or std.mem.indexOfScalar(u8, ";&|()", c) != null;
        i += 1;
    }
    return input.len;
}

fn skip_backtick_substitution(input: []const u8, start: usize) usize {
    var i = start;
    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            i += 2;
            continue;
        }
        if (input[i] == '`') return i + 1;
        i += 1;
    }
    return input.len;
}

fn skip_heredoc_bodies(
    self: PkgbuildParser,
    input: []const u8,
    start: usize,
    pending: *std.ArrayList(heredoc_declaration),
) usize {
    var i = start;
    while (pending.items.len > 0) {
        const declaration = pending.orderedRemove(0);
        defer self.allocator.free(declaration.delimiter);

        while (i < input.len) {
            const line_end = std.mem.indexOfScalarPos(u8, input, i, '\n') orelse input.len;
            var line = input[i..line_end];
            if (declaration.strip_tabs) line = std.mem.trimStart(u8, line, "\t");
            line = std.mem.trimEnd(u8, line, "\r");
            i = if (line_end < input.len) line_end + 1 else line_end;
            if (std.mem.eql(u8, line, declaration.delimiter)) break;
        }
    }
    return i;
}

fn conditional_depth(self: PkgbuildParser, input: []const u8) !usize {
    var pending: std.ArrayList(heredoc_declaration) = .empty;
    defer {
        for (pending.items) |declaration| self.allocator.free(declaration.delimiter);
        pending.deinit(self.allocator);
    }

    var depth: usize = 0;
    var command_start = true;
    var word_start = true;
    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c == '\n') {
            i += 1;
            command_start = true;
            word_start = true;
            if (pending.items.len > 0)
                i = skip_heredoc_bodies(self, input, i, &pending);
            continue;
        }
        if (std.ascii.isWhitespace(c)) {
            i += 1;
            word_start = true;
            continue;
        }
        if (c == '#' and word_start) {
            i = std.mem.indexOfScalarPos(u8, input, i, '\n') orelse input.len;
            continue;
        }
        if (c == '\\' and i + 1 < input.len) {
            if (word_start and command_start) command_start = false;
            i += 2;
            word_start = false;
            continue;
        }
        if (c == '\'' or c == '"') {
            const quote = c;
            if (word_start and command_start) command_start = false;
            i += 1;
            while (i < input.len) {
                if (quote == '"' and input[i] == '\\' and i + 1 < input.len) {
                    i += 2;
                    continue;
                }
                if (input[i] == quote) {
                    i += 1;
                    break;
                }
                i += 1;
            }
            word_start = false;
            continue;
        }
        if (c == '`') {
            if (word_start and command_start) command_start = false;
            i = skip_backtick_substitution(input, i + 1);
            word_start = false;
            continue;
        }
        if (c == '$' and i + 1 < input.len and input[i + 1] == '(') {
            if (word_start and command_start) command_start = false;
            i = skip_command_substitution(input, i + 2);
            word_start = false;
            continue;
        }
        // The previous-byte check rejects the second `<` of a here-string
        // (`<<<`), which would otherwise parse as a quoted heredoc.
        if (c == '<' and i + 1 < input.len and input[i + 1] == '<' and
            (i + 2 >= input.len or input[i + 2] != '<') and
            (i == 0 or input[i - 1] != '<'))
        {
            if (try parse_heredoc_declaration(self, input, i + 2)) |declaration| {
                errdefer self.allocator.free(declaration.delimiter);
                try pending.append(self.allocator, declaration);
                i = declaration.end;
                word_start = false;
                continue;
            }
        }
        if (std.mem.indexOfScalar(u8, ";&|(){}", c) != null) {
            i += 1;
            command_start = true;
            word_start = true;
            continue;
        }
        if (command_start and keyword_at(input, i, "if")) {
            depth += 1;
            i += 2;
            command_start = true;
            word_start = false;
            continue;
        }
        if (command_start and keyword_at(input, i, "fi")) {
            depth = if (depth > 0) depth - 1 else 0;
            i += 2;
            command_start = false;
            word_start = false;
            continue;
        }
        inline for (.{ "then", "else", "elif", "do" }) |keyword| {
            if (command_start and keyword_at(input, i, keyword)) {
                i += keyword.len;
                command_start = true;
                word_start = false;
                break;
            }
        } else {
            if (c == '!' and command_start) {
                i += 1;
                word_start = false;
                continue;
            }

            const start = i;
            while (i < input.len and !is_shell_word_delimiter(input[i])) {
                if (input[i] == '$' and i + 1 < input.len and input[i + 1] == '(') break;
                if (input[i] == '\\' and i + 1 < input.len) i += 1;
                i += 1;
            }
            if (i == start) {
                i += 1;
            } else if (!(command_start and is_assignment_word(input[start..i]))) {
                command_start = false;
            }
            word_start = false;
        }
    }
    return depth;
}

pub fn is_inside_conditional_block(self: PkgbuildParser, content: []const u8, position: usize) !bool {
    return try conditional_depth(self, content[0..@min(position, content.len)]) > 0;
}

/// A heredoc opened on a command line. Its body starts on the next
/// line and runs up to (and including) the delimiter line.
pub const heredoc_declaration = struct {
    delimiter: []const u8, // owned
    expandable: bool, // bash expands bodies only when the delimiter is unquoted
    strip_tabs: bool, // <<- tolerates leading tabs before the delimiter
    end: usize, // index just past the delimiter token
};

pub fn find_command_substitution_close(input: []const u8, start: usize) ?usize {
    var depth: usize = 1;
    var i: usize = start;
    while (i < input.len) : (i += 1) {
        switch (input[i]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// Splits a shell snippet into contiguous slices tagged with whether
/// bash performs parameter expansion inside them. Single-quoted runs
/// and backslash-escaped pairs are not expandable; everything else
/// (including double-quoted and backtick runs) is. Heredoc bodies are
/// emitted as one atomic slice each — non-expandable when the
/// delimiter is quoted (<<'EOF'), expandable otherwise (<<EOF) — so
/// their contents can never disturb quote tracking of later lines.
pub fn split_shell_segments(self: PkgbuildParser, input: []const u8) ![]shell_segment {
    var segments: std.ArrayList(shell_segment) = .empty;
    errdefer segments.deinit(self.allocator);

    var pending: std.ArrayList(heredoc_declaration) = .empty;
    defer {
        for (pending.items) |declaration| self.allocator.free(declaration.delimiter);
        pending.deinit(self.allocator);
    }

    var seg_start: usize = 0;
    var in_single = false;
    var in_double = false;
    var i: usize = 0;

    while (i < input.len) {
        const c = input[i];

        if (in_single) {
            i += 1;
            if (c == '\'') {
                try segments.append(self.allocator, .{ .start = seg_start, .end = i, .expandable = false });
                seg_start = i;
                in_single = false;
            }
            continue;
        }

        // Heredoc bodies declared on this line start on the next one.
        if (c == '\n' and !in_double and pending.items.len > 0) {
            if (i + 1 > seg_start) {
                try segments.append(self.allocator, .{ .start = seg_start, .end = i + 1, .expandable = true });
            }
            i += 1;
            seg_start = i;

            while (pending.items.len > 0) {
                const declaration = pending.orderedRemove(0);
                defer self.allocator.free(declaration.delimiter);

                var cursor = i;
                var body_end = input.len;
                while (cursor < input.len) {
                    const line_end = std.mem.indexOfScalarPos(u8, input, cursor, '\n') orelse input.len;
                    var line = input[cursor..line_end];
                    if (declaration.strip_tabs) line = std.mem.trimStart(u8, line, "\t");
                    line = std.mem.trimEnd(u8, line, "\r");
                    if (std.mem.eql(u8, line, declaration.delimiter)) {
                        body_end = if (line_end < input.len) line_end + 1 else line_end;
                        break;
                    }
                    if (line_end == input.len) break;
                    cursor = line_end + 1;
                }

                try segments.append(self.allocator, .{ .start = i, .end = body_end, .expandable = declaration.expandable });
                i = body_end;
                seg_start = i;
                if (i >= input.len) break;
            }
            continue;
        }

        if (c == '\\' and i + 1 < input.len) {
            const target = input[i + 1];
            // Inside double quotes a backslash is only special before
            // $, `, " or another backslash.
            const special = !in_double or std.mem.indexOfScalar(u8, "$`\"\\", target) != null;
            if (special) {
                if (i > seg_start) {
                    try segments.append(self.allocator, .{ .start = seg_start, .end = i, .expandable = true });
                }
                try segments.append(self.allocator, .{ .start = i, .end = i + 2, .expandable = false });
                i += 2;
                seg_start = i;
                continue;
            }
            i += 1;
            continue;
        }

        if (c == '\'' and !in_double) {
            if (i > seg_start) {
                try segments.append(self.allocator, .{ .start = seg_start, .end = i, .expandable = true });
            }
            seg_start = i;
            in_single = true;
            i += 1;
            continue;
        }

        if (c == '"' or c == '`') {
            in_double = !in_double;
            i += 1;
            continue;
        }

        // Skip arithmetic expansions whole so a << shift inside them
        // is not mistaken for a heredoc introducer.
        if (c == '$' and i + 2 < input.len and input[i + 1] == '(' and input[i + 2] == '(') {
            const close = std.mem.indexOfPos(u8, input, i + 3, "))") orelse {
                i += 1;
                continue;
            };
            i = close + 2;
            continue;
        }

        // The previous-byte check rejects the second `<` of a here-string
        // (`<<<`), which would otherwise parse as a quoted heredoc.
        if (c == '<' and !in_double and i + 1 < input.len and input[i + 1] == '<' and
            (i + 2 >= input.len or input[i + 2] != '<') and
            (i == 0 or input[i - 1] != '<'))
        {
            if (try parse_heredoc_declaration(self, input, i + 2)) |declaration| {
                errdefer self.allocator.free(declaration.delimiter);
                try pending.append(self.allocator, declaration);
                i = declaration.end;
                continue;
            }
        }

        i += 1;
    }

    if (seg_start < input.len) {
        try segments.append(self.allocator, .{ .start = seg_start, .end = input.len, .expandable = !in_single });
    }

    return segments.toOwnedSlice(self.allocator);
}

/// Parses the delimiter of a heredoc introducer starting right after
/// the `<<`. Any quoting in the delimiter (<<'EOF', <<"EOF", <<\EOF)
/// marks the body as non-expanding, mirroring bash. Returns null when
/// no delimiter token follows the introducer.
fn parse_heredoc_declaration(self: PkgbuildParser, input: []const u8, start: usize) !?heredoc_declaration {
    var j = start;
    var strip_tabs = false;
    if (j < input.len and input[j] == '-') {
        strip_tabs = true;
        j += 1;
    }
    while (j < input.len and (input[j] == ' ' or input[j] == '\t')) j += 1;

    var delim: std.ArrayList(u8) = .empty;
    errdefer delim.deinit(self.allocator);

    var quoted = false;
    var quote_char: u8 = 0;
    var k = j;
    while (k < input.len) {
        const ch = input[k];
        if (quote_char != 0) {
            if (ch == quote_char) {
                quote_char = 0;
            } else {
                try delim.append(self.allocator, ch);
            }
            k += 1;
            continue;
        }
        if (ch == '\'' or ch == '"') {
            quoted = true;
            quote_char = ch;
            k += 1;
            continue;
        }
        if (ch == '\\' and k + 1 < input.len) {
            quoted = true;
            try delim.append(self.allocator, input[k + 1]);
            k += 2;
            continue;
        }
        if (!is_heredoc_delimiter_char(ch)) break;
        try delim.append(self.allocator, ch);
        k += 1;
    }

    if (delim.items.len == 0) {
        delim.deinit(self.allocator);
        return null;
    }

    return heredoc_declaration{
        .delimiter = try delim.toOwnedSlice(self.allocator),
        .expandable = !quoted,
        .strip_tabs = strip_tabs,
        .end = k,
    };
}

fn is_heredoc_delimiter_char(ch: u8) bool {
    return switch (ch) {
        ' ', '\t', '\n', '\r', ';', '&', '|', '(', ')', '<', '>', '#', '$', '`' => false,
        else => true,
    };
}

pub fn contains_command_substitution(value: []const u8) bool {
    var index: usize = 0;
    var in_single = false;
    var in_double = false;
    while (index + 1 < value.len) : (index += 1) {
        if (value[index] == '\\' and !in_single) {
            index += 1;
            continue;
        }
        if (value[index] == '\'' and !in_double) {
            in_single = !in_single;
            continue;
        }
        if (value[index] == '"' and !in_single) {
            in_double = !in_double;
            continue;
        }
        if (in_single) continue;
        if (value[index] == '#' and !in_double) {
            index = std.mem.indexOfScalarPos(u8, value, index, '\n') orelse value.len;
            continue;
        }
        if (value[index] == '`') return true;
        if (value[index] != '$' or value[index + 1] != '(') continue;
        if (index + 2 < value.len and value[index + 2] == '(') continue;
        return true;
    }
    return false;
}

test "strip_comment: no comment returns full line" {
    const result = try strip_comment("pkgname=foo");
    try std.testing.expectEqualStrings("pkgname=foo", result);
}

test "strip_comment: simple trailing comment" {
    const result = try strip_comment("pkgname=foo # comment");
    try std.testing.expectEqualStrings("pkgname=foo ", result);
}

test "strip_comment: comment at start of line" {
    const result = try strip_comment("# full comment line");
    try std.testing.expectEqualStrings("", result);
}

test "strip_comment: hash inside double quotes is not a comment" {
    const result = try strip_comment("pkgdesc=\"a # not a comment\"");
    try std.testing.expectEqualStrings("pkgdesc=\"a # not a comment\"", result);
}

test "strip_comment: empty line" {
    const result = try strip_comment("");
    try std.testing.expectEqualStrings("", result);
}

test "is_inside_conditional_block: no if/fi returns false" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content = "pkgname=foo\npkgver=1.0\n";
    try std.testing.expect(!try is_inside_conditional_block(parser, content, content.len));
}

test "is_inside_conditional_block: inside an open if block" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content = "if true; then\n  pkgname=foo\n";
    try std.testing.expect(try is_inside_conditional_block(parser, content, content.len));
}

test "is_inside_conditional_block: closed by matching fi" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content = "if true; then\n  pkgname=foo\nfi\npkgver=1.0\n";
    try std.testing.expect(!try is_inside_conditional_block(parser, content, content.len));
}

test "is_inside_conditional_block: nested if only closed one level" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content = "if true; then\n  if true; then\n    pkgname=foo\n  fi\n";
    try std.testing.expect(try is_inside_conditional_block(parser, content, content.len));
}

test "is_inside_conditional_block: extra fi does not go negative" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content = "fi\nfi\npkgname=foo\n";
    try std.testing.expect(!try is_inside_conditional_block(parser, content, content.len));
}

test "is_inside_conditional_block: word boundary rejects 'ifs' and 'fix'" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content = "ifs=foo\nfix=1\n";
    try std.testing.expect(!try is_inside_conditional_block(parser, content, content.len));
}

test "is_inside_conditional_block: position before the if is not inside" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content = "pkgname=foo\nif true; then\n  pkgrel=1\nfi\n";
    const if_pos = std.mem.indexOf(u8, content, "if").?;
    try std.testing.expect(!try is_inside_conditional_block(parser, content, if_pos));
}

test "is_inside_conditional_block: ignores comments quotes substitutions and heredocs" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\# use this only if the feature exists
        \\description='if fi'
        \\message="if fi"
        \\generated=$(printf 'if')
        \\legacy=`printf fi`
        \\cat <<'EOF'
        \\if this is heredoc prose
        \\EOF
        \\pkgname=(demo)
    ;
    const position = std.mem.indexOf(u8, content, "pkgname").?;
    try std.testing.expect(!try is_inside_conditional_block(parser, content, position));
}

test "is_inside_conditional_block: only command-position keywords affect depth" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\printf '%s' if
        \\echo fi
        \\if true; then
        \\  pkgname=(demo)
    ;
    const position = std.mem.indexOf(u8, content, "pkgname").?;
    try std.testing.expect(try is_inside_conditional_block(parser, content, position));
}

test "is_inside_conditional_block: here-string does not swallow the closing fi" {
    // Issue 1848: the second `<` of `<<<` re-triggered heredoc detection,
    // and the phantom body skip consumed every following line.
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const content =
        \\if true; then
        \\  mapfile -t deps <<< "$(cat list)"
        \\fi
        \\pkgname=foo
    ;
    const position = std.mem.indexOf(u8, content, "pkgname").?;
    try std.testing.expect(!try is_inside_conditional_block(parser, content, position));
}
