//! Extraction of function bodies from PKGBUILD shell source.
const std = @import("std");
const shell_scan = @import("shell_scan.zig");
const PkgbuildParser = @import("parser.zig").PkgbuildParser;

pub fn selected_package_body(self: PkgbuildParser, content: []const u8) !?[]const u8 {
    return selected_package_body_with_vars(self, content, null);
}

/// Returns the package-scoped body selected by makepkg. In addition to a
/// literal package_<name>() declaration, this recognizes the helper dispatch
/// used by CachyOS kernel PKGBUILDs:
///
///   eval "package_$_p() { $(declare -f \"_package${_p#$pkgbase}\"); ... }"
///
/// The reviewed eval text is never executed by the parser. We only map the
/// selected package name to its literal _package<suffix>() helper and extract
/// that helper's body with the normal static function scanner.
pub fn selected_package_body_with_vars(
    self: PkgbuildParser,
    content: []const u8,
    vars: ?*const std.StringHashMap([]const u8),
) !?[]const u8 {
    // A null selection is the initial/global parse. Preserve the global
    // metadata there; package() assignments are applied only once a concrete
    // package member is selected.
    if (self.selected_package_name == null) return null;
    if (try selected_scoped_package_body(self, content, vars)) |body| return body;
    return try extract_function_body(content, "package");
}

/// Like selected_package_body_with_vars, but does not fall back to package().
/// Package-function contract validation uses this to distinguish an actual
/// split member function from a forbidden generic split package function.
pub fn selected_scoped_package_body(
    self: PkgbuildParser,
    content: []const u8,
    vars: ?*const std.StringHashMap([]const u8),
) !?[]const u8 {
    const package_name = self.selected_package_name orelse return null;
    const function_name = try std.fmt.allocPrint(
        self.allocator,
        "package_{s}",
        .{package_name},
    );
    defer self.allocator.free(function_name);

    if (try extract_function_body(content, function_name)) |body| return body;
    const pkgbase = (vars orelse return null).get("pkgbase") orelse return null;
    return try generated_helper_body(self, content, package_name, pkgbase);
}

fn generated_helper_body(
    self: PkgbuildParser,
    content: []const u8,
    package_name: []const u8,
    pkgbase: []const u8,
) !?[]const u8 {
    if (!std.mem.startsWith(u8, package_name, pkgbase)) return null;

    // Require all structural pieces of the known dispatch idiom before
    // treating a private helper as a generated package function. This avoids
    // assigning package semantics to an unrelated _package helper.
    if (!has_generated_helper_dispatch(content)) return null;

    const suffix = package_name[pkgbase.len..];
    const helper_name = try std.fmt.allocPrint(self.allocator, "_package{s}", .{suffix});
    defer self.allocator.free(helper_name);
    return try extract_function_body(content, helper_name);
}

fn has_generated_helper_dispatch(content: []const u8) bool {
    var has_eval = false;
    var has_declaration = false;
    var has_call = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.startsWith(u8, line, "#")) continue;
        if (std.mem.startsWith(u8, line, "eval \"package_")) has_eval = true;
        if (std.mem.startsWith(u8, line, "$(declare -f \"_package${") and
            std.mem.indexOf(u8, line, "#$pkgbase}") != null)
            has_declaration = true;
        if (std.mem.startsWith(u8, line, "_package${") and
            std.mem.indexOf(u8, line, "#$pkgbase}") != null)
            has_call = true;
    }
    return has_eval and has_declaration and has_call;
}

pub fn extract_function_body(content: []const u8, function_name: []const u8) !?[]const u8 {
    const header_match = try match_at_line_start(content, 0, function_name);
    const header = header_match orelse return null;

    const end = switch (header.delimiter) {
        .brace => try find_brace_body_end(content, header.body_start),
        .subshell => try find_subshell_body_end(content, header.body_start),
    };
    const substring = content[header.body_start..end];
    return std.mem.trim(u8, substring, " \t\n\r");
}

pub const function_body_delimiter = enum {
    brace,
    subshell,
};

pub const function_definition = struct {
    body: []const u8,
    delimiter: function_body_delimiter,
};

/// Returns both the function body and the compound-command form used to
/// declare it. Consumers that reconstruct helper functions need the latter to
/// preserve subshell semantics.
pub fn extract_function_definition(
    content: []const u8,
    function_name: []const u8,
) !?function_definition {
    const header = (try match_at_line_start(content, 0, function_name)) orelse return null;
    const end = switch (header.delimiter) {
        .brace => try find_brace_body_end(content, header.body_start),
        .subshell => try find_subshell_body_end(content, header.body_start),
    };
    return .{
        .body = std.mem.trim(u8, content[header.body_start..end], " \t\n\r"),
        .delimiter = header.delimiter,
    };
}

const function_header = struct {
    body_start: usize,
    delimiter: function_body_delimiter,
};

/// Finds the closing brace of a Bash brace-group function body. Braces only
/// affect the nesting depth when they are shell reserved words; quoted text,
/// comments, heredocs, expansions, and substitutions are skipped as opaque
/// regions so data such as a sed expression cannot consume later functions.
fn find_brace_body_end(content: []const u8, start: usize) function_scan_error!usize {
    var depth: usize = 1;
    var word_start = true;
    var pending: [max_pending_heredocs]pending_heredoc = undefined;
    var pending_count: usize = 0;
    var i = start;

    while (i < content.len) {
        const c = content[i];

        if (c == '\n') {
            i += 1;
            word_start = true;
            if (pending_count > 0) {
                i = skip_heredoc_bodies(content, i, pending[0..pending_count]);
                pending_count = 0;
            }
            continue;
        }
        if (std.ascii.isWhitespace(c)) {
            i += 1;
            word_start = true;
            continue;
        }
        if (c == '#' and word_start) {
            i = std.mem.indexOfScalarPos(u8, content, i, '\n') orelse content.len;
            continue;
        }
        if (c == '\\' and i + 1 < content.len) {
            const escaped_newline = content[i + 1] == '\n';
            i += 2;
            if (!escaped_newline) word_start = false;
            continue;
        }
        if (c == '\'') {
            i = skip_single_quote(content, i + 1);
            word_start = false;
            continue;
        }
        if (c == '"') {
            i = try skip_double_quote(content, i + 1);
            word_start = false;
            continue;
        }
        if (c == '`') {
            i = skip_backtick(content, i + 1);
            word_start = false;
            continue;
        }

        if (c == '$' and i + 2 < content.len and content[i + 1] == '(' and content[i + 2] == '(') {
            i = try skip_arithmetic(content, i + 3, 2);
            word_start = false;
            continue;
        }
        if (c == '(' and i + 1 < content.len and content[i + 1] == '(') {
            i = try skip_arithmetic(content, i + 2, 2);
            word_start = false;
            continue;
        }
        if (c == '$' and i + 1 < content.len and content[i + 1] == '(') {
            const close = try find_subshell_body_end(content, i + 2);
            i = if (close < content.len) close + 1 else close;
            word_start = false;
            continue;
        }
        if (c == '$' and i + 1 < content.len and content[i + 1] == '{') {
            i = try skip_parameter_expansion(content, i + 2);
            word_start = false;
            continue;
        }

        // The previous-byte check rejects the second `<` of a here-string
        // (`<<<`), which would otherwise parse as a quoted heredoc.
        if (c == '<' and i + 1 < content.len and content[i + 1] == '<' and
            (i + 2 >= content.len or content[i + 2] != '<') and
            (i == 0 or content[i - 1] != '<'))
        {
            if (parse_heredoc_declaration(content, i + 2)) |declaration| {
                if (pending_count == pending.len) return error.TooManyHeredocs;
                pending[pending_count] = declaration;
                pending_count += 1;
                i = declaration.end;
                word_start = false;
                continue;
            }
        }

        if ((c == '{' or c == '}') and is_structural_brace(content, i, word_start)) {
            if (c == '{') {
                depth += 1;
            } else {
                depth -= 1;
                if (depth == 0) return i;
            }
            i += 1;
            word_start = true;
            continue;
        }

        if (std.mem.indexOfScalar(u8, ";&|()<>", c) != null) {
            i += 1;
            word_start = true;
            continue;
        }

        i += 1;
        word_start = false;
    }

    return content.len;
}

fn is_structural_brace(content: []const u8, index: usize, word_start: bool) bool {
    if (!word_start or index + 1 == content.len) return word_start;
    const next = content[index + 1];
    return std.ascii.isWhitespace(next) or
        std.mem.indexOfScalar(u8, ";&|(){}<>", next) != null;
}

const max_pending_heredocs = 16;
const max_nested_case_statements = 32;
const function_scan_error = error{ TooManyHeredocs, TooManyCaseStatements };

const pending_heredoc = struct {
    delimiter_token: []const u8,
    strip_tabs: bool,
    end: usize,
};

/// Finds the closing parenthesis of a Bash subshell compound command. Unlike
/// a byte-counting scan, this skips quoted text, comments, heredoc bodies, and
/// nested substitutions, and does not mistake `case` pattern terminators for
/// the end of the function.
fn find_subshell_body_end(content: []const u8, start: usize) function_scan_error!usize {
    var depth: usize = 1;
    var case_depths: [max_nested_case_statements]usize = undefined;
    var case_count: usize = 0;
    var command_start = true;
    var word_start = true;
    var pending: [max_pending_heredocs]pending_heredoc = undefined;
    var pending_count: usize = 0;
    var i = start;

    while (i < content.len) {
        const c = content[i];

        if (c == '\n') {
            i += 1;
            command_start = true;
            word_start = true;
            if (pending_count > 0) {
                i = skip_heredoc_bodies(content, i, pending[0..pending_count]);
                pending_count = 0;
            }
            continue;
        }
        if (std.ascii.isWhitespace(c)) {
            i += 1;
            word_start = true;
            continue;
        }
        if (c == '#' and word_start) {
            i = std.mem.indexOfScalarPos(u8, content, i, '\n') orelse content.len;
            continue;
        }
        if (c == '\\' and i + 1 < content.len) {
            i += 2;
            word_start = false;
            continue;
        }
        if (c == '\'') {
            i = skip_single_quote(content, i + 1);
            command_start = false;
            word_start = false;
            continue;
        }
        if (c == '"') {
            i = try skip_double_quote(content, i + 1);
            command_start = false;
            word_start = false;
            continue;
        }
        if (c == '`') {
            i = skip_backtick(content, i + 1);
            command_start = false;
            word_start = false;
            continue;
        }

        // Arithmetic contexts may contain shift operators (`<<`) and
        // parentheses that are unrelated to shell compound commands.
        if (c == '$' and i + 2 < content.len and content[i + 1] == '(' and content[i + 2] == '(') {
            i = try skip_arithmetic(content, i + 3, 2);
            command_start = false;
            word_start = false;
            continue;
        }
        if (c == '(' and i + 1 < content.len and content[i + 1] == '(') {
            i = try skip_arithmetic(content, i + 2, 2);
            command_start = false;
            word_start = false;
            continue;
        }

        // The previous-byte check rejects the second `<` of a here-string
        // (`<<<`), which would otherwise parse as a quoted heredoc.
        if (c == '<' and i + 1 < content.len and content[i + 1] == '<' and
            (i + 2 >= content.len or content[i + 2] != '<') and
            (i == 0 or content[i - 1] != '<'))
        {
            if (parse_heredoc_declaration(content, i + 2)) |declaration| {
                if (pending_count == pending.len) return error.TooManyHeredocs;
                pending[pending_count] = declaration;
                pending_count += 1;
                i = declaration.end;
                word_start = false;
                continue;
            }
        }

        if (c == '(') {
            depth += 1;
            i += 1;
            command_start = true;
            word_start = true;
            continue;
        }
        if (c == ')') {
            // A `case` pattern's terminating ')' is not paired with an
            // opening parenthesis. It is only special at the current
            // compound-command level; nested subshells still balance normally.
            if (case_count > 0 and case_depths[case_count - 1] == depth) {
                i += 1;
                command_start = true;
                word_start = true;
                continue;
            }
            depth -= 1;
            if (depth == 0) return i;
            i += 1;
            command_start = true;
            word_start = true;
            continue;
        }

        if (std.mem.indexOfScalar(u8, ";&|{}", c) != null) {
            i += 1;
            command_start = true;
            word_start = true;
            continue;
        }

        const token_start = i;
        while (i < content.len and !is_shell_token_delimiter(content[i])) {
            if (content[i] == '\\' and i + 1 < content.len) i += 1;
            i += 1;
        }
        if (i == token_start) {
            i += 1;
            word_start = false;
            continue;
        }

        const token = content[token_start..i];
        if (command_start and std.mem.eql(u8, token, "case")) {
            if (case_count == case_depths.len) return error.TooManyCaseStatements;
            case_depths[case_count] = depth;
            case_count += 1;
            command_start = false;
        } else if (command_start and std.mem.eql(u8, token, "esac")) {
            if (case_count > 0) case_count -= 1;
            command_start = false;
        } else if (command_start and is_assignment_word(token)) {
            // Assignment prefixes do not consume command position.
        } else if (is_command_prefix_keyword(token)) {
            command_start = true;
        } else {
            command_start = false;
        }
        word_start = false;
    }

    return content.len;
}

fn skip_single_quote(content: []const u8, start: usize) usize {
    const close = std.mem.indexOfScalarPos(u8, content, start, '\'') orelse return content.len;
    return close + 1;
}

fn skip_double_quote(content: []const u8, start: usize) function_scan_error!usize {
    var i = start;
    while (i < content.len) {
        if (content[i] == '\\' and i + 1 < content.len) {
            i += 2;
            continue;
        }
        if (content[i] == '"') return i + 1;
        if (content[i] == '`') {
            i = skip_backtick(content, i + 1);
            continue;
        }
        if (content[i] == '$' and i + 2 < content.len and content[i + 1] == '(' and content[i + 2] == '(') {
            i = try skip_arithmetic(content, i + 3, 2);
            continue;
        }
        if (content[i] == '$' and i + 1 < content.len and content[i + 1] == '(') {
            const close = try find_subshell_body_end(content, i + 2);
            i = if (close < content.len) close + 1 else close;
            continue;
        }
        if (content[i] == '$' and i + 1 < content.len and content[i + 1] == '{') {
            i = try skip_parameter_expansion(content, i + 2);
            continue;
        }
        i += 1;
    }
    return content.len;
}

fn skip_backtick(content: []const u8, start: usize) usize {
    var i = start;
    while (i < content.len) {
        if (content[i] == '\\' and i + 1 < content.len) {
            i += 2;
            continue;
        }
        if (content[i] == '`') return i + 1;
        i += 1;
    }
    return content.len;
}

fn skip_arithmetic(content: []const u8, start: usize, initial_depth: usize) function_scan_error!usize {
    var depth = initial_depth;
    var i = start;
    while (i < content.len and depth > 0) {
        if (content[i] == '\\' and i + 1 < content.len) {
            i += 2;
            continue;
        }
        if (content[i] == '\'') {
            i = skip_single_quote(content, i + 1);
            continue;
        }
        if (content[i] == '"') {
            i = try skip_double_quote(content, i + 1);
            continue;
        }
        if (content[i] == '(') {
            depth += 1;
        } else if (content[i] == ')') {
            depth -= 1;
        }
        i += 1;
    }
    return i;
}

/// Returns the first byte after a parameter expansion that starts with `${`.
/// Nested expansions and substitutions are opaque to the surrounding
/// function-body scanner, so their braces cannot terminate a function.
fn skip_parameter_expansion(content: []const u8, start: usize) function_scan_error!usize {
    var depth: usize = 1;
    var i = start;
    while (i < content.len) {
        if (content[i] == '\\' and i + 1 < content.len) {
            i += 2;
            continue;
        }
        if (content[i] == '\'') {
            i = skip_single_quote(content, i + 1);
            continue;
        }
        if (content[i] == '"') {
            i = try skip_double_quote(content, i + 1);
            continue;
        }
        if (content[i] == '`') {
            i = skip_backtick(content, i + 1);
            continue;
        }
        if (content[i] == '$' and i + 2 < content.len and content[i + 1] == '(' and content[i + 2] == '(') {
            i = try skip_arithmetic(content, i + 3, 2);
            continue;
        }
        if (content[i] == '$' and i + 1 < content.len and content[i + 1] == '(') {
            const close = try find_subshell_body_end(content, i + 2);
            i = if (close < content.len) close + 1 else close;
            continue;
        }
        if (content[i] == '$' and i + 1 < content.len and content[i + 1] == '{') {
            depth += 1;
            i += 2;
            continue;
        }
        if (content[i] == '}') {
            depth -= 1;
            i += 1;
            if (depth == 0) return i;
            continue;
        }
        i += 1;
    }
    return content.len;
}

fn is_shell_token_delimiter(c: u8) bool {
    return std.ascii.isWhitespace(c) or std.mem.indexOfScalar(u8, ";&|(){}<>\"'`", c) != null;
}

fn is_assignment_word(word: []const u8) bool {
    const equals = std.mem.indexOfScalar(u8, word, '=') orelse return false;
    if (equals == 0 or !(std.ascii.isAlphabetic(word[0]) or word[0] == '_')) return false;
    for (word[1..equals]) |c| if (!shell_scan.is_word(c)) return false;
    return true;
}

fn is_command_prefix_keyword(token: []const u8) bool {
    inline for (.{ "then", "else", "elif", "do", "in" }) |keyword|
        if (std.mem.eql(u8, token, keyword)) return true;
    return false;
}

fn parse_heredoc_declaration(content: []const u8, start: usize) ?pending_heredoc {
    var i = start;
    var strip_tabs = false;
    if (i < content.len and content[i] == '-') {
        strip_tabs = true;
        i += 1;
    }
    while (i < content.len and (content[i] == ' ' or content[i] == '\t')) i += 1;
    const token_start = i;
    var quote: u8 = 0;
    while (i < content.len) {
        const c = content[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
            i += 1;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
            i += 1;
            continue;
        }
        if (c == '\\' and i + 1 < content.len) {
            i += 2;
            continue;
        }
        if (is_shell_token_delimiter(c) or c == '$' or c == '#') break;
        i += 1;
    }
    if (i == token_start) return null;
    return .{
        .delimiter_token = content[token_start..i],
        .strip_tabs = strip_tabs,
        .end = i,
    };
}

fn skip_heredoc_bodies(content: []const u8, start: usize, pending: []const pending_heredoc) usize {
    var i = start;
    for (pending) |declaration| {
        while (i < content.len) {
            const line_end = std.mem.indexOfScalarPos(u8, content, i, '\n') orelse content.len;
            var line = std.mem.trimEnd(u8, content[i..line_end], "\r");
            if (declaration.strip_tabs) line = std.mem.trimStart(u8, line, "\t");
            i = if (line_end < content.len) line_end + 1 else line_end;
            if (heredoc_delimiter_matches(line, declaration.delimiter_token)) break;
        }
    }
    return i;
}

fn heredoc_delimiter_matches(line: []const u8, token: []const u8) bool {
    var line_i: usize = 0;
    var token_i: usize = 0;
    var quote: u8 = 0;
    while (token_i < token.len) : (token_i += 1) {
        const c = token[token_i];
        if (quote != 0) {
            if (c == quote) {
                quote = 0;
                continue;
            }
        } else if (c == '\'' or c == '"') {
            quote = c;
            continue;
        } else if (c == '\\' and token_i + 1 < token.len) {
            token_i += 1;
        }
        if (line_i >= line.len or line[line_i] != token[token_i]) return false;
        line_i += 1;
    }
    return line_i == line.len;
}

fn match_at_line_start(content: []const u8, start: usize, name: []const u8) !?function_header {
    var pos = start;
    while (pos < content.len) {
        const is_line_start = (pos == 0) or (content[pos - 1] == '\n');
        if (is_line_start) {
            const result = matchLineStart(content, pos, name);
            if (result) |r| return r;
            pos += 1;
            continue;
        }
        const nl = std.mem.indexOfScalarPos(u8, content, pos, '\n') orelse break;
        pos = nl + 1;
    }
    return null;
}

fn matchLineStart(c: []const u8, p: usize, n: []const u8) ?function_header {
    var i = shell_scan.skip_ws(c, p);
    if (std.mem.startsWith(u8, c[i..], "function")) {
        const after_kw = i + "function".len;
        const after_ws = shell_scan.skip_ws(c, after_kw);
        if (after_ws > after_kw) {
            i = after_ws;
        }
    }
    if (!std.mem.startsWith(u8, c[i..], n)) return null;
    i += n.len;
    i = shell_scan.skip_ws(c, i);
    if (i >= c.len or c[i] != '(') return null;
    i += 1;
    i = shell_scan.skip_ws(c, i);
    if (i >= c.len or c[i] != ')') return null;
    i += 1;
    i = shell_scan.skip_ws(c, i);
    if (i >= c.len or (c[i] != '{' and c[i] != '(')) return null;
    const delimiter: function_body_delimiter = if (c[i] == '{') .brace else .subshell;
    i += 1;
    return .{ .body_start = i, .delimiter = delimiter };
}

test "match_at_line_start: bare function call syntax, no keyword" {
    const content = "myFunction() {\n  return;\n}";
    const result = try match_at_line_start(content, 0, "myFunction");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 14), result.?.body_start); // index just past the '{'
    try std.testing.expectEqual(function_body_delimiter.brace, result.?.delimiter);
}

test "match_at_line_start: with 'function' keyword prefix" {
    const content = "function myFunction() {\n  return;\n}";
    const result = try match_at_line_start(content, 0, "myFunction");
    try std.testing.expect(result != null);
}

test "match_at_line_start: name that starts with 'function' but isn't the keyword" {
    const content = "functionCall() {\n}";
    const result = try match_at_line_start(content, 0, "functionCall");
    try std.testing.expect(result != null);
}

test "match_at_line_start: wrong function name does not match" {
    const content = "otherFunction() {\n}";
    const result = try match_at_line_start(content, 0, "myFunction");
    try std.testing.expect(result == null);
}

test "match_at_line_start: function with parameters does not match" {
    const content = "myFunction(a, b) {\n}";
    const result = try match_at_line_start(content, 0, "myFunction");
    try std.testing.expect(result == null);
}

test "match_at_line_start: whitespace and newlines between tokens are tolerated" {
    const content =
        \\myFunction
        \\  (
        \\  )
        \\  {
    ;
    const result = try match_at_line_start(content, 0, "myFunction");
    try std.testing.expect(result != null);
}

test "parser_content: subshell body and function keyword are recognized" {
    const content = "function myFunction () (\n  return\n)";
    const result = try match_at_line_start(content, 0, "myFunction");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(function_body_delimiter.subshell, result.?.delimiter);
}

test "extract_function_body: simple body with no nesting" {
    const content = "myFunction() {\n  return 1;\n}";
    const result = try extract_function_body(content, "myFunction");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("return 1;", result.?);
}

test "extract_function_body: nested braces are balanced correctly" {
    const content =
        \\myFunction() {
        \\  if (x) {
        \\    doThing();
        \\  }
        \\  return 1;
        \\}
    ;
    const result = try extract_function_body(content, "myFunction");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(
        "if (x) {\n    doThing();\n  }\n  return 1;",
        result.?,
    );
}

test "extract_function_body: Equicord sed expressions do not consume later functions" {
    const content =
        \\prepare() {
        \\  sed -i \\
        \\    -e '#async function fetchUpdates\\(\\) {#a return false;' \\
        \\    -e '#async function applyUpdates\\(\\) {#a return false;' \\
        \\    src/updater.ts
        \\}
        \\build() {
        \\  pnpm build
        \\}
        \\package() {
        \\  install -Dm644 app.asar "$pkgdir/usr/lib/app.asar"
        \\}
    ;
    const result = (try extract_function_body(content, "prepare")).?;
    try std.testing.expectEqualStrings(
        \\sed -i \\
        \\    -e '#async function fetchUpdates\\(\\) {#a return false;' \\
        \\    -e '#async function applyUpdates\\(\\) {#a return false;' \\
        \\    src/updater.ts
    , result);
    try std.testing.expect(std.mem.indexOf(u8, result, "build()") == null);
}

test "extract_function_body: brace scan skips shell data regions" {
    const content =
        \\prepare() {
        \\  echo "a double-quoted } is data"
        \\  echo escaped \\{
        \\  # a comment containing { does not open a group
        \\  fallback="${value:-{literal data} }"
        \\  generated="$(printf '%s' '{ command substitution data')"
        \\  cat <<'EOF'
        \\heredoc data with unmatched }}}
        \\EOF
        \\  {
        \\    echo nested-group
        \\  }
        \\  echo finished
        \\}
        \\build() { echo build; }
    ;
    const result = (try extract_function_body(content, "prepare")).?;
    try std.testing.expect(std.mem.indexOf(u8, result, "heredoc data with unmatched") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "echo nested-group") != null);
    try std.testing.expect(std.mem.endsWith(u8, result, "echo finished"));
    try std.testing.expect(std.mem.indexOf(u8, result, "build()") == null);
}

test "extract_function_body: no matching function returns null" {
    const content = "otherFunction() {\n  return 1;\n}";
    const result = try extract_function_body(content, "myFunction");
    try std.testing.expect(result == null);
}

test "extract_function_body: empty body" {
    const content = "myFunction() {}";
    const result = try extract_function_body(content, "myFunction");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("", result.?);
}

test "extract_function_body: unclosed brace consumes to end of content" {
    // depth never reaches 0, so the loop runs until content.len
    const content = "myFunction() {\n  return 1;";
    const result = try extract_function_body(content, "myFunction");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("return 1;", result.?);
}

test "parser_content: simple subshell function body" {
    const content =
        \\build() (
        \\  cmake -B build
        \\  cmake --build build
        \\)
        \\package() { install -Dm755 demo "$pkgdir/usr/bin/demo"; }
    ;
    const result = try extract_function_body(content, "build");
    try std.testing.expectEqualStrings("cmake -B build\n  cmake --build build", result.?);
}

test "parser_content: subshell scan ignores nested shell syntax" {
    const content =
        \\build() (
        \\  local values=(one "(two)")
        \\  echo 'single ) quote' "double ) quote"
        \\  echo "$(printf "%s" ")")"
        \\  total=$((1 + (2 * 3)))
        \\  ((total <<= 1))
        \\  # a comment containing ) does not close the body
        \\  (cd nested && run_build)
        \\  case "$target" in
        \\    one|two) echo "matched)" ;;
        \\    *) echo fallback ;;
        \\  esac
        \\  echo "$(case "$target" in one) echo nested ;; *) echo other ;; esac)"
        \\  echo finished
        \\)
        \\package() { echo package; }
    ;
    const result = (try extract_function_body(content, "build")).?;
    try std.testing.expect(std.mem.indexOf(u8, result, "local values=(one") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "case \"$target\" in") != null);
    try std.testing.expect(std.mem.endsWith(u8, result, "echo finished"));
    try std.testing.expect(std.mem.indexOf(u8, result, "package()") == null);
}

test "parser_content: subshell scan skips quoted heredoc bodies" {
    const content =
        \\package() (
        \\  install -d "$pkgdir/usr/share/demo"
        \\  cat <<'EOF' > "$pkgdir/usr/share/demo/template"
        \\this unmatched text is data: ))))
        \\EOF
        \\  install -Dm644 metadata "$pkgdir/usr/share/demo/metadata"
        \\)
        \\after=top-level
    ;
    const result = (try extract_function_body(content, "package")).?;
    try std.testing.expect(std.mem.indexOf(u8, result, "this unmatched text is data") != null);
    try std.testing.expect(std.mem.endsWith(u8, result, "\"$pkgdir/usr/share/demo/metadata\""));
    try std.testing.expect(std.mem.indexOf(u8, result, "after=top-level") == null);
}

test "parser_content: unclosed subshell consumes to end of content" {
    const content = "build() (\n  return 1;";
    const result = try extract_function_body(content, "build");
    try std.testing.expectEqualStrings("return 1;", result.?);
}

test "parser_content: here-string does not open a heredoc in brace bodies" {
    // Issue 1848: the second `<` of `<<<` re-triggered heredoc detection,
    // swallowing the rest of the file into a phantom heredoc body.
    const content =
        \\build() {
        \\  mapfile -t deps <<< "$(sed -n '/dependencies:/,/^$/ {/dependencies:/d; p }' list.txt)"
        \\  echo done
        \\}
        \\package() { echo package; }
    ;
    const result = (try extract_function_body(content, "build")).?;
    try std.testing.expectEqualStrings(
        \\mapfile -t deps <<< "$(sed -n '/dependencies:/,/^$/ {/dependencies:/d; p }' list.txt)"
        \\  echo done
    , result);
}

test "parser_content: here-string does not open a heredoc in subshell bodies" {
    const content =
        \\build() (
        \\  mapfile -t deps <<< "$dependency_list"
        \\  echo done
        \\)
        \\package() { echo package; }
    ;
    const result = (try extract_function_body(content, "build")).?;
    try std.testing.expectEqualStrings(
        \\mapfile -t deps <<< "$dependency_list"
        \\  echo done
    , result);
}

test "parser_content: non-compound function delimiters remain unsupported" {
    try std.testing.expect((try extract_function_body("build() [ echo invalid ]", "build")) == null);
}

test "selected_scoped_package_body: resolves CachyOS generated split helper" {
    const content =
        \\pkgbase=linux-cachyos
        \\pkgname=("$pkgbase" "$pkgbase-headers")
        \\_package() { pkgdesc='kernel'; }
        \\_package-headers() { pkgdesc='headers'; }
        \\for _p in "${pkgname[@]}"; do
        \\  eval "package_$_p() {
        \\    $(declare -f "_package${_p#$pkgbase}")
        \\    _package${_p#$pkgbase}
        \\  }"
        \\done
    ;
    var vars = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("pkgbase", "linux-cachyos");
    const parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .selected_package_name = "linux-cachyos-headers",
    };
    const body = try selected_scoped_package_body(parser, content, &vars);
    try std.testing.expectEqualStrings("pkgdesc='headers';", body.?);
}

test "selected_scoped_package_body: ignores commented generated dispatch" {
    const content =
        \\_package-headers() { pkgdesc='headers'; }
        \\# eval "package_$_p() {
        \\#   $(declare -f "_package${_p#$pkgbase}")
        \\#   _package${_p#$pkgbase}
    ;
    var vars = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("pkgbase", "linux-cachyos");
    const parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .selected_package_name = "linux-cachyos-headers",
    };
    try std.testing.expect((try selected_scoped_package_body(parser, content, &vars)) == null);
}
