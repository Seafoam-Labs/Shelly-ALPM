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
    value: []u8,
    package_scoped: bool,
};

pub fn resolve_file_assignment(
    self: PkgbuildParser,
    content: []const u8,
    vars: *const std.StringHashMap([]const u8),
    field_name: []const u8,
) !?FileAssignment {
    var assignment: ?FileAssignment = if (vars.get(field_name)) |value|
        .{
            .value = try self.allocator.dupe(u8, value),
            .package_scoped = false,
        }
    else
        null;
    errdefer if (assignment) |current| self.allocator.free(current.value);

    if (try function_body.selected_package_body_with_vars(self, content, vars)) |body| {
        if (try variables.parse_variable(body, field_name)) |value| {
            const owned_value = try self.allocator.dupe(u8, value);
            if (assignment) |current| self.allocator.free(current.value);
            assignment = .{
                .value = owned_value,
                .package_scoped = true,
            };
        }
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
    const resolved = if (assignment.package_scoped) blk: {
        const package_name = self.selected_package_name orelse
            return error.MissingSelectedPackageName;
        var scoped_vars = std.StringHashMap([]const u8).init(self.allocator);
        defer scoped_vars.deinit();

        var iterator = vars.iterator();
        while (iterator.next()) |entry|
            try scoped_vars.put(entry.key_ptr.*, entry.value_ptr.*);
        try scoped_vars.put("pkgname", package_name);

        break :blk try expansion.resolve_string(self, assignment.value, &scoped_vars);
    } else try expansion.resolve_string(self, assignment.value, vars);
    errdefer self.allocator.free(resolved);

    if (std.mem.indexOfScalar(u8, resolved, '$') != null)
        return error.UnresolvedPkgbuildVariable;
    return resolved;
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
    const raw = try arrays.parse_array(self, content, var_name);
    defer {
        for (raw) |it| self.allocator.free(it);
        self.allocator.free(raw);
    }
    return dependencies.resolve_variable_references(self, content, vars, raw);
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
    const raw = try arrays.parse_array(self, content, var_name);
    defer variables.freeStringSlice(self.allocator, raw);
    return dependencies.resolve_variable_references_preserving_commands(self, content, vars, raw);
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

    const body = try function_body.selected_package_body_with_vars(self, content, vars) orelse return result;
    var lines = std.mem.splitScalar(u8, body, '\n');
    var scoped_value: ?[]const u8 = null;
    while (lines.next()) |line| {
        if (try variables.parse_variable(line, var_name)) |value| scoped_value = value;
    }
    const raw = scoped_value orelse return result;

    var scoped_vars = try package_scoped_vars(self, vars);
    defer scoped_vars.deinit();
    const resolved = try expansion.resolve_string(self, raw, &scoped_vars);
    if (result) |old| self.allocator.free(old);
    result = resolved;
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

        const raw_items = try arrays.parse_array_body_items(self.allocator, scanned.body);
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
