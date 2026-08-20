const std = @import("std");
const pkgbuild = @import("../pkgbuild/pkgbuild_parser.zig");

pub const ParsedDependency = pkgbuild.parsed_dep;

pub const Role = enum {
    runtime,
    build,
    check,
};

pub const RepoDependency = struct {
    name: []u8,
    role: Role,
};

pub const AurDependency = struct {
    dependency: ParsedDependency,
    role: Role,
};

pub const Backend = struct {
    context: ?*anyopaque,
    is_installed: *const fn (context: ?*anyopaque, dependency: [:0]const u8) bool,
    find_repo_satisfier: *const fn (context: ?*anyopaque, dependency: [:0]const u8) ?[]const u8,
};

pub const Resolution = struct {
    repo_packages: []RepoDependency,
    aur_packages: []AurDependency,

    pub fn deinit(self: *Resolution, allocator: std.mem.Allocator) void {
        for (self.repo_packages) |package| allocator.free(package.name);
        allocator.free(self.repo_packages);
        for (self.aur_packages) |dependency| dependency.dependency.deinit(allocator);
        allocator.free(self.aur_packages);
        self.* = undefined;
    }
};

pub fn resolve(
    allocator: std.mem.Allocator,
    info: *const pkgbuild.Pkgbuild,
    no_check: bool,
    backend: Backend,
) !Resolution {
    var repo: std.ArrayList(RepoDependency) = .empty;
    errdefer {
        for (repo.items) |dependency| allocator.free(dependency.name);
        repo.deinit(allocator);
    }
    var aur: std.ArrayList(AurDependency) = .empty;
    errdefer {
        for (aur.items) |dependency| dependency.dependency.deinit(allocator);
        aur.deinit(allocator);
    }

    try resolveGroup(allocator, info.parsed_depends orelse &.{}, .runtime, backend, &repo, &aur);
    try resolveGroup(allocator, info.parsed_make_depends orelse &.{}, .build, backend, &repo, &aur);
    if (!no_check)
        try resolveGroup(allocator, info.parsed_check_depends orelse &.{}, .check, backend, &repo, &aur);

    return .{
        .repo_packages = try repo.toOwnedSlice(allocator),
        .aur_packages = try aur.toOwnedSlice(allocator),
    };
}

fn resolveGroup(
    allocator: std.mem.Allocator,
    dependencies: []const ParsedDependency,
    role: Role,
    backend: Backend,
    repo: *std.ArrayList(RepoDependency),
    aur: *std.ArrayList(AurDependency),
) !void {
    for (dependencies) |dependency| {
        const dependency_string = try formatDependencyZ(allocator, dependency);
        defer allocator.free(dependency_string);
        if (backend.is_installed(backend.context, dependency_string)) continue;
        if (backend.find_repo_satisfier(backend.context, dependency_string)) |name| {
            if (findRepoDependency(repo.items, name)) |index| {
                repo.items[index].role = strongerRole(repo.items[index].role, role);
            } else try repo.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .role = role,
            });
        } else if (findAurDependency(aur.items, dependency)) |index| {
            aur.items[index].role = strongerRole(aur.items[index].role, role);
        } else try aur.append(allocator, .{
            .dependency = try cloneDependency(allocator, dependency),
            .role = role,
        });
    }
}

fn findRepoDependency(dependencies: []const RepoDependency, name: []const u8) ?usize {
    for (dependencies, 0..) |dependency, index|
        if (std.mem.eql(u8, dependency.name, name)) return index;
    return null;
}

fn findAurDependency(dependencies: []const AurDependency, expected: ParsedDependency) ?usize {
    for (dependencies, 0..) |dependency, index| {
        if (std.mem.eql(u8, dependency.dependency.name, expected.name) and
            std.mem.eql(u8, dependency.dependency.operator, expected.operator) and
            std.mem.eql(u8, dependency.dependency.version, expected.version))
            return index;
    }
    return null;
}

pub fn strongerRole(lhs: Role, rhs: Role) Role {
    if (lhs == .runtime or rhs == .runtime) return .runtime;
    if (lhs == .build or rhs == .build) return .build;
    return .check;
}

pub fn collectBuildOnlyDependencies(
    allocator: std.mem.Allocator,
    info: *const pkgbuild.Pkgbuild,
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
        \\arch=('any')
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
    try std.testing.expectEqualSlices(u8, "cmake", checked.repo_packages[0].name);
    try std.testing.expectEqual(Role.build, checked.repo_packages[0].role);
    try std.testing.expectEqual(@as(usize, 2), checked.aur_packages.len);
    try std.testing.expectEqual(Role.runtime, checked.aur_packages[0].role);
    try std.testing.expectEqual(Role.check, checked.aur_packages[1].role);

    var no_check = try resolve(allocator, &info, true, .{
        .context = null,
        .is_installed = Context.installed,
        .find_repo_satisfier = Context.repo,
    });
    defer no_check.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), no_check.aur_packages.len);
    try std.testing.expectEqualStrings("aur-runtime", no_check.aur_packages[0].dependency.name);
}
