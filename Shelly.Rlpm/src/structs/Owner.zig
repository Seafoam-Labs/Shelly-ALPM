//! Owner is thread-confined except requestCancellation. It owns its configuration
//! and databases; do not shallow-copy an initialized value or move it after
//! publishing its address. Borrowed views end at the next mutating operation.
const std = @import("std");
const Database = @import("Database.zig");
const DatabaseConfiguration = @import("DatabaseConfiguration.zig");
const OwnerConfiguration = @import("OwnerConfiguration.zig");
const DatabaseRef = @import("DatabaseRef.zig");
const PackageRef = @import("PackageRef.zig");
const Package = @import("Package.zig");
const Group = @import("Group.zig");
const Callbacks = @import("Callbacks.zig");
const Diagnostic = @import("Diagnostic.zig");
const Verification = @import("Verification.zig");
const Transaction = @import("Transaction.zig");
const Resolver = @import("Resolver.zig");
const Downloads = @import("Downloads.zig");
const Ops = @import("RootOperations.zig");
const Writer = @import("LocalWriter.zig");
const SignatureResult = @import("SignatureResult.zig");
const PackageRelation = @import("PackageRelation.zig");
const Version = @import("Version.zig");
const ImmutableFile = @import("ImmutableFile.zig");
const PathPatterns = @import("PathPatterns.zig");
const DatabaseUsage = @import("DatabaseUsage.zig");
const DatabaseSearch = @import("DatabaseSearch.zig");
const TransactionPlan = @import("TransactionPlan.zig");
const OwnedQuestion = @import("OwnedQuestion.zig");
const TransactionFlags = @import("TransactionFlags.zig");
const DatabaseLock = @import("DatabaseLock.zig");
const DatabaseSnapshot = @import("DatabaseSnapshot.zig");
const RootPath = @import("RootPath.zig");
const Publication = @import("Publication.zig");

const Owner = @This();

allocator: std.mem.Allocator,
configuration_arena: std.heap.ArenaAllocator,
configuration: OwnerConfiguration,
lock_file: []const u8,
id: DatabaseRef.OwnerId,
local: ?Database,
sync_databases: std.ArrayList(Database) = .empty,
next_database_id: u64 = 1,
busy: bool = false,
in_callback: bool = false,
cancelled: std.atomic.Value(bool) = .init(false),
last_diagnostic: ?Diagnostic = null,
last_verification: ?SignatureResult = null,
active_transaction: ?*Transaction = null,
fallback_cache: ?[]const u8 = null,
download_servers: std.ArrayList(Downloads.ServerState) = .empty,

var next_owner_id: std.atomic.Value(u64) = .init(1);

/// root/dbpath must already be directories. Local format is validated, then
/// identities are loaded. Descriptions/files/groups are loaded on demand.
/// Registration of sync databases never requires their archives or a network.
pub fn init(
    io: std.Io,
    allocator: std.mem.Allocator,
    configuration: OwnerConfiguration,
    databases: []const DatabaseConfiguration,
) !Owner {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = try configuration.copy(arena.allocator(), io);
    const local_path = try std.fmt.allocPrint(arena.allocator(), "{s}local/", .{owned.database_path});
    const lock_file = try std.fmt.allocPrint(arena.allocator(), "{s}db.lck", .{owned.database_path});
    const owner_id = try allocateIdentity();
    var local = try Database.init(allocator, "local", local_path, OwnerConfiguration.disabled_signatures);
    local.backend.local.mode = owned.local_database_mode;
    local.identity = .{ .owner = owner_id, .id = .local };
    var result: Owner = .{
        .allocator = allocator,
        .configuration_arena = arena,
        .configuration = owned,
        .lock_file = lock_file,
        .id = owner_id,
        .local = local,
    };
    // arena is covered by the outer errdefer; only db/list ownership here.
    errdefer result.destroyDatabases();
    for (databases) |db|
        _ = try result.registerInternal(db);
    try result.loadInternal(io, result.localDatabase().?);
    return result;
}

fn allocateIdentity() !DatabaseRef.OwnerId {
    var current = next_owner_id.load(.monotonic);
    while (true) {
        const next = std.math.add(u64, current, 1) catch return error.IdentityExhausted;
        if (next_owner_id.cmpxchgWeak(current, next, .monotonic, .monotonic)) |actual| {
            current = actual;
        } else return @enumFromInt(current);
    }
}

pub fn deinit(self: *Owner) !void {
    try self.checkIdle();
    if (self.active_transaction != null) return error.TransactionActive;
    Verification.clearReport(&self.last_verification);
    self.destroyDatabases();
    for (self.download_servers.items) |entry|
        self.allocator.free(entry.host);
    self.download_servers.deinit(self.allocator);
    if (self.fallback_cache) |path| self.allocator.free(path);
    self.configuration_arena.deinit();
    self.* = undefined;
}

fn destroyDatabases(self: *Owner) void {
    if (self.local) |*local| local.deinit();
    for (self.sync_databases.items) |*db|
        db.deinit();
    self.sync_databases.deinit(self.allocator);
}

pub fn options(self: *const Owner) OwnerConfiguration {
    return self.configuration;
}

pub fn localDatabase(self: *const Owner) ?DatabaseRef {
    return if (self.local) |local| local.identity else null;
}

pub fn findDatabase(self: *const Owner, name: []const u8) ?DatabaseRef {
    if (self.local) |local|
        if (std.mem.eql(u8, name, local.name)) return local.identity;
    for (self.sync_databases.items) |db|
        if (std.mem.eql(u8, name, db.name)) return db.identity;
    return null;
}

/// Registration order is repository priority. The slice is borrowed.
pub fn syncDatabases(self: *const Owner) []const Database {
    return self.sync_databases.items;
}

pub fn database(self: *const Owner, reference: DatabaseRef) !*const Database {
    try self.checkIdle();
    return self.resolveDatabase(reference);
}

fn resolveDatabase(self: *const Owner, reference: DatabaseRef) !*const Database {
    if (reference.owner != self.id) return error.ForeignOwner;
    if (reference.id == .local) return if (self.local) |*local| local else error.StaleDatabaseReference;
    for (self.sync_databases.items) |*db|
        if (db.identity.?.id == reference.id) return db;
    return error.StaleDatabaseReference;
}

fn mutableDatabase(self: *Owner, reference: DatabaseRef) !*Database {
    return @constCast(try self.resolveDatabase(reference));
}

pub fn registerDatabase(self: *Owner, configuration: DatabaseConfiguration) !DatabaseRef {
    try self.begin(.register_database);
    defer self.busy = false;
    return self.registerInternal(configuration) catch |err| return self.fail(.register_database, err, null);
}

fn registerInternal(self: *Owner, configuration: DatabaseConfiguration) !DatabaseRef {
    try configuration.validate();
    if (self.findDatabase(configuration.database_name) != null) return error.DuplicateDatabase;
    const next = std.math.add(u64, self.next_database_id, 1) catch return error.IdentityExhausted;
    if (self.next_database_id == @intFromEnum(DatabaseRef.Id.archive)) return error.IdentityExhausted;
    const path = try self.syncPath(self.allocator, self.configuration, configuration.database_name);
    defer self.allocator.free(path);
    var db = try Database.initSync(
        self.allocator,
        configuration,
        path,
        self.configuration.default_signature_policy,
    );
    errdefer db.deinit();
    const reference: DatabaseRef = .{ .owner = self.id, .id = @enumFromInt(self.next_database_id) };
    db.identity = reference;
    try self.sync_databases.append(self.allocator, db);
    self.next_database_id = next;
    return reference;
}

fn syncPath(
    _: *const Owner,
    allocator: std.mem.Allocator,
    configuration: OwnerConfiguration,
    name: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}sync/{s}{s}",
        .{
            configuration.database_path,
            name,
            configuration.database_extension,
        },
    );
}

pub fn unregisterDatabase(self: *Owner, reference: DatabaseRef) !void {
    try self.begin(.unregister_database);
    defer self.busy = false;
    _ = self.resolveDatabase(reference) catch |err| return self.fail(.unregister_database, err, reference);
    if (reference.id == .local) {
        self.local.?.deinit();
        self.local = null;
        return;
    }
    for (self.sync_databases.items, 0..) |db, index| {
        if (db.identity.?.id == reference.id) {
            var removed = self.sync_databases.orderedRemove(index);
            removed.deinit();
            return;
        }
    }
    unreachable;
}

pub fn unregisterSyncDatabases(self: *Owner) !void {
    try self.begin(.unregister_database);
    defer self.busy = false;
    for (self.sync_databases.items) |*db|
        db.deinit();
    self.sync_databases.clearRetainingCapacity();
}

/// Atomic replacement: copies input before releasing any borrowed old values.
/// Root/dbpath are immutable. Only sync path/signature-policy changes invalidate
/// sync generations. Local metadata and unrelated option changes retain caches.
pub fn setOptions(self: *Owner, io: std.Io, configuration: OwnerConfiguration) !void {
    try self.begin(.configure);
    defer self.busy = false;
    self.replaceOptions(io, configuration) catch |err| return self.fail(.configure, err, null);
}

fn replaceOptions(self: *Owner, io: std.Io, configuration: OwnerConfiguration) !void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    errdefer arena.deinit();
    const owned = try configuration.copy(arena.allocator(), io);
    if (!std.mem.eql(u8, owned.root, self.configuration.root) or
        !std.mem.eql(
            u8,
            owned.database_path,
            self.configuration.database_path,
        ))
        return error.ImmutablePath;
    const lock_file = try std.fmt.allocPrint(arena.allocator(), "{s}db.lck", .{owned.database_path});
    var databases: std.ArrayList(Database) = .empty;
    errdefer {
        for (databases.items) |*db|
            db.deinit();
        databases.deinit(self.allocator);
    }
    for (self.sync_databases.items) |*old| {
        const path = try self.syncPath(arena.allocator(), owned, old.name);
        var replacement = try old.copyRegistration(path, owned.default_signature_policy);
        errdefer replacement.deinit();
        try databases.append(self.allocator, replacement);
    }
    for (self.sync_databases.items, databases.items) |*old, *replacement| {
        if (std.mem.eql(u8, old.path, replacement.path) and
            std.meta.eql(
                old.signature_policy,
                replacement.signature_policy,
            ) and
            optionalEqual(
                self.configuration.gpg_directory,
                owned.gpg_directory,
            ))
            replacement.takeCache(old);
        old.deinit();
    }
    self.sync_databases.deinit(self.allocator);
    self.configuration_arena.deinit();
    self.configuration_arena = arena;
    self.configuration = owned;
    self.lock_file = lock_file;
    self.sync_databases = databases;
    if (self.local) |*local| local.backend.local.mode = owned.local_database_mode;
}

fn optionalEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |first| return if (b) |second| std.mem.eql(u8, first, second) else false;
    return b == null;
}

pub fn setList(
    self: *Owner,
    io: std.Io,
    comptime field: OwnerConfiguration.StringList,
    values: []const []const u8,
) !void {
    var updated = self.options();
    @field(updated, @tagName(field)) = values;
    try self.setOptions(io, updated);
}

pub fn addListValue(
    self: *Owner,
    io: std.Io,
    comptime field: OwnerConfiguration.StringList,
    value: []const u8,
) !void {
    try self.checkIdle();
    const old = self.configuration.list(field);
    const updated = try self.allocator.alloc([]const u8, old.len + 1);
    defer self.allocator.free(updated);
    @memcpy(updated[0..old.len], old);
    updated[old.len] = value;
    try self.setList(io, field, updated);
}

/// Removes the first equal item. Directory comparisons include trailing slash
/// normalization, as with their setter. Duplicate list entries remain ordered.
pub fn removeListValue(
    self: *Owner,
    io: std.Io,
    comptime field: OwnerConfiguration.StringList,
    value: []const u8,
) !bool {
    try self.checkIdle();
    const directories = field == .cache_directories or field == .hook_directories;
    const normalized = if (directories)
        try OwnerConfiguration.directoryString(self.allocator, value)
    else
        try self.allocator.dupe(u8, value);
    defer self.allocator.free(normalized);
    const old = self.configuration.list(field);
    for (old, 0..) |item, index| {
        if (!std.mem.eql(u8, item, normalized)) continue;
        const updated = try self.allocator.alloc([]const u8, old.len - 1);
        defer self.allocator.free(updated);
        @memcpy(updated[0..index], old[0..index]);
        @memcpy(updated[index..], old[index + 1 ..]);
        try self.setList(io, field, updated);
        return true;
    }
    return false;
}

pub fn loadDatabase(self: *Owner, io: std.Io, reference: DatabaseRef) !void {
    try self.begin(.load_database);
    defer self.busy = false;
    self.loadInternal(io, reference) catch |err| return self.fail(.load_database, err, reference);
}

pub fn addAssumedInstalled(
    self: *Owner,
    io: std.Io,
    relation: PackageRelation,
) !void {
    try self.checkIdle();
    const old = self.configuration.assume_installed;
    const values = try self.allocator.alloc(PackageRelation, old.len + 1);
    defer self.allocator.free(values);
    @memcpy(values[0..old.len], old);
    values[old.len] = relation;
    var config = self.configuration;
    config.assume_installed = values;
    try self.setOptions(io, config);
}

/// Removes the first equal name/raw-version, ignoring description/operator.
pub fn removeAssumedInstalled(
    self: *Owner,
    io: std.Io,
    relation: PackageRelation,
) !bool {
    try self.checkIdle();
    const old = self.configuration.assume_installed;
    for (old, 0..) |item, index| {
        if (!std.mem.eql(u8, item.name, relation.name)) continue;
        const wanted = switch (relation.constraint) {
            .any => null,
            inline else => |v| @as(?[]const u8, v),
        };
        const actual = switch (item.constraint) {
            .any => null,
            inline else => |v| @as(?[]const u8, v),
        };
        if (!optionalEqual(wanted, actual)) continue;
        const values = try self.allocator.alloc(PackageRelation, old.len - 1);
        defer self.allocator.free(values);
        @memcpy(values[0..index], old[0..index]);
        @memcpy(values[index..], old[index + 1 ..]);
        var config = self.configuration;
        config.assume_installed = values;
        try self.setOptions(io, config);
        return true;
    }
    return false;
}

pub fn shouldIgnore(self: *Owner, io: std.Io, reference: PackageRef) !bool {
    const pkg = try self.packageMetadata(io, reference, .{});
    try self.begin(.query);
    defer self.busy = false;
    return Resolver.shouldIgnore(
        self.allocator,
        .{
            .ignore_packages = self.configuration.ignore_packages,
            .ignore_groups = self.configuration.ignore_groups,
        },
        pkg,
    ) catch |err|
        return self.fail(.query, err, reference.database);
}

/// Query only: first literal repository match, regardless of usage/ignore policy.
pub fn newVersion(self: *Owner, io: std.Io, target: *const Package) !?PackageRef {
    try self.begin(.query);
    defer self.busy = false;
    for (self.sync_databases.items) |*db| {
        self.ensureInternal(io, db.identity.?) catch |err| {
            if (err == error.FileNotFound) continue;
            return self.fail(.query, err, db.identity);
        };
        const id = db.packages.by_name.get(target.name) orelse continue;
        const candidate = &db.packages.packages.items[@intFromEnum(id)];
        if (Version.compareStrings(candidate.version.raw, target.version.raw) != .greaterThan)
            return null;
        return .{
            .database = db.identity.?,
            .generation = db.generation,
            .id = id,
        };
    }
    return null;
}

fn loadInternal(self: *Owner, io: std.Io, reference: DatabaseRef) !void {
    try self.checkCancelled();
    const db = try self.mutableDatabase(reference);
    if (db.status.package_cache_loaded) return error.DatabaseAlreadyLoaded;
    try db.reloadWithVerification(io, self.verificationContext());
    try self.checkCancelled();
}

pub fn invalidateDatabase(self: *Owner, reference: DatabaseRef) !void {
    try self.begin(.invalidate_database);
    defer self.busy = false;
    const db = self.mutableDatabase(reference) catch |err|
        return self.fail(
            .invalidate_database,
            err,
            reference,
        );
    db.invalidateCache() catch |err| return self.fail(.invalidate_database, err, reference);
}

fn loadedDatabase(self: *const Owner, reference: DatabaseRef) !*const Database {
    const result = try self.database(reference);
    if (!result.status.package_cache_loaded) return error.DatabaseNotLoaded;
    return result;
}

pub fn packageIds(self: *const Owner, reference: DatabaseRef) ![]const Database.PackageId {
    return (try self.loadedDatabase(reference)).packages.ordered.items;
}

pub fn findPackage(self: *const Owner, reference: DatabaseRef, name: []const u8) !?PackageRef {
    const db = try self.loadedDatabase(reference);
    const id = db.packages.by_name.get(name) orelse return null;
    return .{
        .database = reference,
        .generation = db.generation,
        .id = id,
    };
}

pub fn packageReference(self: *const Owner, reference: DatabaseRef, id: Database.PackageId) !PackageRef {
    const db = try self.loadedDatabase(reference);
    if (@intFromEnum(id) >= db.packages.packages.items.len) return error.StalePackageReference;
    return .{
        .database = reference,
        .generation = db.generation,
        .id = id,
    };
}

pub fn package(self: *const Owner, reference: PackageRef) !*const Package {
    const db = try self.database(reference.database);
    if (reference.generation != db.generation or !db.status.package_cache_loaded or
        @intFromEnum(reference.id) >= db.packages.packages.items.len)
        return error.StalePackageReference;
    return &db.packages.packages.items[@intFromEnum(reference.id)];
}

pub fn findGroup(self: *Owner, io: std.Io, reference: DatabaseRef, name: []const u8) !?*const Group {
    try self.ensureDatabase(io, reference);
    try self.begin(.query);
    defer self.busy = false;
    const db = try self.mutableDatabase(reference);
    db.loadGroups(io) catch |err| return self.fail(.query, err, reference);
    const id = db.groups.by_name.get(name) orelse return null;
    return &db.groups.groups.items[@intFromEnum(id)];
}

/// Lazy query variants take Io explicitly; snapshot accessors never hide I/O.
pub fn ensureDatabase(self: *Owner, io: std.Io, reference: DatabaseRef) !void {
    try self.begin(.query);
    defer self.busy = false;
    self.ensureInternal(io, reference) catch |err| return self.fail(.load_database, err, reference);
}

fn ensureInternal(self: *Owner, io: std.Io, reference: DatabaseRef) !void {
    try self.checkCancelled();
    if (!(try self.resolveDatabase(reference)).status.package_cache_loaded)
        try self.loadInternal(io, reference);
}

pub fn reloadDatabase(self: *Owner, io: std.Io, reference: DatabaseRef) !void {
    try self.begin(.load_database);
    defer self.busy = false;
    try self.checkCancelled();
    const db = self.mutableDatabase(reference) catch |err| return self.fail(.load_database, err, reference);
    db.reloadWithVerification(io, self.verificationContext()) catch |err|
        return self.fail(.load_database, err, reference);
}

pub const PackageSource = union(enum) { local_file, remote_file, repository: PackageRef };

/// Every load, including a cache hit, applies the current effective policy.
/// Returns an owned package retaining the verified bytes for future extraction.
pub fn loadPackage(
    self: *Owner,
    io: std.Io,
    path: []const u8,
    source: PackageSource,
    load_options: Package.LoadOptions,
) !Package {
    try self.begin(.load_package);
    defer self.busy = false;
    return self.loadPackageInternal(io, path, source, load_options) catch |err|
        return self.fail(.load_package, err, null);
}

fn loadPackageInternal(
    self: *Owner,
    io: std.Io,
    path: []const u8,
    source: PackageSource,
    load_options: Package.LoadOptions,
) !Package {
    try self.checkCancelled();
    Verification.clearReport(&self.last_verification);
    const policy = switch (source) {
        .local_file => self.configuration.effectiveLocalSignaturePolicy(),
        .remote_file => self.configuration.effectiveRemoteSignaturePolicy(),
        .repository => |reference| (try self.resolveDatabase(reference.database)).signature_policy,
    };
    var expected: ?*const Package = null;
    if (source == .repository) {
        const reference = source.repository;
        const db = try self.resolveDatabase(reference.database);
        if (db.kind != .sync) return error.UnsupportedPackageOrigin;
        if (reference.generation != db.generation or !db.status.package_cache_loaded or
            @intFromEnum(reference.id) >= db.packages.packages.items.len)
            return error.StalePackageReference;
        expected = &db.packages.packages.items[@intFromEnum(reference.id)];
    }
    var snapshot = try ImmutableFile.copy(io, path);
    errdefer snapshot.deinit();
    const validation = try Verification.check(self.allocator, io, self.verificationContext(), &snapshot, path, .{
        .requirement = policy.package,
        .trust = policy.package_trust,
        .md5 = if (expected) |package_info| package_info.md5_sum else null,
        .sha256 = if (expected) |package_info| package_info.sha256_sum else null,
        .base64_signature = if (expected) |package_info| package_info.base64_signature else null,
        .refresh_expired_keys = source != .repository,
    }, &self.last_verification);
    var loaded = try Package.loadArchive(self.allocator, snapshot.path(), load_options);
    errdefer loaded.deinit();
    if (expected) |package_info| {
        if (!std.mem.eql(u8, loaded.name, package_info.name) or
            !std.mem.eql(
                u8,
                loaded.version.raw,
                package_info.version.raw,
            ))
            return error.PackageIdentityMismatch;
        // A repository-authenticated archive can later be transferred into a
        // transaction. Preserve the verification inputs and CachyOS provenance
        // so preflight can repeat checks without requiring a detached sidecar
        // when this repository supplied an embedded signature.
        const owned = loaded.archive_arena.?.allocator();
        inline for (.{ "md5_sum", "sha256_sum", "base64_signature", "repository_filename" }) |field| {
            @field(loaded, field) = if (@field(package_info, field)) |value|
                try owned.dupe(u8, value)
            else
                null;
        }
        loaded.installed_database = try owned.dupe(u8, package_info.database_name);
    }
    loaded.archive_path = try loaded.archive_arena.?.allocator().dupe(u8, path);
    loaded.validation = validation;
    loaded.archive_signature_policy = policy;
    loaded.archive_source = switch (source) {
        .local_file => .local_file,
        .remote_file => .remote_file,
        .repository => .repository,
    };
    loaded.archive_repository = if (source == .repository) source.repository.database else null;
    try self.checkCancelled();
    loaded.verified_archive = snapshot;
    return loaded;
}

pub fn verificationContext(self: *Owner) Verification.Context {
    return .{
        .gpg_directory = self.configuration.gpg_directory,
        .acquisition = self.configuration.key_acquisition,
        .question_context = self,
        .question = importQuestion,
        .check_cancelled = verificationCancellation,
    };
}

pub fn matchNoExtract(self: *const Owner, path: []const u8) !PathPatterns.Match {
    try self.checkIdle();
    return PathPatterns.match(self.allocator, self.configuration.no_extract, path);
}

pub fn matchNoUpgrade(self: *const Owner, path: []const u8) !PathPatterns.Match {
    try self.checkIdle();
    return PathPatterns.match(self.allocator, self.configuration.no_upgrade, path);
}

fn importQuestion(context: ?*anyopaque, question: *Callbacks.Question) !void {
    const self: *Owner = @ptrCast(@alignCast(context.?));
    try self.askInternal(question);
}

fn verificationCancellation(context: ?*anyopaque) !void {
    const self: *Owner = @ptrCast(@alignCast(context.?));
    try self.checkCancelled();
}

pub fn queryPackage(self: *Owner, io: std.Io, reference: DatabaseRef, name: []const u8) !?PackageRef {
    try self.ensureDatabase(io, reference);
    return self.findPackage(reference, name);
}

pub fn packageMetadata(
    self: *Owner,
    io: std.Io,
    reference: PackageRef,
    request: Database.Metadata,
) !*const Package {
    _ = try self.package(reference);
    try self.begin(.query);
    defer self.busy = false;
    try self.checkCancelled();
    const db = try self.mutableDatabase(reference.database);
    db.loadMetadata(io, reference.id, request) catch |err| return self.fail(.query, err, reference.database);
    return &db.packages.packages.items[@intFromEnum(reference.id)];
}

pub fn groupIds(self: *Owner, io: std.Io, reference: DatabaseRef) ![]const Database.GroupId {
    try self.ensureDatabase(io, reference);
    try self.begin(.query);
    defer self.busy = false;
    const db = try self.mutableDatabase(reference);
    db.loadGroups(io) catch |err| return self.fail(.query, err, reference);
    return db.groups.ordered.items;
}

pub const Usage = enum { sync, search, install, upgrade };

/// Caller owns this list. Usage filtering is specific to candidate operations;
/// direct exact/group queries remain visible regardless of these flags.
pub fn repositoriesFor(self: *const Owner, allocator: std.mem.Allocator, usage: Usage) ![]DatabaseRef {
    try self.checkIdle();
    var result: std.ArrayList(DatabaseRef) = .empty;
    errdefer result.deinit(allocator);
    for (self.sync_databases.items) |db|
        if (allows(db, usage)) {
            try result.append(allocator, db.identity.?);
        };
    return result.toOwnedSlice(allocator);
}

fn allows(db: Database, usage: Usage) bool {
    return switch (usage) {
        .sync => db.usage.sync,
        .search => db.usage.search,
        .install => db.usage.install,
        .upgrade => db.usage.upgrade,
    };
}

pub fn setDatabaseUsage(
    self: *Owner,
    reference: DatabaseRef,
    usage: DatabaseUsage,
) !void {
    try self.begin(.configure);
    defer self.busy = false;
    const db = self.mutableDatabase(reference) catch |err| return self.fail(.configure, err, reference);
    db.usage = usage;
}

pub const ServerList = enum { servers, cache_servers };

pub fn setServers(
    self: *Owner,
    reference: DatabaseRef,
    comptime list: ServerList,
    values: []const []const u8,
) !void {
    try self.begin(.configure);
    defer self.busy = false;
    self.editServers(reference, list, .set, values) catch |err| return self.fail(.configure, err, reference);
}

pub fn addServer(
    self: *Owner,
    reference: DatabaseRef,
    comptime list: ServerList,
    value: []const u8,
) !void {
    try self.begin(.configure);
    defer self.busy = false;
    self.editServers(reference, list, .append, &.{value}) catch |err|
        return self.fail(.configure, err, reference);
}

fn editServers(
    self: *Owner,
    reference: DatabaseRef,
    comptime list: ServerList,
    operation: enum { set, append },
    values: []const []const u8,
) !void {
    const db = try self.mutableDatabase(reference);
    for (values) |value|
        try OwnerConfiguration.validateString(value, false);
    var candidate = try db.copyRegistration(db.path, db.signature_policy);
    errdefer candidate.deinit();
    const target = &@field(candidate, @tagName(list));
    if (operation == .set) target.clearRetainingCapacity();
    for (values) |value| {
        const normalized = if (std.mem.endsWith(u8, value, "/")) value[0 .. value.len - 1] else value;
        try target.append(candidate.arena.allocator(), try candidate.arena.allocator().dupe(u8, normalized));
    }
    candidate.takeCache(db);
    db.deinit();
    db.* = candidate;
}

pub fn removeServer(
    self: *Owner,
    reference: DatabaseRef,
    comptime list: ServerList,
    value: []const u8,
) !bool {
    try self.begin(.configure);
    defer self.busy = false;
    return self.removeServerInternal(reference, list, value) catch |err|
        return self.fail(.configure, err, reference);
}

fn removeServerInternal(
    self: *Owner,
    reference: DatabaseRef,
    comptime list: ServerList,
    value: []const u8,
) !bool {
    try OwnerConfiguration.validateString(value, false);
    const db = try self.mutableDatabase(reference);
    const normalized = if (std.mem.endsWith(u8, value, "/")) value[0 .. value.len - 1] else value;
    for (@field(db, @tagName(list)).items, 0..) |server, index| {
        if (!std.mem.eql(u8, server, normalized)) continue;
        var candidate = try db.copyRegistration(db.path, db.signature_policy);
        _ = @field(candidate, @tagName(list)).orderedRemove(index);
        candidate.takeCache(db);
        db.deinit();
        db.* = candidate;
        return true;
    }
    return false;
}

pub fn findCandidate(self: *Owner, io: std.Io, name: []const u8, usage: Usage) !?PackageRef {
    try self.checkIdle();
    for (self.sync_databases.items) |db| {
        if (!allows(db, usage)) continue;
        if (try self.queryPackage(io, db.identity.?, name)) |found| return found;
    }
    return null;
}

/// The returned array is caller-owned; its generation-checked references are
/// borrowed from this Owner. Repository priority wins duplicate package names.
pub fn search(
    self: *Owner,
    io: std.Io,
    allocator: std.mem.Allocator,
    patterns: []const []const u8,
) ![]PackageRef {
    try self.begin(.query);
    defer self.busy = false;
    return self.searchInternal(io, allocator, null, patterns) catch |err| return self.fail(.query, err, null);
}

pub fn searchDatabase(
    self: *Owner,
    io: std.Io,
    allocator: std.mem.Allocator,
    reference: DatabaseRef,
    patterns: []const []const u8,
) ![]PackageRef {
    try self.begin(.query);
    defer self.busy = false;
    return self.searchInternal(io, allocator, reference, patterns) catch |err|
        return self.fail(.query, err, reference);
}

fn searchInternal(
    self: *Owner,
    io: std.Io,
    allocator: std.mem.Allocator,
    reference: ?DatabaseRef,
    patterns: []const []const u8,
) ![]PackageRef {
    var result: std.ArrayList(PackageRef) = .empty;
    errdefer result.deinit(allocator);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    if (reference) |ref| {
        const db = try self.mutableDatabase(ref);
        if (db.usage.search) try self.searchOne(io, allocator, db, patterns, &result, &seen);
    } else {
        for (self.sync_databases.items) |*db|
            if (db.usage.search) {
                try self.searchOne(io, allocator, db, patterns, &result, &seen);
            };
    }
    return result.toOwnedSlice(allocator);
}

fn searchOne(
    self: *Owner,
    io: std.Io,
    allocator: std.mem.Allocator,
    db: *Database,
    patterns: []const []const u8,
    result: *std.ArrayList(PackageRef),
    seen: *std.StringHashMapUnmanaged(void),
) !void {
    try self.ensureInternal(io, db.identity.?);
    try db.loadDescriptions(io);
    var searcher = try DatabaseSearch.init(allocator, patterns);
    defer searcher.deinit();
    for (db.packages.ordered.items) |id| {
        try self.checkCancelled();
        const pkg = &db.packages.packages.items[@intFromEnum(id)];
        if (seen.contains(pkg.name) or !try searcher.matches(pkg)) continue;
        try seen.put(allocator, pkg.name, {});
        try result.append(allocator, .{
            .database = db.identity.?,
            .generation = db.generation,
            .id = id,
        });
    }
}

pub fn groupPackages(
    self: *Owner,
    io: std.Io,
    allocator: std.mem.Allocator,
    name: []const u8,
) ![]PackageRef {
    try self.begin(.query);
    defer self.busy = false;
    return self.groupPackagesInternal(io, allocator, name) catch |err| return self.fail(.query, err, null);
}

fn groupPackagesInternal(
    self: *Owner,
    io: std.Io,
    allocator: std.mem.Allocator,
    name: []const u8,
) ![]PackageRef {
    var result: std.ArrayList(PackageRef) = .empty;
    errdefer result.deinit(allocator);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    for (self.sync_databases.items) |*db| {
        try self.ensureInternal(io, db.identity.?);
        try db.loadGroups(io);
        const group_id = db.groups.by_name.get(name) orelse continue;
        for (db.groups.groups.items[@intFromEnum(group_id)].packages.items) |id| {
            const pkg = &db.packages.packages.items[@intFromEnum(id)];
            if (seen.contains(pkg.name)) continue;
            try seen.put(allocator, pkg.name, {});
            try result.append(
                allocator,
                .{
                    .database = db.identity.?,
                    .generation = db.generation,
                    .id = id,
                },
            );
        }
    }
    return result.toOwnedSlice(allocator);
}

pub fn requiredBy(
    self: *Owner,
    io: std.Io,
    allocator: std.mem.Allocator,
    reference: PackageRef,
) ![]PackageRef {
    const target = try self.packageMetadata(io, reference, .{});
    return self.reverseDependencies(io, allocator, target, false);
}

pub fn optionalFor(
    self: *Owner,
    io: std.Io,
    allocator: std.mem.Allocator,
    reference: PackageRef,
) ![]PackageRef {
    const target = try self.packageMetadata(io, reference, .{});
    return self.reverseDependencies(io, allocator, target, true);
}

/// Local/archive targets inspect the installed universe; sync targets inspect
/// every registered sync database, independent of usage flags. Names are unique
/// and sorted. An archive target can be supplied directly without registration.
pub fn reverseDependencies(
    self: *Owner,
    io: std.Io,
    allocator: std.mem.Allocator,
    target: *const Package,
    optional: bool,
) ![]PackageRef {
    try self.begin(.query);
    defer self.busy = false;
    return self.reverseInternal(io, allocator, target, optional) catch |err|
        return self.fail(.query, err, null);
}

fn reverseInternal(
    self: *Owner,
    io: std.Io,
    allocator: std.mem.Allocator,
    target: *const Package,
    optional: bool,
) ![]PackageRef {
    var result: std.ArrayList(PackageRef) = .empty;
    errdefer result.deinit(allocator);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    if (target.origin == .sync) {
        for (self.sync_databases.items) |*db|
            try self.reverseOne(
                io,
                allocator,
                db,
                target,
                optional,
                &result,
                &seen,
            );
    } else if (self.local) |*db| try self.reverseOne(io, allocator, db, target, optional, &result, &seen);
    std.mem.sort(PackageRef, result.items, self, struct {
        fn less(owner: *Owner, a: PackageRef, b: PackageRef) bool {
            const first = owner.resolveDatabase(a.database) catch unreachable;
            const second = owner.resolveDatabase(b.database) catch unreachable;
            return std.mem.lessThan(
                u8,
                first.packages.packages.items[@intFromEnum(a.id)].name,
                second.packages.packages.items[@intFromEnum(b.id)].name,
            );
        }
    }.less);
    return result.toOwnedSlice(allocator);
}

fn reverseOne(
    self: *Owner,
    io: std.Io,
    allocator: std.mem.Allocator,
    db: *Database,
    target: *const Package,
    optional: bool,
    result: *std.ArrayList(PackageRef),
    seen: *std.StringHashMapUnmanaged(void),
) !void {
    try self.ensureInternal(io, db.identity.?);
    try db.loadDescriptions(io);
    for (db.packages.ordered.items) |id| {
        const pkg = &db.packages.packages.items[@intFromEnum(id)];
        if (seen.contains(pkg.name)) continue;
        for (if (optional) pkg.optional_depends else pkg.depends) |relation| {
            if (!target.satisfies(relation)) continue;
            try seen.put(allocator, pkg.name, {});
            try result.append(
                allocator,
                .{
                    .database = db.identity.?,
                    .generation = db.generation,
                    .id = id,
                },
            );
            break;
        }
    }
}

/// Read-only preparation over owned snapshots. Semantic errors are returned in
/// the plan (check plan.check()); operational errors also set Owner.diagnostic.
/// This does not acquire a transaction lock or authorize a future commit.
pub fn resolve(self: *Owner, io: std.Io, request: Resolver.Request) !TransactionPlan {
    try self.begin(.resolve);
    defer self.busy = false;
    return self.resolveInternal(io, request) catch |err| return self.fail(.resolve, err, null);
}

fn resolveInternal(self: *Owner, io: std.Io, request: Resolver.Request) !TransactionPlan {
    // Reject invalid identities before unrelated lazy database I/O can mask the
    // reference error (or invoke verification callbacks for an invalid request).
    for (request.install) |target|
        if (target == .reference) {
            const reference = target.reference;
            const db = try self.resolveDatabase(reference.database);
            if (db.generation != reference.generation or !db.status.package_cache_loaded or
                @intFromEnum(reference.id) >= db.packages.packages.items.len)
                return error.StalePackageReference;
        };
    var scratch = std.heap.ArenaAllocator.init(self.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const local_ref = self.localDatabase() orelse return error.StaleDatabaseReference;
    const local = try self.resolutionEntries(io, a, local_ref);
    var repos: std.ArrayList(Resolver.Repository) = .empty;
    if (request.install.len != 0 or request.system_upgrade)
        for (self.sync_databases.items) |*db| {
            const entries = self.resolutionEntries(io, a, db.identity.?) catch |err|
                if (err == error.FileNotFound)
                    &.{}
                else
                    return err;
            try repos.append(
                a,
                .{
                    .reference = db.identity.?,
                    .name = db.name,
                    .usage = db.usage,
                    .packages = entries,
                    .status = if (db.status.presence == .missing)
                        .missing
                    else
                        .valid,
                },
            );
        };
    return Resolver.resolve(self.allocator, .{
        .owner = self.id,
        .local = local,
        .repositories = repos.items,
    }, .{
        .architectures = self.configuration.architectures,
        .ignore_packages = self.configuration.ignore_packages,
        .ignore_groups = self.configuration.ignore_groups,
        .assume_installed = self.configuration.assume_installed,
    }, request, .{
        .user = self,
        .question = resolutionQuestion,
        .check_cancelled = verificationCancellation,
        .event = resolutionEvent,
    });
}

fn resolutionEvent(context: ?*anyopaque, event: Callbacks.Event) !void {
    const self: *Owner = @ptrCast(@alignCast(context.?));
    self.transactionEvent(event);
    try self.checkCancelled();
}

fn resolutionEntries(
    self: *Owner,
    io: std.Io,
    a: std.mem.Allocator,
    reference: DatabaseRef,
) ![]const Resolver.Entry {
    try self.ensureInternal(io, reference);
    const db = try self.mutableDatabase(reference);
    const entries = try a.alloc(Resolver.Entry, db.packages.ordered.items.len);
    for (db.packages.ordered.items, entries) |id, *entry| {
        try self.checkCancelled();
        // Incomplete local metadata cannot safely participate in a solve.
        try db.loadMetadata(io, id, .{});
        const pkg = &db.packages.packages.items[@intFromEnum(id)];
        if (pkg.metadata_error) |err| return err;
        entry.* = .{
            .reference = .{
                .database = reference,
                .generation = db.generation,
                .id = id,
            },
            .package = pkg,
        };
    }
    return entries;
}

fn resolutionQuestion(context: ?*anyopaque, question: *Callbacks.Question) anyerror!void {
    const self: *Owner = @ptrCast(@alignCast(context.?));
    try self.askInternal(question);
}

pub fn setCallbacks(self: *Owner, callbacks: Callbacks) !void {
    try self.checkIdle();
    if (self.active_transaction != null) return error.TransactionActive;
    self.configuration.callbacks = callbacks;
}

pub fn emit(self: *Owner, event: Callbacks.Event) !void {
    try self.begin(.callback);
    defer self.busy = false;
    self.checkCancelled() catch |err| return self.fail(.callback, err, null);
    if (self.configuration.callbacks.event) |callback| {
        self.in_callback = true;
        defer self.in_callback = false;
        callback(self.configuration.callbacks.event_context, event);
    }
    self.checkCancelled() catch |err| return self.fail(.callback, err, null);
}

pub fn ask(self: *Owner, question: *Callbacks.Question) !void {
    try self.begin(.callback);
    defer self.busy = false;
    const original = question.*;
    errdefer question.* = original;
    self.askInternal(question) catch |err| return self.fail(.callback, err, null);
    if (std.meta.activeTag(original) != std.meta.activeTag(question.*))
        return self.fail(
            .callback,
            error.InvalidAnswer,
            null,
        );
    if (question.* == .select_provider and
        question.select_provider.selected >= question.select_provider.candidates.len)
        return self.fail(
            .callback,
            error.InvalidAnswer,
            null,
        );
}

pub fn askInternal(self: *Owner, question: *Callbacks.Question) !void {
    try self.checkCancelled();
    var answer = question.*;
    if (self.configuration.callbacks.question_with_error) |callback| {
        self.in_callback = true;
        defer self.in_callback = false;
        try callback(self.configuration.callbacks.question_context, &answer);
    } else if (self.configuration.callbacks.question) |callback| {
        self.in_callback = true;
        defer self.in_callback = false;
        callback(self.configuration.callbacks.question_context, &answer);
    }
    try self.checkCancelled();
    try OwnedQuestion.applyAnswer(question, answer);
}

/// The only method callable from another thread or from an active callback.
pub fn requestCancellation(self: *Owner) void {
    self.cancelled.store(true, .release);
}

pub fn resetCancellation(self: *Owner) !void {
    try self.checkIdle();
    self.cancelled.store(false, .release);
}

pub fn checkCancelled(self: *const Owner) !void {
    if (self.cancelled.load(.acquire)) return error.Cancelled;
}

pub fn diagnostic(self: *const Owner) ?Diagnostic {
    return self.last_diagnostic;
}

fn checkIdle(self: *const Owner) !void {
    if (self.in_callback) return error.CallbackReentry;
    if (self.busy) return error.OwnerBusy;
}

fn begin(self: *Owner, operation: Diagnostic.Operation) !void {
    self.checkIdle() catch |err| return self.fail(operation, err, null);
    if (self.active_transaction != null and operation != .query and operation != .callback and
        operation != .load_package)
        return self.fail(
            operation,
            error.TransactionActive,
            null,
        );
    self.last_diagnostic = null;
    self.busy = true;
}

fn fail(self: *Owner, operation: Diagnostic.Operation, cause: anyerror, db: ?DatabaseRef) anyerror {
    self.last_diagnostic = Diagnostic.init(operation, cause, db);
    return cause;
}

/// Acquires db.lck before reloading cached identities. PackageRefs acquired
/// before initialization become stale; obtain targets after this call.
pub fn initializeTransaction(
    self: *Owner,
    io: std.Io,
    flags: TransactionFlags,
) !*Transaction {
    try self.begin(.transaction);
    defer self.busy = false;
    return self.initializeTransactionInternal(io, flags) catch |err| return self.transactionFailure(err);
}

fn initializeTransactionInternal(
    self: *Owner,
    io: std.Io,
    flags: TransactionFlags,
) !*Transaction {
    try self.checkCancelled();
    var lock: ?DatabaseLock = if (flags.no_lock)
        null
    else
        try DatabaseLock.acquire(
            self.allocator,
            self.lock_file,
        );
    errdefer if (lock) |*value| value.release(self.allocator) catch {};
    const snapshot = try DatabaseSnapshot.capture(self, io);
    const local = if (self.local) |*db| db else return error.StaleDatabaseReference;
    try local.invalidateCache();
    for (self.sync_databases.items) |*db|
        try db.invalidateCache();
    try self.loadInternal(io, self.localDatabase().?);
    if (!std.mem.eql(u8, &snapshot, &try DatabaseSnapshot.capture(self, io)))
        return error.StaleDatabaseState;
    const active = try self.allocator.create(Transaction);
    active.* = .{
        .owner = self,
        .io = io,
        .flags = flags,
        .storage = .init(self.allocator),
        .snapshot = snapshot,
        .lock = lock,
    };
    self.active_transaction = active;
    active.transition(.initialized, null);
    return active;
}

pub fn transaction(self: *const Owner) ?*const Transaction {
    return self.active_transaction;
}

pub fn releaseTransaction(self: *Owner) !void {
    try self.checkIdle();
    const active = self.active_transaction orelse
        return self.transactionFailure(
            error.TransactionNotInitialized,
        );
    self.busy = true;
    defer self.busy = false;
    defer self.active_transaction = null;
    active.destroy() catch |err| return self.transactionFailure(err);
}

/// Explicitly drops only this owner's lock. Foreign/stale locks are never
/// removed. A transaction whose lock was dropped cannot subsequently commit.
pub fn unlock(self: *Owner) !void {
    try self.checkIdle();
    const active = self.active_transaction orelse return;
    if (active.lock) |*lock| {
        defer active.lock = null;
        lock.release(self.allocator) catch |err| return self.transactionFailure(err);
    }
}

// Internal transaction bridge; callers use Transaction methods.
pub fn beginTransactionOperation(self: *Owner, active: *Transaction) !void {
    try self.checkIdle();
    if (self.active_transaction != active)
        return self.transactionFailure(error.TransactionNotInitialized);
    self.last_diagnostic = null;
    self.busy = true;
}

pub fn transactionFailure(self: *Owner, cause: anyerror) anyerror {
    return self.fail(.transaction, cause, null);
}

pub fn transactionPackage(self: *Owner, reference: PackageRef) !*const Package {
    const db = try self.resolveDatabase(reference.database);
    if (db.generation != reference.generation or !db.status.package_cache_loaded or
        @intFromEnum(reference.id) >= db.packages.packages.items.len)
        return error.StalePackageReference;
    return &db.packages.packages.items[@intFromEnum(reference.id)];
}

pub fn resolveTransaction(
    self: *Owner,
    active: *Transaction,
    request: Resolver.Request,
) !TransactionPlan {
    std.debug.assert(self.busy and self.active_transaction == active);
    return self.resolveInternal(active.io, request);
}

pub fn transactionEvent(self: *Owner, event: Callbacks.Event) void {
    if (self.configuration.callbacks.event) |callback| {
        self.in_callback = true;
        defer self.in_callback = false;
        callback(self.configuration.callbacks.event_context, event);
    }
}

/// Download callbacks are always dispatched on the owning thread.
pub fn downloadEvent(self: *Owner, event: Callbacks.Download) void {
    if (self.configuration.callbacks.download) |callback| {
        self.in_callback = true;
        defer self.in_callback = false;
        callback(self.configuration.callbacks.download_context, event);
    }
}

pub fn fetchPackage(self: *Owner, io: std.Io, url: []const u8) !Downloads.File {
    try self.begin(.download);
    defer self.busy = false;
    return self.fetchPackageInternal(io, url) catch |err| return self.fail(.download, err, null);
}

fn fetchPackageInternal(self: *Owner, io: std.Io, url: []const u8) !Downloads.File {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const name = try Downloads.urlFilename(arena.allocator(), url);
    const files = try Downloads.acquire(
        self,
        io,
        &.{
            .{
                .name = name,
                .url = url,
                .servers = &.{},
                .policy = self.configuration.effectiveRemoteSignaturePolicy(),
            },
        },
    );
    defer self.allocator.free(files);
    return files[0];
}

/// Aggregate refresh attempts every enabled repository; inspect result.check().
pub fn refreshDatabases(self: *Owner, io: std.Io, force: bool) !Downloads.RefreshResult {
    try self.begin(.refresh);
    defer self.busy = false;
    return Downloads.refresh(self, io, force) catch |err| return self.fail(.refresh, err, null);
}

/// Bounded acquisition of a URL batch; the caller owns the returned FileSet.
pub fn fetchPackageUrls(self: *Owner, io: std.Io, urls: []const []const u8) !Downloads.FileSet {
    try self.begin(.download);
    defer self.busy = false;
    errdefer |err| {
        self.last_diagnostic = Diagnostic.init(.download, err, null);
    }
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const requests = try arena.allocator().alloc(Downloads.Request, urls.len);
    for (urls, requests) |url, *request|
        request.* = .{
            .name = try Downloads.urlFilename(arena.allocator(), url),
            .url = url,
            .servers = &.{},
            .policy = self.configuration.effectiveRemoteSignaturePolicy(),
        };
    return .{ .allocator = self.allocator, .files = try Downloads.acquire(self, io, requests) };
}

/// Persist a local install reason atomically under db.lck. Invalidates local
/// PackageRefs after publication; archive and repository packages are rejected.
pub fn setInstallReason(
    self: *Owner,
    io: std.Io,
    reference: PackageRef,
    reason: Package.InstallReason,
) !void {
    try self.begin(.transaction);
    defer self.busy = false;
    errdefer |err| self.last_diagnostic = Diagnostic.init(.transaction, err, null);
    if (reason == .unknown) return error.InvalidOption;
    if (self.configuration.local_database_mode == .read_only) return error.ReadOnlyDatabase;
    const borrowed = try self.transactionPackage(reference);
    if (borrowed.origin != .local) return error.UnsupportedPackageOrigin;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const name = try a.dupe(u8, borrowed.name);
    const version = try a.dupe(u8, borrowed.version.raw);
    var lock = try DatabaseLock.acquire(self.allocator, self.lock_file);
    var lock_held = true;
    defer if (lock_held) lock.release(self.allocator) catch |err| {
        self.last_diagnostic = Diagnostic.init(.transaction, err, null);
    };
    const local = &self.local.?;
    try local.reloadDatabase(io, self.configuration.gpg_directory);
    const id = local.packages.by_name.get(name) orelse return error.StalePackageReference;
    try local.loadMetadata(io, id, .{});
    var candidate = local.packages.packages.items[@intFromEnum(id)];
    if (!std.mem.eql(u8, candidate.version.raw, version)) return error.StalePackageReference;
    if (candidate.install_reason == reason) {
        lock_held = false;
        try lock.release(self.allocator);
        return;
    }
    candidate.install_reason = reason;
    var held_database = try RootPath.init(self.configuration.database_path);
    defer held_database.deinit();
    var guard = try Publication.DirectoryLock.acquire(local.path, true, false);
    defer guard.deinit();
    const record = try Writer.recordName(a, &candidate);
    const path = try std.fmt.allocPrint(a, "local/{s}/desc", .{record});
    var stage = try Ops.Stage.init(&held_database, io, path);
    var stage_held = true;
    defer if (stage_held) stage.deinit() catch |err| {
        self.last_diagnostic = Diagnostic.init(.transaction, err, null);
    };
    try Ops.write(stage.fd, "entry", try Writer.description(a, &candidate));
    try lock.validate();
    // Invalidate even when rename succeeds but its following fsync fails.
    defer local.invalidateCache() catch {};
    try stage.publish();
    stage_held = false;
    try stage.deinit();
    lock_held = false;
    try lock.release(self.allocator);
}

/// Recover an interrupted local-record publication before opening an Owner.
/// Never removes a foreign db.lck; callers resolve stale native locks explicitly.
pub fn recoverLocalDatabase(
    io: std.Io,
    allocator: std.mem.Allocator,
    database_path: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ database_path, "db.lck" });
    defer allocator.free(path);
    var lock = try DatabaseLock.acquire(allocator, path);
    var lock_held = true;
    defer if (lock_held) lock.release(allocator) catch {};
    const local = try std.fs.path.join(allocator, &.{ database_path, "local" });
    defer allocator.free(local);
    var guard = try Publication.DirectoryLock.acquire(local, true, false);
    defer guard.deinit();
    var held_database = try RootPath.init(database_path);
    defer held_database.deinit();
    try lock.validate();
    try Writer.recoverLocked(io, allocator, &held_database);
    lock_held = false;
    try lock.release(allocator);
}
