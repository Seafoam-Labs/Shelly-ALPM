const std = @import("std");
const operation_api = @import("operation_context");
const protocol = @import("Shelly_Flatpak_Protocol");
const parser = @import("appstream_parser.zig");
const types = @import("types.zig");
const events = @import("events.zig");
const client_api = @import("client.zig");

const wire = protocol.wire;

pub const Error = error{
    NotInitialized,
    RemoteNotFound,
    CatalogNotFound,
    FlatpakError,
};

pub const AppstreamCatalog = types.AppstreamCatalog;

pub const AppstreamManager = struct {
    allocator: ?std.mem.Allocator = null,
    io: ?std.Io = null,
    operation_context: ?*operation_api.OperationContext = null,
    parent_operation: ?*const operation_api.Operation = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
    ) AppstreamManager {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn setOperationContext(
        self: *AppstreamManager,
        context: ?*operation_api.OperationContext,
    ) void {
        self.operation_context = context;
    }

    pub fn setParentOperation(
        self: *AppstreamManager,
        parent: ?*const operation_api.Operation,
    ) void {
        self.parent_operation = parent;
        if (parent) |operation| self.operation_context = operation.context;
    }

    pub fn updateAllAppstreams(self: AppstreamManager) !void {
        var parsed = try self.call(
            wire.EmptyArguments,
            wire.Method.update_all_appstreams,
            wire.EmptyArguments{},
            .update,
            null,
        );
        parsed.deinit();
    }

    pub fn updateRemoteAppstream(
        self: AppstreamManager,
        scope: types.Scope,
        remote_name: []const u8,
    ) !void {
        var parsed = try self.call(
            wire.EmptyArguments,
            wire.Method.update_remote_appstream,
            wire.UpdateAppstreamArguments{
                .scope = scope.toWire(),
                .remote = remote_name,
            },
            .update,
            remote_name,
        );
        parsed.deinit();
    }

    pub fn getRemoteCatalog(
        self: AppstreamManager,
        remote_name: []const u8,
        requested_arch: ?[]const u8,
    ) !AppstreamCatalog {
        var parsed = try self.call(
            wire.CatalogLocation,
            wire.Method.get_remote_catalog,
            wire.CatalogArguments{
                .remote = remote_name,
                .arch = requested_arch,
            },
            .search,
            remote_name,
        );
        defer parsed.deinit();
        const location = parsed.value;
        return self.loadCatalogFromPath(
            location.remote,
            .fromWire(location.scope),
            location.arch,
            location.path,
        );
    }

    pub fn getAllRemoteCatalogs(
        self: AppstreamManager,
        requested_arch: ?[]const u8,
    ) ![]AppstreamCatalog {
        const allocator = self.allocator orelse return Error.NotInitialized;
        var parsed = try self.call(
            []wire.CatalogLocation,
            wire.Method.get_all_remote_catalogs,
            wire.CatalogsArguments{ .arch = requested_arch },
            .search,
            null,
        );
        defer parsed.deinit();

        var catalogs: std.ArrayList(AppstreamCatalog) = .empty;
        errdefer {
            for (catalogs.items) |*catalog| catalog.deinit();
            catalogs.deinit(allocator);
        }
        for (parsed.value) |location| {
            try catalogs.append(
                allocator,
                try self.loadCatalogFromPath(
                    location.remote,
                    .fromWire(location.scope),
                    location.arch,
                    location.path,
                ),
            );
        }
        return catalogs.toOwnedSlice(allocator);
    }

    /// AppStream XML parsing is deliberately PackageManager-owned and does not
    /// require the optional native backend once a catalog path is known.
    pub fn loadCatalogFromPath(
        self: AppstreamManager,
        remote_name: []const u8,
        scope: types.Scope,
        arch: []const u8,
        path: []const u8,
    ) !AppstreamCatalog {
        var operation_scope = events.OperationScope.init(
            self.operation_context,
            self.parent_operation,
            null,
            .inspect,
            path,
        );
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try operation_scope.checkCancelled();
        const allocator = self.allocator orelse return Error.NotInitialized;
        const io = self.io orelse return Error.NotInitialized;

        const arena_state = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena_state);
        arena_state.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();
        const appstream_parser = parser.AppstreamParser{
            .arena = arena,
            .io = io,
        };
        const apps = try appstream_parser.parseFile(path);
        try operation_scope.checkCancelled();
        return .{
            .owner_allocator = allocator,
            .arena_state = arena_state,
            .remote_name = try arena.dupe(u8, remote_name),
            .scope = scope,
            .arch = try arena.dupe(u8, arch),
            .path = try arena.dupe(u8, path),
            .apps = apps,
        };
    }

    fn call(
        self: AppstreamManager,
        comptime T: type,
        method: []const u8,
        arguments: anytype,
        kind: operation_api.OperationKind,
        subject: ?[]const u8,
    ) !std.json.Parsed(T) {
        const allocator = self.allocator orelse return Error.NotInitialized;
        _ = self.io orelse return Error.NotInitialized;
        var scope = events.OperationScope.init(
            self.operation_context,
            self.parent_operation,
            null,
            kind,
            subject,
        );
        scope.attach();
        defer scope.finish(.success);
        errdefer scope.fail();
        try scope.checkCancelled();
        return (client_api.Client{ .allocator = allocator }).call(
            T,
            method,
            arguments,
            .{
                .operation = if (scope.operation) |*operation|
                    operation
                else
                    null,
                .context = self.operation_context,
                .failure_reported = &scope.failure_reported,
            },
        );
    }
};

test "AppStream manager returns an owned typed catalog" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/appstream.xml",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(path);
    var file = try std.Io.Dir.cwd().createFile(
        std.testing.io,
        path,
        .{},
    );
    defer file.close(std.testing.io);
    try file.writeStreamingAll(
        std.testing.io,
        "<components><component type=\"desktop-application\"><id>org.example.App</id><name>Example</name></component></components>",
    );

    const manager = AppstreamManager.init(
        std.testing.allocator,
        std.testing.io,
    );
    var catalog = try manager.loadCatalogFromPath(
        "test",
        .user,
        "x86_64",
        path,
    );
    defer catalog.deinit();
    try std.testing.expectEqualStrings("test", catalog.remote_name);
    try std.testing.expectEqual(types.Scope.user, catalog.scope);
    try std.testing.expectEqual(@as(usize, 1), catalog.apps.len);
    try std.testing.expectEqualStrings(
        "org.example.App",
        catalog.apps[0].id,
    );
}

test "AppStream manager exposes one and all remote catalog retrieval" {
    _ = AppstreamManager.getRemoteCatalog;
    _ = AppstreamManager.getAllRemoteCatalogs;
    _ = AppstreamCatalog.deinitSlice;
}

test "Flatpak AppStream operation-hooked public APIs compile" {
    _ = AppstreamManager.updateAllAppstreams;
    _ = AppstreamManager.updateRemoteAppstream;
    _ = AppstreamManager.getRemoteCatalog;
    _ = AppstreamManager.getAllRemoteCatalogs;
    _ = AppstreamManager.loadCatalogFromPath;
}
