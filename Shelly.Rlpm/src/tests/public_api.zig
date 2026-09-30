//! A separate consumer module: imports alone do not instantiate lazy function bodies.
const std = @import("std");
const rlpm = @import("Shelly_Rlpm");
const OwnerTests = @import("owner.zig");
const MetadataTests = @import("metadata.zig");
const DatabaseTests = @import("database.zig");
const VerificationTests = @import("verification.zig");
const ResolverTests = @import("resolver.zig");
const TransactionTests = @import("transaction.zig");
const DownloadTests = @import("download.zig");
const PreflightTests = @import("preflight.zig");
const HooksTests = @import("hooks.zig");
const ExecutorTests = @import("executor.zig");

test "public API constructs, compares, and releases versions" {
    var older = try rlpm.Version.init("1:2.0-1", std.testing.allocator);
    defer older.deinit(std.testing.allocator);
    var newer = try rlpm.Version.init("1:2.0-2", std.testing.allocator);
    defer newer.deinit(std.testing.allocator);
    try rlpm.Version.validate(older.raw);
    try std.testing.expectEqual(.lessThan, rlpm.Version.compareVersions(older, newer));
    try std.testing.expectEqual(.equal, rlpm.Version.compareStrings("2.0", "2.0-2"));
    try std.testing.expectError(error.InvalidVersion, rlpm.Version.init("", std.testing.allocator));
}

test "public API converts description metadata with the caller's arena" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parsed: rlpm.ParsedDescription = .{ .name = "demo", .version = "1.2-3" };
    defer parsed.deinit(arena.allocator());
    try parsed.depends.append(arena.allocator(), "runtime>=2");
    const package = try parsed.intoPackage(&arena, .{ .origin = .sync, .database_name = "fixture" });
    try std.testing.expectEqualStrings("demo", package.name);
    try std.testing.expectEqualStrings("fixture", package.database_name);
    try std.testing.expectEqualStrings("runtime", package.depends[0].name);
    try std.testing.expectEqualStrings("2", package.depends[0].constraint.greater_equal);
}

test "public Owner retains two repositories and releases their configuration" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var owner = try rlpm.Owner.init(std.testing.io, std.testing.allocator, .{ .root = path, .database_path = path }, &.{
        .{ .database_name = "core", .servers = &.{"https://example.invalid/core/"} },
        .{ .database_name = "cachyos", .cache_servers = &.{"https://cache.invalid/"} },
    });
    defer owner.deinit() catch unreachable;
    try std.testing.expectEqual(2, owner.syncDatabases().len);
    try std.testing.expectEqual(0, (try owner.packageIds(owner.localDatabase().?)).len);
    const core = owner.findDatabase("core").?;
    try std.testing.expectEqualStrings(
        "https://example.invalid/core",
        (try owner.database(core)).servers.items[0],
    );
    try owner.unregisterDatabase(core);
    try std.testing.expectError(error.StaleDatabaseReference, owner.database(core));
    try std.testing.expectEqualStrings("cachyos", owner.syncDatabases()[0].name);
    try owner.unregisterSyncDatabases();
    try std.testing.expectEqual(0, owner.syncDatabases().len);
    try std.testing.expect(rlpm.capabilities().transactions);
    var physical = try rlpm.PhysicalArchitectures.init(std.testing.allocator);
    defer physical.deinit();
    try std.testing.expect(physical.names.len >= 1);
}

test {
    _ = OwnerTests;
}

test {
    _ = MetadataTests;
}

test {
    _ = DatabaseTests;
    _ = VerificationTests;
    _ = ResolverTests;
    _ = TransactionTests;
}

test {
    _ = DownloadTests;
    _ = PreflightTests;
    _ = HooksTests;
}

test {
    _ = ExecutorTests;
}
