const std = @import("std");
const operation_api = @import("operation_context");
const protocol = @import("Shelly_Flatpak_Protocol");
const types = @import("types.zig");
const events = @import("events.zig");
const client_api = @import("client.zig");
const appstreams = @import("appstream_manager.zig");
pub const eol = @import("eol.zig");

const wire = protocol.wire;

pub const InstalledApplication = types.InstalledApplication;
pub const InstalledRef = types.InstalledRef;
pub const RunningInstance = types.RunningInstance;
pub const UnusedDependency = types.UnusedDependency;
pub const EolStatus = types.EolStatus;

pub const EolRebase = struct {
    old_ref: []u8,
    new_ref: []u8,
    new_id: []u8,
    new_branch: []u8,
    remote: []u8,
    scope: types.Scope,

    pub fn deinit(self: *EolRebase, allocator: std.mem.Allocator) void {
        allocator.free(self.old_ref);
        allocator.free(self.new_ref);
        allocator.free(self.new_id);
        allocator.free(self.new_branch);
        allocator.free(self.remote);
        self.* = undefined;
    }
};

pub const EolDetection = struct {
    reason: ?[]u8,
    rebase: ?EolRebase,

    pub fn deinit(self: *EolDetection, allocator: std.mem.Allocator) void {
        if (self.reason) |value| allocator.free(value);
        if (self.rebase) |*value| value.deinit(allocator);
        self.* = undefined;
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dispatcher: ?*events.Dispatcher = null,
    cancellation: ?events.Cancellation = null,
    operation_context: ?*operation_api.OperationContext = null,
    owned_dispatcher: ?*events.Dispatcher = null,

    pub fn setEventDispatcher(
        self: *Manager,
        dispatcher: ?*events.Dispatcher,
    ) void {
        self.dispatcher = dispatcher orelse self.owned_dispatcher;
    }

    pub fn setCancellation(
        self: *Manager,
        cancellation: ?events.Cancellation,
    ) void {
        self.cancellation = cancellation;
    }

    pub fn setOperationContext(
        self: *Manager,
        context: ?*operation_api.OperationContext,
    ) !void {
        self.operation_context = context;
        if (context != null and self.dispatcher == null) {
            const dispatcher = try self.allocator.create(events.Dispatcher);
            dispatcher.* = events.Dispatcher.init(self.allocator);
            self.owned_dispatcher = dispatcher;
            self.dispatcher = dispatcher;
        }
    }

    pub fn deinit(self: *Manager) void {
        if (self.owned_dispatcher) |dispatcher| {
            if (self.dispatcher == dispatcher) self.dispatcher = null;
            dispatcher.deinit();
            self.allocator.destroy(dispatcher);
            self.owned_dispatcher = null;
        }
        self.operation_context = null;
    }

    pub fn install_flatpak(
        self: Manager,
        flatpak_id: []const u8,
        remote_name: []const u8,
        scope: types.Scope,
        branch: []const u8,
        runtime: bool,
    ) !bool {
        return self.callBool(
            wire.Method.install,
            wire.InstallArguments{
                .id = flatpak_id,
                .remote = remote_name,
                .scope = scope.toWire(),
                .branch = branch,
                .runtime = runtime,
            },
            .install,
            flatpak_id,
        );
    }

    pub fn install_from_ref_flatpak(
        self: Manager,
        path: []const u8,
        scope: types.Scope,
    ) !bool {
        return self.callBool(
            wire.Method.install_ref_file,
            wire.InstallFileArguments{
                .path = path,
                .scope = scope.toWire(),
            },
            .install,
            path,
        );
    }

    pub fn install_from_bundle_flatpak(
        self: Manager,
        path: []const u8,
        scope: types.Scope,
    ) !bool {
        return self.callBool(
            wire.Method.install_bundle,
            wire.InstallFileArguments{
                .path = path,
                .scope = scope.toWire(),
            },
            .install,
            path,
        );
    }

    pub fn update_installed_flatpak(
        self: Manager,
        name_or_id: []const u8,
        commit: ?[]const u8,
    ) !bool {
        return self.callBool(
            wire.Method.update_installed,
            wire.UpdateInstalledArguments{
                .name_or_id = name_or_id,
                .commit = commit,
            },
            .update,
            name_or_id,
        );
    }

    pub fn update_flatpak(
        self: Manager,
        flatpak_id: []const u8,
        scope: types.Scope,
        commit: ?[]const u8,
    ) !bool {
        return self.callBool(
            wire.Method.update_installed,
            wire.UpdateInstalledArguments{
                .name_or_id = flatpak_id,
                .scope = scope.toWire(),
                .commit = commit,
            },
            .update,
            flatpak_id,
        );
    }

    pub fn rebase_flatpak(
        self: Manager,
        old_ref: []const u8,
        new_ref: []const u8,
        remote: []const u8,
        scope: types.Scope,
        previous_ids: []const []const u8,
    ) !bool {
        return self.callBool(
            wire.Method.rebase,
            wire.RebaseArguments{
                .old_ref = old_ref,
                .new_ref = new_ref,
                .remote = remote,
                .scope = scope.toWire(),
                .previous_ids = previous_ids,
            },
            .update,
            old_ref,
        );
    }

    pub fn list_eol_flatpak(self: Manager) ![]types.EolStatus {
        var parsed = try self.call(
            []wire.EolStatus,
            wire.Method.list_eol,
            wire.EmptyArguments{},
            .search,
            null,
        );
        defer parsed.deinit();
        return cloneSlice(types.EolStatus, self.allocator, parsed.value);
    }

    pub fn detect_eol_flatpak(
        self: Manager,
        application: *const types.InstalledApplication,
    ) !?EolDetection {
        var reason: ?[]u8 = null;
        var marker: ?[]u8 = null;
        errdefer {
            if (reason) |value| self.allocator.free(value);
            if (marker) |value| self.allocator.free(value);
        }

        var authoritative = false;
        if (application.origin.len > 0) {
            if (self.get_remote_ref_info_flatpak(
                application.origin,
                application.id,
                application.branch,
                application.scope,
            )) |remote_ref_value| {
                var remote_ref = remote_ref_value;
                defer remote_ref.deinit(self.allocator);
                authoritative = true;
                if (remote_ref.eol) |text| reason = try self.allocator.dupe(u8, text);
                if (remote_ref.eol_rebase) |text| marker = try self.allocator.dupe(u8, text);
            } else |_| {
                // Unreachable remote: fall back to the markers recorded on the installed ref.
            }
        }
        if (!authoritative) {
            if (application.eol) |text| reason = try self.allocator.dupe(u8, text);
            if (application.eol_rebase) |text| marker = try self.allocator.dupe(u8, text);
        }
        if (reason == null and marker == null) return null;

        var rebase: ?EolRebase = null;
        errdefer if (rebase) |*value| value.deinit(self.allocator);
        if (marker) |value| {
            if (eol.parseRebaseTarget(value, application.branch)) |target| {
                rebase = try self.buildEolRebase(application, target);
            }
            self.allocator.free(value);
            marker = null;
        }
        return .{ .reason = reason, .rebase = rebase };
    }

    fn buildEolRebase(
        self: Manager,
        application: *const types.InstalledApplication,
        target: eol.RebaseTarget,
    ) !EolRebase {
        const old_ref = try eol.buildRef(
            self.allocator,
            application.kind,
            application.id,
            application.arch,
            application.branch,
        );
        errdefer self.allocator.free(old_ref);
        const new_id = try self.allocator.dupe(u8, target.id);
        errdefer self.allocator.free(new_id);
        const new_ref = if (target.reference) |reference|
            try self.allocator.dupe(u8, reference)
        else
            try eol.buildRef(
                self.allocator,
                application.kind,
                new_id,
                application.arch,
                target.branch,
            );
        errdefer self.allocator.free(new_ref);
        const new_branch = try self.allocator.dupe(u8, target.branch);
        errdefer self.allocator.free(new_branch);
        const remote = try self.allocator.dupe(u8, application.origin);
        errdefer self.allocator.free(remote);
        return .{
            .old_ref = old_ref,
            .new_ref = new_ref,
            .new_id = new_id,
            .new_branch = new_branch,
            .remote = remote,
            .scope = application.scope,
        };
    }

    pub fn uninstall_installed_flatpak(
        self: Manager,
        name_or_id: []const u8,
        remove_unused: bool,
    ) !bool {
        return self.callBool(
            wire.Method.uninstall_installed,
            wire.UninstallInstalledArguments{
                .name_or_id = name_or_id,
                .remove_unused = remove_unused,
            },
            .remove,
            name_or_id,
        );
    }

    pub fn uninstall_flatpak(
        self: Manager,
        flatpak_id: []const u8,
        scope: types.Scope,
        remove_unused: bool,
    ) !bool {
        return self.callBool(
            wire.Method.uninstall_installed,
            wire.UninstallInstalledArguments{
                .name_or_id = flatpak_id,
                .scope = scope.toWire(),
                .remove_unused = remove_unused,
            },
            .remove,
            flatpak_id,
        );
    }

    pub fn repair_installed_flatpak(
        self: Manager,
        name_or_id: []const u8,
    ) !bool {
        return self.callBool(
            wire.Method.repair_installed,
            wire.NameArguments{ .name_or_id = name_or_id },
            .install,
            name_or_id,
        );
    }

    pub fn upgrade_flatpaks(self: Manager) !bool {
        return self.callBool(
            wire.Method.upgrade_all,
            wire.EmptyArguments{},
            .update,
            null,
        );
    }

    pub fn remove_unused_dependencies(self: Manager) !bool {
        return self.callBool(
            wire.Method.remove_unused,
            wire.EmptyArguments{},
            .cleanup,
            null,
        );
    }

    pub fn list_installed_applications(
        self: Manager,
    ) ![]types.InstalledApplication {
        var parsed = try self.call(
            []wire.InstalledApplication,
            wire.Method.list_installed,
            wire.ListInstalledArguments{ .mode = .applications },
            .search,
            null,
        );
        defer parsed.deinit();
        return cloneSlice(
            types.InstalledApplication,
            self.allocator,
            parsed.value,
        );
    }

    pub fn list_installed_flatpak(self: Manager) ![]types.Ref {
        var parsed = try self.call(
            []wire.Ref,
            wire.Method.list_installed,
            wire.ListInstalledArguments{ .mode = .refs },
            .search,
            null,
        );
        defer parsed.deinit();
        return cloneSlice(types.Ref, self.allocator, parsed.value);
    }

    pub fn find_installed_flatpak(
        self: Manager,
        name_or_id: []const u8,
    ) !?types.InstalledApplication {
        var parsed = try self.call(
            ?wire.InstalledApplication,
            wire.Method.find_installed,
            wire.NameArguments{ .name_or_id = name_or_id },
            .search,
            name_or_id,
        );
        defer parsed.deinit();
        return if (parsed.value) |value|
            try types.InstalledApplication.fromWire(
                self.allocator,
                value,
            )
        else
            null;
    }

    pub fn get_updates_flatpak(self: Manager) ![]types.InstalledRef {
        var parsed = try self.call(
            []wire.InstalledRef,
            wire.Method.list_updates,
            wire.EmptyArguments{},
            .search,
            null,
        );
        defer parsed.deinit();
        return cloneSlice(
            types.InstalledRef,
            self.allocator,
            parsed.value,
        );
    }

    pub fn list_unused_dependencies(
        self: Manager,
    ) ![]types.UnusedDependency {
        var parsed = try self.call(
            []wire.UnusedDependency,
            wire.Method.list_unused,
            wire.EmptyArguments{},
            .cleanup,
            null,
        );
        defer parsed.deinit();
        return cloneSlice(
            types.UnusedDependency,
            self.allocator,
            parsed.value,
        );
    }

    pub fn get_running_instances_flatpak(
        self: Manager,
    ) ![]types.RunningInstance {
        var parsed = try self.call(
            []wire.RunningInstance,
            wire.Method.list_running,
            wire.EmptyArguments{},
            .search,
            null,
        );
        defer parsed.deinit();
        return cloneSlice(
            types.RunningInstance,
            self.allocator,
            parsed.value,
        );
    }

    pub fn search_remote_refs_flatpak(
        self: Manager,
        query: []const u8,
    ) ![]types.Ref {
        var parsed = try self.call(
            []wire.Ref,
            wire.Method.search_remote_refs,
            wire.QueryArguments{ .query = query },
            .search,
            query,
        );
        defer parsed.deinit();
        return cloneSlice(types.Ref, self.allocator, parsed.value);
    }

    pub fn get_flatpaks_from_remote(
        self: Manager,
        remote_name: []const u8,
    ) ![]types.Ref {
        var parsed = try self.call(
            []wire.Ref,
            wire.Method.list_remote_refs,
            wire.RemoteNameArguments{ .remote = remote_name },
            .search,
            remote_name,
        );
        defer parsed.deinit();
        return cloneSlice(types.Ref, self.allocator, parsed.value);
    }

    pub fn get_remote_ref_info_flatpak(
        self: Manager,
        remote_name: []const u8,
        flatpak_name: []const u8,
        branch: []const u8,
        scope: types.Scope,
    ) !types.RemoteRef {
        var parsed = try self.call(
            wire.RemoteRef,
            wire.Method.get_remote_ref,
            wire.RemoteRefArguments{
                .remote = remote_name,
                .name = flatpak_name,
                .branch = branch,
                .scope = scope.toWire(),
            },
            .search,
            flatpak_name,
        );
        defer parsed.deinit();
        return types.RemoteRef.fromWire(self.allocator, parsed.value);
    }

    pub fn launch_flatpak(
        self: Manager,
        flatpak_id: []const u8,
    ) !bool {
        return self.callBool(
            wire.Method.launch,
            wire.NameArguments{ .name_or_id = flatpak_id },
            .launch,
            flatpak_id,
        );
    }

    pub fn kill_flatpak(
        self: Manager,
        flatpak_id: []const u8,
    ) !bool {
        return self.callBool(
            wire.Method.kill,
            wire.NameArguments{ .name_or_id = flatpak_id },
            .remove,
            flatpak_id,
        );
    }

    pub fn get_remote_appstream(
        self: Manager,
        remote_name: []const u8,
        arch: ?[]const u8,
    ) !types.AppstreamCatalog {
        var manager = appstreams.AppstreamManager.init(
            self.allocator,
            self.io,
        );
        manager.setOperationContext(self.operation_context);
        return manager.getRemoteCatalog(remote_name, arch);
    }

    pub fn get_all_remote_appstreams(
        self: Manager,
        arch: ?[]const u8,
    ) ![]types.AppstreamCatalog {
        var manager = appstreams.AppstreamManager.init(
            self.allocator,
            self.io,
        );
        manager.setOperationContext(self.operation_context);
        return manager.getAllRemoteCatalogs(arch);
    }

    fn callBool(
        self: Manager,
        method: []const u8,
        arguments: anytype,
        kind: operation_api.OperationKind,
        subject: ?[]const u8,
    ) !bool {
        var parsed = try self.call(
            wire.BoolResult,
            method,
            arguments,
            kind,
            subject,
        );
        defer parsed.deinit();
        return parsed.value.value;
    }

    fn call(
        self: Manager,
        comptime T: type,
        method: []const u8,
        arguments: anytype,
        kind: operation_api.OperationKind,
        subject: ?[]const u8,
    ) !std.json.Parsed(T) {
        var scope = events.OperationScope.init(
            self.operation_context,
            null,
            self.dispatcher,
            kind,
            subject,
        );
        scope.attach();
        defer scope.finish(.success);
        errdefer scope.fail();
        try scope.checkCancelled();
        const target: client_api.EventTarget = .{
            .operation = if (scope.operation) |*operation|
                operation
            else
                null,
            .dispatcher = self.dispatcher,
            .context = self.operation_context,
            .cancellation = self.cancellation,
            .failure_reported = &scope.failure_reported,
        };
        return (client_api.Client{
            .allocator = self.allocator,
        }).call(T, method, arguments, target);
    }
};

fn cloneSlice(
    comptime T: type,
    allocator: std.mem.Allocator,
    values: anytype,
) ![]T {
    const result = try allocator.alloc(T, values.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |*value| value.deinit(allocator);
        allocator.free(result);
    }
    for (values, result) |value, *output| {
        output.* = try T.fromWire(allocator, value);
        initialized += 1;
    }
    return result;
}

test "Flatpak manager exposes strict-parity operations" {
    _ = Manager.install_flatpak;
    _ = Manager.install_from_ref_flatpak;
    _ = Manager.install_from_bundle_flatpak;
    _ = Manager.update_installed_flatpak;
    _ = Manager.uninstall_installed_flatpak;
    _ = Manager.repair_installed_flatpak;
    _ = Manager.upgrade_flatpaks;
    _ = Manager.remove_unused_dependencies;
    _ = Manager.list_installed_applications;
    _ = Manager.find_installed_flatpak;
    _ = Manager.get_updates_flatpak;
    _ = Manager.list_unused_dependencies;
    _ = Manager.get_running_instances_flatpak;
    _ = Manager.search_remote_refs_flatpak;
    _ = Manager.get_remote_ref_info_flatpak;
    _ = Manager.launch_flatpak;
    _ = Manager.kill_flatpak;
    _ = Manager.rebase_flatpak;
    _ = Manager.list_eol_flatpak;
    _ = Manager.detect_eol_flatpak;
}
