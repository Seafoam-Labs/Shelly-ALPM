//! makepkg semantic validation: package names, xdata, architecture
//! directives, and package function shape.
const std = @import("std");
const package_metadata = @import("../package_metadata.zig");
const types = @import("types.zig");
const shell_scan = @import("shell_scan.zig");
const function_body = @import("function_body.zig");
const fields = @import("fields.zig");
const variables = @import("variables.zig");
const PkgbuildParser = @import("parser.zig").PkgbuildParser;

pub fn has_forbidden_package_assignment(
    self: PkgbuildParser,
    content: []const u8,
    vars: *const std.StringHashMap([]const u8),
) !bool {
    const body = (try function_body.selected_package_body(self, content)) orelse blk: {
        if (try function_body.extract_function_body(content, "package")) |generic| break :blk generic;
        const package_name = vars.get("pkgname") orelse return false;
        const function_name = try std.fmt.allocPrint(self.allocator, "package_{s}", .{package_name});
        defer self.allocator.free(function_name);
        break :blk (try function_body.extract_function_body(content, function_name)) orelse return false;
    };
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const name = direct_assignment_name(line) orelse continue;
        if (package_metadata.isForbiddenPackageAssignment(name, self.package_carch))
            return true;
    }
    return false;
}

fn direct_assignment_name(line: []const u8) ?[]const u8 {
    var rest = std.mem.trimStart(u8, line, " \t\r");
    if (std.mem.startsWith(u8, rest, "declare")) {
        rest = rest["declare".len..];
        if (rest.len == 0 or !std.ascii.isWhitespace(rest[0])) return null;
        rest = std.mem.trimStart(u8, rest, " \t");
        while (rest.len > 0 and rest[0] == '-') {
            const end = std.mem.indexOfAny(u8, rest, " \t") orelse return null;
            rest = std.mem.trimStart(u8, rest[end..], " \t");
        }
    }
    var end: usize = 0;
    while (end < rest.len and shell_scan.is_word(rest[end])) : (end += 1) {}
    if (end == 0) return null;
    const name = rest[0..end];
    if (end < rest.len and rest[end] == '+') end += 1;
    if (end >= rest.len or rest[end] != '=') return null;
    return name;
}

pub fn validate_selected_package(
    self: PkgbuildParser,
    content: []const u8,
    vars: *std.StringHashMap([]const u8),
) !void {
    const selected = self.selected_package_name orelse return;
    const names = try fields.resolve_array_field(self, content, vars, "pkgname");
    defer variables.freeStringSlice(self.allocator, names);
    if (names.len > 0) {
        for (names) |name| if (std.mem.eql(u8, name, selected)) return;
        return error.SelectedPackageNotFound;
    }
    if (vars.get("pkgname")) |name|
        if (std.mem.eql(u8, name, selected)) return;
    return error.SelectedPackageNotFound;
}

pub fn validate_architecture_directives(
    self: PkgbuildParser,
    content: []const u8,
    vars: *std.StringHashMap([]const u8),
) !void {
    const global = try fields.resolve_array_field(self, content, vars, "arch");
    defer variables.freeStringSlice(self.allocator, global);
    if (global.len == 0) return error.InvalidArchitectureDirective;
    try validate_architecture_entries(global);
    if (!types.contains_string(global, "any") and !types.contains_string(global, self.package_carch))
        return error.UnsupportedArchitecture;

    const names = try fields.resolve_array_field(self, content, vars, "pkgname");
    defer variables.freeStringSlice(self.allocator, names);
    if (names.len > 0) {
        for (names) |name|
            try validate_package_architecture_override(self, content, vars, global, name);
    } else if (vars.get("pkgname")) |name| {
        try validate_package_architecture_override(self, content, vars, global, name);
    }
}

fn validate_package_architecture_override(
    self: PkgbuildParser,
    content: []const u8,
    vars: *std.StringHashMap([]const u8),
    global: []const []const u8,
    package_name: []const u8,
) !void {
    var package_parser = self;
    package_parser.selected_package_name = package_name;
    const override = try fields.resolve_package_array_field(package_parser, content, vars, "arch");
    defer variables.freeStringSlice(self.allocator, override);
    if (override.len == 0) return;

    try validate_architecture_entries(override);
    if (types.contains_string(override, "any")) return;
    for (override) |architecture|
        if (!types.contains_string(global, architecture))
            return error.InvalidArchitectureDirective;
}

fn validate_architecture_entries(architectures: []const []const u8) !void {
    if (types.contains_string(architectures, "any") and architectures.len != 1)
        return error.InvalidArchitectureDirective;
    for (architectures, 0..) |architecture, index| {
        for (architecture) |byte|
            if (!std.ascii.isAlphanumeric(byte) and byte != '_')
                return error.InvalidArchitectureDirective;
        for (architectures[0..index]) |earlier|
            if (std.mem.eql(u8, earlier, architecture))
                return error.InvalidArchitectureDirective;
    }
}

const PackageFunctionState = struct {
    is_split: bool,
    has_generic: bool,
    has_selected: bool,
    has_build: bool,
    has_complete_split: bool,
};

/// Records the package-function shape without turning the data parser into
/// a linter. PackageBuilder enforces this state immediately before any
/// PKGBUILD code is executed.
pub fn inspect_package_functions(
    self: PkgbuildParser,
    content: []const u8,
    vars: *std.StringHashMap([]const u8),
) !PackageFunctionState {
    var names = try fields.resolve_array_field(self, content, vars, "pkgname");
    defer variables.freeStringSlice(self.allocator, names);
    if (names.len == 0) {
        const scalar = vars.get("pkgname") orelse return .{
            .is_split = false,
            .has_generic = (try function_body.extract_function_body(content, "package")) != null,
            .has_selected = false,
            .has_build = (try function_body.extract_function_body(content, "build")) != null,
            .has_complete_split = true,
        };
        const scalar_names = try self.allocator.alloc([]const u8, 1);
        scalar_names[0] = self.allocator.dupe(u8, scalar) catch |err| {
            self.allocator.free(scalar_names);
            return err;
        };
        self.allocator.free(names);
        names = scalar_names;
    }
    try validate_package_names(names);

    const has_generic = (try function_body.extract_function_body(content, "package")) != null;
    const selected_name = self.selected_package_name orelse names[0];
    const function_name = try std.fmt.allocPrint(self.allocator, "package_{s}", .{selected_name});
    defer self.allocator.free(function_name);
    const has_scoped = (try function_body.extract_function_body(content, function_name)) != null;
    var has_complete_split = true;
    if (names.len > 1) for (names) |name| {
        const member_function = try std.fmt.allocPrint(self.allocator, "package_{s}", .{name});
        defer self.allocator.free(member_function);
        if ((try function_body.extract_function_body(content, member_function)) == null)
            has_complete_split = false;
    };
    return .{
        .is_split = names.len > 1,
        .has_generic = has_generic,
        .has_selected = has_scoped,
        .has_build = (try function_body.extract_function_body(content, "build")) != null,
        .has_complete_split = has_complete_split,
    };
}

pub fn validate_package_names(names: [][]const u8) !void {
    for (names, 0..) |name, index| {
        if (name.len == 0) return error.MissingPackageName;
        for (names[0..index]) |earlier|
            if (std.mem.eql(u8, earlier, name)) return error.DuplicatePackageName;
    }
}

pub fn validate_xdata(values: []const []const u8) !void {
    for (values) |value| {
        const separator = std.mem.indexOfScalar(u8, value, '=') orelse
            return error.InvalidPackageXdata;
        if (separator == 0 or
            std.mem.indexOfScalar(u8, value[separator + 1 ..], '=') != null or
            std.mem.eql(u8, value[0..separator], "pkgtype"))
            return error.InvalidPackageXdata;
    }
}
