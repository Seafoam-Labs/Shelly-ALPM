//! Builds the makepkg execution plan: lifecycle step extraction,
//! environment preludes, and helper definitions.
const std = @import("std");
const types = @import("types.zig");
const shell_scan = @import("shell_scan.zig");
const function_body = @import("function_body.zig");
const expansion = @import("expansion.zig");
const arrays = @import("arrays.zig");
const variables = @import("variables.zig");
const dependencies = @import("dependencies.zig");
const PkgbuildParser = @import("parser.zig").PkgbuildParser;

const execution_step = types.execution_step;
const execution_plan = types.execution_plan;

/// PKGBUILD functions in the order makepkg executes them.
const execution_step_functions = [_][]const u8{ "prepare", "pkgver", "build", "check", "package" };

pub fn resolve_execution_plan(
    self: PkgbuildParser,
    content: []const u8,
    vars: *std.StringHashMap([]const u8),
    base_dir: ?[]const u8,
) !?execution_plan {
    var steps: std.ArrayList(execution_step) = .empty;
    errdefer {
        for (steps.items) |step| step.deinit(self.allocator);
        steps.deinit(self.allocator);
    }

    var step_vars = try build_step_env(self, content, vars, base_dir, null);
    defer variables.free_vars(self.allocator, &step_vars);

    var package_vars = try build_step_env(self, content, vars, base_dir, self.selected_package_name);
    defer variables.free_vars(self.allocator, &package_vars);

    const shared_prelude = try build_execution_prelude(self, content, &step_vars, null);
    errdefer self.allocator.free(shared_prelude);
    const package_prelude = try build_execution_prelude(
        self,
        content,
        &package_vars,
        self.selected_package_name,
    );
    errdefer self.allocator.free(package_prelude);

    const raw_helpers = try extract_helper_definitions(self, content);
    defer self.allocator.free(raw_helpers);
    const shared_helpers = try self.allocator.dupe(u8, raw_helpers);
    errdefer self.allocator.free(shared_helpers);
    const package_helpers = try self.allocator.dupe(u8, raw_helpers);
    errdefer self.allocator.free(package_helpers);

    var verify_step: ?execution_step = null;
    errdefer if (verify_step) |step| step.deinit(self.allocator);
    if (try function_body.extract_function_body(content, "verify")) |body|
        verify_step = try create_execution_step(self, "verify", body, &step_vars);

    for (execution_step_functions) |function_name| {
        // For split packages the packaging step is the package-scoped
        // function; fall back to the shared package() when absent.
        if (std.mem.eql(u8, function_name, "package")) {
            if (self.selected_package_name) |package_name| {
                const scoped_name = try std.fmt.allocPrint(
                    self.allocator,
                    "package_{s}",
                    .{package_name},
                );
                defer self.allocator.free(scoped_name);

                if (try function_body.extract_function_body(content, scoped_name)) |body| {
                    try append_execution_step(self, &steps, scoped_name, body, &package_vars);
                    continue;
                }
            }
        }

        const body = try function_body.extract_function_body(content, function_name) orelse continue;
        const package_step = std.mem.eql(u8, function_name, "package");
        try append_execution_step(
            self,
            &steps,
            function_name,
            body,
            if (package_step) &package_vars else &step_vars,
        );
    }

    if (steps.items.len == 0 and verify_step == null) {
        steps.deinit(self.allocator);
        self.allocator.free(shared_prelude);
        self.allocator.free(package_prelude);
        self.allocator.free(shared_helpers);
        self.allocator.free(package_helpers);
        return null;
    }
    return .{
        .verify_step = verify_step,
        .steps = try steps.toOwnedSlice(self.allocator),
        .shared_prelude = shared_prelude,
        .package_prelude = package_prelude,
        .shared_helpers = shared_helpers,
        .package_helpers = package_helpers,
    };
}

const execution_value = union(enum) {
    scalar: []const u8,
    indexed_array: [][]const u8,
};

/// Reconstructs the statically supported part of PKGBUILD initialization
/// for Bash. Every value is emitted as data, never executable shell text.
fn build_execution_prelude(
    self: PkgbuildParser,
    content: []const u8,
    vars: *std.StringHashMap([]const u8),
    selected_package: ?[]const u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer output.deinit();
    const writer = &output.writer;

    var array_names = try collect_top_level_array_names(self, content);
    defer {
        for (array_names.items) |name| self.allocator.free(name);
        array_names.deinit(self.allocator);
    }
    std.mem.sort([]const u8, array_names.items, {}, string_before);

    for (array_names.items) |name| {
        if (try array_uses_command_substitution(self, content, name))
            return error.UnsupportedDynamicAssignment;
        const resolved = try resolve_execution_array(self, content, vars, name, 0);
        defer variables.freeStringSlice(self.allocator, resolved);
        try write_execution_declaration(writer, name, .{ .indexed_array = resolved });
    }

    var scalar_names: std.ArrayList([]const u8) = .empty;
    defer scalar_names.deinit(self.allocator);
    var iterator = vars.keyIterator();
    while (iterator.next()) |name| try scalar_names.append(self.allocator, name.*);
    std.mem.sort([]const u8, scalar_names.items, {}, string_before);

    for (scalar_names.items) |name| {
        // An array declaration owns the name in shared functions. For a
        // split-package function, makepkg overlays scalar $pkgname.
        if (types.contains_string(array_names.items, name) and
            !(selected_package != null and std.mem.eql(u8, name, "pkgname")))
        {
            continue;
        }
        try write_execution_declaration(writer, name, .{ .scalar = vars.get(name).? });
    }

    return output.toOwnedSlice();
}

fn resolve_execution_array(
    self: PkgbuildParser,
    content: []const u8,
    vars: *std.StringHashMap([]const u8),
    name: []const u8,
    depth: usize,
) ![][]const u8 {
    if (depth >= 32) return error.ArrayExpansionTooDeep;
    const raw_items = try arrays.parse_array(self, content, name);
    defer variables.freeStringSlice(self.allocator, raw_items);

    var resolved: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (resolved.items) |item| self.allocator.free(item);
        resolved.deinit(self.allocator);
    }
    for (raw_items) |item| {
        if (dependencies.match_array_ref(item)) |referenced_name| {
            const referenced = try resolve_execution_array(
                self,
                content,
                vars,
                referenced_name,
                depth + 1,
            );
            defer variables.freeStringSlice(self.allocator, referenced);
            for (referenced) |value|
                try resolved.append(self.allocator, try self.allocator.dupe(u8, value));
            continue;
        }
        if (std.mem.indexOf(u8, item, "[@]") != null)
            return error.UnsupportedArrayExpansion;
        const value = if (shell_scan.contains_command_substitution(item))
            try self.allocator.dupe(u8, item)
        else
            try expansion.resolve_string(self, item, vars);
        try resolved.append(self.allocator, value);
    }
    return resolved.toOwnedSlice(self.allocator);
}

fn collect_top_level_array_names(
    self: PkgbuildParser,
    content: []const u8,
) !std.ArrayList([]const u8) {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |name| self.allocator.free(name);
        names.deinit(self.allocator);
    }
    var seen = std.StringHashMap(void).init(self.allocator);
    defer seen.deinit();

    var offset: usize = 0;
    while (offset < content.len) {
        const line_end = std.mem.indexOfScalarPos(u8, content, offset, '\n') orelse content.len;
        const line = std.mem.trimEnd(u8, content[offset..line_end], "\r");
        if (array_assignment_name(line)) |name| {
            if (!shell_scan.is_inside_conditional_block(content, offset) and !seen.contains(name)) {
                const owned = try self.allocator.dupe(u8, name);
                names.append(self.allocator, owned) catch |err| {
                    self.allocator.free(owned);
                    return err;
                };
                try seen.put(owned, {});
            }
        }
        if (line_end == content.len) break;
        offset = line_end + 1;
    }
    return names;
}

pub fn validate_execution_assignments(self: PkgbuildParser, content: []const u8) !void {
    var names = try collect_top_level_array_names(self, content);
    defer {
        for (names.items) |name| self.allocator.free(name);
        names.deinit(self.allocator);
    }
    for (names.items) |name| {
        if (try array_uses_command_substitution(self, content, name))
            return error.UnsupportedDynamicAssignment;
    }
}

fn array_uses_command_substitution(
    self: PkgbuildParser,
    content: []const u8,
    name: []const u8,
) !bool {
    var search_from: usize = 0;
    while (arrays.find_next_array_start(content, name, search_from)) |assignment| {
        const scanned = try arrays.scan_array_body(self.allocator, content, assignment.after_paren);
        defer self.allocator.free(scanned.body);
        if (shell_scan.contains_command_substitution(scanned.body)) return true;
        search_from = scanned.end;
    }
    return false;
}

fn string_before(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn write_execution_declaration(
    writer: *std.Io.Writer,
    name: []const u8,
    value: execution_value,
) !void {
    try writer.print("unset -v {s}\n", .{name});
    switch (value) {
        .scalar => |scalar| {
            try writer.print("declare -- {s}=", .{name});
            try write_shell_word(writer, scalar);
            try writer.writeAll("\n");
        },
        .indexed_array => |items| {
            try writer.print("declare -a {s}=(", .{name});
            for (items, 0..) |item, index| {
                if (index != 0) try writer.writeAll(" ");
                try write_shell_word(writer, item);
            }
            try writer.writeAll(")\n");
        },
    }
}

fn write_shell_word(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeAll("'");
    var start: usize = 0;
    for (value, 0..) |byte, index| {
        if (byte != '\'') continue;
        try writer.writeAll(value[start..index]);
        try writer.writeAll("'\\''");
        start = index + 1;
    }
    try writer.writeAll(value[start..]);
    try writer.writeAll("'");
}

fn append_execution_step(
    self: PkgbuildParser,
    steps: *std.ArrayList(execution_step),
    name: []const u8,
    body: []const u8,
    vars: *std.StringHashMap([]const u8),
) !void {
    const step = try create_execution_step(self, name, body, vars);
    errdefer step.deinit(self.allocator);
    try steps.append(self.allocator, step);
}

fn create_execution_step(
    self: PkgbuildParser,
    name: []const u8,
    body: []const u8,
    vars: *std.StringHashMap([]const u8),
) !execution_step {
    const name_owned = try self.allocator.dupe(u8, name);
    errdefer self.allocator.free(name_owned);
    const body_owned = try self.allocator.dupe(u8, body);
    errdefer self.allocator.free(body_owned);
    const expanded_owned = try expansion.resolve_step_string(self, body, vars);
    errdefer self.allocator.free(expanded_owned);
    return .{
        .name = name_owned,
        .body = body_owned,
        .expanded_body = expanded_owned,
    };
}

fn extract_helper_definitions(self: PkgbuildParser, content: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(self.allocator);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const name = functionName(line) orelse continue;
        if (isExecutionFunction(name)) continue;
        const body = try function_body.extract_function_body(content, name) orelse continue;
        try output.appendSlice(self.allocator, name);
        try output.appendSlice(self.allocator, "() {\n");
        try output.appendSlice(self.allocator, body);
        try output.appendSlice(self.allocator, "\n}\n");
    }
    return output.toOwnedSlice(self.allocator);
}

fn functionName(line: []const u8) ?[]const u8 {
    var rest = std.mem.trimStart(u8, line, " \t\r");
    if (std.mem.startsWith(u8, rest, "function "))
        rest = std.mem.trimStart(u8, rest["function ".len..], " \t");
    var end: usize = 0;
    while (end < rest.len and (shell_scan.is_word(rest[end]) or rest[end] == '-')) : (end += 1) {}
    if (end == 0) return null;
    const name = rest[0..end];
    rest = std.mem.trimStart(u8, rest[end..], " \t");
    if (!std.mem.startsWith(u8, rest, "()")) return null;
    rest = std.mem.trimStart(u8, rest[2..], " \t");
    if (rest.len == 0 or rest[0] != '{') return null;
    return name;
}

fn isExecutionFunction(name: []const u8) bool {
    if (std.mem.eql(u8, name, "verify")) return true;
    for (execution_step_functions) |known|
        if (std.mem.eql(u8, name, known)) return true;
    return std.mem.startsWith(u8, name, "package_");
}

/// Builds the variable environment visible to makepkg execution steps:
/// the PKGBUILD's own assignments (already fixpoint-resolved by
/// build_var_hashmap) plus the makepkg built-ins that are statically
/// knowable at parse time. The returned map owns all keys and values;
/// the caller must free them.
fn build_step_env(
    self: PkgbuildParser,
    content: []const u8,
    vars: *const std.StringHashMap([]const u8),
    base_dir: ?[]const u8,
    selected_package: ?[]const u8,
) !std.StringHashMap([]const u8) {
    var env = std.StringHashMap([]const u8).init(self.allocator);
    errdefer variables.free_vars(self.allocator, &env);

    var var_it = vars.iterator();
    while (var_it.next()) |entry| {
        try put_env_entry(self, &env, entry.key_ptr.*, entry.value_ptr.*);
    }

    try put_env_entry(self, &env, "CARCH", self.package_carch);

    // makepkg defaults pkgbase to the first pkgname element when unset.
    if (!env.contains("pkgbase")) {
        const names = try arrays.parse_array(self, content, "pkgname");
        defer {
            for (names) |item| self.allocator.free(item);
            self.allocator.free(names);
        }
        const fallback = if (names.len > 0) names[0] else env.get("pkgname");
        if (fallback) |value| try put_env_entry(self, &env, "pkgbase", value);
    }

    if (selected_package) |name| try put_env_entry(self, &env, "pkgname", name);

    if (base_dir) |dir| {
        try put_env_entry(self, &env, "startdir", dir);

        const srcdir = try std.fs.path.join(self.allocator, &.{ dir, "src" });
        defer self.allocator.free(srcdir);
        try put_env_entry(self, &env, "srcdir", srcdir);

        const pkgname = env.get("pkgname") orelse "";
        const pkgdir = if (pkgname.len > 0)
            try std.fs.path.join(self.allocator, &.{ dir, "pkg", pkgname })
        else
            try std.fs.path.join(self.allocator, &.{ dir, "pkg" });
        defer self.allocator.free(pkgdir);
        try put_env_entry(self, &env, "pkgdir", pkgdir);
    }

    return env;
}

fn put_env_entry(
    self: PkgbuildParser,
    env: *std.StringHashMap([]const u8),
    key: []const u8,
    value: []const u8,
) !void {
    const key_owned = try self.allocator.dupe(u8, key);
    errdefer self.allocator.free(key_owned);
    const value_owned = try self.allocator.dupe(u8, value);
    errdefer self.allocator.free(value_owned);

    if (env.fetchRemove(key_owned)) |old| {
        self.allocator.free(old.key);
        self.allocator.free(old.value);
    }
    try env.put(key_owned, value_owned);
}

fn array_assignment_name(line: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < line.len and shell_scan.is_word(line[pos])) : (pos += 1) {}
    if (pos == 0) return null;
    const name = line[0..pos];
    if (pos < line.len and line[pos] == '+') pos += 1;
    if (pos >= line.len or line[pos] != '=') return null;
    pos += 1;
    if (pos >= line.len or line[pos] != '(') return null;
    return name;
}
