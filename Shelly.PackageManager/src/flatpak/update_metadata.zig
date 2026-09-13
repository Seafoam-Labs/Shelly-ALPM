const std = @import("std");
const types = @import("types.zig");

fn sameCatalog(a: types.InstalledRef, b: types.InstalledRef) bool {
    return a.scope == b.scope and std.mem.eql(u8, a.origin, b.origin) and std.mem.eql(u8, a.arch, b.arch);
}

fn needsVersion(update: types.InstalledRef) bool {
    return update.kind == .app and update.target_commit != null;
}

/// Each needed catalog is refreshed and parsed once, including failed lookups.
/// Missing catalogs leave updates visible with unknown versions.
pub fn enrich(allocator: std.mem.Allocator, updates: []types.InstalledRef, provider: anytype) !void {
    for (updates, 0..) |update, index| {
        if (!needsVersion(update)) continue;
        var visited = false;
        for (updates[0..index]) |previous| {
            if (needsVersion(previous) and sameCatalog(previous, update)) {
                visited = true;
                break;
            }
        }
        if (visited) continue;
        var catalog = provider.getUpdateCatalog(update.scope, update.origin, update.arch) catch |err| switch (err) {
            error.OutOfMemory, error.Cancelled => return err,
            else => continue,
        };
        defer catalog.deinit();
        for (updates[index..]) |*candidate| {
            if (!needsVersion(candidate.*) or !sameCatalog(candidate.*, update)) continue;
            if (targetVersion(catalog, candidate.*)) |version|
                candidate.new_version = try allocator.dupe(u8, version);
        }
    }
}

fn targetVersion(catalog: types.AppstreamCatalog, update: types.InstalledRef) ?[]const u8 {
    if (catalog.scope != update.scope or !std.mem.eql(u8, catalog.remote_name, update.origin) or
        !std.mem.eql(u8, catalog.arch, update.arch)) return null;

    var match: ?types.AppstreamApp = null;
    for (catalog.apps) |app| {
        for (app.flatpak_refs) |reference| {
            if (!std.mem.eql(u8, reference, update.reference)) continue;
            // Duplicate components cannot reliably identify the target release.
            if (match != null) return null;
            match = app;
            break;
        }
    }
    const app = match orelse return null;
    var latest: ?types.AppstreamRelease = null;
    for (app.releases) |release| {
        if (release.version.len == 0) continue;
        if (latest) |previous| {
            if (release.timestamp == null or previous.timestamp == null) {
                if (!std.mem.eql(u8, release.version, previous.version)) return null;
            } else if (release.timestamp.? > previous.timestamp.?) {
                latest = release;
            } else if (release.timestamp.? == previous.timestamp.? and
                !std.mem.eql(u8, release.version, previous.version)) return null;
        } else latest = release;
    }
    return if (latest) |release| release.version else null;
}

const TestProvider = struct {
    calls: usize = 0,
    failure: ?anyerror = null,

    pub fn getUpdateCatalog(self: *@This(), scope: types.Scope, remote: []const u8, arch: []const u8) !types.AppstreamCatalog {
        self.calls += 1;
        if (self.failure) |err| return err;
        const allocator = std.testing.allocator;
        const arena_state = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena_state);
        arena_state.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();
        const version = if (scope == .system) "2.0" else if (std.mem.eql(u8, remote, "testing")) "3.0" else "1.0";
        const source = try std.fmt.allocPrint(arena,
            \\<components>
            \\ <component type="desktop-application">
            \\  <id>org.example.App</id>
            \\  <bundle type="flatpak"> app/org.example.App/{s}/stable </bundle>
            \\  <bundle type="snap">app/org.example.App/{s}/beta</bundle>
            \\  <releases><release version="0.9" timestamp="10"/><release version="{s}" timestamp="20"/></releases>
            \\ </component>
            \\ <component type="desktop-application">
            \\  <id>org.example.App</id>
            \\  <bundle type="flatpak">app/org.example.App/{s}/beta</bundle>
            \\  <releases><release version="4.0-beta"/></releases>
            \\ </component>
            \\ <component type="desktop-application">
            \\  <id>org.example.App.Plugin</id>
            \\  <bundle type="flatpak">app/org.example.App.Plugin/{s}/stable</bundle>
            \\  <releases><release version="9.0"/></releases>
            \\ </component>
            \\</components>
        , .{ arch, arch, version, arch, arch });
        const xml = @import("zig-xml");
        var reader: xml.Reader.Static = .init(allocator, source, .{});
        defer reader.deinit();
        const parser: @import("appstream_parser.zig").AppstreamParser = .{ .arena = arena, .io = std.testing.io };
        return .{
            .owner_allocator = allocator,
            .arena_state = arena_state,
            .remote_name = try arena.dupe(u8, remote),
            .scope = scope,
            .arch = try arena.dupe(u8, arch),
            .path = "fixture",
            .apps = try parser.parseStream(&reader.interface),
        };
    }
};

fn testUpdate(reference: []const u8, scope: types.Scope, remote: []const u8) !types.InstalledRef {
    return types.InstalledRef.fromWire(std.testing.allocator, .{
        .id = "org.example.App",
        .name = "Example",
        .arch = "x86_64",
        .branch = "stable",
        .reference = reference,
        .origin = remote,
        .version = "1.0",
        .summary = "Example",
        .latest_commit = "cached",
        .target_commit = "resolved",
        .download_size = 2048,
        .installed_size = 4096,
        .kind = .app,
        .scope = scope.toWire(),
    });
}

test "Flatpak update metadata matches full refs and loads each scoped catalog once" {
    const allocator = std.testing.allocator;
    const stable = "app/org.example.App/x86_64/stable";
    var updates = [_]types.InstalledRef{
        try testUpdate(stable, .user, "flathub"),
        try testUpdate(stable, .user, "flathub"),
        try testUpdate("app/org.example.App/x86_64/beta", .user, "flathub"),
        try testUpdate(stable, .system, "flathub"),
        try testUpdate(stable, .user, "testing"),
        try testUpdate("app/org.example.App.Plugin/x86_64/stable", .user, "flathub"),
        try testUpdate("app/org.example.App/aarch64/stable", .user, "flathub"),
        try testUpdate("app/org.example.Unknown/x86_64/stable", .user, "flathub"),
    };
    defer for (&updates) |*update| update.deinit(allocator);
    var provider: TestProvider = .{};
    try enrich(allocator, &updates, &provider);
    try std.testing.expectEqual(@as(usize, 3), provider.calls);
    for (updates[0..6], [_][]const u8{ "1.0", "1.0", "4.0-beta", "2.0", "3.0", "9.0" }) |update, expected|
        try std.testing.expectEqualStrings(expected, update.new_version.?);
    try std.testing.expect(updates[6].new_version == null);
    try std.testing.expect(updates[7].new_version == null);
    // A new commit with the same application version remains an update.
    try std.testing.expectEqualStrings(updates[0].version, updates[0].new_version.?);
    try std.testing.expectEqual(@as(?u64, 2048), updates[0].download_size);
}

test "Flatpak update metadata keeps failed lookups unknown and propagates cancellation" {
    const allocator = std.testing.allocator;
    var updates = [_]types.InstalledRef{
        try testUpdate("app/org.example.App/x86_64/stable", .user, "flathub"),
        try testUpdate("app/org.example.App/x86_64/stable", .user, "flathub"),
    };
    defer for (&updates) |*update| update.deinit(allocator);
    var provider: TestProvider = .{ .failure = error.CatalogNotFound };
    try enrich(allocator, &updates, &provider);
    try std.testing.expectEqual(@as(usize, 1), provider.calls);
    for (updates) |update| try std.testing.expect(update.new_version == null);
    provider.failure = error.Cancelled;
    try std.testing.expectError(error.Cancelled, enrich(allocator, &updates, &provider));
    provider.failure = error.OutOfMemory;
    try std.testing.expectError(error.OutOfMemory, enrich(allocator, &updates, &provider));
    provider.calls = 0;
    updates[0].kind = .runtime;
    allocator.free(updates[1].target_commit.?);
    updates[1].target_commit = null;
    try enrich(allocator, &updates, &provider);
    try std.testing.expectEqual(@as(usize, 0), provider.calls);
}

test "Flatpak update metadata rejects wrong catalogs and ambiguous releases" {
    const allocator = std.testing.allocator;
    var update = try testUpdate("app/org.example.App/x86_64/stable", .user, "flathub");
    defer update.deinit(allocator);
    var provider: TestProvider = .{};
    var catalog = try provider.getUpdateCatalog(.system, "flathub", "x86_64");
    defer catalog.deinit();
    try std.testing.expect(targetVersion(catalog, update) == null);
    catalog.scope = .user;
    catalog.remote_name = "other";
    try std.testing.expect(targetVersion(catalog, update) == null);
    catalog.remote_name = "flathub";
    catalog.arch = "aarch64";
    try std.testing.expect(targetVersion(catalog, update) == null);
    catalog.arch = "x86_64";
    try std.testing.expectEqualStrings("2.0", targetVersion(catalog, update).?);
    catalog.apps[0].releases = &.{
        .{ .version = "1.0", .type = "stable", .description = "" },
        .{ .version = "2.0", .type = "stable", .description = "" },
    };
    try std.testing.expect(targetVersion(catalog, update) == null);
    catalog.apps[0].releases = &.{};
    try std.testing.expect(targetVersion(catalog, update) == null);
    catalog.apps[0].flatpak_refs = &.{};
    try std.testing.expect(targetVersion(catalog, update) == null);
}
