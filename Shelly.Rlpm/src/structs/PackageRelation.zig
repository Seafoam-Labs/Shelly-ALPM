//! Relations borrow strings. parse performs no allocation; clone owns all strings
//! and must be paired with deinit. Constraint versions are intentionally raw.
const std = @import("std");
const Version = @import("Version.zig");

const PackageRelation = @This();

pub const Constraint = union(enum) {
    any,
    equal: []const u8,
    greater_equal: []const u8,
    less_equal: []const u8,
    greater: []const u8,
    less: []const u8,
};
name: []const u8,
constraint: Constraint = .any,
description: ?[]const u8 = null,

/// Follows alpm_dep_from_string, including empty names/versions and descriptions
/// in every relation family. Embedded NUL cannot be represented by the C API.
pub fn parse(value: []const u8) !PackageRelation {
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidPackageRelation;
    const end = std.mem.indexOf(u8, value, ": ") orelse value.len;
    const specification = value[0..end];
    var result: PackageRelation = .{
        .name = specification,
        .description = if (end != value.len) value[end + 2 ..] else null,
    };
    // Comparator precedence is '<', then '>', then '='; it is not the first
    // comparator in the string, nor a longest-token-first search.
    for ([_]u8{ '<', '>', '=' }) |operator| {
        const index = std.mem.indexOfScalar(u8, specification, operator) orelse continue;
        result.name = specification[0..index];
        const inclusive = operator != '=' and index + 1 < specification.len and
            specification[index + 1] == '=';
        const version = specification[index + (if (inclusive) @as(usize, 2) else 1) ..];
        result.constraint = switch (operator) {
            '<' => if (inclusive) .{ .less_equal = version } else .{ .less = version },
            '>' => if (inclusive) .{ .greater_equal = version } else .{ .greater = version },
            '=' => .{ .equal = version },
            else => unreachable,
        };
        break;
    }
    return result;
}

pub fn clone(self: PackageRelation, allocator: std.mem.Allocator) !PackageRelation {
    if (std.mem.indexOfScalar(u8, self.name, 0) != null) return error.InvalidPackageRelation;
    if (self.description) |value|
        if (std.mem.indexOfScalar(u8, value, 0) != null)
            return error.InvalidPackageRelation;
    switch (self.constraint) {
        .any => {},
        inline else => |value| if (std.mem.indexOfScalar(u8, value, 0) != null)
            return error.InvalidPackageRelation,
    }
    const name = try allocator.dupe(u8, self.name);
    errdefer allocator.free(name);
    const description = if (self.description) |value| try allocator.dupe(u8, value) else null;
    errdefer if (description) |value| allocator.free(value);
    return .{
        .name = name,
        .description = description,
        .constraint = switch (self.constraint) {
            .any => .any,
            inline else => |value, tag| @unionInit(Constraint, @tagName(tag), try allocator.dupe(u8, value)),
        },
    };
}

/// Only for a relation returned by clone, never a borrowed parse result.
pub fn deinit(self: *PackageRelation, allocator: std.mem.Allocator) void {
    allocator.free(self.name);
    if (self.description) |value| allocator.free(value);
    switch (self.constraint) {
        .any => {},
        inline else => |value| allocator.free(value),
    }
    self.* = undefined;
}

pub fn format(self: PackageRelation, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(self.name);
    switch (self.constraint) {
        .any => {},
        inline else => |value, tag| {
            const operator = switch (tag) {
                .equal => "=",
                .greater_equal => ">=",
                .less_equal => "<=",
                .greater => ">",
                .less => "<",
                .any => unreachable,
            };
            try writer.print("{s}{s}", .{ operator, value });
        },
    }
    if (self.description) |value| try writer.print(": {s}", .{value});
}

pub fn formatAlloc(self: PackageRelation, allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{self});
}

pub fn matchesVersion(self: PackageRelation, version: []const u8) bool {
    return switch (self.constraint) {
        .any => true,
        .equal => |value| Version.compareStrings(version, value) == .equal,
        .greater_equal => |value| Version.compareStrings(version, value) != .lessThan,
        .less_equal => |value| Version.compareStrings(version, value) != .greaterThan,
        .greater => |value| Version.compareStrings(version, value) == .greaterThan,
        .less => |value| Version.compareStrings(version, value) == .lessThan,
    };
}

pub fn satisfiedBy(
    self: PackageRelation,
    name: []const u8,
    version: []const u8,
    provisions: []const PackageRelation,
) bool {
    if (std.mem.eql(u8, self.name, name) and self.matchesVersion(version)) return true;
    return self.providedBy(provisions);
}

/// Provision-only matching also handles permissively parsed empty names without
/// inventing a literal package identity for AssumeInstalled or graph edges.
pub fn providedBy(self: PackageRelation, provisions: []const PackageRelation) bool {
    for (provisions) |provision| {
        if (!std.mem.eql(u8, self.name, provision.name)) continue;
        if (self.constraint == .any) return true;
        if (provision.constraint == .equal and self.matchesVersion(provision.constraint.equal)) return true;
    }
    return false;
}

test "relation defaults and borrowed parsing preserve unusual constraints" {
    const plain: PackageRelation = .{ .name = "go" };
    try std.testing.expect(plain.constraint == .any);
    const relation = try parse("foo>1<2: description");
    try std.testing.expectEqualStrings("foo>1", relation.name);
    try std.testing.expectEqualStrings("2", relation.constraint.less);
    try std.testing.expectEqualStrings("description", relation.description.?);
    try std.testing.expectError(error.InvalidPackageRelation, parse("foo\x00bar"));
}

test "owned relation clone and formatting clean up every failed allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var relation = try (try parse("foo>=alpha:1.0: explanation")).clone(allocator);
            defer relation.deinit(allocator);
            const formatted = try relation.formatAlloc(allocator);
            defer allocator.free(formatted);
            try std.testing.expectEqualStrings("foo>=alpha:1.0: explanation", formatted);
        }
    }.run, .{});
}
