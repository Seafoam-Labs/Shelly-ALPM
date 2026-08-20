//! Bash parameter expansion engine: variables, trimming, replacement,
//! substring, arithmetic, and command-substitution handling.
const std = @import("std");
const shell_scan = @import("shell_scan.zig");
const arithmetic = @import("arithmetic.zig");
const PkgbuildParser = @import("parser.zig").PkgbuildParser;

pub fn resolve_string(self: PkgbuildParser, input: []const u8, vars: *std.StringHashMap([]const u8)) ![]const u8 {
    return resolve_expansions(self, input, vars, .metadata);
}

const expansion_mode = enum { metadata, execution };

fn resolve_expansions(
    self: PkgbuildParser,
    input: []const u8,
    vars: *std.StringHashMap([]const u8),
    mode: expansion_mode,
) ![]const u8 {
    const step1 = try replace_arithmetic(self, input, vars);
    defer self.allocator.free(step1);

    const step2 = switch (mode) {
        .metadata => try replace_command(self, step1),
        .execution => try replace_command_keep(self, step1),
    };
    defer self.allocator.free(step2);

    const step3 = try replace_trim_expansion(self, step2, vars);
    defer self.allocator.free(step3);

    const step4 = try replace_replacement_expansion(self, step3, vars);
    defer self.allocator.free(step4);

    const step5 = try replace_substring_expansion(self, step4, vars);
    defer self.allocator.free(step5);

    return replace_plain_var(self, step5, vars);
}

/// Resolves statically knowable variables in an execution step body.
///
/// Unlike resolve_string this never destroys information the shell
/// still needs: command substitutions are preserved (the shell runs
/// them at execution time) and unknown references stay literal for
/// runtime expansion. Bash quoting rules are honored — single-quoted
/// and backslash-escaped regions pass through untouched, and heredoc
/// bodies follow bash semantics: quoted-delimiter bodies (<<'EOF')
/// stay verbatim while unquoted ones (<<EOF) expand.
pub fn resolve_step_string(self: PkgbuildParser, input: []const u8, vars: *std.StringHashMap([]const u8)) ![]const u8 {
    const segments = try shell_scan.split_shell_segments(self, input);
    defer self.allocator.free(segments);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(self.allocator);

    for (segments) |segment| {
        if (segment.expandable) {
            const expanded = try resolve_step_segment(self, input[segment.start..segment.end], vars);
            defer self.allocator.free(expanded);
            try out.appendSlice(self.allocator, expanded);
        } else {
            try out.appendSlice(self.allocator, input[segment.start..segment.end]);
        }
    }

    return out.toOwnedSlice(self.allocator);
}

/// The resolve_string pipeline adapted for step bodies: command
/// substitutions are kept instead of stripped.
fn resolve_step_segment(self: PkgbuildParser, input: []const u8, vars: *std.StringHashMap([]const u8)) ![]const u8 {
    return resolve_expansions(self, input, vars, .execution);
}

fn replace_replacement_expansion(self: PkgbuildParser, input: []const u8, vars: *const std.StringHashMap([]const u8)) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(self.allocator);

    var pos: usize = 0;
    while (pos < input.len) {
        const open = std.mem.indexOfPos(u8, input, pos, "${") orelse {
            try result.appendSlice(self.allocator, input[pos..]);
            break;
        };
        try result.appendSlice(self.allocator, input[pos..open]);

        var cursor = open + 2;
        const start = cursor;
        cursor = shell_scan.scan_word_chars(input, cursor);
        const var_name = input[start..cursor];

        if (var_name.len == 0 or cursor >= input.len or input[cursor] != '/') {
            try result.append(self.allocator, input[open]);
            pos = open + 1;
            continue;
        }
        cursor += 1;

        var mode: []const u8 = "";
        if (cursor < input.len and (input[cursor] == '/' or input[cursor] == '#' or input[cursor] == '%')) {
            mode = input[cursor .. cursor + 1];
            cursor += 1;
        }

        const pattern_start = cursor;
        while (cursor < input.len and input[cursor] != '/' and input[cursor] != '}') : (cursor += 1) {}
        const find_glob = input[pattern_start..cursor];

        var repl: []const u8 = "";
        if (cursor < input.len and input[cursor] == '/') {
            cursor += 1;
            const repl_start = cursor;
            while (cursor < input.len and input[cursor] != '}') : (cursor += 1) {}
            repl = input[repl_start..cursor];
        }

        if (cursor >= input.len) {
            try result.append(self.allocator, '$');
            pos = input.len;
            continue;
        }
        if (input[cursor] != '}') {
            try result.append(self.allocator, input[open]);
            pos = open + 1;
            continue;
        }
        const match_end = cursor + 1;

        if (vars.get(var_name)) |val| {
            const applied = try apply_replacement(self, val, mode, find_glob, repl);
            defer self.allocator.free(applied);
            try result.appendSlice(self.allocator, applied);
        } else {
            try result.appendSlice(self.allocator, input[open..match_end]);
        }
        pos = match_end;
    }

    return result.toOwnedSlice(self.allocator);
}

fn replace_substring_expansion(self: PkgbuildParser, input: []const u8, vars: *const std.StringHashMap([]const u8)) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(self.allocator);
    var pos: usize = 0;
    while (pos < input.len) {
        const open = std.mem.indexOfPos(u8, input, pos, "${") orelse {
            try result.appendSlice(self.allocator, input[pos..]);
            break;
        };
        try result.appendSlice(self.allocator, input[pos..open]);
        var cursor = open + 2;
        const name_start = cursor;
        cursor = shell_scan.scan_word_chars(input, cursor);
        const var_name = input[name_start..cursor];
        if (var_name.len == 0 or cursor >= input.len or input[cursor] != ':') {
            try result.append(self.allocator, input[open]);
            pos = open + 1;
            continue;
        }
        cursor += 1;
        // Bash permits the offset to be omitted when a length is present:
        // `${parameter::length}` is equivalent to
        // `${parameter:0:length}`.
        var offset: i32 = 0;
        var matched_offset = cursor < input.len and input[cursor] == ':';
        {
            const ws_end = shell_scan.scan_whitespace(input, cursor);
            const digit_end = shell_scan.scan_digits(input, ws_end);
            if (digit_end > ws_end) {
                offset = std.fmt.parseInt(i32, input[ws_end..digit_end], 10) catch {
                    try result.append(self.allocator, input[open]);
                    pos = open + 1;
                    continue;
                };
                cursor = digit_end;
                matched_offset = true;
            }
        }
        if (!matched_offset) {
            const ws_start = cursor;
            const ws_end = shell_scan.scan_whitespace(input, ws_start);
            if (ws_end > ws_start and ws_end < input.len and input[ws_end] == '-') {
                const digit_end = shell_scan.scan_digits(input, ws_end + 1);
                if (digit_end > ws_end + 1) {
                    offset = std.fmt.parseInt(i32, input[ws_end..digit_end], 10) catch {
                        try result.append(self.allocator, input[open]);
                        pos = open + 1;
                        continue;
                    };
                    cursor = digit_end;
                    matched_offset = true;
                }
            }
        }
        if (!matched_offset) {
            try result.append(self.allocator, input[open]);
            pos = open + 1;
            continue;
        }
        var length: ?i32 = null;
        if (cursor < input.len and input[cursor] == ':') {
            const c2 = shell_scan.scan_whitespace(input, cursor + 1);
            const neg = c2 < input.len and input[c2] == '-';
            const digit_start = if (neg) c2 + 1 else c2;
            const digit_end = shell_scan.scan_digits(input, digit_start);
            if (digit_end > digit_start) {
                length = std.fmt.parseInt(i32, input[c2..digit_end], 10) catch {
                    try result.append(self.allocator, input[open]);
                    pos = open + 1;
                    continue;
                };
                cursor = digit_end;
            }
        }
        if (cursor >= input.len) {
            try result.append(self.allocator, '$');
            pos = input.len;
            continue;
        }
        if (input[cursor] != '}') {
            try result.append(self.allocator, input[open]);
            pos = open + 1;
            continue;
        }
        const match_end = cursor + 1;
        if (vars.get(var_name)) |val| {
            const applied = try apply_substring(val, offset, length);
            try result.appendSlice(self.allocator, applied);
        } else {
            try result.appendSlice(self.allocator, input[open..match_end]);
        }
        pos = match_end;
    }
    return result.toOwnedSlice(self.allocator);
}

fn replace_command(self: PkgbuildParser, input: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(self.allocator);

    var pos: usize = 0;
    while (pos < input.len) {
        const open = std.mem.indexOfPos(u8, input, pos, "$(") orelse {
            try result.appendSlice(self.allocator, input[pos..]);
            break;
        };
        try result.appendSlice(self.allocator, input[pos..open]);

        const start = open + 2;
        const close = std.mem.indexOfPos(u8, input, start, ")") orelse {
            try result.appendSlice(self.allocator, input[open..]);
            pos = input.len;
            break;
        };

        if (close == start) {
            try result.appendSlice(self.allocator, input[open .. close + 1]);
            pos = close + 1;
            continue;
        }

        const whole_match = input[open .. close + 1];
        std.debug.print("[Shelly] Warning: Cannot evaluate command substitution: {s}\n", .{whole_match});
        pos = close + 1;
    }

    return result.toOwnedSlice(self.allocator);
}

/// Preserves $(...) command substitutions instead of stripping them so
/// the shell can evaluate them at execution time. Nested parentheses
/// are balanced so substitutions like $(foo $(bar)) are kept whole.
fn replace_command_keep(self: PkgbuildParser, input: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(self.allocator);

    var pos: usize = 0;
    while (pos < input.len) {
        const open = std.mem.indexOfPos(u8, input, pos, "$(") orelse {
            try result.appendSlice(self.allocator, input[pos..]);
            break;
        };
        try result.appendSlice(self.allocator, input[pos..open]);

        const start = open + 2;
        if (start < input.len and input[start] == '(') {
            // $(( ... )) is arithmetic expansion, handled by an earlier
            // pipeline stage; pass it through untouched.
            try result.appendSlice(self.allocator, input[open..start]);
            pos = start;
            continue;
        }

        const close = shell_scan.find_command_substitution_close(input, start) orelse {
            try result.appendSlice(self.allocator, input[open..]);
            pos = input.len;
            break;
        };

        try result.appendSlice(self.allocator, input[open .. close + 1]);
        pos = close + 1;
    }

    return result.toOwnedSlice(self.allocator);
}

fn replace_arithmetic(self: PkgbuildParser, input: []const u8, vars: *std.StringHashMap([]const u8)) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;

    defer result.deinit(self.allocator);

    var pos: usize = 0;
    while (pos < input.len) {
        const open = std.mem.indexOfPos(u8, input, pos, "$((") orelse {
            try result.appendSlice(self.allocator, input[pos..]);
            break;
        };
        try result.appendSlice(self.allocator, input[pos..open]);

        const start = open + 3;
        const close = std.mem.indexOfScalarPos(u8, input, start, ')') orelse {
            try result.appendSlice(self.allocator, input[open..]);
            pos = input.len;
            break;
        };

        if (close == start or close + 1 >= input.len or input[close + 1] != ')') {
            try result.appendSlice(self.allocator, input[open .. close + 1]);
            pos = open + 1;
            continue;
        }

        const expr = input[start..close];
        const evaluated = try arithmetic.evaluate_arithmetic(self, expr, vars);
        defer self.allocator.free(evaluated);
        try result.appendSlice(self.allocator, evaluated);
        pos = close + 2;
    }

    return result.toOwnedSlice(self.allocator);
}

fn replace_trim_expansion(self: PkgbuildParser, input: []const u8, vars: *std.StringHashMap([]const u8)) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(self.allocator);

    var pos: usize = 0;
    while (pos < input.len) {
        const open = std.mem.indexOfPos(u8, input, pos, "${") orelse {
            try result.appendSlice(self.allocator, input[pos..]);
            break;
        };
        try result.appendSlice(self.allocator, input[pos..open]);
        var cursor = open + 2;
        const start = cursor;
        cursor = c: {
            var c_pos = start;
            while (c_pos < input.len and shell_scan.is_word(input[c_pos])) : (c_pos += 1) {}
            break :c c_pos;
        };
        const var_name = input[start..cursor];
        const operation: []const u8 = op: {
            if (cursor + 1 < input.len and input[cursor] == '#' and input[cursor + 1] == '#') {
                cursor += 2;
                break :op "##";
            } else if (cursor < input.len and input[cursor] == '#') {
                cursor += 1;
                break :op "#";
            } else if (cursor + 1 < input.len and input[cursor] == '%' and input[cursor + 1] == '%') {
                cursor += 2;
                break :op "%%";
            } else if (cursor < input.len and input[cursor] == '%') {
                cursor += 1;
                break :op "%";
            } else {
                break :op "";
            }
        };

        if (operation.len == 0) {
            try result.append(self.allocator, input[open]);
            pos = open + 1;
            continue;
        }

        const arg_start = cursor;
        while (cursor < input.len and input[cursor] != '}') : (cursor += 1) {}
        if (cursor >= input.len) {
            try result.append(self.allocator, '$');
            pos = input.len;
            continue;
        }
        const arg = input[arg_start..cursor];
        const match_end = cursor + 1;

        if (vars.get(var_name)) |val| {
            const applied = apply_parameter_expansion(val, operation, arg);
            try result.appendSlice(self.allocator, applied);
        } else {
            try result.appendSlice(self.allocator, input[open..match_end]);
        }

        pos = match_end;
    }

    return result.toOwnedSlice(self.allocator);
}

fn find_glob_match(pattern: []const u8, value: []const u8, search_from: usize, anchor_start: bool, anchor_end: bool) ?struct { start: usize, end: usize } {
    if (anchor_start) {
        if (search_from != 0) return null;
        var end: usize = value.len;
        while (true) {
            if (glob_matches(pattern, value[0..end])) return .{ .start = 0, .end = end };
            if (end == 0) return null;
            end -= 1;
        }
    }
    if (anchor_end) {
        var start: usize = search_from;
        while (start <= value.len) : (start += 1) {
            if (glob_matches(pattern, value[start..])) return .{ .start = start, .end = value.len };
        }
        return null;
    }
    var start: usize = search_from;
    while (start <= value.len) : (start += 1) {
        var end: usize = value.len;
        while (true) {
            if (glob_matches(pattern, value[start..end])) return .{ .start = start, .end = end };
            if (end == start) break;
            end -= 1;
        }
    }
    return null;
}

fn apply_replacement(self: PkgbuildParser, value: []const u8, mode: []const u8, find_glob: []const u8, repl: []const u8) ![]const u8 {
    if (find_glob.len == 0) return self.allocator.dupe(u8, value);
    const start = std.mem.eql(u8, mode, "#");
    const end = std.mem.eql(u8, mode, "%");
    const global = std.mem.eql(u8, mode, "/");
    const max_reps: usize = if (global) std.math.maxInt(usize) else 1;
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(self.allocator);
    var cursor: usize = 0;
    var replaced: usize = 0;
    while (replaced < max_reps) {
        const m = find_glob_match(find_glob, value, cursor, start, end) orelse break;
        try result.appendSlice(self.allocator, value[cursor..m.start]);
        try result.appendSlice(self.allocator, repl);
        replaced += 1;
        if (m.end == m.start) {
            if (m.end < value.len) try result.appendSlice(self.allocator, value[m.end .. m.end + 1]);
            cursor = m.end + 1;
        } else {
            cursor = m.end;
        }
    }
    if (cursor <= value.len) try result.appendSlice(self.allocator, value[cursor..]);
    if (replaced == 0) {
        return self.allocator.dupe(u8, value);
    }
    return result.toOwnedSlice(self.allocator);
}

fn replace_plain_var(self: PkgbuildParser, input: []const u8, vars: *std.StringHashMap([]const u8)) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(self.allocator);
    var pos: usize = 0;
    while (pos < input.len) {
        const dollar = std.mem.indexOfScalarPos(u8, input, pos, '$') orelse {
            try result.appendSlice(self.allocator, input[pos..]);
            break;
        };
        try result.appendSlice(self.allocator, input[pos..dollar]);

        if (dollar + 1 < input.len and input[dollar + 1] == '{') {
            const name_start = dollar + 2;
            const name_end = shell_scan.scan_word_chars(input, name_start);
            if (name_end > name_start and name_end < input.len and input[name_end] == '}') {
                const var_name = input[name_start..name_end];
                const match_end = name_end + 1;
                if (vars.get(var_name)) |val| {
                    try result.appendSlice(self.allocator, val);
                } else {
                    try result.appendSlice(self.allocator, input[dollar..match_end]);
                }
                pos = match_end;
                continue;
            }
        } else if (dollar + 1 < input.len and shell_scan.is_word(input[dollar + 1])) {
            const name_start = dollar + 1;
            const name_end = shell_scan.scan_word_chars(input, name_start);
            const var_name = input[name_start..name_end];
            if (vars.get(var_name)) |val| {
                try result.appendSlice(self.allocator, val);
            } else {
                try result.appendSlice(self.allocator, input[dollar..name_end]);
            }
            pos = name_end;
            continue;
        }

        try result.append(self.allocator, '$');
        pos = dollar + 1;
    }
    return result.toOwnedSlice(self.allocator);
}

fn glob_matches(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return text.len == 0;

    switch (pattern[0]) {
        '*' => {
            var i: usize = 0;
            while (i <= text.len) : (i += 1) {
                if (glob_matches(pattern[1..], text[i..])) return true;
            }
            return false;
        },
        '?' => {
            if (text.len == 0) return false;
            return glob_matches(pattern[1..], text[1..]);
        },
        else => {
            if (text.len == 0 or text[0] != pattern[0]) return false;
            return glob_matches(pattern[1..], text[1..]);
        },
    }
}

fn apply_parameter_expansion(value: []const u8, op: []const u8, glob: []const u8) []const u8 {
    if (glob.len == 0) return value;

    if (std.mem.eql(u8, op, "#")) {
        var j: usize = 0;
        while (j <= value.len) : (j += 1) {
            if (glob_matches(glob, value[0..j])) return value[j..];
        }
        return value;
    } else if (std.mem.eql(u8, op, "##")) {
        var j: usize = value.len;
        while (true) {
            if (glob_matches(glob, value[0..j])) return value[j..];
            if (j == 0) break;
            j -= 1;
        }
        return value;
    } else if (std.mem.eql(u8, op, "%")) {
        var i: usize = value.len;
        while (true) {
            if (glob_matches(glob, value[i..])) return value[0..i];
            if (i == 0) break;
            i -= 1;
        }
        return value;
    } else if (std.mem.eql(u8, op, "%%")) {
        var i: usize = 0;
        while (i <= value.len) : (i += 1) {
            if (glob_matches(glob, value[i..])) return value[0..i];
        }
        return value;
    } else {
        return value;
    }
}

fn apply_substring(value: []const u8, offset: i32, length: ?i32) ![]const u8 {
    const len: i32 = @intCast(value.len);

    var start = if (offset < 0) len + offset else offset;
    start = std.math.clamp(start, 0, len);

    var end: i32 = undefined;
    if (length) |l| {
        end = if (l < 0) len + l else start + l;
    } else {
        end = len;
    }
    end = std.math.clamp(end, start, len);

    const start_u: usize = @intCast(start);
    const end_u: usize = @intCast(end);

    return value[start_u..end_u];
}

test "apply_substring: positive offset, no length" {
    const result = try apply_substring("hello world", 6, null);
    try std.testing.expectEqualStrings("world", result);
}

test "apply_substring: positive offset and length" {
    const result = try apply_substring("hello world", 0, 5);
    try std.testing.expectEqualStrings("hello", result);
}

test "apply_substring: negative offset counts from end" {
    const result = try apply_substring("hello world", -5, null);
    try std.testing.expectEqualStrings("world", result);
}

test "apply_substring: negative length trims from end" {
    const result = try apply_substring("hello world", 0, -6);
    try std.testing.expectEqualStrings("hello", result);
}

test "apply_substring: offset beyond length clamps to empty" {
    const result = try apply_substring("hello", 100, null);
    try std.testing.expectEqualStrings("", result);
}

test "apply_substring: negative offset beyond start clamps to zero" {
    const result = try apply_substring("hello", -100, null);
    try std.testing.expectEqualStrings("hello", result);
}

test "apply_substring: length longer than remaining string clamps" {
    const result = try apply_substring("hello", 2, 100);
    try std.testing.expectEqualStrings("llo", result);
}

test "apply_substring: zero length returns empty string" {
    const result = try apply_substring("hello", 2, 0);
    try std.testing.expectEqualStrings("", result);
}

test "apply_substring: negative length larger than start clamps to empty" {
    const result = try apply_substring("hello", 3, -100);
    try std.testing.expectEqualStrings("", result);
}

test "apply_substring: empty input string" {
    const result = try apply_substring("", 0, null);
    try std.testing.expectEqualStrings("", result);
}

test "replace_arithmetic: simple expression" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try replace_arithmetic(parser, "$((1+2))", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("3", result);
}

test "replace_arithmetic: multiple expressions" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try replace_arithmetic(parser, "$((1+2)) and $((3*4))", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("3 and 12", result);
}

test "replace_arithmetic: no expressions" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try replace_arithmetic(parser, "hello world", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "replace_arithmetic: empty expression" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try replace_arithmetic(parser, "$(()))", &vars);
    defer parser.allocator.free(result);
    // Empty $(( )) is skipped: emits '$' then appends remainder
    try std.testing.expectEqualStrings("$(()(()))", result);
}

test "replace_arithmetic: unclosed expression" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try replace_arithmetic(parser, "$((1+2", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("$((1+2", result);
}

test "replace_arithmetic: mixed text and expressions" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try replace_arithmetic(parser, "count=$((10*2)) items", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("count=20 items", result);
}

test "replace_command: no substitution" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try replace_command(parser, "hello world");
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "replace_command: single substitution stripped" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try replace_command(parser, "prefix $(echo hello) suffix");
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("prefix  suffix", result);
}

test "replace_command: empty substitution preserved" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try replace_command(parser, "test $() end");
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("test $() end", result);
}

test "replace_command: unclosed substitution preserved" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try replace_command(parser, "test $(unclosed");
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("test $(unclosed", result);
}

test "replace_command: multiple substitutions" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try replace_command(parser, "$(cmd1) and $(cmd2)");
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings(" and ", result);
}

test "replace_command: substitution at start and end" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try replace_command(parser, "$(cmd) middle $(cmd2)");
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings(" middle ", result);
}

test "glob_matches: empty pattern and empty text" {
    try std.testing.expect(glob_matches("", ""));
}

test "glob_matches: empty pattern non-empty text" {
    try std.testing.expectEqual(false, glob_matches("", "abc"));
}

test "glob_matches: non-empty pattern empty text" {
    try std.testing.expectEqual(false, glob_matches("abc", ""));
}

test "glob_matches: exact match" {
    try std.testing.expect(glob_matches("hello", "hello"));
    try std.testing.expectEqual(false, glob_matches("hello", "world"));
}

test "glob_matches: star matches all" {
    try std.testing.expect(glob_matches("*", ""));
    try std.testing.expect(glob_matches("*", "anything"));
}

test "glob_matches: star at start" {
    try std.testing.expect(glob_matches("*.txt", "file.txt"));
    try std.testing.expect(glob_matches("*.txt", ".txt"));
    try std.testing.expectEqual(false, glob_matches("*.txt", "file.zip"));
}

test "glob_matches: question mark" {
    try std.testing.expect(glob_matches("?.txt", "a.txt"));
    try std.testing.expectEqual(false, glob_matches("?.txt", "ab.txt"));
    try std.testing.expectEqual(false, glob_matches("?.txt", ".txt"));
}

test "glob_matches: mixed star and question mark" {
    try std.testing.expect(glob_matches("src/?*.zig", "src/main.zig"));
    try std.testing.expectEqual(false, glob_matches("src/?*.zig", "src/.zig"));
}

test "glob_matches: consecutive stars" {
    try std.testing.expect(glob_matches("**", ""));
    try std.testing.expect(glob_matches("**", "a/b/c"));
    try std.testing.expect(glob_matches("a**b", "ab"));
    try std.testing.expect(glob_matches("a**b", "axyzb"));
}

test "apply_parameter_expansion: empty glob returns value" {
    try std.testing.expectEqualStrings("hello", apply_parameter_expansion("hello", "#", ""));
}

test "apply_parameter_expansion: unknown op returns value" {
    try std.testing.expectEqualStrings("hello", apply_parameter_expansion("hello", "!", "h"));
}

test "apply_parameter_expansion: # removes shortest prefix" {
    // "hello.tar.gz" - shortest prefix matching "h" is "h"
    try std.testing.expectEqualStrings("ello.tar.gz", apply_parameter_expansion("hello.tar.gz", "#", "h"));
    // shortest prefix matching "*." is ".gz" → no, it's "hello."
    try std.testing.expectEqualStrings("tar.gz", apply_parameter_expansion("hello.tar.gz", "#", "*."));
}

test "apply_parameter_expansion: ## removes longest prefix" {
    // longest prefix matching "*." is "hello.tar."
    try std.testing.expectEqualStrings("gz", apply_parameter_expansion("hello.tar.gz", "##", "*."));
    // longest prefix matching "h" is "h"
    try std.testing.expectEqualStrings("ello.tar.gz", apply_parameter_expansion("hello.tar.gz", "##", "h"));
}

test "apply_parameter_expansion: % removes shortest suffix" {
    try std.testing.expectEqualStrings("hello.tar", apply_parameter_expansion("hello.tar.gz", "%", ".gz"));
    try std.testing.expectEqualStrings("hello.tar", apply_parameter_expansion("hello.tar.gz", "%", "*.gz"));
}

test "apply_parameter_expansion: %% removes longest suffix" {
    try std.testing.expectEqualStrings("hello", apply_parameter_expansion("hello.tar.gz", "%%", ".tar.gz"));
    try std.testing.expectEqualStrings("hello.tar.g", apply_parameter_expansion("hello.tar.gz", "%%", "z"));
}

test "apply_parameter_expansion: # no match returns value" {
    try std.testing.expectEqualStrings("hello", apply_parameter_expansion("hello", "#", "xyz"));
}

test "apply_parameter_expansion: % no match returns value" {
    try std.testing.expectEqualStrings("hello", apply_parameter_expansion("hello", "%", "xyz"));
}

test "apply_parameter_expansion: # with question mark" {
    try std.testing.expectEqualStrings("lo", apply_parameter_expansion("hello", "#", "he?"));
}

test "replace_trim_expansion: hash removes shortest matching prefix" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("file", "hello.tar.gz");
    const result = try replace_trim_expansion(parser, "${file#h}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("ello.tar.gz", result);
}

test "replace_trim_expansion: double hash removes longest matching prefix" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("file", "hello.tar.gz");
    const result = try replace_trim_expansion(parser, "${file##*.}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("gz", result);
}

test "replace_trim_expansion: percent removes shortest matching suffix" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("file", "hello.tar.gz");
    const result = try replace_trim_expansion(parser, "${file%.gz}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("hello.tar", result);
}

test "replace_trim_expansion: double percent removes longest matching suffix" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("file", "hello.tar.gz");
    const result = try replace_trim_expansion(parser, "${file%%.*}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "replace_trim_expansion: multiple expansions" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("file", "hello.tar.gz");
    const result = try replace_trim_expansion(parser, "${file#h} and ${file%.gz}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("ello.tar.gz and hello.tar", result);
}

test "replace_trim_expansion: no operation leaves input untouched" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("file", "hello.tar.gz");
    const result = try replace_trim_expansion(parser, "${file}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("${file}", result);
}

test "replace_trim_expansion: variable not found keeps original text" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    const result = try replace_trim_expansion(parser, "${unknown#p}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("${unknown#p}", result);
}

test "replace_trim_expansion: pattern with no match returns value unchanged" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("file", "hello.tar.gz");
    const result = try replace_trim_expansion(parser, "${file#xyz}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("hello.tar.gz", result);
}

test "replace_trim_expansion: glob wildcards in pattern" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("path", "/usr/local/bin");
    const result = try replace_trim_expansion(parser, "${path##*/}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("bin", result);
}

test "replace_trim_expansion: empty pattern matches empty string" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("file", "hello");
    const result = try replace_trim_expansion(parser, "${file#}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "replace_trim_expansion: unclosed expansion emits dollar sign" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("file", "hello.tar.gz");
    const result = try replace_trim_expansion(parser, "${file#h", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("$", result);
}

test "replace_trim_expansion: text with no expansions is unchanged" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    const result = try replace_trim_expansion(parser, "plain text, nothing here", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("plain text, nothing here", result);
}

test "replace_trim_expansion: literal text surrounding an expansion is preserved" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("ext", "tar.gz");
    const result = try replace_trim_expansion(parser, "archive.${ext%.gz} ready", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("archive.tar ready", result);
}

test "find_glob_match: unanchored literal match in the middle" {
    const m = find_glob_match("cd", "abcdef", 0, false, false);
    try std.testing.expect(m != null);
    try std.testing.expectEqual(@as(usize, 2), m.?.start);
    try std.testing.expectEqual(@as(usize, 4), m.?.end);
}

test "find_glob_match: unanchored no match returns null" {
    const m = find_glob_match("xyz", "abcdef", 0, false, false);
    try std.testing.expect(m == null);
}

test "find_glob_match: unanchored leftmost match wins" {
    const m = find_glob_match("a*b", "xaybzab", 0, false, false);
    try std.testing.expect(m != null);
    try std.testing.expectEqual(@as(usize, 1), m.?.start);
}

test "find_glob_match: unanchored greedy star takes longest span at leftmost start" {
    const m = find_glob_match("a*b", "aXbYb", 0, false, false);
    try std.testing.expect(m != null);
    try std.testing.expectEqual(@as(usize, 0), m.?.start);
    try std.testing.expectEqual(@as(usize, 5), m.?.end);
}

test "find_glob_match: anchor_start only matches at position 0" {
    const m1 = find_glob_match("ab", "abcabc", 0, true, false);
    try std.testing.expect(m1 != null);
    try std.testing.expectEqual(@as(usize, 0), m1.?.start);
    try std.testing.expectEqual(@as(usize, 2), m1.?.end);

    const m2 = find_glob_match("bc", "abcabc", 0, true, false);
    try std.testing.expect(m2 == null);
}

test "find_glob_match: anchor_start refuses non-zero search_from" {
    const m = find_glob_match("ab", "ababab", 2, true, false);
    try std.testing.expect(m == null);
}

test "find_glob_match: anchor_end only matches at end of string" {
    const m1 = find_glob_match("bc", "abcabc", 0, false, true);
    try std.testing.expect(m1 != null);
    try std.testing.expectEqual(@as(usize, 4), m1.?.start);
    try std.testing.expectEqual(@as(usize, 6), m1.?.end);

    const m2 = find_glob_match("ab", "abcabc", 0, false, true);
    try std.testing.expect(m2 == null);
}

test "find_glob_match: glob wildcards work in search" {
    const m = find_glob_match("f?o", "xxfooxx", 0, false, false);
    try std.testing.expect(m != null);
    try std.testing.expectEqual(@as(usize, 2), m.?.start);
    try std.testing.expectEqual(@as(usize, 5), m.?.end);
}

test "find_glob_match: search_from skips earlier occurrences" {
    const m = find_glob_match("ab", "ababab", 2, false, false);
    try std.testing.expect(m != null);
    try std.testing.expectEqual(@as(usize, 2), m.?.start);
}

test "find_glob_match: zero-width pattern matches empty span" {
    const m = find_glob_match("", "abc", 0, false, false);
    try std.testing.expect(m != null);
    try std.testing.expectEqual(@as(usize, 0), m.?.start);
    try std.testing.expectEqual(@as(usize, 0), m.?.end);
}

test "apply_replacement: empty glob returns value unchanged" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try apply_replacement(parser, "hello", "", "", "X");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "apply_replacement: no match returns value unchanged" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try apply_replacement(parser, "hello", "", "xyz", "X");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "apply_replacement: unanchored mode replaces first match only" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try apply_replacement(parser, "foo bar foo", "", "foo", "X");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("X bar foo", result);
}

test "apply_replacement: slash mode replaces all matches" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try apply_replacement(parser, "foo bar foo", "/", "foo", "X");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("X bar X", result);
}

test "apply_replacement: hash mode replaces only if match is at the start" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try apply_replacement(parser, "foobar", "#", "foo", "X");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Xbar", result);
}

test "apply_replacement: hash mode does nothing if match is not at the start" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try apply_replacement(parser, "barfoo", "#", "foo", "X");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("barfoo", result);
}

test "apply_replacement: percent mode replaces only if match is at the end" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try apply_replacement(parser, "barfoo", "%", "foo", "X");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("barX", result);
}

test "apply_replacement: percent mode does nothing if match is not at the end" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try apply_replacement(parser, "foobar", "%", "foo", "X");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("foobar", result);
}

test "apply_replacement: glob wildcards in find pattern" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try apply_replacement(parser, "aXbYc", "/", "?", "_");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("_____", result);
}

test "apply_replacement: empty replacement deletes matches" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try apply_replacement(parser, "hello world", "/", "o", "");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hell wrld", result);
}

test "apply_replacement: global replace with trailing star consumes greedily" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try apply_replacement(parser, "aXaXaX", "/", "a*", "_");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("_", result);
}

test "replace_plain_var: braced variable found" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("name", "world");
    const result = try replace_plain_var(parser, "hello ${name}!", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("hello world!", result);
}

test "replace_plain_var: bare variable found" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("name", "world");
    const result = try replace_plain_var(parser, "hello $name!", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("hello world!", result);
}

test "replace_plain_var: braced variable not found keeps original text" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    const result = try replace_plain_var(parser, "hello ${missing}!", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("hello ${missing}!", result);
}

test "replace_plain_var: bare variable not found keeps original text" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    const result = try replace_plain_var(parser, "hello $missing!", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("hello $missing!", result);
}

test "replace_plain_var: multiple variables in one string" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("first", "foo");
    try vars.put("second", "bar");
    const result = try replace_plain_var(parser, "${first}-$second", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("foo-bar", result);
}

test "replace_plain_var: unclosed brace is left untouched" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("name", "world");
    const result = try replace_plain_var(parser, "hello ${name and more", &vars);
    defer parser.allocator.free(result);
    // No closing '}' -> the regex wouldn't match at all, so nothing is substituted
    // and the text passes through as-is (this also exercises the infinite-loop bug fix).
    try std.testing.expectEqualStrings("hello ${name and more", result);
}

test "replace_plain_var: trailing lone dollar sign" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    const result = try replace_plain_var(parser, "price: $", &vars);
    defer parser.allocator.free(result);
    // '$' at the very end of the string, with nothing after it -- this also
    // exercises the infinite-loop bug fix (dollar+1 == input.len).
    try std.testing.expectEqualStrings("price: $", result);
}

test "replace_plain_var: dollar followed by non-word non-brace character" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    const result = try replace_plain_var(parser, "cost: $5.00", &vars);
    defer parser.allocator.free(result);
    // '$' followed by a digit, which is neither '{' nor a word-start char
    // per is_word's definition used elsewhere -- passes through untouched.
    try std.testing.expectEqualStrings("cost: $5.00", result);
}

test "replace_plain_var: no dollar sign at all" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    const result = try replace_plain_var(parser, "no variables here", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("no variables here", result);
}

test "replace_replacement_expansion: unanchored replaces first match only" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("greeting", "foo bar foo");
    const result = try replace_replacement_expansion(parser, "${greeting/foo/X}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("X bar foo", result);
}

test "replace_replacement_expansion: double slash replaces all matches" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("greeting", "foo bar foo");
    const result = try replace_replacement_expansion(parser, "${greeting//foo/X}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("X bar X", result);
}

test "replace_replacement_expansion: hash mode replaces only prefix match" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("file", "foobar");
    const result = try replace_replacement_expansion(parser, "${file/#foo/X}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("Xbar", result);
}

test "replace_replacement_expansion: percent mode replaces only suffix match" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("file", "barfoo");
    const result = try replace_replacement_expansion(parser, "${file/%foo/X}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("barX", result);
}

test "replace_replacement_expansion: missing replacement deletes the match" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("greeting", "hello world");
    const result = try replace_replacement_expansion(parser, "${greeting/o/}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("hell world", result);
}

test "replace_replacement_expansion: glob wildcards in find pattern" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("word", "cat");
    const result = try replace_replacement_expansion(parser, "${word/?at/dog}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("dog", result);
}

test "replace_replacement_expansion: variable not found keeps original text" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    const result = try replace_replacement_expansion(parser, "${missing/foo/X}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("${missing/foo/X}", result);
}

test "replace_replacement_expansion: no slash after var name is not a match" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("name", "world");
    // no '/' -> not this expansion type; passed through untouched
    const result = try replace_replacement_expansion(parser, "${name}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("${name}", result);
}

test "replace_replacement_expansion: unclosed expansion discards to end" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("greeting", "foo bar");
    const result = try replace_replacement_expansion(parser, "${greeting/foo/X", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("$", result);
}

test "replace_replacement_expansion: multiple expansions in one string" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("first", "aaa");
    try vars.put("second", "bbb");
    const result = try replace_replacement_expansion(parser, "${first/a/X} and ${second/b/Y}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("Xaa and Ybb", result);
}

test "replace_substring_expansion: offset only" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("word", "hello world");
    const result = try replace_substring_expansion(parser, "${word:6}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("world", result);
}

test "replace_substring_expansion: offset and length" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("word", "hello world");
    const result = try replace_substring_expansion(parser, "${word:0:5}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "replace_substring_expansion: omitted offset starts at zero" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("word", "hello world");

    const first = try replace_substring_expansion(parser, "${word::1}", &vars);
    defer parser.allocator.free(first);
    try std.testing.expectEqualStrings("h", first);

    const prefix = try replace_substring_expansion(parser, "${word::5}", &vars);
    defer parser.allocator.free(prefix);
    try std.testing.expectEqualStrings("hello", prefix);

    const empty = try replace_substring_expansion(parser, "${word::0}", &vars);
    defer parser.allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);

    const clamped = try replace_substring_expansion(parser, "${word::100}", &vars);
    defer parser.allocator.free(clamped);
    try std.testing.expectEqualStrings("hello world", clamped);
}

test "replace_substring_expansion: omitted offset supports negative length" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("word", "hello world");
    const result = try replace_substring_expansion(parser, "${word::-1}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("hello worl", result);
}

test "replace_substring_expansion: negative offset counts from the end" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("word", "hello world");
    const result = try replace_substring_expansion(parser, "${word: -5}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("world", result);
}

test "replace_substring_expansion: negative length counts back from the end" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("word", "hello world");
    const result = try replace_substring_expansion(parser, "${word:0:-6}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "replace_substring_expansion: offset beyond string length clamps to empty" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("word", "hi");
    const result = try replace_substring_expansion(parser, "${word:10}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "replace_substring_expansion: variable not found keeps original text" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    const result = try replace_substring_expansion(parser, "${missing:0:3}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("${missing:0:3}", result);
}

test "replace_substring_expansion: unknown variable with omitted offset is preserved" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    const result = try replace_substring_expansion(parser, "${missing::1}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("${missing::1}", result);
}

test "replace_substring_expansion: no colon after var name is not a match" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("name", "world");
    const result = try replace_substring_expansion(parser, "${name}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("${name}", result);
}

test "replace_substring_expansion: unclosed expansion discards to end" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("word", "hello world");
    const result = try replace_substring_expansion(parser, "${word:0:5", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("$", result);
}

test "replace_substring_expansion: multiple expansions in one string" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("a", "abcdef");
    try vars.put("b", "123456");
    const result = try replace_substring_expansion(parser, "${a:0:3} and ${b:3}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("abc and 456", result);
}

test "resolve_string: plain braced variable" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("name", "world");
    const result = try resolve_string(parser, "hello ${name}!", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("hello world!", result);
}

test "resolve_string: plain bare variable" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("name", "world");
    const result = try resolve_string(parser, "hello $name!", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("hello world!", result);
}

test "resolve_string: trim expansion" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("file", "hello.tar.gz");
    const result = try resolve_string(parser, "${file#h} and ${file%.gz}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("ello.tar.gz and hello.tar", result);
}

test "resolve_string: replacement expansion" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("greeting", "foo bar foo");
    const result = try resolve_string(parser, "${greeting//foo/X}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("X bar X", result);
}

test "resolve_string: substring expansion" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("word", "hello world");
    const result = try resolve_string(parser, "${word:6} and ${word:0:5}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("world and hello", result);
}

test "resolve_string: arithmetic expansion" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("count", "3");
    const result = try resolve_string(parser, "total: $((count * 2))", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("total: 6", result);
}

test "resolve_string: command substitution is unresolved and emptied" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    const result = try resolve_string(parser, "output: [$(echo hello)]", &vars);
    defer parser.allocator.free(result);
    // Command substitution can't be evaluated -> warns to stderr, replaced with "".
    try std.testing.expectEqualStrings("output: []", result);
}

test "resolve_string: variable not found in any step keeps original text" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    const result = try resolve_string(parser, "${missing} and ${missing#x} and ${missing/a/b} and ${missing:0:1}", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("${missing} and ${missing#x} and ${missing/a/b} and ${missing:0:1}", result);
}

test "resolve_string: combines multiple expansion types in one string" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("pkgname", "my-package");
    try vars.put("count", "2");
    const result = try resolve_string(
        parser,
        "${pkgname%-package}-$((count + 1)).tar.gz for $pkgname",
        &vars,
    );
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("my-3.tar.gz for my-package", result);
}

test "resolve_string: plain text with no expansions is unchanged" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    const result = try resolve_string(parser, "nothing special here", &vars);
    defer parser.allocator.free(result);
    try std.testing.expectEqualStrings("nothing special here", result);
}
