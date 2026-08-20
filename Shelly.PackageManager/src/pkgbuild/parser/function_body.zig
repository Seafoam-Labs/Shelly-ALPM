//! Extraction of function bodies from PKGBUILD shell source.
const std = @import("std");
const shell_scan = @import("shell_scan.zig");
const PkgbuildParser = @import("parser.zig").PkgbuildParser;

pub fn selected_package_body(self: PkgbuildParser, content: []const u8) !?[]const u8 {
    const package_name = self.selected_package_name orelse return null;
    const function_name = try std.fmt.allocPrint(
        self.allocator,
        "package_{s}",
        .{package_name},
    );
    defer self.allocator.free(function_name);

    return (try extract_function_body(content, function_name)) orelse
        try extract_function_body(content, "package");
}

pub fn extract_function_body(content: []const u8, function_name: []const u8) !?[]const u8 {
    const header_match = try match_at_line_start(content, 0, function_name);
    const start = header_match orelse return null;

    var depth: usize = 1;
    var i = start;
    var closed = false;
    while (i < content.len and depth > 0) {
        const c = content[i];
        if (c == '{') {
            depth += 1;
        } else if (c == '}') {
            depth -= 1;
            if (depth == 0) closed = true;
        }
        i += 1;
    }

    const end: usize = if (closed) i - 1 else i;
    const substring = content[start..end];
    const trimmed = std.mem.trim(u8, substring, " \t\n\r");
    return trimmed;
}

fn match_at_line_start(content: []const u8, start: usize, name: []const u8) !?usize {
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

fn matchLineStart(c: []const u8, p: usize, n: []const u8) ?usize {
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
    if (i >= c.len or c[i] != '{') return null;
    i += 1;
    return i;
}

test "match_at_line_start: bare function call syntax, no keyword" {
    const content = "myFunction() {\n  return;\n}";
    const result = try match_at_line_start(content, 0, "myFunction");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 14), result.?); // index just past the '{'
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
