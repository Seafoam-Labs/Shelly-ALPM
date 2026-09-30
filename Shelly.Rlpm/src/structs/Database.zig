const std = @import("std");
const Package = @import("Package.zig");
const Group = @import("Group.zig");
const DatabaseStatus = @import("DatabaseStatus.zig");
const SignaturePolicy = @import("SignaturePolicy.zig");
const DatabaseUsage = @import("DatabaseUsage.zig");
const ParsedDescription = @import("ParsedDescription.zig");
const ShellyKey = @import("Shelly_Key");
const DatabaseConfiguration = @import("DatabaseConfiguration.zig");
const DatabaseRef = @import("DatabaseRef.zig");
const Verification = @import("Verification.zig");
const SignatureResult = @import("SignatureResult.zig");
pub const PackageId = @import("PackageRef.zig").Id;
pub const Backend = @import("Backend.zig").Backend;
pub const Metadata = @import("LocalBackend.zig").Metadata;
const Publication = @import("Publication.zig");
const ImmutableFile = @import("ImmutableFile.zig");
const SyncBackend = @import("SyncBackend.zig");
const LocalBackend = @import("LocalBackend.zig");

const Database = @This();

pub const Kind = enum { local, sync };

pub const EntryIssue = struct {
    entry: []const u8,
    cause: anyerror,
};

pub const GroupId = enum(u32) {
    _,
};

pub const GroupIndex = struct {
    groups: std.ArrayList(Group) = .empty,
    by_name: std.StringHashMapUnmanaged(GroupId) = .empty,
    ordered: std.ArrayList(GroupId) = .empty,
};

pub const PackageIndex = struct {
    packages: std.ArrayList(Package) = .empty,
    by_name: std.StringHashMapUnmanaged(PackageId) = .empty,
    ordered: std.ArrayList(PackageId) = .empty,
};

allocator: std.mem.Allocator,
last_refresh_updated: bool = false,
arena: std.heap.ArenaAllocator,
cache_arena: std.heap.ArenaAllocator,
kind: Kind = .local,
backend: Backend = .{ .local = .{} },
metadata_arenas: std.ArrayList(std.heap.ArenaAllocator) = .empty,
skipped_entries: std.ArrayList(EntryIssue) = .empty,
last_load_error: ?anyerror = null,
/// Last verification attempt, including a rejected reload. Cache generations
/// remain unchanged on failure. null means no GPG check was performed.
last_verification: ?SignatureResult = null,
identity: ?DatabaseRef = null,
generation: u64 = 1,

name: []const u8,
path: []const u8,

packages: PackageIndex = .{},
groups: GroupIndex = .{},

cache_servers: std.ArrayList([]const u8) = .empty,
servers: std.ArrayList([]const u8) = .empty,

status: DatabaseStatus = .{},
signature_policy: SignaturePolicy = .{},
signature_override: ?SignaturePolicy = null,
usage: DatabaseUsage = .{},

pub fn init(
    allocator: std.mem.Allocator,
    name: []const u8,
    path: []const u8,
    signature_policy: SignaturePolicy,
) !Database {
    var result: Database = .{
        .path = "",
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .cache_arena = std.heap.ArenaAllocator.init(allocator),
        .name = undefined,
        .signature_policy = signature_policy,
        .signature_override = signature_policy,
    };
    errdefer result.arena.deinit();

    const database_allocator = result.arena.allocator();
    result.name = try database_allocator.dupe(u8, name);
    result.path = try database_allocator.dupe(u8, path);
    return result;
}

pub fn initSync(
    allocator: std.mem.Allocator,
    configuration: DatabaseConfiguration,
    path: []const u8,
    default_policy: SignaturePolicy,
) !Database {
    try configuration.validate();
    var result = try init(
        allocator,
        configuration.database_name,
        path,
        configuration.signature_policy orelse
            default_policy,
    );
    errdefer result.deinit();
    result.kind = .sync;
    result.backend = .{ .sync = .{} };
    result.signature_override = configuration.signature_policy;
    result.usage = configuration.usage;
    const owned = result.arena.allocator();
    for (configuration.servers) |url|
        try result.servers.append(owned, try copyServer(owned, url));
    for (configuration.cache_servers) |url|
        try result.cache_servers.append(owned, try copyServer(owned, url));
    return result;
}

fn copyServer(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    // Match the reference's removal of one terminal slash, preserving order.
    return allocator.dupe(u8, if (std.mem.endsWith(u8, url, "/")) url[0 .. url.len - 1] else url);
}

pub fn configurationView(self: *const Database) DatabaseConfiguration {
    return .{
        .database_name = self.name,
        .signature_policy = self.signature_override,
        .servers = self.servers.items,
        .cache_servers = self.cache_servers.items,
        .usage = self.usage,
    };
}

/// Rebuild registration storage without repeatedly normalizing stored URLs.
pub fn copyRegistration(
    self: *const Database,
    path: []const u8,
    default_policy: SignaturePolicy,
) !Database {
    var result = try init(self.allocator, self.name, path, self.signature_override orelse default_policy);
    errdefer result.deinit();
    result.kind = self.kind;
    result.backend = switch (self.backend) {
        .local => |local| .{ .local = local },
        .sync => .{ .sync = .{} },
    };
    result.identity = self.identity;
    result.generation = std.math.add(u64, self.generation, 1) catch return error.IdentityExhausted;
    result.signature_override = self.signature_override;
    result.usage = self.usage;
    const owned = result.arena.allocator();
    for (self.servers.items) |url|
        try result.servers.append(owned, try owned.dupe(u8, url));
    for (self.cache_servers.items) |url|
        try result.cache_servers.append(owned, try owned.dupe(u8, url));
    return result;
}

/// Used only after candidate configuration has been fully allocated. Borrowed
/// cache data never points into registration storage, so it can move unchanged.
pub fn takeCache(self: *Database, source: *Database) void {
    self.resetCacheStorage();
    self.cache_arena = source.cache_arena;
    self.metadata_arenas = source.metadata_arenas;
    self.packages = source.packages;
    self.groups = source.groups;
    self.skipped_entries = source.skipped_entries;
    self.status = source.status;
    self.backend = source.backend;
    self.generation = source.generation;
    self.last_load_error = source.last_load_error;
    self.last_verification = source.last_verification;
    source.last_verification = null;
    source.cache_arena = std.heap.ArenaAllocator.init(source.allocator);
    source.metadata_arenas = .empty;
    source.packages = .{};
    source.groups = .{};
    source.skipped_entries = .empty;
    source.status = .{};
}

pub fn deinit(self: *Database) void {
    Verification.clearReport(&self.last_verification);
    for (self.metadata_arenas.items) |*arena|
        arena.deinit();
    self.cache_arena.deinit();
    self.arena.deinit();
    self.* = undefined;
}

/// Invalidates PackageRef generations; registration/configuration remain owned.
pub fn invalidateCache(self: *Database) !void {
    const next = std.math.add(u64, self.generation, 1) catch return error.IdentityExhausted;
    self.resetCacheStorage();
    self.generation = next;
    self.status = .{};
}

fn resetCacheStorage(self: *Database) void {
    Verification.clearReport(&self.last_verification);
    for (self.metadata_arenas.items) |*arena|
        arena.deinit();
    self.metadata_arenas = .empty;
    self.skipped_entries = .empty;
    self.last_load_error = null;
    if (self.backend == .sync) self.backend.sync = .{};
    self.cache_arena.deinit();
    self.cache_arena = std.heap.ArenaAllocator.init(self.allocator);
    self.packages = .{};
    self.groups = .{};
    self.status.clearCaches();
}

/// Explicit load retains the historical AlreadyLoaded error. reloadDatabase
/// builds a separate generation and retains the old generation on every failure.
pub fn loadDatabase(self: *Database, io: std.Io, gnupg_path: ?[]const u8) !void {
    if (self.status.package_cache_loaded) return error.DatabaseAlreadyLoaded;
    try self.reloadDatabase(io, gnupg_path);
}

pub fn reloadDatabase(self: *Database, io: std.Io, gnupg_path: ?[]const u8) !void {
    try self.reloadWithVerification(io, .{ .gpg_directory = gnupg_path });
}

pub fn reloadWithVerification(self: *Database, io: std.Io, context: Verification.Context) !void {
    var candidate = self.copyRegistration(self.path, self.signature_policy) catch |err| {
        self.last_load_error = err;
        return err;
    };
    errdefer candidate.deinit();
    candidate.populate(io, context) catch |err| {
        Verification.clearReport(&self.last_verification);
        self.last_verification = candidate.last_verification;
        candidate.last_verification = null;
        self.last_load_error = err;
        if (!self.status.package_cache_loaded) {
            if (err == error.FileNotFound) self.status.markMissing() else self.status.markInvalid();
        }
        return err;
    };
    try context.checkCancelled();
    var old = self.*;
    self.* = candidate;
    old.deinit();
}

fn populate(self: *Database, io: std.Io, context: Verification.Context) !void {
    if (self.backend == .sync) {
        var guard = Publication.DirectoryLock.acquire(std.fs.path.dirname(self.path).?, false, false) catch |err| {
            std.Io.Dir.cwd().access(io, self.path, .{}) catch |failure| return failure;
            return err;
        };
        defer guard.deinit();
        try Publication.ensureReadable(io, self.allocator, self.path);
        return self.populateStaged(io, context);
    }
    return self.populateStaged(io, context);
}

/// Internal: caller owns exclusive access to this private staging directory.
pub fn populateStaged(self: *Database, io: std.Io, context: Verification.Context) !void {
    switch (self.backend) {
        .local => |local| try local.populate(io, self),
        .sync => {
            var snapshot = try ImmutableFile.copy(io, self.path);
            defer snapshot.deinit();
            return self.populateSealed(io, context, &snapshot, .read_from_path);
        },
    }
    self.finishPopulation();
}

pub fn populateSealed(
    self: *Database,
    io: std.Io,
    context: Verification.Context,
    snapshot: *const ImmutableFile,
    signature: @FieldType(Verification.Options, "detached_signature"),
) !void {
    _ = try Verification.check(self.allocator, io, context, snapshot, self.path, .{
        .requirement = self.signature_policy.database,
        .trust = self.signature_policy.database_trust,
        .detached_signature = signature,
    }, &self.last_verification);
    try SyncBackend.populateFromPath(self, snapshot.path());
    self.finishPopulation();
}

fn finishPopulation(self: *Database) void {
    std.mem.sort(PackageId, self.packages.ordered.items, self, struct {
        fn lessThan(db: *Database, a: PackageId, b: PackageId) bool {
            return std.mem.lessThan(
                u8,
                db.packages.packages.items[@intFromEnum(a)].name,
                db.packages.packages.items[@intFromEnum(b)].name,
            );
        }
    }.lessThan);
    if (self.status.presence != .missing) self.status.markValid();
    self.status.package_cache_loaded = true;
}

pub fn addPackage(self: *Database, package: Package) !void {
    const allocator = self.cache_arena.allocator();
    const id: PackageId = @enumFromInt(std.math.cast(u32, self.packages.packages.items.len) orelse
        return error.TooManyPackages);
    if (self.packages.by_name.contains(package.name)) return error.DuplicatePackage;
    try self.packages.packages.append(allocator, package);
    try self.packages.by_name.put(allocator, package.name, id);
    try self.packages.ordered.append(allocator, id);
}

pub fn recordSkipped(self: *Database, entry: []const u8, cause: anyerror) !void {
    const allocator = self.cache_arena.allocator();
    try self.skipped_entries.append(allocator, .{ .entry = try allocator.dupe(u8, entry), .cause = cause });
}

pub fn loadMetadata(self: *Database, io: std.Io, id: PackageId, request: Metadata) !void {
    const index = @intFromEnum(id);
    if (!self.status.package_cache_loaded or index >= self.packages.packages.items.len)
        return error.StalePackageReference;
    const package = &self.packages.packages.items[index];
    if (self.kind != .local) return;
    if ((!request.description or package.description_loaded) and (!request.files or package.files_loaded) and
        (!request.members or
            package.members.install != .unknown))
        return;
    if (package.metadata_error) |err| return err;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    errdefer arena.deinit();
    var candidate = package.*;
    LocalBackend.loadMetadata(io, &arena, &candidate, request) catch |err| {
        if (isCorruptMetadata(err)) package.metadata_error = err;
        return err;
    };
    try self.metadata_arenas.append(self.cache_arena.allocator(), arena);
    package.* = candidate;
}

fn isCorruptMetadata(err: anyerror) bool {
    return switch (err) {
        error.FileNotFound,
        error.InvalidDatabaseEntry,
        error.InvalidXData,
        error.InvalidBackup,
        error.StreamTooLong,
        error.MetadataLineTooLong,
        => true,
        else => false,
    };
}

pub fn loadDescriptions(self: *Database, io: std.Io) !void {
    for (self.packages.ordered.items) |id|
        self.loadMetadata(io, id, .{}) catch |err| {
            if (!isCorruptMetadata(err)) return err;
        };
}

pub fn loadGroups(self: *Database, io: std.Io) !void {
    if (self.status.group_cache_loaded) return;
    if (!self.status.package_cache_loaded) return error.DatabaseNotLoaded;
    try self.loadDescriptions(io);
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    var groups: GroupIndex = .{};
    for (self.packages.ordered.items) |package_id| {
        const package = self.packages.packages.items[@intFromEnum(package_id)];
        for (package.groups) |group_name| {
            const group_id = try groupForPackage(&groups, allocator, group_name, package_id);
            try groups.groups.items[@intFromEnum(group_id)].packages.append(allocator, package_id);
        }
    }
    // libalpm group enumeration follows first encounter in sorted package order.
    try self.metadata_arenas.append(self.cache_arena.allocator(), arena);
    self.groups = groups;
    self.status.group_cache_loaded = true;
}

fn groupForPackage(
    groups: *GroupIndex,
    allocator: std.mem.Allocator,
    name: []const u8,
    package: PackageId,
) !GroupId {
    if (groups.by_name.get(name)) |first| {
        const members = groups.groups.items[@intFromEnum(first)].packages.items;
        if (members.len == 0 or members[members.len - 1] != package) return first;
        // The reference creates another same-name group for duplicate group
        // metadata. Preserve that observable enumeration; exact lookup uses first.
        for (groups.groups.items[@intFromEnum(first) + 1 ..], @intFromEnum(first) + 1..) |group, index| {
            if (!std.mem.eql(u8, group.name, name)) continue;
            const other = group.packages.items;
            if (other.len == 0 or other[other.len - 1] != package) return @enumFromInt(index);
        }
    }
    const id: GroupId = @enumFromInt(std.math.cast(u32, groups.groups.items.len) orelse
        return error.TooManyGroups);
    try groups.groups.append(allocator, .{ .name = name, .packages = .empty });
    if (!groups.by_name.contains(name)) try groups.by_name.put(allocator, name, id);
    try groups.ordered.append(allocator, id);
    return id;
}

fn parseDescription(allocator: std.mem.Allocator, contents: []const u8) !ParsedDescription {
    return ParsedDescription.parse(allocator, contents);
}

fn freeStrings(
    allocator: std.mem.Allocator,
    strings: *std.ArrayList([]u8),
) void {
    for (strings.items) |string| {
        allocator.free(string);
    }
    strings.deinit(allocator);
    strings.* = .empty;
}

/// Legacy cryptographic boolean check (no trust policy). Prefer database loading
/// and last_verification for policy enforcement and structured results.
pub fn validateSignature(
    self: *Database,
    io: std.Io,
    gnupg_path: ?[]const u8,
) !bool {
    const gpg_path = if (gnupg_path) |path| path else "/etc/pacman.d/gnupg";
    const gpg: ShellyKey.gpg.Gpg = .{
        .io = io,
        .homedir = gpg_path,
    };
    const db_name = try std.fmt.allocPrint(self.allocator, "{s}.db", .{self.name});
    defer self.allocator.free(db_name);
    const db_path = if (self.kind == .sync)
        try self.allocator.dupe(u8, self.path)
    else
        try std.fs.path.join(
            self.allocator,
            &.{ self.path, db_name },
        );
    defer self.allocator.free(db_path);
    const sig_path = try std.fmt.allocPrint(self.allocator, "{s}.sig", .{db_path});
    defer self.allocator.free(sig_path);

    const status = gpg.runCapture(self.allocator, &.{
        "--no-options",
        "--batch",
        "--no-tty",
        "--no-auto-key-retrieve",
        "--no-auto-key-import",
        "--auto-key-locate",
        "clear",
        "--no-autostart",
        "--proc-all-sigs",
        "--no-auto-check-trustdb",
        "--status-fd",
        "1",
        "--verify",
        "--",
        sig_path,
        db_path,
    }) catch |err| switch (err) {
        error.GpgFailed => return false,
        else => return err,
    };
    defer self.allocator.free(status);
    return true;
}

test "parseDescription parses a local database desc entry" {
    const contents =
        \\%NAME%
        \\demo
        \\
        \\%VERSION%
        \\1.2.3-4
        \\
        \\%DESC%
        \\Demo package
        \\
        \\%INSTALLED_DB%
        \\extra
        \\
        \\%SIZE%
        \\4096
        \\
        \\%REASON%
        \\1
        \\
        \\%DEPENDS%
        \\glibc>=2.39
        \\
        \\%OPTDEPENDS%
        \\docs: documentation support
        \\
        \\%XDATA%
        \\pkgtype=pkg
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var parsed = try parseDescription(allocator, contents);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("demo", parsed.name.?);
    try std.testing.expectEqualStrings("extra", parsed.installed_database.?);
    try std.testing.expectEqualStrings("glibc>=2.39", parsed.depends.items[0]);

    const package = try parsed.intoPackage(&arena, .{ .origin = .local, .database_name = "local" });
    try std.testing.expectEqualStrings("demo", package.name);
    try std.testing.expectEqualStrings("extra", package.installed_database.?);
    try std.testing.expectEqualStrings("glibc", package.depends[0].name);
    try std.testing.expectEqualStrings("documentation support", package.optional_depends[0].description.?);
}

test "parseDescription covers every supported local database field" {
    const contents =
        \\%NAME%
        \\demo
        \\
        \\%VERSION%
        \\2:1.2.3-4
        \\
        \\%BASE%
        \\demo-base
        \\
        \\%DESC%
        \\A complete parser fixture
        \\
        \\%GROUPS%
        \\base
        \\tools
        \\
        \\%URL%
        \\https://example.test/demo
        \\
        \\%LICENSE%
        \\MIT
        \\Apache-2.0
        \\
        \\%ARCH%
        \\x86_64
        \\
        \\%BUILDDATE%
        \\1700000000
        \\
        \\%INSTALLDATE%
        \\1700000100
        \\
        \\%PACKAGER%
        \\Shelly Tests <tests@example.test>
        \\
        \\%INSTALLED_DB%
        \\extra
        \\
        \\%SIZE%
        \\8192
        \\
        \\%REASON%
        \\0
        \\
        \\%VALIDATION%
        \\none
        \\sha256
        \\pgp
        \\
        \\%DEPENDS%
        \\glibc>=2.39
        \\zlib
        \\
        \\%OPTDEPENDS%
        \\docs: documentation support
        \\
        \\%MAKEDEPENDS%
        \\cmake>=3
        \\
        \\%CHECKDEPENDS%
        \\pytest
        \\
        \\%CONFLICTS%
        \\demo-old<2
        \\
        \\%PROVIDES%
        \\virtual-demo=2:1.2.3
        \\
        \\%REPLACES%
        \\old-demo<=1
        \\
        \\%XDATA%
        \\pkgtype=pkg
        \\detail=value=containing=equals
        \\
        \\%FUTURE_FIELD%
        \\ignored value
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var parsed = try parseDescription(allocator, contents);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("demo", parsed.name.?);
    try std.testing.expectEqualStrings("2:1.2.3-4", parsed.version.?);
    try std.testing.expectEqualStrings("demo-base", parsed.base.?);
    try std.testing.expectEqualStrings("A complete parser fixture", parsed.description.?);
    try std.testing.expectEqual(@as(usize, 2), parsed.groups.items.len);
    try std.testing.expectEqual(@as(usize, 2), parsed.licenses.items.len);
    try std.testing.expectEqual(@as(i64, 1700000000), parsed.build_date.?);
    try std.testing.expectEqual(@as(i64, 1700000100), parsed.install_date.?);
    try std.testing.expectEqual(@as(u64, 8192), parsed.installed_size.?);
    try std.testing.expect(parsed.validation.none);
    try std.testing.expect(parsed.validation.sha256);
    try std.testing.expect(parsed.validation.pgp);
    try std.testing.expectEqual(@as(usize, 2), parsed.xdata.items.len);
    try std.testing.expectEqualStrings("value=containing=equals", parsed.xdata.items[1].value);

    const package = try parsed.intoPackage(&arena, .{ .origin = .local, .database_name = "local" });
    try std.testing.expectEqualStrings("demo", package.name);
    try std.testing.expectEqualStrings("2", package.version.epoch);
    try std.testing.expectEqualStrings("1.2.3", package.version.pkgver);
    try std.testing.expectEqualStrings("4", package.version.pkgrel.?);
    try std.testing.expectEqualStrings("extra", package.installed_database.?);
    try std.testing.expectEqual(Package.InstallReason.explicit, package.install_reason.?);
    try std.testing.expectEqualStrings("https://example.test/demo", package.url.?);
    try std.testing.expectEqualStrings("x86_64", package.architecture.?);
    try std.testing.expectEqualStrings("Shelly Tests <tests@example.test>", package.packager.?);
    try std.testing.expectEqualStrings("MIT", package.licenses[0]);
    try std.testing.expectEqualStrings("tools", package.groups[1]);

    try std.testing.expectEqualStrings("glibc", package.depends[0].name);
    switch (package.depends[0].constraint) {
        .greater_equal => |version| try std.testing.expectEqualStrings("2.39", version),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("zlib", package.depends[1].name);
    try std.testing.expect(package.depends[1].constraint == .any);
    try std.testing.expectEqualStrings("documentation support", package.optional_depends[0].description.?);
    try std.testing.expectEqualStrings("cmake", package.make_depends[0].name);
    try std.testing.expectEqualStrings("pytest", package.check_depends[0].name);
    try std.testing.expectEqualStrings("demo-old", package.conflicts[0].name);
    try std.testing.expectEqualStrings("virtual-demo", package.provides[0].name);
    switch (package.provides[0].constraint) {
        .equal => |version| try std.testing.expectEqualStrings("2:1.2.3", version),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("old-demo", package.replaces[0].name);
}

test "parseDescription accepts CRLF and ignores unknown sections" {
    const contents =
        "%NAME%\r\ndemo\r\n\r\n" ++
        "%UNKNOWN%\r\nignored\r\n\r\n" ++
        "%VERSION%\r\n1.0-1\r\n";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var parsed = try parseDescription(allocator, contents);
    defer parsed.deinit(allocator);
    const package = try parsed.intoPackage(&arena, .{ .origin = .local, .database_name = "local" });

    try std.testing.expectEqualStrings("demo", package.name);
    try std.testing.expectEqualStrings("0", package.version.epoch);
    try std.testing.expectEqualStrings("1.0", package.version.pkgver);
    try std.testing.expectEqualStrings("1", package.version.pkgrel.?);
}

test "parseDescription rejects malformed scalar values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(
        error.ValueOutsideSection,
        parseDescription(allocator, "orphan value\n"),
    );
    try std.testing.expectError(
        error.DuplicateValue,
        parseDescription(allocator, "%NAME%\ndemo\nduplicate\n"),
    );
    try std.testing.expectError(
        error.InvalidCharacter,
        parseDescription(allocator, "%BUILDDATE%\nnot-a-number\n"),
    );
    var unknown_reason = try parseDescription(allocator, "%REASON%\n9\n");
    defer unknown_reason.deinit(allocator);
    try std.testing.expectEqual(.unknown, unknown_reason.reason.?);
    try std.testing.expectError(
        error.InvalidXData,
        parseDescription(allocator, "%XDATA%\nmissing-equals\n"),
    );
}

test "ParsedDescription requires package identity and valid relations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var missing_name = try parseDescription(allocator, "%VERSION%\n1.0-1\n");
    defer missing_name.deinit(allocator);
    try std.testing.expectError(
        error.MissingPackageName,
        missing_name.intoPackage(&arena, .{ .origin = .local, .database_name = "local" }),
    );

    var missing_version = try parseDescription(allocator, "%NAME%\ndemo\n");
    defer missing_version.deinit(allocator);
    try std.testing.expectError(
        error.MissingPackageVersion,
        missing_version.intoPackage(&arena, .{ .origin = .local, .database_name = "local" }),
    );

    var invalid_relation = try parseDescription(
        allocator,
        "%NAME%\ndemo\n\n%VERSION%\n1.0-1\n\n%DEPENDS%\ninvalid\x00relation\n",
    );
    defer invalid_relation.deinit(allocator);
    try std.testing.expectError(
        error.InvalidPackageRelation,
        invalid_relation.intoPackage(&arena, .{ .origin = .local, .database_name = "local" }),
    );
}

test "loadDatabase owns and indexes parsed packages" {
    const contents =
        \\%NAME%
        \\demo
        \\
        \\%VERSION%
        \\1.2.3-4
        \\
        \\%DESC%
        \\Demo package
        \\
        \\%GROUPS%
        \\base
        \\
        \\%DEPENDS%
        \\glibc
    ;

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, "demo-1.2.3-4", .default_dir);
    var package_dir = try temporary.dir.openDir(std.testing.io, "demo-1.2.3-4", .{});
    defer package_dir.close(std.testing.io);
    try package_dir.writeFile(std.testing.io, .{
        .sub_path = "desc",
        .data = contents,
    });

    const path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);

    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "ALPM_DB_VERSION", .data = "9\n" });
    var database = try Database.init(std.testing.allocator, "local", path, .{});
    defer database.deinit();
    database.signature_policy.database = .disabled;
    try database.loadDatabase(std.testing.io, null);

    try std.testing.expect(database.status.package_cache_loaded);
    try std.testing.expectEqual(@as(usize, 1), database.packages.packages.items.len);
    const package_id = database.packages.by_name.get("demo") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(package_id));
    try database.loadMetadata(std.testing.io, package_id, .{});
    try database.loadGroups(std.testing.io);
    const package = database.packages.packages.items[@intFromEnum(package_id)];
    try std.testing.expectEqualStrings("demo", package.name);
    try std.testing.expectEqualStrings("1.2.3-4", package.version.raw);
    try std.testing.expectEqualStrings("glibc", package.depends[0].name);
    const group_id = database.groups.by_name.get("base") orelse return error.TestUnexpectedResult;
    const group = database.groups.groups.items[@intFromEnum(group_id)];
    try std.testing.expectEqual(@as(usize, 1), group.packages.items.len);
    try std.testing.expectEqual(package_id, group.packages.items[0]);
    try std.testing.expectError(
        error.DatabaseAlreadyLoaded,
        database.loadDatabase(std.testing.io, null),
    );
}

test "loadDatabase retains identities with missing and incomplete descriptions" {
    const previous_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = previous_log_level;

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    try temporary.dir.createDir(std.testing.io, "valid-1.0-1", .default_dir);
    try temporary.dir.createDir(std.testing.io, "malformed-1.0-1", .default_dir);
    try temporary.dir.createDir(std.testing.io, "missing-1.0-1", .default_dir);

    {
        var valid_dir = try temporary.dir.openDir(std.testing.io, "valid-1.0-1", .{});
        defer valid_dir.close(std.testing.io);
        try valid_dir.writeFile(std.testing.io, .{
            .sub_path = "desc",
            .data = "%NAME%\nvalid\n\n%VERSION%\n1.0-1\n",
        });
    }
    {
        var malformed_dir = try temporary.dir.openDir(std.testing.io, "malformed-1.0-1", .{});
        defer malformed_dir.close(std.testing.io);
        try malformed_dir.writeFile(std.testing.io, .{
            .sub_path = "desc",
            .data = "%NAME%\nmalformed\n",
        });
    }

    const path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);

    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "ALPM_DB_VERSION", .data = "9\n" });
    var database = try Database.init(std.testing.allocator, "local", path, .{});
    defer database.deinit();
    database.signature_policy.database = .disabled;
    try database.loadDatabase(std.testing.io, null);

    try std.testing.expectEqual(@as(usize, 3), database.packages.packages.items.len);
    try std.testing.expect(database.packages.by_name.contains("valid"));
    try database.loadMetadata(std.testing.io, database.packages.by_name.get("malformed").?, .{});
    try std.testing.expectError(
        error.FileNotFound,
        database.loadMetadata(
            std.testing.io,
            database.packages.by_name.get("missing").?,
            .{},
        ),
    );
}

/// Opt-in host smoke tests; never referenced by the ordinary test root.
pub const HostTests = struct {
    test "host-readonly: parses the actual local package database" {
        const local_database_path = "/var/lib/pacman/local";
        var probe = std.Io.Dir.cwd().openDir(std.testing.io, local_database_path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied => return error.SkipZigTest,
            else => return err,
        };
        probe.close(std.testing.io);

        const previous_log_level = std.testing.log_level;
        std.testing.log_level = .err;
        defer std.testing.log_level = previous_log_level;

        var database = try Database.init(std.testing.allocator, "local", local_database_path, .{});
        defer database.deinit();
        database.signature_policy.database = .disabled;
        try database.loadDatabase(std.testing.io, null);

        try std.testing.expect(database.status.package_cache_loaded);
        try std.testing.expect(database.packages.packages.items.len > 0);
        try std.testing.expectEqual(
            database.packages.packages.items.len,
            database.packages.ordered.items.len,
        );
        try std.testing.expectEqual(
            database.packages.packages.items.len,
            database.packages.by_name.count(),
        );

        const preview_count = @min(database.packages.ordered.items.len, 5);
        std.debug.print(
            "\nlocal database preview ({d} of {d} packages):\n",
            .{ preview_count, database.packages.packages.items.len },
        );
        for (database.packages.ordered.items[0..preview_count]) |package_id| {
            const package = database.packages.packages.items[@intFromEnum(package_id)];
            std.debug.print("  {s} {s}\n", .{ package.name, package.version.raw });
        }

        for (database.packages.ordered.items) |package_id| {
            const package = database.packages.packages.items[@intFromEnum(package_id)];
            try std.testing.expect(package.name.len > 0);
            try std.testing.expect(package.version.raw.len > 0);
            try std.testing.expectEqual(
                package_id,
                database.packages.by_name.get(package.name).?,
            );
        }
    }

    test "host-readonly: production backend reads actual sync databases" {
        const path = "/var/lib/pacman/sync";
        var dir = std.Io.Dir.cwd().openDir(std.testing.io, path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied => return error.SkipZigTest,
            else => return err,
        };
        defer dir.close(std.testing.io);
        var count: usize = 0;
        var iterator = dir.iterate();
        while (try iterator.next(std.testing.io)) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".db")) continue;
            const full_path = try std.fs.path.join(std.testing.allocator, &.{ path, entry.name });
            defer std.testing.allocator.free(full_path);
            var database = try Database.initSync(
                std.testing.allocator,
                .{
                    .database_name = entry.name[0 .. entry.name.len - 3],
                },
                full_path,
                .{
                    .package = .disabled,
                    .database = .disabled,
                },
            );
            defer database.deinit();
            try database.loadDatabase(std.testing.io, null);
            try database.loadGroups(std.testing.io);
            try std.testing.expect(database.packages.ordered.items.len > 0);
            std.debug.print(
                "  {s}: {d} packages ({t})\n",
                .{
                    database.name,
                    database.packages.ordered.items.len,
                    database.backend.sync.format,
                },
            );
            count += 1;
        }
        if (count == 0) return error.SkipZigTest;
    }
};

test "freeStrings frees each string and the list storage" {
    const allocator = std.testing.allocator;
    var strings: std.ArrayList([]u8) = .empty;
    defer {
        for (strings.items) |string|
            allocator.free(string);
        strings.deinit(allocator);
    }

    const first = try allocator.dupe(u8, "https://mirror-one.example");
    strings.append(allocator, first) catch |err| {
        allocator.free(first);
        return err;
    };

    const second = try allocator.dupe(u8, "https://mirror-two.example");
    strings.append(allocator, second) catch |err| {
        allocator.free(second);
        return err;
    };

    freeStrings(allocator, &strings);

    try std.testing.expectEqual(@as(usize, 0), strings.items.len);
    try std.testing.expectEqual(@as(usize, 0), strings.capacity);
}
