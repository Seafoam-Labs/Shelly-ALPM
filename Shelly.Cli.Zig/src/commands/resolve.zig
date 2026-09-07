const std = @import("std");
const Zigalpm = @import("Zigalpm");
const parser = @import("../cli/parser.zig");
const runtime = @import("../runtime/context.zig");
const aur_url = @import("../config/aur_url.zig");

const command_path = "shelly resolve resolve";

const Source = enum { auto, standard, aur };

const ResolutionError = struct {
    code: []const u8,
    message: []const u8,
};

const Resolution = struct {
    requested_name: []const u8,
    source_kind: ?[]const u8 = null,
    name: ?[]const u8 = null,
    package_base: ?[]const u8 = null,
    repository: ?[]const u8 = null,
    version: ?[]const u8 = null,
    source_url: ?[]const u8 = null,
    resolution_error: ?ResolutionError = null,
};

const Selection = struct { index: ?usize = null, count: usize = 0 };

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    if (!std.mem.eql(u8, invocation.command.path, command_path)) return null;
    if (!invocation.globals.json) {
        try context.stderr.writeAll("shelly resolve requires --json.\n");
        try context.stderr.flush();
        return 2;
    }
    const source = parseSource(optionValue(invocation, "--source") orelse "auto") catch {
        try context.stderr.writeAll("--source must be auto, standard, or aur.\n");
        try context.stderr.flush();
        return 2;
    };
    var arena = std.heap.ArenaAllocator.init(context.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const results = try allocator.alloc(Resolution, invocation.positionals.len);
    for (invocation.positionals, results) |name, *result|
        result.* = .{ .requested_name = name };

    var allowed_repositories: std.ArrayList([]const u8) = .empty;
    defer allowed_repositories.deinit(allocator);
    for (invocation.options) |option|
        if (std.mem.eql(u8, option.name, "--repository"))
            try allowed_repositories.append(allocator, option.value orelse continue);

    if (source != .aur) {
        const manager_optional = Zigalpm.AlpmManager.init(
            context.allocator,
            context.environ,
            .{},
        ) catch null;
        if (manager_optional) |manager| {
            defer manager.deinit();
            var databases_available = true;
            const packages = manager.get_available_packages() catch blk: {
                databases_available = false;
                break :blk try context.allocator.alloc(Zigalpm.alpm.OwnedPackage, 0);
            };
            defer Zigalpm.alpm.OwnedPackage.deinitSlice(context.allocator, packages);
            if (!databases_available and source == .standard) {
                for (results) |*result| result.resolution_error = .{
                    .code = "StandardUnavailable",
                    .message = "The configured standard package databases could not be read.",
                };
            }
            if (databases_available) for (invocation.positionals, results) |requested, *result| {
                const selection = selectStandard(packages, requested, allowed_repositories.items);
                if (selection.count > 1) {
                    result.resolution_error = .{
                        .code = "Ambiguous",
                        .message = "The package name exists in more than one allowed repository.",
                    };
                } else if (selection.index) |index| {
                    const package = packages[index];
                    const package_base = try allocator.dupe(u8, package.base());
                    result.* = .{
                        .requested_name = requested,
                        .source_kind = "standard",
                        .name = try allocator.dupe(u8, package.name().?),
                        .package_base = package_base,
                        .repository = try allocator.dupe(u8, package.repository() orelse ""),
                        .version = try allocator.dupe(u8, package.version() orelse ""),
                        .source_url = try standardSourceUrl(allocator, package.repository() orelse "", package_base),
                    };
                }
            };
        } else if (source == .standard) {
            for (results) |*result| result.resolution_error = .{
                .code = "StandardUnavailable",
                .message = "The configured standard package databases could not be opened.",
            };
        }
    }

    if (source != .standard) {
        var unresolved: std.ArrayList([]const u8) = .empty;
        defer unresolved.deinit(allocator);
        for (results) |result|
            if (needsAurLookup(source, result))
                try unresolved.append(allocator, result.requested_name);
        if (unresolved.items.len > 0) {
            const configured_base = try aur_url.resolveFor(context, invocation);
            const base_url = try Zigalpm.aur.endpoints.normalizeBase(allocator, configured_base);
            const rpc_url = try Zigalpm.aur.endpoints.rpcUrl(allocator, base_url);
            var client = try Zigalpm.aur.rpc.Client.init(
                context.allocator,
                context.io,
                rpc_url,
            );
            defer client.deinit();
            var response = try client.getInfo(unresolved.items);
            defer response.deinit(context.allocator);
            for (results) |*result| {
                if (result.source_kind != null or result.resolution_error != null) continue;
                const selection = selectAur(response.results, result.requested_name);
                if (selection.count > 1) {
                    result.resolution_error = .{ .code = "Ambiguous", .message = "The AUR returned duplicate exact package names." };
                } else if (selection.index) |index| {
                    const package = &response.results[index];
                    result.source_kind = "aur";
                    result.name = try allocator.dupe(u8, package.name);
                    result.package_base = try allocator.dupe(u8, package.package_base);
                    result.version = try allocator.dupe(u8, package.version);
                    result.source_url = try Zigalpm.aur.endpoints.gitRemoteUrl(
                        allocator,
                        base_url,
                        package.package_base,
                    );
                } else if (response.error_message) |message| {
                    result.resolution_error = try missingAurError(allocator, message);
                } else {
                    result.resolution_error = .{ .code = "NotFound", .message = "No exact package name was found." };
                }
            }
        }
    }

    for (results) |*result| {
        if (result.source_kind == null and result.resolution_error == null) {
            result.resolution_error = .{ .code = "NotFound", .message = "No exact package name was found." };
        }
    }
    try writeJson(context.stdout, results);
    try context.stdout.writeByte('\n');
    try context.stdout.flush();
    return 0;
}

fn parseSource(value: []const u8) !Source {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "standard")) return .standard;
    if (std.mem.eql(u8, value, "aur")) return .aur;
    return error.InvalidSource;
}

fn repositoryAllowed(allowed: []const []const u8, repository: []const u8) bool {
    if (allowed.len == 0) return true;
    for (allowed) |candidate| if (std.mem.eql(u8, candidate, repository)) return true;
    return false;
}

fn standardSourceUrl(
    allocator: std.mem.Allocator,
    repository: []const u8,
    package_base: []const u8,
) !?[]const u8 {
    const official = std.mem.eql(u8, repository, "core") or
        std.mem.eql(u8, repository, "extra") or
        std.mem.eql(u8, repository, "multilib") or
        std.mem.endsWith(u8, repository, "-testing") or
        std.mem.endsWith(u8, repository, "-staging");
    if (!official) return null;
    return try std.fmt.allocPrint(
        allocator,
        "https://gitlab.archlinux.org/archlinux/packaging/packages/{s}.git",
        .{package_base},
    );
}

fn selectStandard(packages: anytype, requested: []const u8, allowed: []const []const u8) Selection {
    var selection: Selection = .{};
    for (packages, 0..) |package, index| {
        const name = package.name() orelse continue;
        if (!std.mem.eql(u8, name, requested)) continue;
        if (!repositoryAllowed(allowed, package.repository() orelse "")) continue;
        selection.count += 1;
        if (selection.index == null) selection.index = index;
    }
    return selection;
}

fn selectAur(packages: anytype, requested: []const u8) Selection {
    var selection: Selection = .{};
    for (packages, 0..) |package, index| {
        if (!std.mem.eql(u8, package.name, requested)) continue;
        selection.count += 1;
        if (selection.index == null) selection.index = index;
    }
    return selection;
}

fn needsAurLookup(source: Source, result: Resolution) bool {
    return source != .standard and result.source_kind == null and result.resolution_error == null;
}

fn missingAurError(allocator: std.mem.Allocator, partial_failure: ?[]const u8) !ResolutionError {
    if (partial_failure) |message| return .{
        .code = "AurPartialFailure",
        .message = try allocator.dupe(u8, message),
    };
    return .{ .code = "NotFound", .message = "No exact package name was found." };
}

fn optionValue(invocation: *const parser.Invocation, name: []const u8) ?[]const u8 {
    for (invocation.options) |option|
        if (std.mem.eql(u8, option.name, name)) return option.value;
    return null;
}

fn writeJson(writer: *std.Io.Writer, results: []const Resolution) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    try json.objectField("schemaVersion");
    try json.write(1);
    try json.objectField("results");
    try json.beginArray();
    for (results) |result| {
        try json.beginObject();
        try json.objectField("requestedName");
        try json.write(result.requested_name);
        try json.objectField("sourceKind");
        try json.write(result.source_kind);
        try json.objectField("name");
        try json.write(result.name);
        try json.objectField("packageBase");
        try json.write(result.package_base);
        try json.objectField("repository");
        try json.write(result.repository);
        try json.objectField("version");
        try json.write(result.version);
        try json.objectField("sourceUrl");
        try json.write(result.source_url);
        try json.objectField("error");
        if (result.resolution_error) |resolution_error| {
            try json.beginObject();
            try json.objectField("code");
            try json.write(resolution_error.code);
            try json.objectField("message");
            try json.write(resolution_error.message);
            try json.endObject();
        } else try json.write(null);
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
}

test "repository filtering happens before duplicate resolution" {
    try std.testing.expect(repositoryAllowed(&.{ "core", "extra" }, "core"));
    try std.testing.expect(!repositoryAllowed(&.{"core"}, "third-party"));
    try std.testing.expect(repositoryAllowed(&.{}, "third-party"));
}

test "resolve source accepts only exact source modes" {
    try std.testing.expectEqual(Source.auto, try parseSource("auto"));
    try std.testing.expectEqual(Source.standard, try parseSource("standard"));
    try std.testing.expectEqual(Source.aur, try parseSource("aur"));
    try std.testing.expectError(error.InvalidSource, parseSource("all"));
}

test "exact standard resolution maps split binaries to package base" {
    const Fake = struct {
        package_name: [:0]const u8,
        package_base: [:0]const u8,
        repo: [:0]const u8,

        fn name(self: @This()) ?[:0]const u8 {
            return self.package_name;
        }
        fn repository(self: @This()) ?[:0]const u8 {
            return self.repo;
        }
        fn base(self: @This()) [:0]const u8 {
            return self.package_base;
        }
    };
    const packages = [_]Fake{.{ .package_name = "linux-headers", .package_base = "linux", .repo = "core" }};
    const selection = selectStandard(&packages, "linux-headers", &.{"core"});
    try std.testing.expectEqual(@as(usize, 1), selection.count);
    try std.testing.expectEqualStrings("linux", packages[selection.index.?].base());
}

test "allowed repositories remove third-party shadowing before ambiguity" {
    const Fake = struct {
        package_name: [:0]const u8,
        repo: [:0]const u8,
        fn name(self: @This()) ?[:0]const u8 {
            return self.package_name;
        }
        fn repository(self: @This()) ?[:0]const u8 {
            return self.repo;
        }
    };
    const packages = [_]Fake{
        .{ .package_name = "demo", .repo = "core" },
        .{ .package_name = "demo", .repo = "third-party" },
    };
    try std.testing.expectEqual(@as(usize, 1), selectStandard(&packages, "demo", &.{"core"}).count);
    try std.testing.expectEqual(@as(usize, 2), selectStandard(&packages, "demo", &.{}).count);
}

test "batched AUR selection reports missing partial and ambiguous entries independently" {
    const Fake = struct { name: []const u8 };
    const packages = [_]Fake{ .{ .name = "one" }, .{ .name = "duplicate" }, .{ .name = "duplicate" } };
    try std.testing.expectEqual(@as(usize, 1), selectAur(&packages, "one").count);
    try std.testing.expectEqual(@as(usize, 0), selectAur(&packages, "missing").count);
    try std.testing.expectEqual(@as(usize, 2), selectAur(&packages, "duplicate").count);
    const partial = try missingAurError(std.testing.allocator, "NetworkError");
    defer std.testing.allocator.free(partial.message);
    try std.testing.expectEqualStrings("AurPartialFailure", partial.code);
    try std.testing.expectEqualStrings("NetworkError", partial.message);
}

test "auto resolution queries AUR only after an allowed standard miss" {
    const unresolved: Resolution = .{ .requested_name = "yay" };
    const standard: Resolution = .{
        .requested_name = "linux-headers",
        .source_kind = "standard",
    };
    try std.testing.expect(needsAurLookup(.auto, unresolved));
    try std.testing.expect(!needsAurLookup(.auto, standard));
    try std.testing.expect(!needsAurLookup(.standard, unresolved));
    try std.testing.expect(needsAurLookup(.aur, unresolved));
}
