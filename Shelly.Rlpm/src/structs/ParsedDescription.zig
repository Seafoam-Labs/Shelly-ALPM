const ParsedDescription = @This();

const std = @import("std");
const Package = @import("Package.zig");
const PackageRelation = @import("PackageRelation.zig");
const Version = @import("Version.zig");

/// Temporary representation of a local database `desc` file.
///
/// String values borrow from the input buffer passed to the parser. The array
/// lists own only their backing storage, not the strings stored in them. Keep
/// the input buffer alive for as long as this value or its resulting Package is
/// in use. Database satisfies that requirement by allocating the buffer in its
/// arena.
name: ?[]const u8 = null,
version: ?[]const u8 = null,
base: ?[]const u8 = null,
description: ?[]const u8 = null,
url: ?[]const u8 = null,
architecture: ?[]const u8 = null,
build_date: ?i64 = null,
install_date: ?i64 = null,
packager: ?[]const u8 = null,
installed_size: ?u64 = null,
installed_database: ?[]const u8 = null,
reason: ?Package.InstallReason = null,
validation: Package.Validation = .{},

groups: std.ArrayList([]const u8) = .empty,
licenses: std.ArrayList([]const u8) = .empty,
depends: std.ArrayList([]const u8) = .empty,
optional_depends: std.ArrayList([]const u8) = .empty,
make_depends: std.ArrayList([]const u8) = .empty,
check_depends: std.ArrayList([]const u8) = .empty,
conflicts: std.ArrayList([]const u8) = .empty,
provides: std.ArrayList([]const u8) = .empty,
replaces: std.ArrayList([]const u8) = .empty,
xdata: std.ArrayList(Package.XData) = .empty,

/// Validates the parsed fields and converts them into a package whose owned
/// allocations use `allocator`. Borrowed strings remain valid as long as the
/// `desc` input buffer remains alive; Database keeps that buffer in its arena.
pub fn intoPackage(
    self: *ParsedDescription,
    allocator: std.mem.Allocator,
    database_name: []const u8,
) !Package {
    const name = self.name orelse return error.MissingPackageName;
    const raw_version = self.version orelse return error.MissingPackageVersion;
    if (name.len == 0) return error.MissingPackageName;

    const groups = try self.groups.toOwnedSlice(allocator);
    const licenses = try self.licenses.toOwnedSlice(allocator);
    const xdata = try self.xdata.toOwnedSlice(allocator);

    return .{
        .name = name,
        .version = try Version.init(raw_version, allocator),
        .database_name = database_name,
        .installed_database = self.installed_database,
        .base = self.base,
        .description = self.description,
        .provides = try parseRelations(allocator, self.provides.items, false),
        .depends = try parseRelations(allocator, self.depends.items, false),
        .optional_depends = try parseRelations(allocator, self.optional_depends.items, true),
        .make_depends = try parseRelations(allocator, self.make_depends.items, false),
        .check_depends = try parseRelations(allocator, self.check_depends.items, false),
        .conflicts = try parseRelations(allocator, self.conflicts.items, false),
        .replaces = try parseRelations(allocator, self.replaces.items, false),
        .install_reason = self.reason,
        .validation = self.validation,
        .url = self.url,
        .architecture = self.architecture,
        .build_date = self.build_date,
        .install_date = self.install_date,
        .installed_size = self.installed_size,
        .packager = self.packager,
        .groups = groups,
        .licenses = licenses,
        .xdata = xdata,
    };
}

/// Releases list backing storage. Borrowed strings are not freed.
pub fn deinit(self: *ParsedDescription, allocator: std.mem.Allocator) void {
    self.groups.deinit(allocator);
    self.licenses.deinit(allocator);
    self.depends.deinit(allocator);
    self.optional_depends.deinit(allocator);
    self.make_depends.deinit(allocator);
    self.check_depends.deinit(allocator);
    self.conflicts.deinit(allocator);
    self.provides.deinit(allocator);
    self.replaces.deinit(allocator);
    self.xdata.deinit(allocator);
    self.* = undefined;
}

fn parseRelations(
    allocator: std.mem.Allocator,
    values: []const []const u8,
    parse_description: bool,
) ![]PackageRelation {
    var relations: std.ArrayList(PackageRelation) = .empty;
    for (values) |value| {
        try relations.append(allocator, try parseRelation(allocator, value, parse_description));
    }
    return relations.toOwnedSlice(allocator);
}

fn parseRelation(
    allocator: std.mem.Allocator,
    value: []const u8,
    parse_description: bool,
) !PackageRelation {
    var specification = value;
    var description: ?[]const u8 = null;

    if (parse_description) {
        if (std.mem.find(u8, value, ": ")) |description_index| {
            specification = value[0..description_index];
            description = value[description_index + 2 ..];
        }
    }

    const Operator = struct {
        text: []const u8,
        kind: enum { equal, greater_equal, less_equal, greater, less },
    };
    const operators = [_]Operator{
        .{ .text = ">=", .kind = .greater_equal },
        .{ .text = "<=", .kind = .less_equal },
        .{ .text = "=", .kind = .equal },
        .{ .text = ">", .kind = .greater },
        .{ .text = "<", .kind = .less },
    };

    for (operators) |operator| {
        if (std.mem.find(u8, specification, operator.text)) |operator_index| {
            const relation_name = specification[0..operator_index];
            const relation_version = specification[operator_index + operator.text.len ..];
            if (relation_name.len == 0 or relation_version.len == 0) {
                return error.InvalidPackageRelation;
            }

            const version = try Version.init(relation_version, allocator);
            const constraint: PackageRelation.Constraint = switch (operator.kind) {
                .equal => .{ .equal = version },
                .greater_equal => .{ .greater_equal = version },
                .less_equal => .{ .less_equal = version },
                .greater => .{ .greater = version },
                .less => .{ .less = version },
            };
            return .{
                .name = relation_name,
                .constraint = constraint,
                .description = description,
            };
        }
    }

    if (specification.len == 0) return error.InvalidPackageRelation;
    return .{
        .name = specification,
        .description = description,
    };
}

test "ParsedDescription defaults to empty and releases list storage" {
    const allocator = std.testing.allocator;
    var parsed: ParsedDescription = .{};
    defer parsed.deinit(allocator);

    try parsed.groups.append(allocator, "base");
    try parsed.depends.append(allocator, "glibc>=2.39");
    try parsed.xdata.append(allocator, .{
        .name = "pkgtype",
        .value = "pkg",
    });

    try std.testing.expect(parsed.name == null);
    try std.testing.expectEqualStrings("base", parsed.groups.items[0]);
    try std.testing.expectEqualStrings("glibc>=2.39", parsed.depends.items[0]);
    try std.testing.expectEqualStrings("pkgtype", parsed.xdata.items[0].name);
}

test "ParsedDescription converts local metadata into an arena-owned package" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var parsed: ParsedDescription = .{
        .name = "demo",
        .version = "1.2.3-4",
        .description = "Demo package",
        .installed_size = 4096,
        .reason = .dependency,
        .validation = .{ .sha256 = true, .pgp = true },
    };
    defer parsed.deinit(allocator);

    try parsed.depends.append(allocator, "glibc>=2.39");
    try parsed.optional_depends.append(allocator, "docs: documentation support");
    try parsed.groups.append(allocator, "base");

    const package = try parsed.intoPackage(allocator, "local");

    try std.testing.expectEqualStrings("demo", package.name);
    try std.testing.expectEqual(@as(u64, 0), package.version.epoch);
    try std.testing.expectEqualStrings("1.2.3", package.version.pkgver);
    try std.testing.expectEqualStrings("4", package.version.pkgrel.?);
    try std.testing.expectEqualStrings("glibc", package.depends[0].name);
    switch (package.depends[0].constraint) {
        .greater_equal => |version| try std.testing.expectEqualStrings("2.39", version.raw),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("docs", package.optional_depends[0].name);
    try std.testing.expectEqualStrings("documentation support", package.optional_depends[0].description.?);
    try std.testing.expectEqualStrings("base", package.groups[0]);
    try std.testing.expectEqual(@as(u64, 4096), package.installed_size.?);
    try std.testing.expect(package.validation.sha256);
    try std.testing.expect(package.validation.pgp);
}
