//! PKGBUILD top-level variable map construction and resolution.
const std = @import("std");
const types = @import("types.zig");
const shell_scan = @import("shell_scan.zig");
const expansion = @import("expansion.zig");
const arrays = @import("arrays.zig");
const PkgbuildParser = @import("parser.zig").PkgbuildParser;

const kvp = types.kvp;

pub fn parse_variable(content: []const u8, var_name: []const u8) !?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, var_name)) continue;

        const after_name = trimmed[var_name.len..];
        if (after_name.len == 0 or after_name[0] != '=') continue;

        const value_part = after_name[1..];
        if (value_part.len == 0) return "";

        return switch (value_part[0]) {
            '"' => extract_quoted(value_part, '"'),
            '\'' => extract_quoted(value_part, '\''),
            else => extract_bare_token(value_part),
        };
    }
    return null;
}

fn extract_quoted(s: []const u8, quote: u8) ?[]const u8 {
    const rest = s[1..];
    if (std.mem.indexOfScalar(u8, rest, quote)) |end| {
        return rest[0..end];
    }
    return null;
}

fn extract_bare_token(s: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, s, " \t\r\n") orelse s.len;
    return s[0..end];
}

pub fn resolve_or_parse(self: PkgbuildParser, content: []const u8, var_name: []const u8, vars: *const std.StringHashMap([]const u8)) !?[]const u8 {
    if (vars.get(var_name)) |val| {
        return try self.allocator.dupe(u8, val);
    }
    const parsed = try parse_variable(content, var_name) orelse return null;
    return try self.allocator.dupe(u8, parsed);
}

fn parse_kvp(line: []const u8) ?kvp {
    var pos: usize = 0;
    while (pos < line.len and shell_scan.is_word(line[pos])) : (pos += 1) {}
    if (pos == 0) return null;
    const key = line[0..pos];

    const append = pos < line.len and line[pos] == '+';
    if (append) pos += 1;
    if (pos >= line.len or line[pos] != '=') return null;
    pos += 1;
    if (pos >= line.len) return null;

    if (line[pos] == '"') {
        const start = pos + 1;
        const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse return null;
        return kvp{ .key = key, .value = line[start..end], .append = append };
    }

    if (line[pos] == '\'') {
        const start = pos + 1;
        const end = std.mem.indexOfScalarPos(u8, line, start, '\'') orelse return null;
        return kvp{ .key = key, .value = line[start..end], .append = append };
    }

    const start = pos;
    while (pos < line.len and !std.ascii.isWhitespace(line[pos])) : (pos += 1) {}
    if (pos == start) return null;
    return kvp{ .key = key, .value = line[start..pos], .append = append };
}

pub fn build_var_hashmap(self: PkgbuildParser, content: []const u8) !std.StringHashMap([]const u8) {
    var vars = std.StringHashMap([]const u8).init(self.allocator);
    errdefer free_vars(self.allocator, &vars);

    var line_itr = std.mem.splitScalar(u8, content, '\n');
    while (line_itr.next()) |full_line| {
        const line = std.mem.trimEnd(u8, full_line, "\r");
        const executable_line = try shell_scan.strip_comment(line);
        const parsed = parse_kvp(executable_line) orelse continue;

        if (std.mem.startsWith(u8, parsed.value, "(")) continue;
        if (shell_scan.contains_command_substitution(executable_line)) {
            if (dynamicOverride(self, parsed.key)) |override_value| {
                const key_owned = try self.allocator.dupe(u8, parsed.key);
                const value_owned = try self.allocator.dupe(u8, override_value);
                if (vars.fetchRemove(key_owned)) |old| {
                    self.allocator.free(old.key);
                    self.allocator.free(old.value);
                }
                vars.put(key_owned, value_owned) catch |err| {
                    self.allocator.free(key_owned);
                    self.allocator.free(value_owned);
                    return err;
                };
            }
            // A dynamic assignment without an override is skipped: the static
            // parser never executes command substitution. The builder evaluates
            // the recorded assignments post-review and re-parses with their
            // values seeded as overrides.
            continue;
        }

        const key_owned = try self.allocator.dupe(u8, parsed.key);
        errdefer self.allocator.free(key_owned);
        const value_owned = if (parsed.append and vars.get(parsed.key) != null)
            try std.mem.concat(self.allocator, u8, &.{ vars.get(parsed.key).?, parsed.value })
        else
            try self.allocator.dupe(u8, parsed.value);
        errdefer self.allocator.free(value_owned);

        if (vars.fetchRemove(key_owned)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
        try vars.put(key_owned, value_owned);
    }

    // makepkg exposes CARCH to every top-level assignment, so metadata that
    // references it (most commonly source=() URLs) resolves statically. Seed
    // it unless the PKGBUILD defined its own value.
    if (!vars.contains("CARCH")) {
        const key_owned = try self.allocator.dupe(u8, "CARCH");
        const value_owned = try self.allocator.dupe(u8, self.package_carch);
        vars.put(key_owned, value_owned) catch |err| {
            self.allocator.free(key_owned);
            self.allocator.free(value_owned);
            return err;
        };
    }

    try inject_array_pkgname(self, content, &vars);

    var pass: usize = 0;
    while (pass < 10) : (pass += 1) {
        var changed = false;
        var keys: std.ArrayList([]const u8) = .empty;
        defer keys.deinit(self.allocator);
        var key_it = vars.keyIterator();
        while (key_it.next()) |k| try keys.append(self.allocator, k.*);

        for (keys.items) |key| {
            const original = vars.get(key).?;
            const resolved = try expansion.resolve_string(self, original, &vars);
            defer self.allocator.free(resolved);

            if (!std.mem.eql(u8, resolved, original)) {
                const resolved_owned = try self.allocator.dupe(u8, resolved);
                errdefer self.allocator.free(resolved_owned);

                if (vars.fetchRemove(key)) |old| {
                    self.allocator.free(old.value);
                    try vars.put(old.key, resolved_owned);
                }
                changed = true;
            }
        }
        if (!changed) break;
    }

    return vars;
}

fn dynamicOverride(self: PkgbuildParser, name: []const u8) ?[]const u8 {
    const overrides = self.dynamic_overrides orelse return null;
    return overrides.get(name);
}

/// Collects every top-level scalar assignment whose value contains a command
/// substitution and that has no seeded override, in declaration order. The
/// builder evaluates these post-review in the sandbox and re-parses with the
/// results. Returns an empty slice when there are none.
pub fn collect_dynamic_assignments(self: PkgbuildParser, content: []const u8) ![]types.dynamic_assignment {
    var list: std.ArrayList(types.dynamic_assignment) = .empty;
    errdefer {
        for (list.items) |item| {
            self.allocator.free(item.name);
            self.allocator.free(item.statement);
        }
        list.deinit(self.allocator);
    }

    var line_itr = std.mem.splitScalar(u8, content, '\n');
    while (line_itr.next()) |full_line| {
        const line = std.mem.trimEnd(u8, full_line, "\r");
        const executable_line = try shell_scan.strip_comment(line);
        const parsed = parse_kvp(executable_line) orelse continue;
        if (std.mem.startsWith(u8, parsed.value, "(")) continue;
        if (!shell_scan.contains_command_substitution(executable_line)) continue;
        if (dynamicOverride(self, parsed.key) != null) continue;

        const name_owned = try self.allocator.dupe(u8, parsed.key);
        const statement_owned = try self.allocator.dupe(u8, std.mem.trim(u8, executable_line, " \t"));
        list.append(self.allocator, .{ .name = name_owned, .statement = statement_owned }) catch |err| {
            self.allocator.free(name_owned);
            self.allocator.free(statement_owned);
            return err;
        };
    }

    if (list.items.len == 0) {
        list.deinit(self.allocator);
        return @as([]types.dynamic_assignment, &.{});
    }
    return list.toOwnedSlice(self.allocator);
}

fn inject_array_pkgname(
    self: PkgbuildParser,
    content: []const u8,
    vars: *std.StringHashMap([]const u8),
) !void {
    if (vars.contains("pkgname")) return;

    const names = try arrays.parse_array(self, content, "pkgname");
    defer {
        for (names) |name| self.allocator.free(name);
        self.allocator.free(names);
    }
    if (names.len == 0) return;

    // Top-level PKGBUILD evaluation always sees the first split-package
    // name. The selected name is overlaid only while evaluating its
    // package_* function.
    const value = names[0];

    const owned_key = try self.allocator.dupe(u8, "pkgname");
    errdefer self.allocator.free(owned_key);
    const owned_value = try self.allocator.dupe(u8, value);
    errdefer self.allocator.free(owned_value);
    try vars.put(owned_key, owned_value);
}

pub fn free_vars(allocator: std.mem.Allocator, vars: *std.StringHashMap([]const u8)) void {
    var it = vars.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    vars.deinit();
}

pub fn freeStringSlice(allocator: std.mem.Allocator, values: [][]const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

test "parse_variable: bare token stops at whitespace" {
    const content = "pkgver=1.2.3 extra stuff\n";
    const result = try parse_variable(content, "pkgver");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("1.2.3", result.?);
}

test "parse_variable: quoted value containing spaces" {
    const content = "pkgdesc=\"a package with spaces\"\n";
    const result = try parse_variable(content, "pkgdesc");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("a package with spaces", result.?);
}

test "parse_variable: variable not found returns null" {
    const content = "pkgname=foo\n";
    const result = try parse_variable(content, "pkgver");
    try std.testing.expect(result == null);
}

test "parse_variable: empty value returns empty string" {
    const content = "pkgrel=\n";
    const result = try parse_variable(content, "pkgrel");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("", result.?);
}

test "parse_variable: does not match prefix of longer variable name" {
    const content = "pkgname=foo\n";
    const result = try parse_variable(content, "pkg");
    try std.testing.expect(result == null);
}

test "parse_variable: matches on later line" {
    const content =
        \\pkgname=foo
        \\pkgver=1.0.0
        \\pkgrel=1
    ;
    const result = try parse_variable(content, "pkgver");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("1.0.0", result.?);
}

test "build_var_hashmap: parses double-quoted, single-quoted, and bare values" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars = try build_var_hashmap(
        parser,
        "pkgname=\"my app\"\npkgver='1.0'\narch=x86_64\n",
    );
    defer free_vars(std.testing.allocator, &vars);

    try std.testing.expectEqualStrings("my app", vars.get("pkgname").?);
    try std.testing.expectEqualStrings("1.0", vars.get("pkgver").?);
    try std.testing.expectEqualStrings("x86_64", vars.get("arch").?);
}

test "build_var_hashmap: skips array declarations" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars = try build_var_hashmap(parser, "depends=(foo bar)\npkgname=app\n");
    defer free_vars(std.testing.allocator, &vars);

    try std.testing.expect(vars.get("depends") == null);
    try std.testing.expectEqualStrings("app", vars.get("pkgname").?);
}

test "build_var_hashmap: skips command substitution but keeps arithmetic" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var dynamic_vars = try build_var_hashmap(parser, "gitrev=$(git rev-parse HEAD)\n");
    defer free_vars(std.testing.allocator, &dynamic_vars);
    try std.testing.expect(dynamic_vars.get("gitrev") == null);

    var vars = try build_var_hashmap(parser, "count=$((1+2))\n");
    defer free_vars(std.testing.allocator, &vars);
    try std.testing.expect(vars.get("count") != null);
}

test "build_var_hashmap: seeded override replaces a skipped command substitution" {
    var overrides: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer overrides.deinit();
    try overrides.put("_date", "20260819");

    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io, .dynamic_overrides = &overrides };
    var vars = try build_var_hashmap(parser, "_date=\"$(date -u +%Y%m%d)\"\n_tag=\"nightly-$_date\"\n");
    defer free_vars(std.testing.allocator, &vars);
    try std.testing.expectEqualStrings("20260819", vars.get("_date").?);
    try std.testing.expectEqualStrings("nightly-20260819", vars.get("_tag").?);
}

test "collect_dynamic_assignments: records command substitutions in order, skips overridden" {
    var overrides: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer overrides.deinit();
    try overrides.put("_resolved", "value");

    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io, .dynamic_overrides = &overrides };
    const content =
        \\pkgname=demo
        \\_date="$(date -u +%Y%m%d)"
        \\_resolved="$(already known)"
        \\_rev="$(git rev-parse --short HEAD)"
    ;
    const dynamic = try collect_dynamic_assignments(parser, content);
    defer {
        for (dynamic) |assignment| assignment.deinit(std.testing.allocator);
        if (dynamic.len > 0) std.testing.allocator.free(dynamic);
    }
    try std.testing.expectEqual(@as(usize, 2), dynamic.len);
    try std.testing.expectEqualStrings("_date", dynamic[0].name);
    try std.testing.expectEqualStrings("_date=\"$(date -u +%Y%m%d)\"", dynamic[0].statement);
    try std.testing.expectEqualStrings("_rev", dynamic[1].name);
    try std.testing.expectEqualStrings("_rev=\"$(git rev-parse --short HEAD)\"", dynamic[1].statement);
}

test "build_var_hashmap: resolves chained variable references" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars = try build_var_hashmap(parser, "_a=1\n_b=$_a\n_c=$_b\n");
    defer free_vars(std.testing.allocator, &vars);

    try std.testing.expectEqualStrings("1", vars.get("_a").?);
    try std.testing.expectEqualStrings("1", vars.get("_b").?);
    try std.testing.expectEqualStrings("1", vars.get("_c").?);
}

test "build_var_hashmap: later redeclaration overwrites earlier value" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars = try build_var_hashmap(parser, "pkgver=1.0\npkgver=2.0\n");
    defer free_vars(std.testing.allocator, &vars);

    try std.testing.expectEqualStrings("2.0", vars.get("pkgver").?);
}

test "build_var_hashmap: empty content seeds only CARCH" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars = try build_var_hashmap(parser, "");
    defer free_vars(std.testing.allocator, &vars);

    try std.testing.expectEqual(@as(usize, 1), vars.count());
    try std.testing.expectEqualStrings("x86_64", vars.get("CARCH").?);
}

test "build_var_hashmap: lines that do not match key=value are ignored" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars = try build_var_hashmap(parser, "# a comment\n\npkgname=app\n");
    defer free_vars(std.testing.allocator, &vars);

    try std.testing.expectEqual(@as(usize, 2), vars.count());
    try std.testing.expectEqualStrings("app", vars.get("pkgname").?);
}

test "inject_array_pkgname: no-op when vars already contains pkgname" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer free_vars(std.testing.allocator, &vars);

    const existing_key = try std.testing.allocator.dupe(u8, "pkgname");
    const existing_value = try std.testing.allocator.dupe(u8, "already-set");
    try vars.put(existing_key, existing_value);

    try inject_array_pkgname(parser, "pkgname=(foo bar)\n", &vars);

    try std.testing.expectEqual(@as(usize, 1), vars.count());
    try std.testing.expectEqualStrings("already-set", vars.get("pkgname").?);
}

test "inject_array_pkgname: missing pkgname array leaves vars untouched" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer free_vars(std.testing.allocator, &vars);

    try inject_array_pkgname(parser, "pkgver=1.0\narch=(x86_64)\n", &vars);

    try std.testing.expect(!vars.contains("pkgname"));
}

test "inject_array_pkgname: empty pkgname array leaves vars untouched" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer free_vars(std.testing.allocator, &vars);

    try inject_array_pkgname(parser, "pkgname=()\n", &vars);

    try std.testing.expect(!vars.contains("pkgname"));
}

test "inject_array_pkgname: null selected_package_name uses names[0]" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer free_vars(std.testing.allocator, &vars);

    try inject_array_pkgname(parser, "pkgname=(alpha beta gamma)\n", &vars);

    try std.testing.expectEqualStrings("alpha", vars.get("pkgname").?);
}

test "inject_array_pkgname: null selected_package_name with single-element array" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer free_vars(std.testing.allocator, &vars);

    try inject_array_pkgname(parser, "pkgname=(solo)\n", &vars);

    try std.testing.expectEqualStrings("solo", vars.get("pkgname").?);
}

test "inject_array_pkgname: selected_package_name matching names[0] uses that name" {
    const parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .selected_package_name = "alpha",
    };
    var vars = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer free_vars(std.testing.allocator, &vars);

    try inject_array_pkgname(parser, "pkgname=(alpha beta gamma)\n", &vars);

    try std.testing.expectEqualStrings("alpha", vars.get("pkgname").?);
}

test "inject_array_pkgname: selected_package_name does not change global array value" {
    const parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .selected_package_name = "beta",
    };
    var vars = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer free_vars(std.testing.allocator, &vars);

    try inject_array_pkgname(parser, "pkgname=(alpha beta gamma)\n", &vars);

    try std.testing.expectEqualStrings("alpha", vars.get("pkgname").?);
}

test "inject_array_pkgname: selected last name still uses first global value" {
    const parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .selected_package_name = "gamma",
    };
    var vars = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer free_vars(std.testing.allocator, &vars);

    try inject_array_pkgname(parser, "pkgname=(alpha beta gamma)\n", &vars);

    try std.testing.expectEqualStrings("alpha", vars.get("pkgname").?);
}

test "inject_array_pkgname: unrelated selected name does not alter global value" {
    const parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .selected_package_name = "delta",
    };
    var vars = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer free_vars(std.testing.allocator, &vars);

    try inject_array_pkgname(parser, "pkgname=(alpha beta gamma)\n", &vars);

    try std.testing.expectEqualStrings("alpha", vars.get("pkgname").?);
}

test "inject_array_pkgname: selected name case does not alter global value" {
    const parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .selected_package_name = "Beta",
    };
    var vars = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer free_vars(std.testing.allocator, &vars);

    try inject_array_pkgname(parser, "pkgname=(alpha beta gamma)\n", &vars);

    try std.testing.expectEqualStrings("alpha", vars.get("pkgname").?);
}

test "inject_array_pkgname: global value is independent of selected name buffer" {
    var name_buffer: [4]u8 = undefined;
    @memcpy(name_buffer[0..], "beta");

    const parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .selected_package_name = name_buffer[0..],
    };
    var vars = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer free_vars(std.testing.allocator, &vars);

    try inject_array_pkgname(parser, "pkgname=(alpha beta gamma)\n", &vars);

    name_buffer[0] = 'x';

    try std.testing.expectEqualStrings("alpha", vars.get("pkgname").?);
}
