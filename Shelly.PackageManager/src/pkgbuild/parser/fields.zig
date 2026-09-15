//! Resolution of PKGBUILD metadata fields, including architecture
//! suffixes and package_-scoped overrides.
const std = @import("std");
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

pub fn resolve_array_field(self: PkgbuildParser, content: []const u8, vars: *std.StringHashMap([]const u8), var_name: []const u8) ![][]const u8 {
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

/// Expand each array assignment against the scalar state at that assignment,
/// rather than against later reassignments in the final variable map.
fn resolve_static_array(self: PkgbuildParser, content: []const u8, _: *std.StringHashMap([]const u8), name: []const u8) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (result.items) |item| self.allocator.free(item);
        result.deinit(self.allocator);
    }
    var assignments = @import("word.zig").Assignments{ .input = content };
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
        const expanded = try dependencies.resolve_variable_references(at_assignment, content[0..assignment.offset], &vars, raw);
        defer self.allocator.free(expanded);
        if (!assignment.append) {
            // Deferred source keys borrow these result strings.
            for (result.items) |item| {
                if (self.deferred_source_words) |deferred| _ = deferred.remove(@intFromPtr(item.ptr));
                self.allocator.free(item);
            }
            result.clearRetainingCapacity();
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
        const resolved = try dependencies.resolve_variable_references(self, content, &scoped_vars, raw_items);
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
