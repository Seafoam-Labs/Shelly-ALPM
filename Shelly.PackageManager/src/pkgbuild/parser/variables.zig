//! PKGBUILD top-level variable map construction and resolution.
const std = @import("std");
const types = @import("types.zig");
const shell_scan = @import("shell_scan.zig");
const expansion = @import("expansion.zig");
const arrays = @import("arrays.zig");
const PkgbuildParser = @import("parser.zig").PkgbuildParser;

const kvp = types.kvp;

const word = @import("word.zig");

/// Returns source syntax, including quotes, for callers that inspect assignment
/// presence. Values must be evaluated with resolve_word, never stripped here.
pub fn parse_variable(content: []const u8, var_name: []const u8) !?[]const u8 {
    var assignments = word.Assignments{ .input = content };
    while (try assignments.next(std.heap.page_allocator)) |assignment| {
        if (std.mem.eql(u8, assignment.name, var_name)) return assignment.raw;
    }
    return null;
}

pub fn resolve_or_parse(self: PkgbuildParser, _: []const u8, var_name: []const u8, vars: *const std.StringHashMap([]const u8)) !?[]const u8 {
    const value = vars.get(var_name) orelse return null;
    return try self.allocator.dupe(u8, value);
}

fn putValue(self: PkgbuildParser, vars: *std.StringHashMap([]const u8), key: []const u8, value: []const u8) !void {
    const owned_key = try self.allocator.dupe(u8, key);
    errdefer self.allocator.free(owned_key);
    const owned_value = try self.allocator.dupe(u8, value);
    errdefer self.allocator.free(owned_value);
    if (vars.fetchRemove(key)) |old| {
        self.allocator.free(old.key);
        self.allocator.free(old.value);
    }
    try vars.put(owned_key, owned_value);
}

pub fn apply_assignments(self: PkgbuildParser, content: []const u8, vars: *std.StringHashMap([]const u8)) !void {
    var assignments = word.Assignments{ .input = content };
    while (try assignments.next(self.allocator)) |assignment| {
        if (dynamicOverride(self, assignment.name) != null or dynamicallyUnset(self, assignment.name)) continue;
        if (std.mem.startsWith(u8, assignment.raw, "(")) {
            if (self.dynamic_array_overrides) |overrides| if (overrides.contains(assignment.name)) continue;
            if (self.dynamic_array_unsets) |unsets| if (unsets.contains(assignment.name)) continue;
            // Bash exposes the first pkgname array member as scalar pkgname.
            if (std.mem.eql(u8, assignment.name, "pkgname") and !assignment.deferred) {
                const items = try arrays.parse_array_body_syntax(self.allocator, assignment.raw[1 .. assignment.raw.len - 1]);
                defer freeStringSlice(self.allocator, items);
                if (items.len > 0) {
                    const value = try expansion.resolve_word(self, items[0], vars);
                    defer self.allocator.free(value.value);
                    try putValue(self, vars, assignment.name, value.value);
                    if (self.unresolved_variables) |unresolved| {
                        if (value.unresolved) try unresolved.put(assignment.name, {}) else _ = unresolved.remove(assignment.name);
                    }
                }
            }
            continue;
        }
        if (assignment.deferred or shell_scan.contains_command_substitution(assignment.raw)) {
            // Keep uncertain assignments out of the value map. In particular,
            // an earlier value cannot stand in for a later dynamic replacement.
            if (self.unresolved_variables) |unresolved| try unresolved.put(assignment.name, {});
            if (vars.fetchRemove(assignment.name)) |old| {
                self.allocator.free(old.key);
                self.allocator.free(old.value);
            }
            continue;
        }
        const value = try expansion.resolve_word(self, assignment.raw, vars);
        defer self.allocator.free(value.value);
        const was_unresolved = if (self.unresolved_variables) |unresolved| unresolved.contains(assignment.name) else false;
        const joined = if (assignment.append)
            try std.mem.concat(self.allocator, u8, &.{ vars.get(assignment.name) orelse "", value.value })
        else
            try self.allocator.dupe(u8, value.value);
        defer self.allocator.free(joined);
        try putValue(self, vars, assignment.name, joined);
        if (self.unresolved_variables) |unresolved| {
            if (value.unresolved or (assignment.append and was_unresolved))
                try unresolved.put(assignment.name, {})
            else
                _ = unresolved.remove(assignment.name);
        }
    }
}

pub fn build_var_hashmap(context: PkgbuildParser, content: []const u8) !std.StringHashMap([]const u8) {
    var unresolved = std.StringHashMap(void).init(context.allocator);
    defer unresolved.deinit();
    var self = context;
    if (self.unresolved_variables == null) self.unresolved_variables = &unresolved;
    var vars = std.StringHashMap([]const u8).init(self.allocator);
    errdefer free_vars(self.allocator, &vars);
    try putValue(self, &vars, "CARCH", self.package_carch);
    // Sandbox snapshots are final values. Seed them before evaluating dependent
    // syntax, and never expand or overwrite them during the static reparse.
    if (self.dynamic_overrides) |overrides| {
        var it = overrides.iterator();
        while (it.next()) |entry| try putValue(self, &vars, entry.key_ptr.*, entry.value_ptr.*);
    }
    try inject_array_pkgname(self, "", &vars);
    try apply_assignments(self, content, &vars);
    return vars;
}

fn dynamicOverride(self: PkgbuildParser, name: []const u8) ?[]const u8 {
    const overrides = self.dynamic_overrides orelse return null;
    return overrides.get(name);
}

fn dynamicallyUnset(self: PkgbuildParser, name: []const u8) bool {
    const unsets = self.dynamic_unsets orelse return false;
    return unsets.contains(name);
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

    var assignments = word.Assignments{ .input = content };
    while (try assignments.next(self.allocator)) |parsed| {
        if (std.mem.startsWith(u8, parsed.raw, "(")) continue;
        if (!shell_scan.contains_command_substitution(parsed.raw)) continue;
        if (dynamicOverride(self, parsed.name) != null or dynamicallyUnset(self, parsed.name)) continue;
        const executable_line = content[parsed.offset .. parsed.offset + parsed.name.len + @as(usize, if (parsed.append) 2 else 1) + parsed.raw.len];
        const name_owned = try self.allocator.dupe(u8, parsed.name);
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

    if (self.dynamic_array_overrides) |overrides| if (overrides.get("pkgname")) |names| {
        if (names.len == 0) return;
        const key = try self.allocator.dupe(u8, "pkgname");
        errdefer self.allocator.free(key);
        const value = try self.allocator.dupe(u8, names[0]);
        errdefer self.allocator.free(value);
        try vars.put(key, value);
        return;
    };
    if (dynamicallyUnset(self, "pkgname")) return;
    if (self.dynamic_array_unsets) |unsets| if (unsets.contains("pkgname")) return;

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
    try std.testing.expectEqualStrings("\"a package with spaces\"", result.?);
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

test "build_var_hashmap: evaluated shell state overlays and unsets static values" {
    var overrides: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer overrides.deinit();
    try overrides.put("_defaulted", "portable");
    try overrides.put("_changed", "shell-value");
    var unsets: std.StringHashMap(void) = .init(std.testing.allocator);
    defer unsets.deinit();
    try unsets.put("_removed", {});

    const parser = PkgbuildParser{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .dynamic_overrides = &overrides,
        .dynamic_unsets = &unsets,
    };
    var vars = try build_var_hashmap(
        parser,
        "_changed=static\n_removed=static\n_dependent=$_defaulted\n",
    );
    defer free_vars(std.testing.allocator, &vars);

    try std.testing.expectEqualStrings("portable", vars.get("_defaulted").?);
    try std.testing.expectEqualStrings("shell-value", vars.get("_changed").?);
    try std.testing.expectEqualStrings("portable", vars.get("_dependent").?);
    try std.testing.expect(vars.get("_removed") == null);
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

test "issue 1880 ordered scalar assignments preserve literal and adjacent segments" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const cases = .{
        .{ "_name=mypkg\ninstall=\"${_name}\".install", "mypkg.install" },
        .{ "_name=mypkg\ninstall=${_name}\".install\"", "mypkg.install" },
        .{ "install=''my\"pkg\".install", "mypkg.install" },
        .{ "install=old\ninstall=", "" },
        .{ "install=my\ninstall+=\"pkg\".install", "mypkg.install" },
        .{ "_name=old\ninstall=$_name.install\n_name=new", "old.install" },
        .{ "install=my\\ pkg.install;", "my pkg.install" },
        .{ "install=\"my\\\"pkg.install\"", "my\"pkg.install" },
        .{ "_name=expanded\ninstall='${_name}.install'", "${_name}.install" },
        .{ "_name=expanded\n_literal='$'\ninstall=${_literal}{_name}.install", "${_name}.install" },
        .{ "_name=expanded\n_literal='${_name}'\ninstall=${_literal,,}.install", "${_name}.install" },
        .{ "install=my\\\npkg.install", "mypkg.install" },
        .{ "install=mypkg{a,b}.install", "mypkg{a,b}.install" },
        .{ "install=mypkg#hash.install # comment", "mypkg#hash.install" },
        .{ "install=global.install\nf() {\ninstall=wrong.install\n}\n", "global.install" },
    };
    inline for (cases) |case| {
        var vars = try build_var_hashmap(parser, case[0]);
        defer free_vars(std.testing.allocator, &vars);
        try std.testing.expectEqualStrings(case[1], vars.get("install").?);
    }
}

test "issue 1880 trusted Bash differential word matrix" {
    const allocator = std.testing.allocator;
    const parser = PkgbuildParser{ .allocator = allocator, .io = std.testing.io };
    // Only these authored grammar fragments reach Bash. Never feed this oracle
    // downloaded PKGBUILDs, arbitrary input, or command substitutions.
    const prefixes = [_][]const u8{ "mypkg", "\"mypkg\"", "'mypkg'", "\"${_name}\"", "${_name}", "''mypkg", "my\\ pkg", "'${literal}'" };
    const suffixes = [_][]const u8{ ".install", "\".install\"", "'.install'", "\\.install", "''" };
    for (prefixes) |prefix| for (suffixes) |suffix| {
        const content = try std.fmt.allocPrint(allocator, "_name=mypkg\ninstall={s}{s}\n", .{ prefix, suffix });
        defer allocator.free(content);
        const script = try std.mem.concat(allocator, u8, &.{ content, "printf '%s' \"$install\"" });
        defer allocator.free(script);
        const bash = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "/bin/bash", "--noprofile", "--norc", "-c", script } });
        defer allocator.free(bash.stdout);
        defer allocator.free(bash.stderr);
        try std.testing.expect(bash.term == .exited and bash.term.exited == 0);
        var vars = try build_var_hashmap(parser, content);
        defer free_vars(allocator, &vars);
        try std.testing.expectEqualStrings(bash.stdout, vars.get("install").?);
    };
}

test "issue 1880 heredoc contents and skipped function bodies are never assignments" {
    const allocator = std.testing.allocator;
    const content =
        \\install=good.install
        \\cat <<'END'
        \\install=wrong.install
        \\arbitrary='unterminated
        \\END
        \\f() {
        \\  cat <<'END'
        \\}
        \\install=also-wrong.install
        \\END
        \\}
        \\suffix=.install
    ;
    var vars = try build_var_hashmap(.{ .allocator = allocator, .io = std.testing.io }, content);
    defer free_vars(allocator, &vars);
    try std.testing.expectEqualStrings("good.install", vars.get("install").?);
    try std.testing.expectEqualStrings(".install", vars.get("suffix").?);
    try std.testing.expect(!vars.contains("arbitrary"));
}
