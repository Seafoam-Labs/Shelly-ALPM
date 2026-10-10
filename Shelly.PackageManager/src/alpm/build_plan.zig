//! Versioned, portable isolated build environment. The native transaction owns
//! package selection; this module records its result and binds it to build inputs.
const std = @import("std");
const transaction = @import("build_transaction.zig");
const Configuration = @import("configuration.zig").Configuration;
const Manager = @import("manager.zig").Manager;
const Relation = @import("Shelly_Rlpm").PackageRelation;

pub const Requirement = struct { requirement: []const u8, role: enum { bootstrap, runtime, build, check } };
pub const Edge = struct { from: []const u8, requirement: []const u8, role: []const u8, provider: ?[]const u8, viaProvides: bool = false };
pub const Unresolved = transaction.Issue;
pub const Repository = struct { name: []const u8, servers: []const []const u8, cacheServers: []const []const u8, signatureLevel: u32, usage: u32, databaseSha256: ?[]const u8 = null };

pub const Plan = struct {
    schemaVersion: u32 = 1,
    capability: []const u8 = "build.resolve-dependencies",
    isolated: bool = true,
    complete: bool = false,
    planDigest: []const u8 = "",
    reviewDigest: []const u8,
    configurationDigest: []const u8,
    buildPolicyDigest: []const u8,
    backend: []const u8,
    bootstrapProfile: []const u8,
    architectures: []const []const u8,
    check: bool,
    providerPolicy: []const u8 = "native-repository-order-v1",
    hashProvenance: []const u8 = "repository-metadata; archives verified during provisioning",
    repositories: []const Repository,
    requirements: []const Requirement,
    packages: []const transaction.Package = &.{},
    relationships: []const Edge = &.{},
    unresolved: []const Unresolved = &.{},
    choices: []const struct { requirement: []const u8, candidates: []const []const u8 } = &.{},

    pub fn digest(self: Plan, allocator: std.mem.Allocator) ![]const u8 {
        var canonical = self;
        canonical.planDigest = "";
        const bytes = try std.json.Stringify.valueAlloc(allocator, canonical, .{});
        defer allocator.free(bytes);
        return hashBytes(allocator, bytes);
    }

    pub fn validate(self: Plan, allocator: std.mem.Allocator) !void {
        if (self.schemaVersion != 1 or !std.mem.eql(u8, self.capability, "build.resolve-dependencies")) return error.UnsupportedDependencyPlan;
        if (!self.isolated or !self.complete or self.architectures.len == 0 or self.packages.len == 0 or self.unresolved.len != 0 or self.choices.len != 0) return error.IncompleteDependencyPlan;
        const expected = try self.digest(allocator);
        defer allocator.free(expected);
        if (!std.mem.eql(u8, expected, self.planDigest)) return error.DependencyPlanMismatch;
        for (self.packages, 0..) |package, index| {
            if (!transaction.validHash(package.sha256 orelse return error.MissingArtifactHash)) return error.MissingArtifactHash;
            if (index != 0 and !std.mem.lessThan(u8, self.packages[index - 1].name, package.name)) return error.DependencyPlanMismatch;
        }
    }
};

pub fn hashBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return allocator.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
}

pub fn repositories(allocator: std.mem.Allocator, config: *const Configuration.Config) ![]Repository {
    const result = try allocator.alloc(Repository, config.repositories.items.len);
    for (config.repositories.items, result) |repo, *output| output.* = .{
        .name = try allocator.dupe(u8, repo.name),
        .servers = try cloneStrings(allocator, repo.servers.items),
        .cacheServers = try cloneStrings(allocator, repo.cache_servers.items),
        .signatureLevel = repo.sig_level,
        .usage = repo.usage,
    };
    return result;
}

fn cloneStrings(allocator: std.mem.Allocator, strings: anytype) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, strings.len);
    for (strings, result) |source, *target| target.* = try allocator.dupe(u8, source);
    return result;
}

/// Hash effective directives, including expanded includes, rather than a filename
/// or temporary database paths. Both shelly.conf and pacman.conf use this parser.
pub fn configurationDigest(allocator: std.mem.Allocator, config: *const Configuration.Config) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    inline for (std.meta.fields(Configuration.Config)) |field| {
        if (comptime !std.mem.eql(u8, field.name, "arena")) {
            try json.objectField(field.name);
            const value = @field(config, field.name);
            if (comptime std.mem.eql(u8, field.name, "repositories")) {
                try json.write(try repositories(allocator, config));
            } else if (comptime @typeInfo(field.type) == .@"struct" and @hasField(field.type, "items")) {
                try json.write(value.items);
            } else try json.write(value);
        }
    }
    try json.endObject();
    return hashBytes(allocator, output.written());
}

pub fn resolve(allocator: std.mem.Allocator, io: std.Io, manager: *Manager, input: Plan) !Plan {
    if (input.architectures.len == 0) return error.MissingArchitecture;
    var result = input;
    const repos = try repositories(allocator, manager.config);
    for (repos) |*repo| {
        const path = try std.fmt.allocPrint(allocator, "{s}/sync/{s}.db", .{ manager.config.database_path, repo.name });
        repo.databaseSha256 = try hashFile(allocator, io, path);
    }
    result.repositories = repos;
    var unresolved: std.ArrayList(Unresolved) = .empty;
    var targets: std.ArrayList([:0]const u8) = .empty;
    for (result.requirements) |requirement| {
        const target = try allocator.dupeZ(u8, requirement.requirement);
        // Bootstrap targets can be native package groups. Recipe requirements
        // are relations, never groups, and missing ones are not assumed to be AUR.
        if (requirement.role != .bootstrap) {
            _ = manager.find_remote_satisfier_for_dependency(target) catch |err| {
                if (err != error.PkgNotFound) return err;
                try unresolved.append(allocator, .{ .requirement = target, .requiredBy = "PKGBUILD", .code = "not_in_repositories" });
                continue;
            };
        }
        var duplicate = false;
        for (targets.items) |existing| if (std.mem.eql(u8, target, existing)) {
            duplicate = true;
            break;
        };
        if (!duplicate) try targets.append(allocator, target);
    }
    var native_issues: []const transaction.Issue = &.{};
    result.packages = manager.prepare_build_packages_report(allocator, targets.items, &native_issues) catch |err| blk: {
        if (err == error.Cancelled or err == error.OutOfMemory) return err;
        if (native_issues.len != 0) try unresolved.appendSlice(allocator, native_issues) else try unresolved.append(allocator, .{ .requirement = "transaction", .requiredBy = "environment", .code = @errorName(err) });
        break :blk &.{};
    };
    const packages = try allocator.dupe(transaction.Package, result.packages);
    for (packages) |*package| {
        var locations: std.ArrayList([]const u8) = .empty;
        for (repos) |repo| {
            if (!std.mem.eql(u8, package.repository, repo.name)) continue;
            for ([_][]const []const u8{ repo.cacheServers, repo.servers }) |servers| for (servers) |server| {
                const with_repo = try std.mem.replaceOwned(u8, allocator, server, "$repo", repo.name);
                const with_arch = try std.mem.replaceOwned(u8, allocator, with_repo, "$arch", result.architectures[0]);
                try locations.append(allocator, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ std.mem.trimEnd(u8, with_arch, "/"), package.filename }));
            };
        }
        package.locations = try locations.toOwnedSlice(allocator);
    }
    result.packages = packages;
    var edges: std.ArrayList(Edge) = .empty;
    for (result.requirements) |requirement| {
        // A bootstrap group has multiple members; its targets are recorded in
        // requirements and the prepared package closure remains authoritative.
        if (requirement.role == .bootstrap and findProvider(result.packages, requirement.requirement) == null) {
            const before = edges.items.len;
            for (result.packages) |package| for (package.groups) |group| {
                if (std.mem.eql(u8, group, requirement.requirement)) try edges.append(allocator, .{ .from = "bootstrap", .requirement = group, .role = "bootstrap", .provider = package.name });
            };
            if (result.packages.len != 0 and edges.items.len == before)
                try unresolved.append(allocator, .{ .requirement = requirement.requirement, .requiredBy = "bootstrap", .code = "not_in_environment" });
            continue;
        }
        const origin = if (requirement.role == .bootstrap) "bootstrap" else "PKGBUILD";
        try appendEdge(allocator, &edges, result.packages, origin, requirement.requirement, @tagName(requirement.role));
        if (result.packages.len != 0 and findProvider(result.packages, requirement.requirement) == null)
            try unresolved.append(allocator, .{ .requirement = requirement.requirement, .requiredBy = origin, .code = "not_in_environment" });
    }
    for (result.packages) |package| {
        if (!transaction.validHash(package.sha256 orelse "")) try unresolved.append(allocator, .{ .requirement = package.name, .requiredBy = package.repository, .code = "missing_artifact_sha256" });
        for (package.depends) |requirement| {
            try appendEdge(allocator, &edges, result.packages, package.name, requirement, "transitive");
            if (findProvider(result.packages, requirement) == null) try unresolved.append(allocator, .{ .requirement = requirement, .requiredBy = package.name, .code = "not_in_environment" });
        }
    }
    result.relationships = try edges.toOwnedSlice(allocator);
    result.unresolved = try unresolved.toOwnedSlice(allocator);
    result.complete = result.unresolved.len == 0 and result.packages.len != 0;
    result.planDigest = try result.digest(allocator);
    return result;
}

fn appendEdge(allocator: std.mem.Allocator, edges: *std.ArrayList(Edge), packages: []const transaction.Package, from: []const u8, requirement: []const u8, role: []const u8) !void {
    const provider = findProvider(packages, requirement);
    const relation = try Relation.parse(requirement);
    try edges.append(allocator, .{ .from = from, .requirement = requirement, .role = role, .provider = provider, .viaProvides = if (provider) |name| !std.mem.eql(u8, name, relation.name) else false });
}

// Describes satisfiers already in the prepared set; never selects packages from
// repositories. Native relation semantics also cover versioned shared libraries.
fn findProvider(packages: []const transaction.Package, requirement: []const u8) ?[]const u8 {
    const relation = Relation.parse(requirement) catch return null;
    for (packages) |package| if (std.mem.eql(u8, relation.name, package.name) and relation.matchesVersion(package.version)) return package.name;
    for (packages) |package| for (package.provides) |provided| {
        const provision = Relation.parse(provided) catch continue;
        if (relation.satisfiedBy(package.name, package.version, &.{provision})) return package.name;
    };
    return null;
}

pub fn targetArchitectures(allocator: std.mem.Allocator, config: *const Configuration.Config) ![]const []const u8 {
    var expanded = try @import("architectures.zig").expand(allocator, config.architectures.items, config.architecture);
    defer expanded.deinit(allocator);
    return cloneStrings(allocator, expanded.items);
}

pub fn hashFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var reader_buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);
    var buffer: [8192]u8 = undefined;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    while (true) {
        const count = try reader.interface.readSliceShort(&buffer);
        if (count == 0) break;
        hash.update(buffer[0..count]);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return allocator.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}
