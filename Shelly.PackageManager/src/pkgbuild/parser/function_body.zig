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
