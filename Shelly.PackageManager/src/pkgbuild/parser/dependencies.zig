//! Dependency string parsing and variable-reference resolution.
const std = @import("std");
const types = @import("types.zig");
const shell_scan = @import("shell_scan.zig");
const expansion = @import("expansion.zig");
const arrays = @import("arrays.zig");
const PkgbuildParser = @import("parser.zig").PkgbuildParser;

const parsed_dep = types.parsed_dep;

fn match_operator_len(input: []const u8, pos: usize) ?usize {
    if (pos >= input.len) return null;
    switch (input[pos]) {
        '>', '<' => {
            if (pos + 1 < input.len and input[pos + 1] == '=') return 2;
            return 1;
        },
        '=' => return 1,
        else => return null,
    }
}

pub fn match_array_ref(item: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, item, "${")) return null;
    if (!std.mem.endsWith(u8, item, "[@]}")) return null;
    const name_start = 2;
    const name_end = item.len - 4;
    if (name_end <= name_start) return null;
    const name = item[name_start..name_end];
    for (name) |c| {
        if (!shell_scan.is_word(c)) return null;
    }
    return name;
}

fn strip_version_constraint(dep: []const u8) []const u8 {
    var pos: usize = 0;
    while (pos < dep.len) : (pos += 1) {
        const op_len = match_operator_len(dep, pos) orelse continue;
        var cursor = pos + op_len;

        if (cursor >= dep.len or dep[cursor] != '$') continue;
        cursor += 1;

        if (cursor < dep.len and dep[cursor] == '{') cursor += 1;

        const name_start = cursor;
        while (cursor < dep.len and shell_scan.is_word(dep[cursor])) : (cursor += 1) {}
        if (cursor == name_start) continue;

        return dep[0..pos];
    }
    return dep;
}

// Mirrors: (>=|<=|>|<|=)$
fn strip_dangling_operator(dep: []const u8) []const u8 {
    if (dep.len >= 2) {
        const last2 = dep[dep.len - 2 ..];
        if (std.mem.eql(u8, last2, ">=") or std.mem.eql(u8, last2, "<=")) {
            return dep[0 .. dep.len - 2];
        }
    }
    if (dep.len >= 1) {
        const last = dep[dep.len - 1];
        if (last == '>' or last == '<' or last == '=') {
            return dep[0 .. dep.len - 1];
        }
    }
    return dep;
}

pub fn resolve_variable_references(self: PkgbuildParser, content: []const u8, vars: *std.StringHashMap([]const u8), items: [][]const u8) ![][]const u8 {
    var resolved: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (resolved.items) |it| self.allocator.free(it);
        resolved.deinit(self.allocator);
    }

    for (items) |item| {
        if (match_array_ref(item)) |referenced_var| {
            const referenced_items = try arrays.parse_array(self, content, referenced_var);
            defer {
                for (referenced_items) |it| self.allocator.free(it);
                self.allocator.free(referenced_items);
            }

            const nested = try resolve_variable_references(self, content, vars, referenced_items);
            defer self.allocator.free(nested);
            for (nested) |it| {
                try resolved.append(self.allocator, it);
            }
        } else {
            const resolved_item = try expansion.resolve_string(self, item, vars);
            try resolved.append(self.allocator, resolved_item);
        }
    }

    for (resolved.items, 0..) |dep, idx| {
        var cleaned = strip_version_constraint(dep);
        if (std.mem.eql(u8, cleaned, dep)) {
            cleaned = strip_dangling_operator(dep);
        }
        if (!std.mem.eql(u8, cleaned, dep)) {
            std.debug.print("[Shelly] Warning: Stripped unresolved version constraint: {s} -> {s}\n", .{ dep, cleaned });
            const cleaned_owned = try self.allocator.dupe(u8, cleaned);
            self.allocator.free(dep);
            resolved.items[idx] = cleaned_owned;
        }
    }

    return resolved.toOwnedSlice(self.allocator);
}

fn is_dep_name_char(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '@' or c == '.' or c == '_' or c == '+' or c == '-';
}

fn match_dep_operator(s: []const u8, pos: usize) ?usize {
    if (pos >= s.len) return null;
    if (pos + 1 < s.len and (s[pos] == '>' or s[pos] == '<') and s[pos + 1] == '=') return 2;
    return switch (s[pos]) {
        '=', '>', '<' => 1,
        else => null,
    };
}

fn parse_dependency(self: PkgbuildParser, dependency: []const u8) !parsed_dep {
    const trimmed = std.mem.trim(u8, dependency, " \t\r\n");

    var i: usize = 0;
    while (i < trimmed.len and is_dep_name_char(trimmed[i])) : (i += 1) {}

    if (i > 0) {
        if (match_dep_operator(trimmed, i)) |op_len| {
            const version_start = i + op_len;
            if (version_start < trimmed.len) {
                const name = std.mem.trim(u8, trimmed[0..i], " \t\r\n");
                const operator = trimmed[i..version_start];
                const version = std.mem.trim(u8, trimmed[version_start..], " \t\r\n");
                return parsed_dep{
                    .name = try self.allocator.dupe(u8, name),
                    .operator = try self.allocator.dupe(u8, operator),
                    .version = try self.allocator.dupe(u8, version),
                };
            }
        }
    }

    return parsed_dep{
        .name = try self.allocator.dupe(u8, trimmed),
        .operator = try self.allocator.dupe(u8, ""),
        .version = try self.allocator.dupe(u8, ""),
    };
}

pub fn parse_dependencies(self: PkgbuildParser, items: [][]const u8) ![]parsed_dep {
    var result: std.ArrayList(parsed_dep) = .empty;
    errdefer {
        for (result.items) |d| d.deinit(self.allocator);
        result.deinit(self.allocator);
    }
    for (items) |item| {
        const d = try parse_dependency(self, item);
        try result.append(self.allocator, d);
    }
    return result.toOwnedSlice(self.allocator);
}

test "match_operator_len: greater-than returns length 1" {
    try std.testing.expectEqual(@as(?usize, 1), match_operator_len(">", 0));
}

test "match_operator_len: less-than returns length 1" {
    try std.testing.expectEqual(@as(?usize, 1), match_operator_len("<", 0));
}

test "match_operator_len: equal returns length 1" {
    try std.testing.expectEqual(@as(?usize, 1), match_operator_len("=", 0));
}

test "match_operator_len: greater-than-or-equal returns length 2" {
    try std.testing.expectEqual(@as(?usize, 2), match_operator_len(">=", 0));
}

test "match_operator_len: less-than-or-equal returns length 2" {
    try std.testing.expectEqual(@as(?usize, 2), match_operator_len("<=", 0));
}

test "match_operator_len: greater-than followed by non-equals returns length 1" {
    try std.testing.expectEqual(@as(?usize, 1), match_operator_len(">x", 0));
}

test "match_array_ref: valid array reference extracts name" {
    try std.testing.expectEqualStrings("arr", match_array_ref("${arr[@]}").?);
}

test "match_array_ref: valid array reference with underscore" {
    try std.testing.expectEqualStrings("my_arr", match_array_ref("${my_arr[@]}").?);
}

test "match_array_ref: name with digits is accepted" {
    try std.testing.expectEqualStrings("a1", match_array_ref("${a1[@]}").?);
}

test "match_array_ref: single character name" {
    try std.testing.expectEqualStrings("x", match_array_ref("${x[@]}").?);
}

test "match_array_ref: name containing hyphen returns null" {
    try std.testing.expectEqual(null, match_array_ref("${my-arr[@]}"));
}

test "strip_version_constraint: no constraint returns full string" {
    try std.testing.expectEqualStrings("bash", strip_version_constraint("bash"));
}

test "strip_version_constraint: greater-than-or-equal with bare variable strips to name" {
    try std.testing.expectEqualStrings("bash", strip_version_constraint("bash>=$pkgver"));
}

test "strip_version_constraint: greater-than with bare variable strips to name" {
    try std.testing.expectEqualStrings("foo", strip_version_constraint("foo>$ver"));
}

test "strip_version_constraint: less-than with bare variable strips to name" {
    try std.testing.expectEqualStrings("lib", strip_version_constraint("lib<$pkgver"));
}

test "strip_version_constraint: less-than-or-equal with bare variable strips to name" {
    try std.testing.expectEqualStrings("bar", strip_version_constraint("bar<=$ver"));
}

test "strip_version_constraint: equals with bare variable strips to name" {
    try std.testing.expectEqualStrings("dep", strip_version_constraint("dep=$pkgver"));
}

test "strip_version_constraint: operator with braced variable strips to name" {
    try std.testing.expectEqualStrings("bash", strip_version_constraint("bash>=${pkgver}"));
}

test "strip_version_constraint: operator with space before dollar returns full string" {
    try std.testing.expectEqualStrings("bash>= $pkgver", strip_version_constraint("bash>= $pkgver"));
}

test "strip_version_constraint: operator not followed by dollar returns full string" {
    try std.testing.expectEqualStrings("bash>= 5.0", strip_version_constraint("bash>= 5.0"));
}

test "strip_version_constraint: operator at end of string returns full string" {
    try std.testing.expectEqualStrings("bash>=", strip_version_constraint("bash>="));
}

test "strip_version_constraint: empty input returns empty string" {
    try std.testing.expectEqualStrings("", strip_version_constraint(""));
}

test "strip_version_constraint: dollar without operator returns full string" {
    try std.testing.expectEqualStrings("$pkgver", strip_version_constraint("$pkgver"));
}

test "strip_version_constraint: operator followed by dollar but no variable name returns full string" {
    try std.testing.expectEqualStrings("foo>=$", strip_version_constraint("foo>=$"));
}

test "strip_version_constraint: operator followed by dollar and non-word char returns full string" {
    try std.testing.expectEqualStrings("bar>$-bad", strip_version_constraint("bar>$-bad"));
}

test "strip_dangling_operator: strips trailing greater-than-or-equal" {
    try std.testing.expectEqualStrings("bash", strip_dangling_operator("bash>="));
}

test "strip_dangling_operator: strips trailing less-than-or-equal" {
    try std.testing.expectEqualStrings("foo", strip_dangling_operator("foo<="));
}

test "strip_dangling_operator: strips trailing greater-than" {
    try std.testing.expectEqualStrings("bar", strip_dangling_operator("bar>"));
}

test "strip_dangling_operator: strips trailing less-than" {
    try std.testing.expectEqualStrings("lib", strip_dangling_operator("lib<"));
}

test "strip_dangling_operator: strips trailing equals" {
    try std.testing.expectEqualStrings("dep", strip_dangling_operator("dep="));
}

test "strip_dangling_operator: no trailing operator returns unchanged" {
    try std.testing.expectEqualStrings("bash", strip_dangling_operator("bash"));
}

test "strip_dangling_operator: empty input returns empty string" {
    try std.testing.expectEqualStrings("", strip_dangling_operator(""));
}

test "strip_dangling_operator: lone greater-than-or-equal returns empty string" {
    try std.testing.expectEqualStrings("", strip_dangling_operator(">="));
}

test "strip_dangling_operator: lone greater-than returns empty string" {
    try std.testing.expectEqualStrings("", strip_dangling_operator(">"));
}

test "strip_dangling_operator: double equals strips only one" {
    try std.testing.expectEqualStrings("foo=", strip_dangling_operator("foo=="));
}

test "strip_dangling_operator: operator in the middle is untouched" {
    try std.testing.expectEqualStrings("a>b", strip_dangling_operator("a>b"));
}

test "resolve_variable_references: empty items returns empty slice" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    var items = [_][]const u8{};
    const result = try resolve_variable_references(parser, "", &vars, &items);
    defer {
        for (result) |it| parser.allocator.free(it);
        parser.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "resolve_variable_references: resolves plain variable" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("dep_name", "bash");

    var items = [_][]const u8{"${dep_name}"};
    const result = try resolve_variable_references(parser, "", &vars, &items);
    defer {
        for (result) |it| parser.allocator.free(it);
        parser.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("bash", result[0]);
}

test "resolve_variable_references: strips dangling greater-than-or-equal" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    var items = [_][]const u8{"bash>="};
    const result = try resolve_variable_references(parser, "", &vars, &items);
    defer {
        for (result) |it| parser.allocator.free(it);
        parser.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("bash", result[0]);
}

test "resolve_variable_references: strips dangling less-than" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    var items = [_][]const u8{"foo<"};
    const result = try resolve_variable_references(parser, "", &vars, &items);
    defer {
        for (result) |it| parser.allocator.free(it);
        parser.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("foo", result[0]);
}

test "resolve_variable_references: strips dangling equals" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    var items = [_][]const u8{"bar="};
    const result = try resolve_variable_references(parser, "", &vars, &items);
    defer {
        for (result) |it| parser.allocator.free(it);
        parser.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("bar", result[0]);
}

test "resolve_variable_references: does not strip when no dangling operator" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    var items = [_][]const u8{"bash"};
    const result = try resolve_variable_references(parser, "", &vars, &items);
    defer {
        for (result) |it| parser.allocator.free(it);
        parser.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("bash", result[0]);
}

test "resolve_variable_references: multiple items resolved independently" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("a", "first");
    try vars.put("b", "second");

    var items = [_][]const u8{ "${a}", "${b}" };
    const result = try resolve_variable_references(parser, "", &vars, &items);
    defer {
        for (result) |it| parser.allocator.free(it);
        parser.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("first", result[0]);
    try std.testing.expectEqualStrings("second", result[1]);
}

test "resolve_variable_references: array reference expands to multiple items" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const content = "mydep=(alpha beta gamma)\n";
    var items = [_][]const u8{"${mydep[@]}"};
    const result = try resolve_variable_references(parser, content, &vars, &items);
    defer {
        for (result) |it| parser.allocator.free(it);
        parser.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("alpha", result[0]);
    try std.testing.expectEqualStrings("beta", result[1]);
    try std.testing.expectEqualStrings("gamma", result[2]);
}

test "resolve_variable_references: strips dangling operator from array expanded items" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const content = "mydep=(x>= y<)\n";
    var items = [_][]const u8{"${mydep[@]}"};
    const result = try resolve_variable_references(parser, content, &vars, &items);
    defer {
        for (result) |it| parser.allocator.free(it);
        parser.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("x", result[0]);
    try std.testing.expectEqualStrings("y", result[1]);
}

test "resolve_variable_references: mixed plain and array items" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const content = "extra=(one two)\n";
    var items = [_][]const u8{ "static", "${extra[@]}" };
    const result = try resolve_variable_references(parser, content, &vars, &items);
    defer {
        for (result) |it| parser.allocator.free(it);
        parser.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("static", result[0]);
    try std.testing.expectEqualStrings("one", result[1]);
    try std.testing.expectEqualStrings("two", result[2]);
}
