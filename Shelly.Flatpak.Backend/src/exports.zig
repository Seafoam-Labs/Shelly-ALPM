const std = @import("std");
const protocol = @import("Shelly_Flatpak_Protocol");
const wire = protocol.wire;
const operation_api = @import("operation_context");
const native_manager = @import("flatpak/manager.zig");
const native_remotes = @import("flatpak/remote_manager.zig");
const native_catalogs = @import("flatpak/catalogs.zig");
const bindings = @import("flatpak/bindings.zig");

const native = bindings.libflatpak;
const raw = native.flatpak;
const allocator = std.heap.c_allocator;

const State = struct {
    host: protocol.HostApiV1,
    threaded: std.Io.Threaded,
    operations: operation_api.OperationContext,
    event_subscription: operation_api.SubscriptionId,
    current_operation_id: std.atomic.Value(u64) = .init(0),
    pending_cancel_operation_id: std.atomic.Value(u64) = .init(0),
    execute_mutex: std.Io.Mutex = .init,
};

export fn shelly_flatpak_backend_get_api(
    requested_version: u32,
    host: *const protocol.HostApiV1,
    api: *protocol.BackendApiV1,
) callconv(.c) protocol.Status {
    if (requested_version != protocol.abi_version)
        return .incompatible;
    if (!protocol.hostApiValid(host))
        return .invalid_argument;
    api.* = .{
        .struct_size = @sizeOf(protocol.BackendApiV1),
        .abi_version = protocol.abi_version,
        .create = create,
        .destroy = destroy,
        .execute = execute,
        .cancel = cancel,
        .free_response = freeResponse,
    };
    return .success;
}

fn create(
    host: *const protocol.HostApiV1,
    output: *?*anyopaque,
) callconv(.c) protocol.Status {
    if (!protocol.hostApiValid(host))
        return .invalid_argument;
    const state = allocator.create(State) catch return .internal_error;
    state.host = host.*;
    state.threaded = .init(allocator, .{});
    state.operations = operation_api.OperationContext.init(
        allocator,
        state.threaded.io(),
    );
    state.current_operation_id = .init(0);
    state.pending_cancel_operation_id = .init(0);
    state.execute_mutex = .init;
    state.event_subscription = state.operations.subscribe(.{
        .function = forwardOperationEvent,
        .data = state,
    }) catch {
        state.operations.deinit();
        state.threaded.deinit();
        allocator.destroy(state);
        return .internal_error;
    };
    output.* = state;
    return .success;
}

fn destroy(handle: ?*anyopaque) callconv(.c) void {
    const state = stateFromHandle(handle) orelse return;
    _ = state.operations.unsubscribe(state.event_subscription);
    state.operations.deinit();
    state.threaded.deinit();
    allocator.destroy(state);
}

fn execute(
    handle: ?*anyopaque,
    request_buffer: protocol.RequestBuffer,
    response: *protocol.ResponseBuffer,
) callconv(.c) protocol.Status {
    const state = stateFromHandle(handle) orelse return .invalid_argument;
    response.* = .{};
    if (request_buffer.len == 0 or
        request_buffer.len > wire.max_message_size)
        return .invalid_argument;

    state.execute_mutex.lockUncancelable(state.threaded.io());
    defer state.execute_mutex.unlock(state.threaded.io());

    var request = protocol.parseRequest(
        allocator,
        request_buffer.slice(),
    ) catch return .invalid_argument;
    defer request.deinit();

    state.current_operation_id.store(
        request.value.operation_id,
        .release,
    );
    defer state.current_operation_id.store(0, .release);
    if (state.operations.isCancelled())
        state.operations.resetCancellation();
    if (state.pending_cancel_operation_id.load(.acquire) ==
        request.value.operation_id)
    {
        state.pending_cancel_operation_id.store(0, .release);
        state.operations.cancel();
    }

    const encoded = dispatch(state, request.value) catch |err|
        failureResponse(
            request.value.operation_id,
            errorCode(err),
            errorMessage(err),
            null,
        ) catch return .internal_error;
    if (encoded.len > wire.max_message_size) {
        allocator.free(encoded);
        return .internal_error;
    }
    response.* = .{ .ptr = encoded.ptr, .len = encoded.len };
    return .success;
}

fn cancel(
    handle: ?*anyopaque,
    operation_id: u64,
) callconv(.c) protocol.Status {
    const state = stateFromHandle(handle) orelse return .invalid_argument;
    const active = state.current_operation_id.load(.acquire);
    if (active == 0) {
        state.pending_cancel_operation_id.store(
            operation_id,
            .release,
        );
        return .success;
    }
    if (active != operation_id)
        return .success;
    state.operations.cancel();
    return .success;
}

fn freeResponse(
    _: ?*anyopaque,
    response: protocol.ResponseBuffer,
) callconv(.c) void {
    if (response.ptr) |ptr| allocator.free(ptr[0..response.len]);
}

fn stateFromHandle(handle: ?*anyopaque) ?*State {
    return @ptrCast(@alignCast(handle orelse return null));
}

fn dispatch(
    state: *State,
    request: wire.RequestEnvelope,
) ![]u8 {
    const method = request.method;
    if (std.mem.eql(u8, method, wire.Method.install))
        return install(state, request);
    if (std.mem.eql(u8, method, wire.Method.install_ref_file))
        return installFile(state, request, false);
    if (std.mem.eql(u8, method, wire.Method.install_bundle))
        return installFile(state, request, true);
    if (std.mem.eql(u8, method, wire.Method.update_installed))
        return updateInstalled(state, request);
    if (std.mem.eql(u8, method, wire.Method.uninstall_installed))
        return uninstallInstalled(state, request);
    if (std.mem.eql(u8, method, wire.Method.repair_installed))
        return repairInstalled(state, request);
    if (std.mem.eql(u8, method, wire.Method.upgrade_all))
        return upgradeAll(state, request);
    if (std.mem.eql(u8, method, wire.Method.remove_unused))
        return removeUnused(state, request);
    if (std.mem.eql(u8, method, wire.Method.list_installed))
        return listInstalled(state, request);
    if (std.mem.eql(u8, method, wire.Method.find_installed))
        return findInstalled(state, request);
    if (std.mem.eql(u8, method, wire.Method.list_updates))
        return listUpdates(state, request);
    if (std.mem.eql(u8, method, wire.Method.list_unused))
        return listUnused(state, request);
    if (std.mem.eql(u8, method, wire.Method.list_running))
        return listRunning(state, request);
    if (std.mem.eql(u8, method, wire.Method.search_remote_refs))
        return searchRemoteRefs(state, request);
    if (std.mem.eql(u8, method, wire.Method.get_remote_ref))
        return getRemoteRef(state, request);
    if (std.mem.eql(u8, method, wire.Method.launch))
        return launch(state, request);
    if (std.mem.eql(u8, method, wire.Method.kill))
        return kill(state, request);
    if (std.mem.eql(u8, method, wire.Method.list_remotes))
        return listRemotes(state, request);
    if (std.mem.eql(u8, method, wire.Method.add_remote))
        return addRemote(state, request);
    if (std.mem.eql(u8, method, wire.Method.remove_remote))
        return removeRemote(state, request);
    if (std.mem.eql(u8, method, wire.Method.highest_priority_remote))
        return highestPriorityRemote(state, request);
    if (std.mem.eql(u8, method, wire.Method.list_remote_refs))
        return listRemoteRefs(state, request);
    if (std.mem.eql(u8, method, wire.Method.update_all_appstreams))
        return updateAllAppstreams(state, request);
    if (std.mem.eql(u8, method, wire.Method.update_remote_appstream))
        return updateRemoteAppstream(state, request);
    if (std.mem.eql(u8, method, wire.Method.get_remote_catalog))
        return getRemoteCatalog(state, request);
    if (std.mem.eql(u8, method, wire.Method.get_all_remote_catalogs))
        return getAllRemoteCatalogs(state, request);
    if (std.mem.eql(u8, method, wire.Method.load_catalog))
        return loadCatalog(state, request);
    return error.UnknownMethod;
}

fn install(state: *State, request: wire.RequestEnvelope) ![]u8 {
    var args = try parseArgs(wire.InstallArguments, request);
    defer args.deinit();
    const id = try allocator.dupeZ(u8, args.value.id);
    defer allocator.free(id);
    const remote = try allocator.dupeZ(u8, args.value.remote);
    defer allocator.free(remote);
    const branch = try allocator.dupeZ(u8, args.value.branch);
    defer allocator.free(branch);
    var manager = managerFor(state);
    defer manager.deinit();
    const result = try manager.install_flatpak(
        id,
        remote,
        scopeFromWire(args.value.scope),
        branch,
        args.value.runtime,
    );
    return successResponse(
        request.operation_id,
        wire.BoolResult{ .value = result },
    );
}

fn installFile(
    state: *State,
    request: wire.RequestEnvelope,
    bundle: bool,
) ![]u8 {
    var args = try parseArgs(wire.InstallFileArguments, request);
    defer args.deinit();
    const path = try allocator.dupeZ(u8, args.value.path);
    defer allocator.free(path);
    var manager = managerFor(state);
    defer manager.deinit();
    const result = if (bundle)
        try manager.install_from_bundle_flatpak(
            path,
            scopeFromWire(args.value.scope),
        )
    else
        try manager.install_from_ref_flatpak(
            path,
            scopeFromWire(args.value.scope),
        );
    return successResponse(
        request.operation_id,
        wire.BoolResult{ .value = result },
    );
}

fn updateInstalled(state: *State, request: wire.RequestEnvelope) ![]u8 {
    var args = try parseArgs(wire.UpdateInstalledArguments, request);
    defer args.deinit();
    var manager = managerFor(state);
    defer manager.deinit();
    const result = if (args.value.scope) |scope| direct: {
        const id = try allocator.dupeZ(u8, args.value.name_or_id);
        defer allocator.free(id);
        const commit = if (args.value.commit) |value|
            try allocator.dupeZ(u8, value)
        else
            null;
        defer if (commit) |value| allocator.free(value);
        break :direct try manager.update_flatpak(
            id,
            scopeFromWire(scope),
            commit,
        );
    } else try manager.update_installed_flatpak(
        args.value.name_or_id,
        args.value.commit,
    );
    return successResponse(
        request.operation_id,
        wire.BoolResult{ .value = result },
    );
}

fn uninstallInstalled(
    state: *State,
    request: wire.RequestEnvelope,
) ![]u8 {
    var args = try parseArgs(wire.UninstallInstalledArguments, request);
    defer args.deinit();
    var manager = managerFor(state);
    defer manager.deinit();
    const result = if (args.value.scope) |scope| direct: {
        const id = try allocator.dupeZ(u8, args.value.name_or_id);
        defer allocator.free(id);
        break :direct try manager.uninstall_flatpak(
            id,
            scopeFromWire(scope),
            args.value.remove_unused,
        );
    } else try manager.uninstall_installed_flatpak(
        args.value.name_or_id,
        args.value.remove_unused,
    );
    return successResponse(
        request.operation_id,
        wire.BoolResult{ .value = result },
    );
}

fn repairInstalled(state: *State, request: wire.RequestEnvelope) ![]u8 {
    var args = try parseArgs(wire.NameArguments, request);
    defer args.deinit();
    var manager = managerFor(state);
    defer manager.deinit();
    return successResponse(
        request.operation_id,
        wire.BoolResult{
            .value = try manager.repair_installed_flatpak(
                args.value.name_or_id,
            ),
        },
    );
}

fn upgradeAll(state: *State, request: wire.RequestEnvelope) ![]u8 {
    var args = try parseArgs(wire.EmptyArguments, request);
    defer args.deinit();
    var manager = managerFor(state);
    defer manager.deinit();
    return successResponse(
        request.operation_id,
        wire.BoolResult{ .value = try manager.upgrade_flatpaks() },
    );
}

fn removeUnused(state: *State, request: wire.RequestEnvelope) ![]u8 {
    var args = try parseArgs(wire.EmptyArguments, request);
    defer args.deinit();
    var manager = managerFor(state);
    defer manager.deinit();
    return successResponse(
        request.operation_id,
        wire.BoolResult{
            .value = try manager.remove_unused_dependencies(),
        },
    );
}

fn listInstalled(state: *State, request: wire.RequestEnvelope) ![]u8 {
    var args = try parseArgs(wire.ListInstalledArguments, request);
    defer args.deinit();
    var manager = managerFor(state);
    defer manager.deinit();
    return switch (args.value.mode) {
        .applications => listInstalledApplications(&manager, request),
        .refs => listInstalledRefs(&manager, request),
    };
}

fn listInstalledApplications(
    manager: *native_manager.Manager,
    request: wire.RequestEnvelope,
) ![]u8 {
    const values = try manager.list_installed_applications();
    defer native_manager.InstalledApplication.deinitSlice(
        allocator,
        values,
    );
    const result = try allocator.alloc(
        wire.InstalledApplication,
        values.len,
    );
    defer allocator.free(result);
    for (values, result) |value, *output| output.* = .{
        .id = value.id,
        .name = value.name,
        .arch = value.arch,
        .branch = value.branch,
        .summary = value.summary,
        .version = value.version,
        .latest_commit = value.latest_commit,
        .origin = value.origin,
        .kind = kindFromNative(value.kind),
        .installed_size = value.installed_size,
        .scope = scopeToWire(value.scope),
    };
    return successResponse(request.operation_id, result);
}

fn listInstalledRefs(
    manager: *native_manager.Manager,
    request: wire.RequestEnvelope,
) ![]u8 {
    const values = try manager.list_installed_flatpak();
    defer {
        for (values) |value| raw.g_object_unref(value.ptr);
        allocator.free(values);
    }
    return refsResponse(request.operation_id, values);
}

fn findInstalled(state: *State, request: wire.RequestEnvelope) ![]u8 {
    var args = try parseArgs(wire.NameArguments, request);
    defer args.deinit();
    var manager = managerFor(state);
    defer manager.deinit();
    var value = try manager.find_installed_flatpak(
        args.value.name_or_id,
    );
    defer if (value) |*application| application.deinit(allocator);
    const result: ?wire.InstalledApplication = if (value) |application| .{
        .id = application.id,
        .name = application.name,
        .arch = application.arch,
        .branch = application.branch,
        .summary = application.summary,
        .version = application.version,
        .latest_commit = application.latest_commit,
        .origin = application.origin,
        .kind = kindFromNative(application.kind),
        .installed_size = application.installed_size,
        .scope = scopeToWire(application.scope),
    } else null;
    return successResponse(request.operation_id, result);
}

fn listUpdates(state: *State, request: wire.RequestEnvelope) ![]u8 {
    var args = try parseArgs(wire.EmptyArguments, request);
    defer args.deinit();
    var manager = managerFor(state);
    defer manager.deinit();
    const values = try manager.get_updates_flatpak();
    defer {
        for (values) |value| {
            value.deinitPermissions(allocator);
            raw.g_object_unref(value.ptr);
        }
        allocator.free(values);
    }

    const result = try allocator.alloc(wire.InstalledRef, values.len);
    defer allocator.free(result);
    var initialized: usize = 0;
    defer for (result[0..initialized]) |value| {
        allocator.free(value.reference);
        allocator.free(value.permissions);
    };
    for (values, result) |value, *output| {
        const reference = try native.refToString(allocator, value.ptr);
        errdefer allocator.free(reference);
        const permissions = try permissionView(value.permissions);
        errdefer allocator.free(permissions);
        output.* = .{
            .id = value.id(),
            .name = value.name(),
            .arch = value.arch(),
            .branch = value.branch(),
            .reference = reference,
            .origin = value.origin(),
            .version = value.version(),
            .summary = value.summary(),
            .latest_commit = value.last_commit(),
            .installed_size = value.installed_size(),
            .kind = kindFromNative(value.kind()),
            .scope = scopeToWire(value.get_scope()),
            .permissions = permissions,
        };
        initialized += 1;
    }
    return successResponse(request.operation_id, result);
}

fn listUnused(state: *State, request: wire.RequestEnvelope) ![]u8 {
    var args = try parseArgs(wire.EmptyArguments, request);
    defer args.deinit();
    var manager = managerFor(state);
    defer manager.deinit();
    const values = try manager.list_unused_dependencies();
    defer native_manager.UnusedDependency.deinitSlice(allocator, values);
    const result = try allocator.alloc(
        wire.UnusedDependency,
        values.len,
    );
    defer allocator.free(result);
    for (values, result) |value, *output| output.* = .{
        .reference = value.reference,
        .scope = scopeToWire(value.scope),
    };
    return successResponse(request.operation_id, result);
}

fn listRunning(state: *State, request: wire.RequestEnvelope) ![]u8 {
    var args = try parseArgs(wire.EmptyArguments, request);
    defer args.deinit();
    var manager = managerFor(state);
    defer manager.deinit();
    const values = try manager.get_running_instances_flatpak();
    defer native_manager.RunningInstance.deinitSlice(allocator, values);
    const result = try allocator.alloc(
        wire.RunningInstance,
        values.len,
    );
    defer allocator.free(result);
    for (values, result) |value, *output| output.* = .{
        .instance_id = value.instance_id,
        .application_id = value.application_id,
        .arch = value.arch,
        .branch = value.branch,
        .pid = value.pid,
        .child_pid = value.child_pid,
    };
    return successResponse(request.operation_id, result);
}

fn searchRemoteRefs(state: *State, request: wire.RequestEnvelope) ![]u8 {
    var args = try parseArgs(wire.QueryArguments, request);
    defer args.deinit();
    const query = try allocator.dupeZ(u8, args.value.query);
    defer allocator.free(query);
    var manager = managerFor(state);
    defer manager.deinit();
    const values = try manager.search_remote_refs_flatpak(query);
    defer {
        for (values) |value| raw.g_object_unref(value.ptr);
        allocator.free(values);
    }
    return refsResponse(request.operation_id, values);
}

fn getRemoteRef(state: *State, request: wire.RequestEnvelope) ![]u8 {
    var args = try parseArgs(wire.RemoteRefArguments, request);
    defer args.deinit();
    const remote = try allocator.dupeZ(u8, args.value.remote);
    defer allocator.free(remote);
    const name = try allocator.dupeZ(u8, args.value.name);
    defer allocator.free(name);
    const branch = try allocator.dupeZ(u8, args.value.branch);
    defer allocator.free(branch);
    var manager = managerFor(state);
    defer manager.deinit();
    const value = try manager.get_remote_ref_info_flatpak(
        remote,
        name,
        branch,
        scopeFromWire(args.value.scope),
    );
    defer value.deinit(allocator);
    const permissions = try permissionView(value.permissions);
    defer allocator.free(permissions);
    const result: wire.RemoteRef = .{
        .remote_name = value.remote_name() orelse "",
        .installed_size = value.installed_size(),
        .download_size = value.download_size(),
        .eol = value.eol(),
        .eol_rebase = value.eol_rebase(),
        .scope = scopeToWire(value.get_scope()),
        .permissions = permissions,
    };
    return successResponse(request.operation_id, result);
}

fn launch(state: *State, request: wire.RequestEnvelope) ![]u8 {
    var args = try parseArgs(wire.NameArguments, request);
    defer args.deinit();
    const name = try allocator.dupeZ(u8, args.value.name_or_id);
    defer allocator.free(name);
    var manager = managerFor(state);
    defer manager.deinit();
    return successResponse(
        request.operation_id,
        wire.BoolResult{ .value = try manager.launch_flatpak(name) },
    );
}

fn kill(state: *State, request: wire.RequestEnvelope) ![]u8 {
    var args = try parseArgs(wire.NameArguments, request);
    defer args.deinit();
    const name = try allocator.dupeZ(u8, args.value.name_or_id);
    defer allocator.free(name);
    var manager = managerFor(state);
    defer manager.deinit();
    return successResponse(
        request.operation_id,
        wire.BoolResult{ .value = try manager.kill_flatpak(name) },
    );
}

fn listRemotes(state: *State, request: wire.RequestEnvelope) ![]u8 {
    var args = try parseArgs(wire.EmptyArguments, request);
    defer args.deinit();
    var manager = remoteManagerFor(state);
    const values = try manager.listRemotesWithDetails();
    defer native_remotes.RemoteManager.deinitRemotes(allocator, values);
    const result = try allocator.alloc(wire.Remote, values.len);
    defer allocator.free(result);
    for (values, result) |value, *output|
        output.* = remoteToWire(value);
    return successResponse(request.operation_id, result);
}

fn addRemote(state: *State, request: wire.RequestEnvelope) ![]u8 {
    var args = try parseArgs(wire.AddRemoteArguments, request);
    defer args.deinit();
    const name = try allocator.dupeZ(u8, args.value.name);
    defer allocator.free(name);
    const url = try allocator.dupeZ(u8, args.value.url);
    defer allocator.free(url);
    var manager = remoteManagerFor(state);
    return successResponse(
        request.operation_id,
        wire.BoolResult{
            .value = try manager.addRemoteConfig(
                name,
                url,
                scopeFromWire(args.value.scope),
                args.value.gpg_verify,
                args.value.gpg_key,
            ),
        },
    );
}

fn removeRemote(state: *State, request: wire.RequestEnvelope) ![]u8 {
    var args = try parseArgs(wire.RemoteMutationArguments, request);
    defer args.deinit();
    const name = try allocator.dupeZ(u8, args.value.name);
    defer allocator.free(name);
    var manager = remoteManagerFor(state);
    return successResponse(
        request.operation_id,
        wire.BoolResult{
            .value = try manager.removeRemote(
                name,
                scopeFromWire(args.value.scope),
            ),
        },
    );
}

fn highestPriorityRemote(
    state: *State,
    request: wire.RequestEnvelope,
) ![]u8 {
    var args = try parseArgs(wire.EmptyArguments, request);
    defer args.deinit();
    var manager = remoteManagerFor(state);
    const values = try manager.listRemotesWithDetails();
    defer native_remotes.RemoteManager.deinitRemotes(allocator, values);
    var best: ?wire.Remote = null;
    for (values) |value| {
        const candidate = remoteToWire(value);
        if (best == null or candidate.priority > best.?.priority)
            best = candidate;
    }
    return successResponse(request.operation_id, best);
}

fn listRemoteRefs(state: *State, request: wire.RequestEnvelope) ![]u8 {
    var args = try parseArgs(wire.RemoteNameArguments, request);
    defer args.deinit();
    const remote = try allocator.dupeZ(u8, args.value.remote);
    defer allocator.free(remote);
    var manager = managerFor(state);
    defer manager.deinit();
    const values = try manager.get_flatpaks_from_remote(remote);
    defer {
        for (values) |value| raw.g_object_unref(value.ptr);
        allocator.free(values);
    }
    return refsResponse(request.operation_id, values);
}

fn updateAllAppstreams(
    state: *State,
    request: wire.RequestEnvelope,
) ![]u8 {
    var args = try parseArgs(wire.EmptyArguments, request);
    defer args.deinit();
    var manager = catalogManagerFor(state);
    try manager.updateAll();
    return successResponse(request.operation_id, wire.EmptyArguments{});
}

fn updateRemoteAppstream(
    state: *State,
    request: wire.RequestEnvelope,
) ![]u8 {
    var args = try parseArgs(wire.UpdateAppstreamArguments, request);
    defer args.deinit();
    var manager = catalogManagerFor(state);
    try manager.updateRemote(
        scopeFromWire(args.value.scope),
        args.value.remote,
    );
    return successResponse(request.operation_id, wire.EmptyArguments{});
}

fn getRemoteCatalog(
    state: *State,
    request: wire.RequestEnvelope,
) ![]u8 {
    var args = try parseArgs(wire.CatalogArguments, request);
    defer args.deinit();
    var manager = catalogManagerFor(state);
    const location = try manager.getRemote(
        args.value.remote,
        args.value.arch,
    );
    defer native_catalogs.Manager.deinitLocation(allocator, location);
    return successResponse(request.operation_id, location);
}

fn getAllRemoteCatalogs(
    state: *State,
    request: wire.RequestEnvelope,
) ![]u8 {
    var args = try parseArgs(wire.CatalogsArguments, request);
    defer args.deinit();
    var manager = catalogManagerFor(state);
    const locations = try manager.getAll(args.value.arch);
    defer native_catalogs.Manager.deinitLocations(allocator, locations);
    return successResponse(request.operation_id, locations);
}

fn loadCatalog(state: *State, request: wire.RequestEnvelope) ![]u8 {
    var args = try parseArgs(wire.LoadCatalogArguments, request);
    defer args.deinit();
    _ = std.Io.Dir.cwd().statFile(
        state.threaded.io(),
        args.value.path,
        .{},
    ) catch return error.CatalogNotFound;
    const location: wire.CatalogLocation = .{
        .remote = args.value.remote,
        .scope = args.value.scope,
        .arch = args.value.arch,
        .path = args.value.path,
    };
    return successResponse(request.operation_id, location);
}

fn managerFor(state: *State) native_manager.Manager {
    var manager: native_manager.Manager = .{
        .allocator = allocator,
        .io = state.threaded.io(),
    };
    manager.setOperationContext(&state.operations) catch {};
    return manager;
}

fn remoteManagerFor(state: *State) native_remotes.RemoteManager {
    var manager: native_remotes.RemoteManager = .{
        .allocator = allocator,
        .io = state.threaded.io(),
    };
    manager.setOperationContext(&state.operations);
    return manager;
}

fn catalogManagerFor(state: *State) native_catalogs.Manager {
    var manager: native_catalogs.Manager = .{
        .allocator = allocator,
        .io = state.threaded.io(),
    };
    manager.setOperationContext(&state.operations);
    return manager;
}

fn parseArgs(
    comptime T: type,
    request: wire.RequestEnvelope,
) !std.json.Parsed(T) {
    return protocol.parseArguments(T, allocator, request.arguments);
}

fn refsResponse(
    operation_id: u64,
    values: []const native.Flatpak,
) ![]u8 {
    const result = try allocator.alloc(wire.Ref, values.len);
    defer allocator.free(result);
    var initialized: usize = 0;
    defer for (result[0..initialized]) |value|
        allocator.free(value.reference);
    for (values, result) |value, *output| {
        const reference = try native.refToString(allocator, value.ptr);
        output.* = .{
            .id = value.id() orelse "",
            .arch = value.arch() orelse "",
            .branch = value.branch() orelse "",
            .reference = reference,
            .kind = kindFromNative(value.kind()),
            .scope = scopeToWire(value.get_scope()),
        };
        initialized += 1;
    }
    return successResponse(operation_id, result);
}

fn permissionView(
    values: []const [:0]const u8,
) ![][]const u8 {
    const result = try allocator.alloc([]const u8, values.len);
    for (values, result) |value, *output| output.* = value;
    return result;
}

fn remoteToWire(value: native.Remote) wire.Remote {
    return .{
        .name = value.name() orelse "",
        .url = value.url() orelse "",
        .priority = value.priority(),
        .scope = scopeToWire(value.get_scope()),
        .gpg_verify = value.gpg_verify(),
        .nodeps = value.nodeps(),
        .noenumerate = value.noenumerate(),
        .remote_type = @intCast(value.remote_type()),
        .disabled = value.disabled(),
    };
}

fn scopeFromWire(scope: wire.Scope) native.Scope {
    return switch (scope) {
        .system => .SYSTEM,
        .user => .USER,
        .unknown => .UNKNOWN,
    };
}

fn scopeToWire(scope: native.Scope) wire.Scope {
    return switch (scope) {
        .SYSTEM => .system,
        .USER => .user,
        .UNKNOWN => .unknown,
    };
}

fn kindFromNative(value: i32) wire.RefKind {
    if (value == raw.FLATPAK_REF_KIND_APP) return .app;
    if (value == raw.FLATPAK_REF_KIND_RUNTIME) return .runtime;
    return .unknown;
}

fn successResponse(operation_id: u64, result: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(
        allocator,
        .{
            .schema = wire.schema_version,
            .operation_id = operation_id,
            .result = result,
        },
        .{},
    );
}

fn failureResponse(
    operation_id: u64,
    code: []const u8,
    message: []const u8,
    native_code: ?i64,
) ![]u8 {
    return std.json.Stringify.valueAlloc(
        allocator,
        .{
            .schema = wire.schema_version,
            .operation_id = operation_id,
            .@"error" = wire.ErrorPayload{
                .code = code,
                .message = message,
                .native_code = native_code,
            },
        },
        .{},
    );
}

fn errorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.Cancelled => "flatpak.cancelled",
        error.RemoteNotFound => "flatpak.remote_not_found",
        error.CatalogNotFound => "flatpak.catalog_not_found",
        error.FlatpakNotFound => "flatpak.not_found",
        error.UnknownMethod => "protocol.unknown_method",
        error.UnsupportedSchema => "protocol.unsupported_schema",
        error.InvalidMessageSize => "protocol.message_too_large",
        error.OutOfMemory => "backend.out_of_memory",
        else => "flatpak.operation_failed",
    };
}

fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.Cancelled => "The Flatpak operation was cancelled.",
        error.RemoteNotFound => "The requested Flatpak remote was not found.",
        error.CatalogNotFound => "The requested AppStream catalog was not found.",
        error.FlatpakNotFound => "The requested Flatpak application was not found.",
        error.UnknownMethod => "The Flatpak backend does not support the requested operation.",
        error.UnsupportedSchema => "The Flatpak request uses an unsupported wire schema.",
        error.InvalidMessageSize => "The Flatpak request exceeds the protocol size limit.",
        error.OutOfMemory => "The Flatpak backend ran out of memory.",
        else => @errorName(err),
    };
}

fn forwardOperationEvent(
    data: ?*anyopaque,
    event: operation_api.Event,
) void {
    const state: *State = @ptrCast(@alignCast(data orelse return));
    const operation_id = state.current_operation_id.load(.acquire);
    if (operation_id == 0) return;
    const output: wire.EventEnvelope = switch (event) {
        .started => .{
            .schema = wire.schema_version,
            .operation_id = operation_id,
            .kind = .started,
            .code = "flatpak.started",
            .message = "Flatpak operation started",
        },
        .status => |value| .{
            .schema = wire.schema_version,
            .operation_id = operation_id,
            .kind = .status,
            .code = value.code orelse "flatpak.status",
            .message = value.message,
            .level = switch (value.level) {
                .debug, .information => .information,
                .warning => .warning,
                .success => .success,
            },
            .native_code = value.native_code,
        },
        .progress => |value| .{
            .schema = wire.schema_version,
            .operation_id = operation_id,
            .kind = .progress,
            .code = "flatpak.progress",
            .message = value.update.message orelse
                value.update.stage orelse "Flatpak operation in progress",
            .percentage = value.update.percentage,
            .completed = value.update.completed orelse
                value.update.bytes_completed,
            .total = value.update.total orelse value.update.bytes_total,
            .native_code = value.update.native_code,
        },
        .failure => |value| .{
            .schema = wire.schema_version,
            .operation_id = operation_id,
            .kind = .failure,
            .code = errorCode(value.err),
            .message = value.message,
            .level = .err,
            .native_code = value.native_code,
        },
        .completed => |value| .{
            .schema = wire.schema_version,
            .operation_id = operation_id,
            .kind = .completed,
            .code = switch (value.status) {
                .success => "flatpak.completed",
                .failed => "flatpak.failed",
                .cancelled => "flatpak.cancelled",
            },
            .message = switch (value.status) {
                .success => "Flatpak operation completed",
                .failed => "Flatpak operation failed",
                .cancelled => "Flatpak operation cancelled",
            },
            .level = switch (value.status) {
                .success => .success,
                .failed, .cancelled => .err,
            },
        },
    };
    const encoded = std.json.Stringify.valueAlloc(
        allocator,
        output,
        .{},
    ) catch return;
    defer allocator.free(encoded);
    const callback = state.host.emit_event orelse return;
    callback(
        state.host.user_data,
        .{ .ptr = encoded.ptr, .len = encoded.len },
    );
}
