const std = @import("std");
const bindings = @import("bindings.zig");
const events = @import("events.zig");
const operation_api = @import("operation_context");
const wire = @import("Shelly_Flatpak_Protocol").wire;

const flatpak = bindings.libflatpak;
const raw = flatpak.flatpak;

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    operation_context: ?*operation_api.OperationContext = null,

    pub fn setOperationContext(
        self: *Manager,
        context: ?*operation_api.OperationContext,
    ) void {
        self.operation_context = context;
    }

    pub fn updateAll(self: Manager) !void {
        var scope = events.OperationScope.init(
            self.operation_context,
            null,
            null,
            .update,
            null,
        );
        scope.attach();
        defer scope.finish(.success);
        errdefer scope.fail();
        try scope.checkCancelled();
        try self.updateScope(.SYSTEM);
        try self.updateScope(.USER);
        scope.status(
            .success,
            "Flatpak AppStream catalogs updated",
            "flatpak.appstream.updated",
        );
    }

    pub fn updateRemote(
        self: Manager,
        scope_value: flatpak.Scope,
        remote_name: []const u8,
    ) !void {
        var scope = events.OperationScope.init(
            self.operation_context,
            null,
            null,
            .update,
            remote_name,
        );
        scope.attach();
        defer scope.finish(.success);
        errdefer scope.fail();
        try scope.checkCancelled();

        const name_z = try self.allocator.dupeZ(u8, remote_name);
        defer self.allocator.free(name_z);
        const cancellable: *raw.GCancellable = raw.g_cancellable_new();
        defer raw.g_object_unref(cancellable);
        var bridge = try events.CancellationBridge.init(
            self.operation_context,
            cancellable,
        );
        defer bridge.deinit();
        var g_error: ?*raw.GError = null;
        defer if (g_error) |value| raw.g_error_free(value);
        const installation = try installationForScope(
            scope_value,
            cancellable,
            &g_error,
        );
        defer raw.g_object_unref(installation);
        const arch = raw.flatpak_get_default_arch();
        _ = raw.flatpak_installation_update_appstream_sync(
            installation,
            name_z,
            arch,
            null,
            cancellable,
            &g_error,
        );
        if (g_error) |value| {
            scope.reportError(
                error.FlatpakError,
                std.mem.span(value.message),
                value.code,
            );
            return error.FlatpakError;
        }
        scope.status(
            .success,
            "Flatpak AppStream catalog updated",
            "flatpak.appstream.updated",
        );
    }

    pub fn getRemote(
        self: Manager,
        remote_name: []const u8,
        requested_arch: ?[]const u8,
    ) !wire.CatalogLocation {
        if (try self.getRemoteForScope(remote_name, requested_arch, .SYSTEM)) |value|
            return value;
        if (try self.getRemoteForScope(remote_name, requested_arch, .USER)) |value|
            return value;
        return error.RemoteNotFound;
    }

    pub fn getAll(
        self: Manager,
        requested_arch: ?[]const u8,
    ) ![]wire.CatalogLocation {
        var locations: std.ArrayList(wire.CatalogLocation) = .empty;
        errdefer {
            for (locations.items) |location| deinitLocation(self.allocator, location);
            locations.deinit(self.allocator);
        }
        try self.appendScope(&locations, requested_arch, .SYSTEM);
        try self.appendScope(&locations, requested_arch, .USER);
        return locations.toOwnedSlice(self.allocator);
    }

    pub fn deinitLocation(
        allocator: std.mem.Allocator,
        location: wire.CatalogLocation,
    ) void {
        allocator.free(location.remote);
        allocator.free(location.arch);
        allocator.free(location.path);
    }

    pub fn deinitLocations(
        allocator: std.mem.Allocator,
        locations: []wire.CatalogLocation,
    ) void {
        for (locations) |location| deinitLocation(allocator, location);
        allocator.free(locations);
    }

    fn updateScope(self: Manager, scope_value: flatpak.Scope) !void {
        const cancellable: *raw.GCancellable = raw.g_cancellable_new();
        defer raw.g_object_unref(cancellable);
        var bridge = try events.CancellationBridge.init(
            self.operation_context,
            cancellable,
        );
        defer bridge.deinit();
        var g_error: ?*raw.GError = null;
        defer if (g_error) |value| raw.g_error_free(value);
        const installation = try installationForScope(
            scope_value,
            cancellable,
            &g_error,
        );
        defer raw.g_object_unref(installation);
        const remotes = raw.flatpak_installation_list_remotes(
            installation,
            cancellable,
            &g_error,
        );
        if (remotes == null or g_error != null) return error.FlatpakError;
        defer raw.g_ptr_array_unref(remotes);

        var index: usize = 0;
        while (index < remotes.*.len) : (index += 1) {
            if (self.operation_context) |context|
                if (context.isCancelled()) return error.Cancelled;
            const remote: *raw.FlatpakRemote =
                @ptrCast(@alignCast(remotes.*.pdata[index]));
            if (raw.flatpak_remote_get_disabled(remote) != 0) continue;
            const name_ptr = raw.flatpak_remote_get_name(remote);
            if (name_ptr == null) continue;
            try self.updateRemote(scope_value, std.mem.span(name_ptr));
        }
    }

    fn getRemoteForScope(
        self: Manager,
        remote_name: []const u8,
        requested_arch: ?[]const u8,
        scope_value: flatpak.Scope,
    ) !?wire.CatalogLocation {
        const name_z = try self.allocator.dupeZ(u8, remote_name);
        defer self.allocator.free(name_z);
        const cancellable: *raw.GCancellable = raw.g_cancellable_new();
        defer raw.g_object_unref(cancellable);
        var bridge = try events.CancellationBridge.init(
            self.operation_context,
            cancellable,
        );
        defer bridge.deinit();
        var g_error: ?*raw.GError = null;
        defer if (g_error) |value| raw.g_error_free(value);
        const installation = installationForScope(
            scope_value,
            cancellable,
            &g_error,
        ) catch return null;
        defer raw.g_object_unref(installation);
        const remote = raw.flatpak_installation_get_remote_by_name(
            installation,
            name_z,
            cancellable,
            &g_error,
        );
        if (remote == null or g_error != null) return null;
        defer raw.g_object_unref(remote);
        if (raw.flatpak_remote_get_disabled(remote) != 0) return null;
        return self.locationForRemote(
            remote,
            remote_name,
            requested_arch,
            scope_value,
        );
    }

    fn appendScope(
        self: Manager,
        locations: *std.ArrayList(wire.CatalogLocation),
        requested_arch: ?[]const u8,
        scope_value: flatpak.Scope,
    ) !void {
        const cancellable: *raw.GCancellable = raw.g_cancellable_new();
        defer raw.g_object_unref(cancellable);
        var bridge = try events.CancellationBridge.init(
            self.operation_context,
            cancellable,
        );
        defer bridge.deinit();
        var g_error: ?*raw.GError = null;
        defer if (g_error) |value| raw.g_error_free(value);
        const installation = installationForScope(
            scope_value,
            cancellable,
            &g_error,
        ) catch return;
        defer raw.g_object_unref(installation);
        const remotes = raw.flatpak_installation_list_remotes(
            installation,
            cancellable,
            &g_error,
        );
        if (remotes == null or g_error != null) return;
        defer raw.g_ptr_array_unref(remotes);

        var index: usize = 0;
        while (index < remotes.*.len) : (index += 1) {
            if (self.operation_context) |context|
                if (context.isCancelled()) return error.Cancelled;
            const remote: *raw.FlatpakRemote =
                @ptrCast(@alignCast(remotes.*.pdata[index]));
            if (raw.flatpak_remote_get_disabled(remote) != 0) continue;
            const name_ptr = raw.flatpak_remote_get_name(remote);
            if (name_ptr == null) continue;
            const location = try self.locationForRemote(
                remote,
                std.mem.span(name_ptr),
                requested_arch,
                scope_value,
            ) orelse continue;
            locations.append(self.allocator, location) catch |err| {
                deinitLocation(self.allocator, location);
                return err;
            };
        }
    }

    fn locationForRemote(
        self: Manager,
        remote: *raw.FlatpakRemote,
        remote_name: []const u8,
        requested_arch: ?[]const u8,
        scope_value: flatpak.Scope,
    ) !?wire.CatalogLocation {
        const arch = requested_arch orelse
            std.mem.span(raw.flatpak_get_default_arch());
        const arch_z = try self.allocator.dupeZ(u8, arch);
        defer self.allocator.free(arch_z);
        const directory = raw.flatpak_remote_get_appstream_dir(
            remote,
            arch_z,
        ) orelse return null;
        defer raw.g_object_unref(directory);
        const directory_path_ptr = raw.g_file_get_path(directory);
        if (directory_path_ptr == null) return null;
        defer raw.g_free(directory_path_ptr);
        const directory_path = std.mem.span(directory_path_ptr);

        const xml_path = try std.fs.path.join(
            self.allocator,
            &.{ directory_path, "appstream.xml" },
        );
        defer self.allocator.free(xml_path);
        if (fileExists(self.io, xml_path))
            return try self.makeLocation(
                remote_name,
                arch,
                xml_path,
                scope_value,
            );

        const gzip_path = try std.fs.path.join(
            self.allocator,
            &.{ directory_path, "appstream.xml.gz" },
        );
        defer self.allocator.free(gzip_path);
        if (!fileExists(self.io, gzip_path)) return null;
        return try self.makeLocation(
            remote_name,
            arch,
            gzip_path,
            scope_value,
        );
    }

    fn makeLocation(
        self: Manager,
        remote_name: []const u8,
        arch: []const u8,
        path: []const u8,
        scope_value: flatpak.Scope,
    ) !wire.CatalogLocation {
        const remote_copy = try self.allocator.dupe(u8, remote_name);
        errdefer self.allocator.free(remote_copy);
        const arch_copy = try self.allocator.dupe(u8, arch);
        errdefer self.allocator.free(arch_copy);
        return .{
            .remote = remote_copy,
            .scope = scopeToWire(scope_value),
            .arch = arch_copy,
            .path = try self.allocator.dupe(u8, path),
        };
    }
};

fn installationForScope(
    scope: flatpak.Scope,
    cancellable: *raw.GCancellable,
    g_error: *?*raw.GError,
) !*raw.FlatpakInstallation {
    const installation = if (scope == .SYSTEM)
        raw.flatpak_installation_new_system(cancellable, g_error)
    else
        raw.flatpak_installation_new_user(cancellable, g_error);
    if (installation == null or g_error.* != null)
        return error.InstallationCreateFailed;
    return installation.?;
}

test "native Flatpak AppStream manager exposes backend parity operations" {
    _ = Manager.updateAll;
    _ = Manager.updateRemote;
    _ = Manager.getRemote;
    _ = Manager.getAll;

    var analyze_bodies = false;
    std.mem.doNotOptimizeAway(&analyze_bodies);
    if (analyze_bodies) {
        const manager: Manager = .{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
        };
        const locations = try manager.getAll(null);
        Manager.deinitLocations(std.testing.allocator, locations);
    }
}

fn fileExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

fn scopeToWire(scope: flatpak.Scope) wire.Scope {
    return switch (scope) {
        .SYSTEM => .system,
        .USER => .user,
        .UNKNOWN => .unknown,
    };
}
