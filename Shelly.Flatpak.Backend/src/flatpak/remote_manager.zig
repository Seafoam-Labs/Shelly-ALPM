const std = @import("std");
const bindings = @import("bindings.zig");
const events = @import("events.zig");
const operation_api = @import("operation_context");

const flatpak = bindings.libflatpak;
const raw = flatpak.flatpak;

pub const RemoteManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    operation_context: ?*operation_api.OperationContext = null,
    parent_operation: ?*const operation_api.Operation = null,

    pub fn setOperationContext(
        self: *RemoteManager,
        context: ?*operation_api.OperationContext,
    ) void {
        self.operation_context = context;
    }

    pub fn setParentOperation(
        self: *RemoteManager,
        parent: ?*const operation_api.Operation,
    ) void {
        self.parent_operation = parent;
        if (parent) |operation| self.operation_context = operation.context;
    }

    /// Each returned wrapper owns one GObject reference.
    pub fn listRemotesWithDetails(self: RemoteManager) ![]flatpak.Remote {
        var scope = events.OperationScope.init(
            self.operation_context,
            self.parent_operation,
            null,
            .search,
            null,
        );
        scope.attach();
        defer scope.finish(.success);
        errdefer scope.fail();
        try scope.checkCancelled();

        var remotes: std.ArrayList(flatpak.Remote) = .empty;
        errdefer {
            for (remotes.items) |remote| raw.g_object_unref(remote.ptr);
            remotes.deinit(self.allocator);
        }
        try self.appendRemotes(&remotes, .SYSTEM);
        try self.appendRemotes(&remotes, .USER);
        scope.status(.success, "Flatpak remotes listed", "flatpak.remotes.listed");
        return remotes.toOwnedSlice(self.allocator);
    }

    pub fn deinitRemotes(
        allocator: std.mem.Allocator,
        remotes: []flatpak.Remote,
    ) void {
        for (remotes) |remote| raw.g_object_unref(remote.ptr);
        allocator.free(remotes);
    }

    pub fn addRemote(
        self: RemoteManager,
        name: [:0]const u8,
        url: [:0]const u8,
        scope_value: flatpak.Scope,
        gpg_verify: bool,
    ) !bool {
        return self.addRemoteConfig(name, url, scope_value, gpg_verify, null);
    }

    pub fn addRemoteConfig(
        self: RemoteManager,
        name: [:0]const u8,
        url: [:0]const u8,
        scope_value: flatpak.Scope,
        gpg_verify: bool,
        gpg_key: ?[]const u8,
    ) !bool {
        var scope = events.OperationScope.init(
            self.operation_context,
            self.parent_operation,
            null,
            .configure,
            name,
        );
        scope.attach();
        defer scope.finish(.success);
        errdefer scope.fail();
        try scope.checkCancelled();

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

        const remote = raw.flatpak_remote_new(name) orelse
            return error.RemoteCreateFailed;
        defer raw.g_object_unref(remote);
        raw.flatpak_remote_set_url(remote, url);
        raw.flatpak_remote_set_gpg_verify(remote, @intFromBool(gpg_verify));

        if (gpg_key) |encoded| {
            const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
            const decoded = try self.allocator.alloc(u8, decoded_len);
            defer self.allocator.free(decoded);
            try std.base64.standard.Decoder.decode(decoded, encoded);
            const bytes = raw.g_bytes_new(decoded.ptr, decoded.len) orelse
                return error.GpgKeyCreateFailed;
            defer raw.g_bytes_unref(bytes);
            raw.flatpak_remote_set_gpg_key(remote, bytes);
        }

        const result = raw.flatpak_installation_add_remote(
            installation,
            remote,
            1,
            cancellable,
            &g_error,
        );
        if (result == 0) {
            if (g_error) |value|
                scope.reportError(
                    error.FlatpakError,
                    std.mem.span(value.message),
                    value.code,
                );
            return false;
        }
        scope.status(.success, "Flatpak remote added", "flatpak.remote.added");
        return true;
    }

    pub fn removeRemote(
        self: RemoteManager,
        name: [:0]const u8,
        scope_value: flatpak.Scope,
    ) !bool {
        var scope = events.OperationScope.init(
            self.operation_context,
            self.parent_operation,
            null,
            .configure,
            name,
        );
        scope.attach();
        defer scope.finish(.success);
        errdefer scope.fail();
        try scope.checkCancelled();

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

        const result = raw.flatpak_installation_remove_remote(
            installation,
            name,
            cancellable,
            &g_error,
        );
        if (result == 0) return false;
        scope.status(.success, "Flatpak remote removed", "flatpak.remote.removed");
        return true;
    }

    fn appendRemotes(
        self: RemoteManager,
        list: *std.ArrayList(flatpak.Remote),
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

        const installation = try installationForScope(
            scope_value,
            cancellable,
            &g_error,
        );
        defer raw.g_object_unref(installation);
        const native = raw.flatpak_installation_list_remotes(
            installation,
            cancellable,
            &g_error,
        );
        if (native == null or g_error != null) return error.FlatpakError;
        defer raw.g_ptr_array_unref(native);

        var index: usize = 0;
        while (index < native.*.len) : (index += 1) {
            if (self.operation_context) |context|
                if (context.isCancelled()) return error.Cancelled;
            const remote: *raw.FlatpakRemote =
                @ptrCast(@alignCast(native.*.pdata[index]));
            _ = raw.g_object_ref(remote);
            list.append(
                self.allocator,
                flatpak.Remote.new(remote, scope_value),
            ) catch |err| {
                raw.g_object_unref(remote);
                return err;
            };
        }
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

test "native Flatpak remote manager exposes backend parity operations" {
    _ = RemoteManager.listRemotesWithDetails;
    _ = RemoteManager.addRemote;
    _ = RemoteManager.addRemoteConfig;
    _ = RemoteManager.removeRemote;

    var analyze_bodies = false;
    std.mem.doNotOptimizeAway(&analyze_bodies);
    if (analyze_bodies) {
        const manager: RemoteManager = .{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
        };
        const remotes = try manager.listRemotesWithDetails();
        RemoteManager.deinitRemotes(std.testing.allocator, remotes);
    }
}
