//! Resolution of PKGBUILD metadata fields, including architecture
//! suffixes and package_-scoped overrides.
const std = @import("std");
const shell_word = @import("word.zig");
const parser_diagnostic = @import("diagnostic.zig");
const function_body = @import("function_body.zig");
const variables = @import("variables.zig");
const expansion = @import("expansion.zig");
const arrays = @import("arrays.zig");
const dependencies = @import("dependencies.zig");
const PkgbuildParser = @import("parser.zig").PkgbuildParser;

const FileAssignment = struct {
    value: []const u8,
    package_scoped: bool,
    unresolved: bool = false,
};

pub fn resolve_file_assignment(
    self: PkgbuildParser,
    content: []const u8,
    vars: *const std.StringHashMap([]const u8),
    field_name: []const u8,
) !?FileAssignment {
    const unresolved = if (self.unresolved_variables) |names| names.contains(field_name) else false;
    var assignment: ?FileAssignment = if (vars.get(field_name)) |value|
        .{
            .value = try self.allocator.dupe(u8, value),
            .package_scoped = false,
            .unresolved = unresolved,
        }
    else if (unresolved)
        .{ .value = try self.allocator.dupe(u8, ""), .package_scoped = false, .unresolved = true }
    else
        null;
    errdefer if (assignment) |current| self.allocator.free(current.value);

    if (try resolve_scoped_scalar(self, content, vars, field_name)) |value| {
        if (assignment) |current| self.allocator.free(current.value);
        assignment = .{ .value = value.value, .package_scoped = true, .unresolved = value.unresolved };
    }

    return assignment;
}

/// Empty optional file selections mean no auxiliary file, as in makepkg.
/// Keep SRCINFO serialization on the raw string resolver.
pub fn resolve_optional_file_string(
    self: PkgbuildParser,
    assignment: FileAssignment,
    vars: *std.StringHashMap([]const u8),
) !?[]const u8 {
    const resolved = try resolve_file_string(self, assignment, vars);
    if (resolved.len == 0) {
        self.allocator.free(resolved);
        return null;
    }
    return resolved;
}

pub fn resolve_file_string(
    self: PkgbuildParser,
    assignment: FileAssignment,
    vars: *std.StringHashMap([]const u8),
) ![]const u8 {
    _ = vars;
    if (assignment.unresolved) return error.UnresolvedPkgbuildVariable;
    return self.allocator.dupe(u8, assignment.value);
}

fn resolve_scoped_scalar(
    context: PkgbuildParser,
    content: []const u8,
    vars: *const std.StringHashMap([]const u8),
    field: []const u8,
) !?expansion.WordValue {
    const body = try function_body.selected_package_body_with_vars(context, content, vars) orelse return null;
    if (try variables.parse_variable(body, field) == null) return null;
    var unresolved = std.StringHashMap(void).init(context.allocator);
    defer unresolved.deinit();
    if (context.unresolved_variables) |global| {
        var it = global.keyIterator();
        while (it.next()) |key| try unresolved.put(key.*, {});
    }
    var self = context;
    self.unresolved_variables = &unresolved;
    // Global shell snapshots cannot override package-local assignments.
    self.dynamic_overrides = null;
    self.dynamic_unsets = null;
    self.array_reference_content = content;
    var scoped = std.StringHashMap([]const u8).init(self.allocator);
    defer variables.free_vars(self.allocator, &scoped);
    var it = vars.iterator();
    while (it.next()) |entry| {
        const key = try self.allocator.dupe(u8, entry.key_ptr.*);
        errdefer self.allocator.free(key);
        const value = try self.allocator.dupe(u8, entry.value_ptr.*);
        errdefer self.allocator.free(value);
        try scoped.put(key, value);
    }
    if (self.selected_package_name) |name| {
        if (scoped.getPtr("pkgname")) |value| {
            const owned = try self.allocator.dupe(u8, name);
            self.allocator.free(value.*);
            value.* = owned;
        }
    }
    try variables.apply_assignments(self, body, &scoped);
    return .{ .value = try self.allocator.dupe(u8, scoped.get(field) orelse ""), .unresolved = unresolved.contains(field) };
}

pub fn resolve_array_field(self: PkgbuildParser, content: []const u8, vars: *std.StringHashMap([]const u8), var_name: []const u8) anyerror![][]const u8 {
    if (self.dynamic_array_unsets) |unsets| if (unsets.contains(var_name))
        return self.allocator.alloc([]const u8, 0);
    if (self.dynamic_array_overrides) |overrides| if (overrides.get(var_name)) |items| {
        const cloned = try self.allocator.alloc([]const u8, items.len);
        errdefer self.allocator.free(cloned);
        var cloned_count: usize = 0;
        errdefer for (cloned[0..cloned_count]) |item| self.allocator.free(item);
        for (items, cloned) |item, *destination| {
            destination.* = try self.allocator.dupe(u8, item);
            cloned_count += 1;
        }
        return cloned;
    };
    return resolve_static_array(self, content, vars, var_name);
}

/// Return owned element data, or null when its value still needs reviewed
/// evaluation. A known empty/out-of-range element is the empty string.
pub fn resolve_array_element(self: PkgbuildParser, vars: *std.StringHashMap([]const u8), name: []const u8, index: usize) anyerror!?[]const u8 {
    if (self.dynamic_array_unsets) |unsets| if (unsets.contains(name)) return try self.allocator.dupe(u8, "");
    if (self.dynamic_unsets) |unsets| if (unsets.contains(name)) return try self.allocator.dupe(u8, "");
    if (self.dynamic_array_overrides) |overrides| if (overrides.get(name)) |items| {
        if (items.len > 4096) return error.ArrayExpansionTooLarge;
        return try self.allocator.dupe(u8, if (index < items.len) items[index] else "");
    };
    if (self.dynamic_overrides) |overrides| if (overrides.get(name)) |value|
        return try self.allocator.dupe(u8, if (index == 0) value else "");
    const content = self.array_reference_content orelse return null;
    var has_array = false;
    var has_scalar = false;
    var uncertain = false;
    var assignments = shell_word.Assignments{ .input = content, .include_indexed = true };
    while (try assignments.next(self.allocator)) |assignment| {
        if (!std.mem.eql(u8, assignment.name, name)) continue;
        if (assignment.indexed) return error.UnsupportedArrayExpansion;
        if (assignment.deferred) {
            uncertain = true;
            continue;
        }
        if (!std.mem.startsWith(u8, assignment.raw, "(")) {
            // Scalar writes to an existing array mutate element zero rather
            // than replacing the array. Do not resolve a stale dense snapshot.
            if (has_array) return error.UnsupportedArrayExpansion;
            has_scalar = true;
            continue;
        }
        if (assignment.append and has_scalar and !has_array) return error.UnsupportedArrayExpansion;
        has_array = true;
        if (!assignment.append) uncertain = false;
        const raw = try arrays.parse_array_body_syntax(self.allocator, assignment.raw[1 .. assignment.raw.len - 1]);
        defer variables.freeStringSlice(self.allocator, raw);
        for (raw) |item| {
            // Explicit subscripts can create holes; the dense array resolver
            // cannot preserve their indices. Quoted bytes remain literal data.
            if (std.mem.startsWith(u8, item, "[") and std.mem.indexOf(u8, item, "]=") != null)
                return error.UnsupportedArrayExpansion;
        }
    }
    if (uncertain) return null;
    if (!has_array) {
        if (self.unresolved_variables) |unresolved| if (unresolved.contains(name)) return null;
        const value = vars.get(name) orelse return null;
        return try self.allocator.dupe(u8, if (index == 0) value else "");
    }
    if (self.array_expansion_depth >= 32) return error.ArrayExpansionTooDeep;
    // Track provenance even in scalar assignments, which have no outer source
    // tracking map. Never infer unresolved state from the returned bytes.
    var deferred = std.AutoHashMap(usize, void).init(self.allocator);
    defer deferred.deinit();
    var nested = self;
    nested.array_expansion_depth += 1;
    nested.deferred_source_words = &deferred;
    const items = try resolve_array_field(nested, content, vars, name);
    defer variables.freeStringSlice(self.allocator, items);
    if (index >= items.len) return try self.allocator.dupe(u8, "");
    if (deferred.contains(@intFromPtr(items[index].ptr))) return null;
    return try self.allocator.dupe(u8, items[index]);
}

fn resolve_array_values(self: PkgbuildParser, content: []const u8, vars: *std.StringHashMap([]const u8), name: []const u8, items: [][]const u8) ![][]const u8 {
    // Dependency cleanup must never reinterpret generic array values as
    // version constraints (for example a literal filename ending in '=').
    for ([_][]const u8{ "depends", "makedepends", "checkdepends", "optdepends", "provides", "conflicts", "replaces" }) |field| {
        if (std.mem.eql(u8, name, field) or
            (name.len > field.len and std.mem.startsWith(u8, name, field) and name[field.len] == '_'))
            return dependencies.resolve_variable_references(self, content, vars, items);
    }
    return dependencies.resolve_array_values(self, content, vars, items);
}

test "static array references bound nesting and expanded element count" {
    const allocator = std.testing.allocator;
    const parser = PkgbuildParser{ .allocator = allocator, .io = std.testing.io };
    var vars = std.StringHashMap([]const u8).init(allocator);
    defer vars.deinit();
    var deep: std.Io.Writer.Allocating = .init(allocator);
    defer deep.deinit();
    try deep.writer.writeAll("a0=(path/value)\n");
    for (1..35) |index| try deep.writer.print("a{d}=(\"${{a{d}[@]##*/}}\")\n", .{ index, index - 1 });
    try std.testing.expectError(error.ArrayExpansionTooDeep, resolve_array_field(parser, deep.written(), &vars, "a34"));

    var large: std.Io.Writer.Allocating = .init(allocator);
    defer large.deinit();
    try large.writer.writeAll("a0=(value)\n");
    for (1..14) |index| try large.writer.print("a{d}=(\"${{a{d}[@]}}\" \"${{a{d}[@]}}\")\n", .{ index, index - 1, index - 1 });
    try std.testing.expectError(error.ArrayExpansionTooLarge, resolve_array_field(parser, large.written(), &vars, "a13"));

    var indexed: std.Io.Writer.Allocating = .init(allocator);
    defer indexed.deinit();
    try indexed.writer.writeAll("a0=(value)\n");
    for (1..35) |index| try indexed.writer.print("a{d}=(\"${{a{d}[0]}}\")\n", .{ index, index - 1 });
    try std.testing.expectError(error.ArrayExpansionTooDeep, resolve_array_field(parser, indexed.written(), &vars, "a34"));
}

/// Expand each array assignment against the scalar state at that assignment,
/// rather than against later reassignments in the final variable map.
fn resolve_static_array(self: PkgbuildParser, content: []const u8, _: *std.StringHashMap([]const u8), name: []const u8) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (result.items) |item| self.allocator.free(item);
        result.deinit(self.allocator);
    }
    var assignments = shell_word.Assignments{ .input = content };
    while (try assignments.next(self.allocator)) |assignment| {
        if (!std.mem.eql(u8, assignment.name, name) or assignment.deferred or !std.mem.startsWith(u8, assignment.raw, "(")) continue;
        var unresolved = std.StringHashMap(void).init(self.allocator);
        defer unresolved.deinit();
        var at_assignment = self;
        at_assignment.unresolved_variables = &unresolved;
        var vars = try variables.build_var_hashmap(at_assignment, content[0..assignment.offset]);
        defer variables.free_vars(self.allocator, &vars);
        const raw = try arrays.parse_array_body_syntax(self.allocator, assignment.raw[1 .. assignment.raw.len - 1]);
        defer variables.freeStringSlice(self.allocator, raw);
        const expanded = resolve_array_values(at_assignment, content[0..assignment.offset], &vars, name, raw) catch |err| {
            if (self.diagnostic) |destination| if (destination.* == null) {
                destination.* = parser_diagnostic.Diagnostic.init(
                    self.allocator,
                    content[0 .. @intFromPtr(assignment.raw.ptr) - @intFromPtr(content.ptr) + assignment.raw.len],
                    self.pkgbuild_path,
                    self.selected_package_name orelse vars.get("pkgname") orelse "unknown",
                    name,
                    null,
                    err,
                ) catch null;
            };
            return err;
        };
        defer self.allocator.free(expanded);
        if (!assignment.append) {
            // Deferred source keys borrow these result strings.
            for (result.items) |item| {
                if (self.deferred_source_words) |deferred| _ = deferred.remove(@intFromPtr(item.ptr));
                self.allocator.free(item);
            }
            result.clearRetainingCapacity();
        }
        if (result.items.len + expanded.len > 4096) {
            for (expanded) |item| self.allocator.free(item);
            return error.ArrayExpansionTooLarge;
        }
        result.appendSlice(self.allocator, expanded) catch |err| {
            for (expanded) |item| self.allocator.free(item);
            return err;
        };
    }
    return result.toOwnedSlice(self.allocator);
}

fn resolve_array_field_preserving_commands(
    self: PkgbuildParser,
    content: []const u8,
    vars: *std.StringHashMap([]const u8),
    var_name: []const u8,
) ![][]const u8 {
    if (self.dynamic_array_unsets) |unsets| if (unsets.contains(var_name))
        return self.allocator.alloc([]const u8, 0);
    if (self.dynamic_array_overrides) |overrides| if (overrides.get(var_name)) |items| {
        const cloned = try self.allocator.alloc([]const u8, items.len);
        errdefer self.allocator.free(cloned);
        var cloned_count: usize = 0;
        errdefer for (cloned[0..cloned_count]) |item| self.allocator.free(item);
        for (items, cloned) |item, *destination| {
            destination.* = try self.allocator.dupe(u8, item);
            cloned_count += 1;
        }
        return cloned;
    };
    return resolve_static_array(self, content, vars, var_name);
}

/// Initial-analysis source resolution keeps command substitutions as inert
/// text. That lets source classification ignore only the unresolved entry
/// instead of turning its truncated prefix into a bogus local file.
pub fn resolve_dynamic_source_array_field(
    self: PkgbuildParser,
    content: []const u8,
    vars: *std.StringHashMap([]const u8),
) ![][]const u8 {
    const generic = try resolve_array_field_preserving_commands(self, content, vars, "source");
    errdefer variables.freeStringSlice(self.allocator, generic);
    const arch_name = try std.fmt.allocPrint(self.allocator, "source_{s}", .{self.package_carch});
    defer self.allocator.free(arch_name);
    const architecture = try resolve_array_field_preserving_commands(self, content, vars, arch_name);
    errdefer variables.freeStringSlice(self.allocator, architecture);

    const combined = try self.allocator.alloc([]const u8, generic.len + architecture.len);
    @memcpy(combined[0..generic.len], generic);
    @memcpy(combined[generic.len..], architecture);
    self.allocator.free(generic);
    self.allocator.free(architecture);
    return combined;
}

/// makepkg appends the active architecture's array to the generic array
/// and requires the checksum arrays to follow the same ordering.
pub fn resolve_arch_array_field(
    self: PkgbuildParser,
    content: []const u8,
    vars: *std.StringHashMap([]const u8),
    var_name: []const u8,
) ![][]const u8 {
    const generic = try resolve_array_field(self, content, vars, var_name);
    errdefer variables.freeStringSlice(self.allocator, generic);
    const arch_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ var_name, self.package_carch });
    defer self.allocator.free(arch_name);
    const architecture = try resolve_array_field(self, content, vars, arch_name);
    errdefer variables.freeStringSlice(self.allocator, architecture);

    const combined = try self.allocator.alloc([]const u8, generic.len + architecture.len);
    @memcpy(combined[0..generic.len], generic);
    @memcpy(combined[generic.len..], architecture);
    self.allocator.free(generic);
    self.allocator.free(architecture);
    return combined;
}

fn package_scoped_vars(
    self: PkgbuildParser,
    vars: *const std.StringHashMap([]const u8),
) !std.StringHashMap([]const u8) {
    var scoped = std.StringHashMap([]const u8).init(self.allocator);
    errdefer scoped.deinit();
    var iterator = vars.iterator();
    while (iterator.next()) |entry|
        try scoped.put(entry.key_ptr.*, entry.value_ptr.*);
    if (self.selected_package_name) |name| try scoped.put("pkgname", name);
    return scoped;
}

pub fn resolve_package_string_field(
    self: PkgbuildParser,
    content: []const u8,
    vars: *std.StringHashMap([]const u8),
    var_name: []const u8,
) !?[]const u8 {
    var result: ?[]const u8 = if (vars.get(var_name)) |value|
        try self.allocator.dupe(u8, value)
    else
        null;
    errdefer if (result) |value| self.allocator.free(value);

    const resolved = try resolve_scoped_scalar(self, content, vars, var_name) orelse return result;
    if (result) |old| self.allocator.free(old);
    result = resolved.value;
    return result;
}

pub fn resolve_package_array_field(
    self: PkgbuildParser,
    content: []const u8,
    vars: *std.StringHashMap([]const u8),
    var_name: []const u8,
) ![][]const u8 {
    const global = try resolve_array_field(self, content, vars, var_name);
    var global_owned = true;
    errdefer if (global_owned) variables.freeStringSlice(self.allocator, global);
    const body = try function_body.selected_package_body_with_vars(self, content, vars) orelse return global;

    var values: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (values.items) |value| self.allocator.free(value);
        values.deinit(self.allocator);
    }
    try values.appendSlice(self.allocator, global);
    self.allocator.free(global);
    global_owned = false;

    var scoped_vars = try package_scoped_vars(self, vars);
    defer scoped_vars.deinit();
    var search_from: usize = 0;
    while (arrays.find_next_scoped_array_start(body, var_name, search_from)) |assignment| {
        const scanned = try arrays.scan_array_body(self.allocator, body, assignment.after_paren);
        defer self.allocator.free(scanned.body);
        search_from = scanned.end;
        if (!assignment.append) {
            for (values.items) |value| self.allocator.free(value);
            values.clearRetainingCapacity();
        }

        const raw_items = try arrays.parse_array_body_syntax(self.allocator, scanned.body);
        defer variables.freeStringSlice(self.allocator, raw_items);
        const resolved = try resolve_array_values(self, content, &scoped_vars, var_name, raw_items);
        defer self.allocator.free(resolved);
        try values.appendSlice(self.allocator, resolved);
    }

    return values.toOwnedSlice(self.allocator);
}

pub fn resolve_effective_architecture_field(
    self: PkgbuildParser,
    content: []const u8,
    vars: *std.StringHashMap([]const u8),
) ![][]const u8 {
    const effective = try resolve_package_array_field(self, content, vars, "arch");
    if (effective.len > 0) return effective;
    self.allocator.free(effective);
    return resolve_array_field(self, content, vars, "arch");
}
