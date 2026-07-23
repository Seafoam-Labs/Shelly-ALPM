const std = @import("std");
const pkgbuild = @import("../pkgbuild/pkgbuild_parser.zig");

pub const ParsedDependency = pkgbuild.parsed_dep;

pub const Backend = struct {
    context: ?*anyopaque,
    is_installed: *const fn (context: ?*anyopaque, dependency: [:0]const u8) bool,
    find_repo_satisfier: *const fn (context: ?*anyopaque, dependency: [:0]const u8) ?[]const u8,
};

pub const Resolution = struct {
    repo_packages: [][]u8,
    aur_packages: []ParsedDependency,

    pub fn deinit(self: *Resolution, allocator: std.mem.Allocator) void {
        for (self.repo_packages) |package| allocator.free(package);
        allocator.free(self.repo_packages);
        for (self.aur_packages) |dependency| dependency.deinit(allocator);
        allocator.free(self.aur_packages);
        self.* = undefined;
    }
};

pub fn resolve(
    allocator: std.mem.Allocator,
    info: *const pkgbuild.pkgbuild_info,
    no_check: bool,
    backend: Backend,
) !Resolution {
    var all_dependencies: std.ArrayList(ParsedDependency) = .empty;
    defer all_dependencies.deinit(allocator);
    try appendDistinct(&all_dependencies, allocator, info.parsed_depends orelse &.{});
    try appendDistinct(&all_dependencies, allocator, info.parsed_make_depends orelse &.{});
    if (!no_check) try appendDistinct(&all_dependencies, allocator, info.parsed_check_depends orelse &.{});

    var repo: std.ArrayList([]u8) = .empty;
    errdefer {
        for (repo.items) |name| allocator.free(name);
        repo.deinit(allocator);
    }
    var aur: std.ArrayList(ParsedDependency) = .empty;
    errdefer {
        for (aur.items) |dependency| dependency.deinit(allocator);
        aur.deinit(allocator);
    }

    for (all_dependencies.items) |dependency| {
        const dependency_string = try formatDependencyZ(allocator, dependency);
        defer allocator.free(dependency_string);
        if (backend.is_installed(backend.context, dependency_string)) continue;
        if (backend.find_repo_satisfier(backend.context, dependency_string)) |name| {
            if (!containsString(repo.items, name)) try repo.append(allocator, try allocator.dupe(u8, name));
        } else try aur.append(allocator, try cloneDependency(allocator, dependency));
    }

    return .{
        .repo_packages = try repo.toOwnedSlice(allocator),
        .aur_packages = try aur.toOwnedSlice(allocator),
    };
}

pub fn collectBuildOnlyDependencies(
    allocator: std.mem.Allocator,
    info: *const pkgbuild.pkgbuild_info,
    no_check: bool,
    backend: Backend,
) ![][]u8 {
    const runtime = info.parsed_depends orelse &.{};
    var build_only: std.ArrayList([]u8) = .empty;
    errdefer {
        for (build_only.items) |name| allocator.free(name);
        build_only.deinit(allocator);
    }

    const groups = [_][]const ParsedDependency{
        info.parsed_make_depends orelse &.{},
        if (no_check) &.{} else info.parsed_check_depends orelse &.{},
    };
    for (groups) |dependencies| for (dependencies) |dependency| {
        var is_runtime = false;
        for (runtime) |runtime_dependency| {
            if (std.mem.eql(u8, runtime_dependency.name, dependency.name)) {
                is_runtime = true;
                break;
            }
        }
        if (is_runtime) continue;
        const dependency_string = try formatDependencyZ(allocator, dependency);
        defer allocator.free(dependency_string);
        if (backend.is_installed(backend.context, dependency_string)) continue;
        const name = backend.find_repo_satisfier(backend.context, dependency_string) orelse dependency.name;
        if (!containsString(build_only.items, name)) try build_only.append(allocator, try allocator.dupe(u8, name));
    };
    return build_only.toOwnedSlice(allocator);
}

pub const OptionalDependency = struct {
    name: []const u8,
    description: []const u8,
};

pub fn parseOptionalDependency(raw: []const u8) OptionalDependency {
    const colon = std.mem.indexOfScalar(u8, raw, ':');
    const decorated_name = std.mem.trim(u8, if (colon) |index| raw[0..index] else raw, " \t");
    var end = decorated_name.len;
    for (decorated_name, 0..) |char, index| {
        if (char == '>' or char == '<' or char == '=') {
            end = index;
            break;
        }
    }
    const description = if (colon) |index|
        std.mem.trim(u8, raw[index + 1 ..], " \t")
    else
        "";
    return .{
        .name = std.mem.trim(u8, decorated_name[0..end], " \t"),
        .description = if (description.len == 0) "No description found" else description,
    };
}

pub fn isValidPackageName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name, 0..) |char, index| {
        const valid = std.ascii.isAlphanumeric(char) or char == '@' or char == '.' or
            char == '_' or char == '+' or (char == '-' and index > 0);
        if (!valid) return false;
    }
    return true;
}

pub fn formatDependency(allocator: std.mem.Allocator, dependency: ParsedDependency) ![]u8 {
    if (dependency.operator.len == 0 or dependency.version.len == 0)
        return allocator.dupe(u8, dependency.name);
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ dependency.name, dependency.operator, dependency.version });
}

pub fn formatDependencyZ(allocator: std.mem.Allocator, dependency: ParsedDependency) ![:0]u8 {
    if (dependency.operator.len == 0 or dependency.version.len == 0)
        return allocator.dupeZ(u8, dependency.name);
    return std.fmt.allocPrintSentinel(allocator, "{s}{s}{s}", .{ dependency.name, dependency.operator, dependency.version }, 0);
}

pub fn cloneDependency(allocator: std.mem.Allocator, dependency: ParsedDependency) !ParsedDependency {
    const name = try allocator.dupe(u8, dependency.name);
    errdefer allocator.free(name);
    const operator = try allocator.dupe(u8, dependency.operator);
    errdefer allocator.free(operator);
    return .{
        .name = name,
        .operator = operator,
        .version = try allocator.dupe(u8, dependency.version),
    };
}

fn appendDistinct(
    list: *std.ArrayList(ParsedDependency),
    allocator: std.mem.Allocator,
    dependencies: []const ParsedDependency,
) !void {
    for (dependencies) |dependency| {
        var duplicate = false;
        for (list.items) |existing| {
            if (std.mem.eql(u8, existing.name, dependency.name) and
                std.mem.eql(u8, existing.operator, dependency.operator) and
                std.mem.eql(u8, existing.version, dependency.version))
            {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) try list.append(allocator, dependency);
    }
}

fn containsString(strings: []const []u8, expected: []const u8) bool {
    for (strings) |string| if (std.mem.eql(u8, string, expected)) return true;
    return false;
}

test "optional dependency decorations and descriptions mirror the C# parser" {
    const parsed = parseOptionalDependency("  docs>=2: HTML documentation ");
    try std.testing.expectEqualStrings("docs", parsed.name);
    try std.testing.expectEqualStrings("HTML documentation", parsed.description);
    try std.testing.expect(isValidPackageName(parsed.name));
    try std.testing.expect(!isValidPackageName("bad/name"));
}

test "dependency resolution partitions installed repo and AUR dependencies" {
    const Context = struct {
        fn installed(_: ?*anyopaque, dependency: [:0]const u8) bool {
            return std.mem.eql(u8, dependency, "glibc");
        }
        fn repo(_: ?*anyopaque, dependency: [:0]const u8) ?[]const u8 {
            if (std.mem.eql(u8, dependency, "cmake>=3")) return "cmake";
            return null;
        }
    };

    const allocator = std.testing.allocator;
    const parser = pkgbuild.PkgbuildParser{ .allocator = allocator, .io = std.testing.io };
    var info = try parser.parser_content(
        \\pkgname=demo
        \\depends=('glibc' 'aur-runtime')
        \\makedepends=('cmake>=3')
        \\checkdepends=('check-only')
    , null);
    defer info.deinit(allocator);

    var checked = try resolve(allocator, &info, false, .{
        .context = null,
        .is_installed = Context.installed,
        .find_repo_satisfier = Context.repo,
    });
    defer checked.deinit(allocator);
    try std.testing.expectEqualSlices(u8, "cmake", checked.repo_packages[0]);
    try std.testing.expectEqual(@as(usize, 2), checked.aur_packages.len);

    var no_check = try resolve(allocator, &info, true, .{
        .context = null,
        .is_installed = Context.installed,
        .find_repo_satisfier = Context.repo,
    });
    defer no_check.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), no_check.aur_packages.len);
    try std.testing.expectEqualStrings("aur-runtime", no_check.aur_packages[0].name);
}
