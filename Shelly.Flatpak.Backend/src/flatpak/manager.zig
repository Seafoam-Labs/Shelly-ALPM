const bindings = @import("bindings.zig");
const std = @import("std");
const remotes = @import("remote_manager.zig");
const events = @import("events.zig");
const operation_api = @import("operation_context");

const flatpak = bindings.libflatpak;
const rawflatpak = bindings.libflatpak.flatpak;

/// Fully owned installed application metadata returned by name/ID resolution.
pub const InstalledApplication = struct {
    id: [:0]u8,
    name: [:0]u8,
    arch: [:0]u8,
    branch: [:0]u8,
    summary: [:0]u8,
    version: [:0]u8,
    latest_commit: [:0]u8,
    origin: [:0]u8,
    kind: i32,
    installed_size: u64,
    scope: flatpak.Scope,
    eol: ?[:0]u8 = null,
    eol_rebase: ?[:0]u8 = null,

    pub fn deinit(self: *InstalledApplication, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.arch);
        allocator.free(self.branch);
        allocator.free(self.summary);
        allocator.free(self.version);
        allocator.free(self.latest_commit);
        allocator.free(self.origin);
        if (self.eol) |value| allocator.free(value);
        if (self.eol_rebase) |value| allocator.free(value);
        self.* = undefined;
    }

    pub fn deinitSlice(allocator: std.mem.Allocator, applications: []InstalledApplication) void {
        for (applications) |*application| application.deinit(allocator);
        allocator.free(applications);
    }
};

/// Fully owned metadata for one currently running Flatpak instance.
pub const RunningInstance = struct {
    instance_id: [:0]u8,
    application_id: [:0]u8,
    arch: [:0]u8,
    branch: [:0]u8,
    pid: i32,
    child_pid: i32,

    pub fn deinit(self: *RunningInstance, allocator: std.mem.Allocator) void {
        allocator.free(self.instance_id);
        allocator.free(self.application_id);
        allocator.free(self.arch);
        allocator.free(self.branch);
        self.* = undefined;
    }

    pub fn deinitSlice(allocator: std.mem.Allocator, instances: []RunningInstance) void {
        for (instances) |*instance| instance.deinit(allocator);
        allocator.free(instances);
    }
};

/// Fully owned unused Flatpak ref returned by cleanup planning.
pub const UnusedDependency = struct {
    reference: [:0]u8,
    scope: flatpak.Scope,

    pub fn deinit(self: *UnusedDependency, allocator: std.mem.Allocator) void {
        allocator.free(self.reference);
        self.* = undefined;
    }

    pub fn deinitSlice(allocator: std.mem.Allocator, dependencies: []UnusedDependency) void {
        for (dependencies) |*dependency| dependency.deinit(allocator);
        allocator.free(dependencies);
    }
};

pub const EolStatus = struct {
    reference: [:0]u8,
    id: [:0]u8,
    branch: [:0]u8,
    origin: [:0]u8,
    scope: flatpak.Scope,
    eol: ?[:0]u8 = null,
    eol_rebase: ?[:0]u8 = null,

    pub fn deinit(self: *EolStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.reference);
        allocator.free(self.id);
        allocator.free(self.branch);
        allocator.free(self.origin);
        if (self.eol) |value| allocator.free(value);
        if (self.eol_rebase) |value| allocator.free(value);
        self.* = undefined;
    }

    pub fn deinitSlice(allocator: std.mem.Allocator, statuses: []EolStatus) void {
        for (statuses) |*status| status.deinit(allocator);
        allocator.free(statuses);
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dispatcher: ?*events.Dispatcher = null,
    cancellation: ?events.Cancellation = null,
    operation_context: ?*operation_api.OperationContext = null,
    owned_dispatcher: ?*events.Dispatcher = null,

    pub fn setEventDispatcher(self: *Manager, dispatcher: ?*events.Dispatcher) void {
        self.dispatcher = dispatcher orelse self.owned_dispatcher;
    }

    pub fn setCancellation(self: *Manager, cancellation: ?events.Cancellation) void {
        self.cancellation = cancellation;
    }

    /// Borrows the shared operation context. If no legacy dispatcher is
    /// installed, a private compatibility dispatcher is created so existing
    /// status/progress emission automatically reaches the shared context. The
    /// context must outlive this manager and all synchronous calls.
    pub fn setOperationContext(self: *Manager, context: ?*operation_api.OperationContext) !void {
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

    pub fn install_flatpak(self: Manager, flatpak_id: [:0]const u8, remote_name: [:0]const u8, scope: flatpak.Scope, branch: [:0]const u8, runtime: bool) !bool {
        var operation_scope = OperationScope.init(self, .install, flatpak_id);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);
        var cancellation_bridge = try CancellationBridge.init(self, cancellable);
        defer cancellation_bridge.deinit();

        const installation = if (scope == flatpak.Scope.SYSTEM)
            rawflatpak.flatpak_installation_new_system(cancellable, &g_error)
        else
            rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        if (installation == null or g_error != null) {
            self.emitGError(g_error, "Failed to open the Flatpak installation");
            return error.InstallationCreateFailed;
        }
        defer rawflatpak.g_object_unref(installation);

        const trans_ptr = rawflatpak.flatpak_transaction_new_for_installation(installation, cancellable, &g_error);
        if (trans_ptr == null or g_error != null) {
            self.emitGError(g_error, "Failed to create the Flatpak transaction");
            return error.TransactionCreateFailed;
        }
        defer rawflatpak.g_object_unref(trans_ptr);

        if (rawflatpak.flatpak_installation_update_remote_sync(installation, remote_name, cancellable, &g_error) == 0) {
            self.emitGError(g_error, "Failed to update the Flatpak remote");
            return error.RemoteUpdateFailed;
        }

        const resolved_branch: [:0]u8 = blk: {
            if (branch.len > 0) break :blk try self.allocator.dupeZ(u8, branch);
            const kind: c_int = if (runtime) rawflatpak.FLATPAK_REF_KIND_RUNTIME else rawflatpak.FLATPAK_REF_KIND_APP;
            break :blk (try self.resolve_remote_branch(installation, remote_name, flatpak_id, kind, cancellable)) orelse {
                self.emitGError(g_error, "Failed to resolve the Flatpak branch from the remote");
                return error.AddInstallFailed;
            };
        };
        defer self.allocator.free(resolved_branch);

        const arch = std.mem.span(rawflatpak.flatpak_get_default_arch());
        const ref_str = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/{s}/{s}",
            .{ if (runtime) "runtime" else "app", flatpak_id, arch, resolved_branch },
        );
        defer self.allocator.free(ref_str);

        const ref_string = try self.allocator.dupeSentinel(u8, ref_str, 0);
        defer self.allocator.free(ref_string);

        if (rawflatpak.flatpak_transaction_add_install(trans_ptr, remote_name, ref_string, null, &g_error) == 0) {
            self.emitGError(g_error, "Failed to add the Flatpak installation operation");
            return error.AddInstallFailed;
        }

        var callback_context = self.transactionCallbackContext(cancellable);
        connectTransactionCallbacks(trans_ptr, &callback_context);

        const result = rawflatpak.flatpak_transaction_run(trans_ptr, cancellable, &g_error);
        return self.finishTransaction(result, g_error, "Flatpak installation completed");
    }

    pub fn list_installed_flatpak(self: Manager) ![]flatpak.Flatpak {
        var operation_scope = OperationScope.init(self, .search, null);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        var list: std.ArrayList(flatpak.Flatpak) = .empty;
        errdefer list.deinit(self.allocator);

        var installation = rawflatpak.flatpak_installation_new_system(cancellable, &g_error);

        var installed_refs_ptr = rawflatpak.flatpak_installation_list_installed_refs(installation, cancellable, &g_error);
        var j: usize = 0;
        while (j < installed_refs_ptr.*.len) : (j += 1) {
            const raw: *rawflatpak.FlatpakRef = @ptrCast(@alignCast(installed_refs_ptr.*.pdata[j]));
            try list.append(self.allocator, flatpak.Flatpak.new(raw, flatpak.Scope.SYSTEM));
        }

        installation = rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        installed_refs_ptr = rawflatpak.flatpak_installation_list_installed_refs(installation, cancellable, &g_error);
        j = 0;
        while (j < installed_refs_ptr.*.len) : (j += 1) {
            const raw: *rawflatpak.FlatpakRef = @ptrCast(@alignCast(installed_refs_ptr.*.pdata[j]));
            try list.append(self.allocator, flatpak.Flatpak.new(raw, flatpak.Scope.USER));
        }

        return list.toOwnedSlice(self.allocator);
    }

    /// Return owned metadata for every installed system and user Flatpak.
    /// Unlike `list_installed_flatpak`, the returned values do not borrow
    /// `FlatpakInstalledRef` objects and remain valid after the native arrays
    /// and installations have been released.
    pub fn list_installed_applications(self: Manager) ![]InstalledApplication {
        var operation_scope = OperationScope.init(self, .search, null);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();

        var applications: std.ArrayList(InstalledApplication) = .empty;
        errdefer {
            for (applications.items) |*application| application.deinit(self.allocator);
            applications.deinit(self.allocator);
        }

        try self.appendSystemInstalledApplications(&applications);
        try self.appendUserInstalledApplications(&applications);
        return applications.toOwnedSlice(self.allocator);
    }

    /// Resolve a system or user installation by exact/partial ID or friendly
    /// application name, following the original manager's system-first order.
    pub fn find_installed_flatpak(self: Manager, name_or_id: []const u8) !?InstalledApplication {
        var operation_scope = OperationScope.init(self, .search, name_or_id);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        if (try self.findInSystemInstallations(name_or_id)) |application| return application;
        return self.findInUserInstallation(name_or_id);
    }

    /// Update an installed application without requiring callers to know its
    /// canonical ID or installation scope.
    pub fn update_installed_flatpak(
        self: Manager,
        name_or_id: []const u8,
        commit: ?[]const u8,
    ) !bool {
        var operation_scope = OperationScope.init(self, .update, name_or_id);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        var application = (try self.find_installed_flatpak(name_or_id)) orelse return error.FlatpakNotFound;
        defer application.deinit(self.allocator);
        const commit_z: ?[:0]u8 = if (commit) |value| try self.allocator.dupeSentinel(u8, value, 0) else null;
        defer if (commit_z) |value| self.allocator.free(value);
        return self.update_flatpak(application.id, application.scope, commit_z);
    }

    /// Uninstall an installed application without requiring callers to know
    /// its canonical ID or installation scope.
    pub fn uninstall_installed_flatpak(
        self: Manager,
        name_or_id: []const u8,
        remove_unused: bool,
    ) !bool {
        var operation_scope = OperationScope.init(self, .remove, name_or_id);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        var application = (try self.find_installed_flatpak(name_or_id)) orelse return error.FlatpakNotFound;
        defer application.deinit(self.allocator);
        return self.uninstall_flatpak(application.id, application.scope, remove_unused);
    }

    /// Reinstall an installed Flatpak while preserving its application data.
    /// The original ID, origin, branch, scope, and app/runtime kind are
    /// retained. Unused refs are deliberately not removed; the subsequent
    /// install transaction resolves and restores every required dependency.
    pub fn repair_installed_flatpak(self: Manager, name_or_id: []const u8) !bool {
        var application = (try self.find_installed_flatpak(name_or_id)) orelse
            return error.FlatpakNotFound;
        defer application.deinit(self.allocator);
        if (application.origin.len == 0) return error.FlatpakOriginMissing;
        if (application.scope == .UNKNOWN) return error.FlatpakScopeUnknown;

        if (!try self.uninstall_flatpak(application.id, application.scope, false))
            return false;
        return self.install_flatpak(
            application.id,
            application.origin,
            application.scope,
            application.branch,
            application.kind != rawflatpak.FLATPAK_REF_KIND_APP,
        );
    }

    pub fn upgrade_flatpaks(self: Manager) !bool {
        var operation_scope = OperationScope.init(self, .update, null);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);
        var cancellation_bridge = try CancellationBridge.init(self, cancellable);
        defer cancellation_bridge.deinit();

        const installation_system = rawflatpak.flatpak_installation_new_system(cancellable, &g_error);
        if (installation_system == null or g_error != null) {
            self.emitGError(g_error, "Failed to open the system Flatpak installation");
            return error.InstallationCreateFailed;
        }
        defer rawflatpak.g_object_unref(installation_system);
        self.emitStatus(.information, "Checking system Flatpak installation for updates");
        const sys_result = try upgrade_installation(self, installation_system, .SYSTEM);

        const installation_user = rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        if (installation_user == null or g_error != null) {
            self.emitGError(g_error, "Failed to open the user Flatpak installation");
            return error.InstallationCreateFailed;
        }
        defer rawflatpak.g_object_unref(installation_user);
        self.emitStatus(.information, "Checking user Flatpak installation for updates");
        const user_result = try upgrade_installation(self, installation_user, .USER);

        return sys_result and user_result;
    }

    pub fn uninstall_flatpak(self: Manager, flatpak_id: [:0]const u8, scope: flatpak.Scope, remove_unused: bool) !bool {
        var operation_scope = OperationScope.init(self, .remove, flatpak_id);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);
        var cancellation_bridge = try CancellationBridge.init(self, cancellable);
        defer cancellation_bridge.deinit();

        const installation = if (scope == flatpak.Scope.SYSTEM)
            rawflatpak.flatpak_installation_new_system(cancellable, &g_error)
        else
            rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        if (installation == null or g_error != null) {
            self.emitGError(g_error, "Failed to open the Flatpak installation");
            return error.InstallationCreateFailed;
        }
        defer rawflatpak.g_object_unref(installation);

        const flatpak_struct = try get_ref_id_and_installation(self, flatpak_id, installation);
        defer rawflatpak.g_object_unref(flatpak_struct.ptr);

        const ref_string = try flatpak.refToString(self.allocator, flatpak_struct.ptr);
        defer self.allocator.free(ref_string);

        const trans_ptr = rawflatpak.flatpak_transaction_new_for_installation(installation, cancellable, &g_error);
        if (trans_ptr == null or g_error != null) {
            self.emitGError(g_error, "Failed to create the Flatpak transaction");
            return error.TransactionCreateFailed;
        }
        defer rawflatpak.g_object_unref(trans_ptr);

        if (rawflatpak.flatpak_transaction_add_uninstall(trans_ptr, ref_string, &g_error) == 0) {
            self.emitGError(g_error, "Failed to add the Flatpak removal operation");
            return error.AddUninstallFailed;
        }

        var callback_context = self.transactionCallbackContext(cancellable);
        connectTransactionCallbacks(trans_ptr, &callback_context);

        const result = rawflatpak.flatpak_transaction_run(trans_ptr, cancellable, &g_error);
        const succeeded = try self.finishTransaction(result, g_error, "Flatpak removal completed");

        if (succeeded and remove_unused) {
            _ = try removed_unused(self, installation);
        }

        return succeeded;
    }

    pub fn update_flatpak(self: Manager, flatpak_id: [:0]const u8, scope: flatpak.Scope, commit: ?[:0]const u8) !bool {
        var operation_scope = OperationScope.init(self, .update, flatpak_id);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);
        var cancellation_bridge = try CancellationBridge.init(self, cancellable);
        defer cancellation_bridge.deinit();

        const installation = if (scope == flatpak.Scope.SYSTEM)
            rawflatpak.flatpak_installation_new_system(cancellable, &g_error)
        else
            rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        if (installation == null or g_error != null) {
            self.emitGError(g_error, "Failed to open the Flatpak installation");
            return error.InstallationCreateFailed;
        }
        defer rawflatpak.g_object_unref(installation);

        const flatpak_struct = try get_ref_id_and_installation(self, flatpak_id, installation);
        defer rawflatpak.g_object_unref(flatpak_struct.ptr);
        const ref_string = try flatpak.refToString(self.allocator, flatpak_struct.ptr);
        defer self.allocator.free(ref_string);

        const commit_c_safe: ?[:0]u8 = if (commit) |c|
            try self.allocator.dupeSentinel(u8, c, 0)
        else
            null;
        defer if (commit_c_safe) |c| self.allocator.free(c);

        const commit_ptr: [*c]const u8 = if (commit_c_safe) |c| c.ptr else null;

        const trans_ptr = rawflatpak.flatpak_transaction_new_for_installation(installation, cancellable, &g_error);
        if (trans_ptr == null or g_error != null) {
            self.emitGError(g_error, "Failed to create the Flatpak transaction");
            return error.TransactionCreateFailed;
        }
        defer rawflatpak.g_object_unref(trans_ptr);

        if (rawflatpak.flatpak_transaction_add_update(trans_ptr, ref_string, null, commit_ptr, &g_error) == 0) {
            self.emitGError(g_error, "Failed to add the Flatpak update operation");
            return error.AddUpdateFailed;
        }
        var callback_context = self.transactionCallbackContext(cancellable);
        connectTransactionCallbacks(trans_ptr, &callback_context);

        const result = rawflatpak.flatpak_transaction_run(trans_ptr, cancellable, &g_error);
        return self.finishTransaction(result, g_error, "Flatpak update completed");
    }

    pub fn rebase_flatpak(
        self: Manager,
        old_ref: [:0]const u8,
        new_ref: [:0]const u8,
        remote_name: [:0]const u8,
        scope: flatpak.Scope,
        previous_ids: []const [:0]const u8,
    ) !bool {
        if (previous_ids.len == 0) {
            self.emitStatus(.err, "Cannot rebase without at least one previous application ID");
            return error.InvalidRef;
        }

        var operation_scope = OperationScope.init(self, .update, old_ref);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);
        var cancellation_bridge = try CancellationBridge.init(self, cancellable);
        defer cancellation_bridge.deinit();

        const installation = if (scope == flatpak.Scope.SYSTEM)
            rawflatpak.flatpak_installation_new_system(cancellable, &g_error)
        else
            rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        if (installation == null or g_error != null) {
            self.emitGError(g_error, "Failed to open the Flatpak installation");
            return error.InstallationCreateFailed;
        }
        defer rawflatpak.g_object_unref(installation);

        const trans_ptr = rawflatpak.flatpak_transaction_new_for_installation(installation, cancellable, &g_error);
        if (trans_ptr == null or g_error != null) {
            self.emitGError(g_error, "Failed to create the Flatpak transaction");
            return error.TransactionCreateFailed;
        }
        defer rawflatpak.g_object_unref(trans_ptr);

        const previous_ids_c = try self.allocator.allocSentinel([*c]const u8, previous_ids.len, null);
        defer self.allocator.free(previous_ids_c);
        for (previous_ids, previous_ids_c) |id, *out| out.* = id.ptr;

        if (rawflatpak.flatpak_transaction_add_rebase_and_uninstall(
            trans_ptr,
            remote_name,
            new_ref,
            old_ref,
            null,
            previous_ids_c.ptr,
            &g_error,
        ) == 0) {
            self.emitGError(g_error, "Failed to add the Flatpak rebase operation");
            return error.AddRebaseFailed;
        }

        var callback_context = self.transactionCallbackContext(cancellable);
        connectTransactionCallbacks(trans_ptr, &callback_context);

        const result = rawflatpak.flatpak_transaction_run(trans_ptr, cancellable, &g_error);
        return self.finishTransaction(
            result,
            g_error,
            "Flatpak rebase completed; app data migrated to the new ID",
        );
    }

    pub fn list_eol_flatpak(self: Manager) ![]EolStatus {
        var operation_scope = OperationScope.init(self, .search, null);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();

        var statuses: std.ArrayList(EolStatus) = .empty;
        errdefer EolStatus.deinitSlice(self.allocator, statuses.items);

        try self.appendEolStatuses(&statuses, .SYSTEM);
        try self.appendEolStatuses(&statuses, .USER);
        return statuses.toOwnedSlice(self.allocator);
    }

    fn appendEolStatuses(
        self: Manager,
        statuses: *std.ArrayList(EolStatus),
        scope: flatpak.Scope,
    ) !void {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        const installation = if (scope == flatpak.Scope.SYSTEM)
            rawflatpak.flatpak_installation_new_system(cancellable, &g_error)
        else
            rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        if (installation == null or g_error != null) {
            return;
        }
        defer rawflatpak.g_object_unref(installation);

        const installed_refs_ptr = rawflatpak.flatpak_installation_list_installed_refs(installation, cancellable, &g_error);
        if (installed_refs_ptr == null or g_error != null) return;
        defer rawflatpak.g_ptr_array_unref(installed_refs_ptr);

        var j: usize = 0;
        while (j < installed_refs_ptr.*.len) : (j += 1) {
            const raw: *rawflatpak.FlatpakRef = @ptrCast(@alignCast(installed_refs_ptr.*.pdata[j]));
            try self.appendEolStatusForRef(statuses, installation, raw, scope);
        }
    }

    fn appendEolStatusForRef(
        self: Manager,
        statuses: *std.ArrayList(EolStatus),
        installation: [*c]rawflatpak.FlatpakInstallation,
        ref: *rawflatpak.FlatpakRef,
        scope: flatpak.Scope,
    ) !void {
        const installed: *rawflatpak.FlatpakInstalledRef = @ptrCast(ref);
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        const id = spanOrEmpty(rawflatpak.flatpak_ref_get_name(ref));
        const branch = spanOrEmpty(rawflatpak.flatpak_ref_get_branch(ref));
        const origin = spanOrEmpty(rawflatpak.flatpak_installed_ref_get_origin(installed));

        const ref_arch_ptr = rawflatpak.flatpak_ref_get_arch(ref);
        const arch: [:0]const u8 = if (ref_arch_ptr != null)
            std.mem.span(ref_arch_ptr)
        else
            std.mem.span(rawflatpak.flatpak_get_default_arch());

        var remote_eol: ?[]const u8 = null;
        var remote_rebase: ?[]const u8 = null;
        defer if (remote_eol) |value| self.allocator.free(value);
        defer if (remote_rebase) |value| self.allocator.free(value);
        if (origin.len > 0) {
            const id_z = try self.allocator.dupeZ(u8, id);
            defer self.allocator.free(id_z);
            const branch_z = try self.allocator.dupeZ(u8, branch);
            defer self.allocator.free(branch_z);
            const origin_z = try self.allocator.dupeZ(u8, origin);
            defer self.allocator.free(origin_z);
            const remote_ref_ptr = rawflatpak.flatpak_installation_fetch_remote_ref_sync(
                installation,
                origin_z.ptr,
                0,
                id_z.ptr,
                arch,
                branch_z.ptr,
                cancellable,
                &g_error,
            );
            if (remote_ref_ptr) |ptr| {
                defer rawflatpak.g_object_unref(ptr);
                remote_eol = if (flatpak.str(rawflatpak.flatpak_remote_ref_get_eol(ptr))) |value|
                    try self.allocator.dupe(u8, value)
                else
                    null;
                remote_rebase = if (flatpak.str(rawflatpak.flatpak_remote_ref_get_eol_rebase(ptr))) |value|
                    try self.allocator.dupe(u8, value)
                else
                    null;
            } else {
                if (g_error) |e| rawflatpak.g_error_free(e);
                g_error = null;
            }
        }

        const installed_eol = flatpak.str(rawflatpak.flatpak_installed_ref_get_eol(installed));
        const installed_rebase = flatpak.str(rawflatpak.flatpak_installed_ref_get_eol_rebase(installed));

        const eol = remote_eol orelse installed_eol;
        const eol_rebase = remote_rebase orelse installed_rebase;
        if (eol == null and eol_rebase == null) return;

        const reference = try flatpak.refToString(self.allocator, ref);
        errdefer self.allocator.free(reference);
        const id_owned = try self.allocator.dupeSentinel(u8, id, 0);
        errdefer self.allocator.free(id_owned);
        const branch_owned = try self.allocator.dupeSentinel(u8, branch, 0);
        errdefer self.allocator.free(branch_owned);
        const origin_owned = try self.allocator.dupeSentinel(u8, origin, 0);
        errdefer self.allocator.free(origin_owned);
        const eol_owned = if (eol) |value| try self.allocator.dupeSentinel(u8, value, 0) else null;
        errdefer if (eol_owned) |value| self.allocator.free(value);
        const eol_rebase_owned = if (eol_rebase) |value| try self.allocator.dupeSentinel(u8, value, 0) else null;
        errdefer if (eol_rebase_owned) |value| self.allocator.free(value);

        try statuses.append(self.allocator, .{
            .reference = reference,
            .id = id_owned,
            .branch = branch_owned,
            .origin = origin_owned,
            .scope = scope,
            .eol = eol_owned,
            .eol_rebase = eol_rebase_owned,
        });
    }

    pub fn launch_flatpak(self: Manager, flatpak_id: [:0]const u8) !bool {
        var operation_scope = OperationScope.init(self, .launch, flatpak_id);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        var application = (try self.find_installed_flatpak(flatpak_id)) orelse return false;
        defer application.deinit(self.allocator);

        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);
        var cancellation_bridge = try CancellationBridge.init(self, cancellable);
        defer cancellation_bridge.deinit();

        const installation = if (application.scope == .SYSTEM)
            rawflatpak.flatpak_installation_new_system(cancellable, &g_error)
        else
            rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        if (installation == null or g_error != null) {
            self.emitGError(g_error, "Failed to open the Flatpak installation");
            return false;
        }
        defer rawflatpak.g_object_unref(installation);

        const result = rawflatpak.flatpak_installation_launch(
            installation,
            application.id,
            application.arch,
            application.branch,
            null,
            cancellable,
            &g_error,
        );
        if (result != 0) {
            self.emitStatus(.success, "Flatpak application launched");
        } else {
            self.emitGError(g_error, "Failed to launch the Flatpak application");
        }
        return result != 0;
    }

    pub fn install_from_ref_flatpak(self: Manager, flatpak_location: [:0]const u8, scope: flatpak.Scope) !bool {
        var operation_scope = OperationScope.init(self, .install, flatpak_location);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);
        var cancellation_bridge = try CancellationBridge.init(self, cancellable);
        defer cancellation_bridge.deinit();

        var installation: ?*rawflatpak.FlatpakInstallation = null;
        if (scope == flatpak.Scope.SYSTEM) {
            installation = rawflatpak.flatpak_installation_new_system(cancellable, &g_error);
        } else {
            installation = rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        }
        if (installation == null) {
            self.emitGError(g_error, "Failed to open the Flatpak installation");
            return error.InstallationCreateFailed;
        }
        defer rawflatpak.g_object_unref(installation);

        const ref_data = try self.readRefBytes(flatpak_location);
        defer self.allocator.free(ref_data);

        const g_bytes_ptr = rawflatpak.g_bytes_new(ref_data.ptr, ref_data.len);
        defer rawflatpak.g_bytes_unref(g_bytes_ptr);

        const trans_ptr = rawflatpak.flatpak_transaction_new_for_installation(installation, cancellable, &g_error);
        if (trans_ptr == null) {
            self.emitGError(g_error, "Failed to create the Flatpak transaction");
            return error.TransactionCreateFailed;
        }
        defer rawflatpak.g_object_unref(trans_ptr);

        const added = rawflatpak.flatpak_transaction_add_install_flatpakref(trans_ptr, g_bytes_ptr, &g_error);
        if (added == 0) {
            self.emitGError(g_error, "Failed to add the Flatpak ref installation operation");
            return error.AddInstallFailed;
        }

        var callback_context = self.transactionCallbackContext(cancellable);
        connectTransactionCallbacks(trans_ptr, &callback_context);

        const result = rawflatpak.flatpak_transaction_run(trans_ptr, cancellable, &g_error);
        return self.finishTransaction(result, g_error, "Flatpak ref installation completed");
    }

    pub fn install_from_bundle_flatpak(self: Manager, flatpak_location: [:0]const u8, scope: flatpak.Scope) !bool {
        var operation_scope = OperationScope.init(self, .install, flatpak_location);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);
        var cancellation_bridge = try CancellationBridge.init(self, cancellable);
        defer cancellation_bridge.deinit();

        var installation: ?*rawflatpak.FlatpakInstallation = null;
        if (scope == flatpak.Scope.SYSTEM) {
            installation = rawflatpak.flatpak_installation_new_system(cancellable, &g_error);
        } else {
            installation = rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        }
        if (installation == null) {
            self.emitGError(g_error, "Failed to open the Flatpak installation");
            return error.InstallationCreateFailed;
        }
        defer rawflatpak.g_object_unref(installation);

        const file_ptr = rawflatpak.g_file_new_for_path(flatpak_location);
        if (file_ptr == null) {
            self.emitStatus(.err, "Failed to open the Flatpak bundle");
            return error.BundleOpenFailed;
        }
        defer rawflatpak.g_object_unref(file_ptr);

        const trans_ptr = rawflatpak.flatpak_transaction_new_for_installation(installation, cancellable, &g_error);
        if (trans_ptr == null) {
            self.emitGError(g_error, "Failed to create the Flatpak transaction");
            return error.TransactionCreateFailed;
        }
        defer rawflatpak.g_object_unref(trans_ptr);

        const added = rawflatpak.flatpak_transaction_add_install_bundle(trans_ptr, file_ptr, null, &g_error);
        if (added == 0) {
            self.emitGError(g_error, "Failed to add the Flatpak bundle installation operation");
            return error.AddInstallFailed;
        }

        var callback_context = self.transactionCallbackContext(cancellable);
        connectTransactionCallbacks(trans_ptr, &callback_context);

        const result = rawflatpak.flatpak_transaction_run(trans_ptr, cancellable, &g_error);
        return self.finishTransaction(result, g_error, "Flatpak bundle installation completed");
    }

    pub fn search_remote_refs_flatpak(self: Manager, query: [:0]const u8) ![]flatpak.Flatpak {
        var operation_scope = OperationScope.init(self, .search, query);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        var list: std.ArrayList(flatpak.Flatpak) = .empty;
        errdefer list.deinit(self.allocator);

        const installation_system = rawflatpak.flatpak_installation_new_system(cancellable, &g_error);
        const sys_result = try get_remote_refs_by_query(self, query, flatpak.Scope.SYSTEM, installation_system);
        defer self.allocator.free(sys_result);
        try list.appendSlice(self.allocator, sys_result);

        const installation_user = rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        const user_result = try get_remote_refs_by_query(self, query, flatpak.Scope.USER, installation_user);
        defer self.allocator.free(user_result);
        try list.appendSlice(self.allocator, user_result);

        return list.toOwnedSlice(self.allocator);
    }

    pub fn get_flatpaks_from_remote(self: Manager, remote_name: [:0]const u8) ![]flatpak.Flatpak {
        var operation_scope = OperationScope.init(self, .search, remote_name);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        var list: std.ArrayList(flatpak.Flatpak) = .empty;
        errdefer list.deinit(self.allocator);

        const installation_system = rawflatpak.flatpak_installation_new_system(cancellable, &g_error);
        if (installation_system != null and g_error == null) {
            const sys_result = try get_all_flatpaks_by_remote(
                self,
                remote_name,
                flatpak.Scope.SYSTEM,
                installation_system,
            );
            defer self.allocator.free(sys_result);
            try list.appendSlice(self.allocator, sys_result);
        }

        if (g_error) |value| {
            rawflatpak.g_error_free(value);
            g_error = null;
        }
        const installation_user = rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        if (installation_user != null and g_error == null) {
            const user_result = try get_all_flatpaks_by_remote(
                self,
                remote_name,
                flatpak.Scope.USER,
                installation_user,
            );
            defer self.allocator.free(user_result);
            try list.appendSlice(self.allocator, user_result);
        }

        return list.toOwnedSlice(self.allocator);
    }

    pub fn get_remote_ref_info_flatpak(self: Manager, remote_name: [:0]const u8, flatpak_name: [:0]const u8, branch: [:0]const u8, scope: flatpak.Scope) !flatpak.RemoteRef {
        var operation_scope = OperationScope.init(self, .search, flatpak_name);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        var installation: ?*rawflatpak.FlatpakInstallation = null;

        if (scope == flatpak.Scope.SYSTEM) {
            installation = rawflatpak.flatpak_installation_new_system(cancellable, &g_error);
        } else {
            installation = rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        }
        if (installation == null or g_error != null) {
            self.emitGError(g_error, "Failed to open the Flatpak installation");
            return error.FlatpakError;
        }
        defer rawflatpak.g_object_unref(installation);

        const resolved_branch: [:0]u8 = blk: {
            if (branch.len > 0) break :blk try self.allocator.dupeZ(u8, branch);
            break :blk (try self.resolve_remote_branch(
                installation,
                remote_name,
                flatpak_name,
                rawflatpak.FLATPAK_REF_KIND_APP,
                cancellable,
            )) orelse {
                self.emitGError(g_error, "Failed to resolve the Flatpak branch from the remote");
                return error.FetchRemoteRefFailed;
            };
        };
        defer self.allocator.free(resolved_branch);

        const remote_ref_ptr = rawflatpak.flatpak_installation_fetch_remote_ref_sync(installation, cStr(remote_name), 0, cStr(flatpak_name), rawflatpak.flatpak_get_default_arch(), resolved_branch.ptr, cancellable, &g_error);
        if (remote_ref_ptr == null) {
            self.emitGError(g_error, "Failed to fetch the Flatpak remote reference");
            return error.FetchRemoteRefFailed;
        }
        errdefer rawflatpak.g_object_unref(remote_ref_ptr);

        const permissions = try get_permissions_from_remote_ref(self, remote_ref_ptr);
        return flatpak.RemoteRef.new(remote_ref_ptr, scope, permissions);
    }

    pub fn get_updates_flatpak(self: Manager) ![]flatpak.InstalledFlatpak {
        var operation_scope = OperationScope.init(self, .search, null);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        const installation_system = rawflatpak.flatpak_installation_new_system(cancellable, &g_error);
        const installation_user = rawflatpak.flatpak_installation_new_user(cancellable, &g_error);

        var list: std.ArrayList(flatpak.InstalledFlatpak) = .empty;
        errdefer list.deinit(self.allocator);

        if (installation_system != null) {
            const sys_result = try get_updates_ptr(self, installation_system, flatpak.Scope.SYSTEM);
            defer self.allocator.free(sys_result);
            try list.appendSlice(self.allocator, sys_result);
        }

        if (installation_user != null) {
            const user_result = try get_updates_ptr(self, installation_user, flatpak.Scope.USER);
            defer self.allocator.free(user_result);
            try list.appendSlice(self.allocator, user_result);
        }

        return list.toOwnedSlice(self.allocator);
    }

    pub fn get_running_instances_flatpak(self: Manager) ![]RunningInstance {
        var operation_scope = OperationScope.init(self, .search, null);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        var list: std.ArrayList(RunningInstance) = .empty;
        errdefer {
            for (list.items) |*instance| instance.deinit(self.allocator);
            list.deinit(self.allocator);
        }

        const instances_ptr = rawflatpak.flatpak_instance_get_all();
        if (instances_ptr == null) return list.toOwnedSlice(self.allocator);
        defer rawflatpak.g_ptr_array_unref(instances_ptr);
        var j: usize = 0;
        while (j < instances_ptr.*.len) : (j += 1) {
            const raw: *rawflatpak.FlatpakInstance = @ptrCast(@alignCast(instances_ptr.*.pdata[j]));
            if (rawflatpak.flatpak_instance_is_running(raw) == 0) continue;
            var instance = try runningInstanceFromRaw(self.allocator, raw);
            list.append(self.allocator, instance) catch |err| {
                instance.deinit(self.allocator);
                return err;
            };
        }

        return list.toOwnedSlice(self.allocator);
    }

    pub fn kill_flatpak(self: Manager, flatpak_id: [:0]const u8) !bool {
        var operation_scope = OperationScope.init(self, .remove, flatpak_id);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        const instances_ptr = rawflatpak.flatpak_instance_get_all();
        if (instances_ptr == null) return error.InvalidPid;
        defer rawflatpak.g_ptr_array_unref(instances_ptr);
        var pid: ?i32 = null;
        var j: usize = 0;
        while (j < instances_ptr.*.len) : (j += 1) {
            const raw: *rawflatpak.FlatpakInstance = @ptrCast(@alignCast(instances_ptr.*.pdata[j]));
            const app_id_c = rawflatpak.flatpak_instance_get_app(raw);
            if (app_id_c == null) continue;

            if (std.ascii.eqlIgnoreCase(std.mem.span(app_id_c), flatpak_id)) {
                pid = rawflatpak.flatpak_instance_get_child_pid(raw);
                break;
            }
        }

        const found_pid = pid orelse {
            std.log.err("Failed to find PID for running instance of {s}.", .{flatpak_id});
            self.emitStatus(.err, "Failed to find a running Flatpak instance");
            return error.InvalidPid;
        };

        if (found_pid <= 0) {
            std.log.err("Invalid PID for running instance of {s}.", .{flatpak_id});
            self.emitStatus(.err, "Flatpak instance has an invalid PID");
            return error.InvalidPid;
        }

        std.posix.kill(found_pid, std.posix.SIG.KILL) catch |err| {
            std.log.err("Failed to kill instance of {s} with PID {d}: {s}", .{ flatpak_id, found_pid, @errorName(err) });
            self.emitStatus(.err, "Failed to kill Flatpak instance");
            return err;
        };

        self.emitStatus(.success, "Flatpak instance killed");
        return true;
    }

    fn get_updates_ptr(self: Manager, installation: [*c]rawflatpak.FlatpakInstallation, scope: flatpak.Scope) ![]flatpak.InstalledFlatpak {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);
        var cancellation_bridge = try CancellationBridge.init(self, cancellable);
        defer cancellation_bridge.deinit();

        var list: std.ArrayList(flatpak.InstalledFlatpak) = .empty;
        errdefer list.deinit(self.allocator);

        const update_refs_ptr = rawflatpak.flatpak_installation_list_installed_refs_for_update(installation, cancellable, &g_error);
        if (update_refs_ptr == null) {
            if (g_error) |e| std.debug.print("failed to list updates: {s}\n", .{e.*.message});
            return list.toOwnedSlice(self.allocator);
        }
        defer rawflatpak.g_ptr_array_unref(update_refs_ptr);

        const trans_ptr = rawflatpak.flatpak_transaction_new_for_installation(installation, cancellable, &g_error);
        if (trans_ptr == null) {
            if (g_error) |e| std.debug.print("failed to create transaction: {s}\n", .{e.*.message});
            return list.toOwnedSlice(self.allocator);
        }
        defer rawflatpak.g_object_unref(trans_ptr);

        var j: usize = 0;
        while (j < update_refs_ptr.*.len) : (j += 1) {
            const raw: *rawflatpak.FlatpakRef = @ptrCast(@alignCast(update_refs_ptr.*.pdata[j]));
            _ = rawflatpak.g_object_ref(raw); // keep this ref alive after the array is freed //TODO: Re-visit this but works for now.
            const flatpak_ref = flatpak.InstalledFlatpak.new(raw, scope);
            try list.append(self.allocator, flatpak_ref);

            const ref_string = try flatpak.refToString(self.allocator, raw);
            defer self.allocator.free(ref_string);
            _ = rawflatpak.flatpak_transaction_add_update(trans_ptr, ref_string, null, null, null);
        }

        var ctx = DiffContext{ .manager = self, .list = &list };
        _ = rawflatpak.g_signal_connect_data(trans_ptr, "ready", @ptrCast(&onReadyDiffPermissions), &ctx, null, 0);
        _ = rawflatpak.flatpak_transaction_run(trans_ptr, cancellable, null);

        return list.toOwnedSlice(self.allocator);
    }

    fn onReadyDiffPermissions(trans: ?*rawflatpak.FlatpakTransaction, user_data: ?*anyopaque) callconv(.c) c_int {
        const ctx: *DiffContext = @ptrCast(@alignCast(user_data.?));

        var operations: ?*rawflatpak.GList = rawflatpak.flatpak_transaction_get_operations(trans);
        while (operations) |operation| {
            const operation_ptr: *rawflatpak.FlatpakTransactionOperation = @ptrCast(@alignCast(operation.data));
            const ref_c = rawflatpak.flatpak_transaction_operation_get_ref(operation_ptr);

            if (ref_c != null) {
                const ref_str = std.mem.span(ref_c);

                for (ctx.list.items) |*item| {
                    const id = item.id();
                    if (std.mem.indexOf(u8, ref_str, id) != null) {
                        const new_kf = rawflatpak.flatpak_transaction_operation_get_metadata(operation_ptr);
                        const old_kf = rawflatpak.flatpak_transaction_operation_get_old_metadata(operation_ptr);

                        item.permissions = diffPermissions(ctx.manager, new_kf, old_kf) catch &.{};
                        break;
                    }
                }
            }
            operations = operation.next;
        }
        return 0; // FALSE — stop before applying anything
    }

    fn diffPermissions(self: Manager, new_kf: ?*rawflatpak.GKeyFile, old_kf: ?*rawflatpak.GKeyFile) ![]const [:0]u8 {
        var new_raw: std.ArrayList([:0]u8) = .empty;
        const new_perms = try get_permissions_from_key_file(self, new_kf, &new_raw);
        defer {
            for (new_perms) |p| self.allocator.free(p);
            self.allocator.free(new_perms);
        }

        var old_raw: std.ArrayList([:0]u8) = .empty;
        const old_perms = try get_permissions_from_key_file(self, old_kf, &old_raw);
        defer {
            for (old_perms) |p| self.allocator.free(p);
            self.allocator.free(old_perms);
        }

        var diff: std.ArrayList([:0]u8) = .empty;
        errdefer {
            for (diff.items) |p| self.allocator.free(p);
            diff.deinit(self.allocator);
        }

        for (new_perms) |p| {
            if (!containsStr(old_perms, p)) {
                try diff.append(self.allocator, try std.fmt.allocPrintSentinel(self.allocator, "+ {s}", .{p}, 0));
            }
        }
        for (old_perms) |p| {
            if (!containsStr(new_perms, p)) {
                try diff.append(self.allocator, try std.fmt.allocPrintSentinel(self.allocator, "- {s}", .{p}, 0));
            }
        }

        return diff.toOwnedSlice(self.allocator);
    }

    fn get_permissions_from_remote_ref(self: Manager, remote_ref_ptr: *rawflatpak.FlatpakRemoteRef) ![]const [:0]u8 {
        var g_error: ?*rawflatpak.GError = null;
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        var permissions: std.ArrayList([:0]u8) = .empty;
        errdefer {
            for (permissions.items) |p| self.allocator.free(p);
            permissions.deinit(self.allocator);
        }

        const bytes_ptr = rawflatpak.flatpak_remote_ref_get_metadata(remote_ref_ptr);
        if (bytes_ptr == null) return permissions.toOwnedSlice(self.allocator);

        var size: usize = 0;
        const data_ptr = rawflatpak.g_bytes_get_data(bytes_ptr, &size);
        if (data_ptr == null) return permissions.toOwnedSlice(self.allocator);

        const key_file_ptr = rawflatpak.g_key_file_new();
        defer rawflatpak.g_key_file_free(key_file_ptr);

        const loaded = rawflatpak.g_key_file_load_from_data(key_file_ptr, @ptrCast(data_ptr), size, 0, &g_error);
        if (loaded == 0) {
            if (g_error) |e| std.debug.print("failed to load keyfile: {s}\n", .{e.*.message});
            return permissions.toOwnedSlice(self.allocator);
        }

        return get_permissions_from_key_file(self, key_file_ptr, &permissions);
    }

    fn get_permissions_from_key_file(self: Manager, key_file_ptr: ?*rawflatpak.GKeyFile, permissions: *std.ArrayList([:0]u8)) ![]const [:0]u8 {
        const groups = [_][:0]const u8{ "Context", "ExtensionBus", "Shared", "Sockets", "Filesystems", "SessionBus", "SystemBus" };

        for (groups) |group| {
            var num_keys: usize = 0;
            const keys_ptr = rawflatpak.g_key_file_get_keys(key_file_ptr, group.ptr, &num_keys, null);
            if (keys_ptr == null) continue;
            defer rawflatpak.g_strfreev(keys_ptr);

            var i: usize = 0;
            while (keys_ptr[i] != null) : (i += 1) {
                const key = keys_ptr[i];
                if (key == null or std.mem.len(key) == 0) continue;

                var list_len: usize = 0;
                const list_ptr = rawflatpak.g_key_file_get_string_list(key_file_ptr, group.ptr, key, &list_len, null);
                if (list_ptr != null) {
                    defer rawflatpak.g_strfreev(list_ptr);
                    var j: usize = 0;
                    while (list_ptr[j] != null) : (j += 1) {
                        const val = list_ptr[j];
                        if (val == null or std.mem.len(val) == 0) continue;
                        const entry = try std.fmt.allocPrintSentinel(
                            self.allocator,
                            "{s}={s}:{s}",
                            .{ group, std.mem.span(key), std.mem.span(val) },
                            0,
                        );
                        try permissions.append(self.allocator, entry);
                    }
                } else {
                    const val_ptr = rawflatpak.g_key_file_get_string(key_file_ptr, group.ptr, key, null);
                    if (val_ptr == null) continue;
                    defer rawflatpak.g_free(val_ptr);
                    if (std.mem.len(val_ptr) == 0) continue;
                    const entry = try std.fmt.allocPrintSentinel(
                        self.allocator,
                        "{s}={s}:{s}",
                        .{ group, std.mem.span(key), std.mem.span(val_ptr) },
                        0,
                    );
                    try permissions.append(self.allocator, entry);
                }
            }
        }

        return permissions.toOwnedSlice(self.allocator);
    }

    fn resolve_remote_branch(
        self: Manager,
        installation: [*c]rawflatpak.FlatpakInstallation,
        remote_name: [:0]const u8,
        flatpak_name: [:0]const u8,
        kind: c_int,
        cancellable: *rawflatpak.GCancellable,
    ) !?[:0]u8 {
        var g_error: ?*rawflatpak.GError = null;
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        var preferred: ?[:0]u8 = null;
        defer if (preferred) |value| self.allocator.free(value);
        const remote_ptr = rawflatpak.flatpak_installation_get_remote_by_name(installation, remote_name, cancellable, &g_error);
        if (remote_ptr != null) {
            defer rawflatpak.g_object_unref(remote_ptr);
            const default_branch_ptr = rawflatpak.flatpak_remote_get_default_branch(remote_ptr);
            if (default_branch_ptr != null) {
                const default_branch = std.mem.span(default_branch_ptr);
                if (default_branch.len > 0) {
                    preferred = try self.allocator.dupeZ(u8, default_branch);
                }
            }
        }
        if (g_error) |e| {
            rawflatpak.g_error_free(e);
            g_error = null;
        }

        const refs_ptr = rawflatpak.flatpak_installation_list_remote_refs_sync_full(installation, remote_name, rawflatpak.FLATPAK_QUERY_FLAGS_NONE, cancellable, &g_error);
        if (refs_ptr == null) return null;
        defer rawflatpak.g_ptr_array_unref(refs_ptr);

        var first_match: ?[:0]const u8 = null;
        var stable_match: ?[:0]const u8 = null;
        var preferred_match: ?[:0]const u8 = null;

        var j: usize = 0;
        while (j < refs_ptr.*.len) : (j += 1) {
            const raw_ref: *rawflatpak.FlatpakRef = @ptrCast(@alignCast(refs_ptr.*.pdata[j]));
            if (@as(c_int, @intCast(rawflatpak.flatpak_ref_get_kind(raw_ref))) != kind) continue;
            const name_ptr = rawflatpak.flatpak_ref_get_name(raw_ref);
            if (name_ptr == null or !std.mem.eql(u8, std.mem.span(name_ptr), flatpak_name)) continue;
            const branch_ptr = rawflatpak.flatpak_ref_get_branch(raw_ref);
            if (branch_ptr == null) continue;
            const ref_branch = std.mem.span(branch_ptr);
            if (first_match == null) first_match = ref_branch;
            if (std.mem.eql(u8, ref_branch, "stable")) stable_match = ref_branch;
            if (preferred) |value| {
                if (std.mem.eql(u8, ref_branch, value)) preferred_match = ref_branch;
            }
        }

        const chosen = preferred_match orelse stable_match orelse first_match orelse return null;
        return try self.allocator.dupeZ(u8, chosen);
    }

    fn get_all_flatpaks_by_remote(self: Manager, remote: [:0]const u8, scope: flatpak.Scope, installation: [*c]rawflatpak.FlatpakInstallation) ![]flatpak.Flatpak {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);
        var cancellation_bridge = try CancellationBridge.init(self, cancellable);
        defer cancellation_bridge.deinit();

        var list: std.ArrayList(flatpak.Flatpak) = .empty;
        errdefer list.deinit(self.allocator);

        const updated = rawflatpak.flatpak_installation_update_remote_sync(installation, remote, cancellable, &g_error);
        if (updated == 0) {
            if (g_error) |e| std.debug.print("failed to update remote cache: {s}\n", .{e.*.message});
            return error.RemoteUpdateFailed;
        }

        const refs_ptr = rawflatpak.flatpak_installation_list_remote_refs_sync_full(installation, remote, 1, cancellable, &g_error);
        if (refs_ptr == null) {
            if (g_error) |e| std.debug.print("failed to list remote refs: {s}\n", .{e.*.message});
            return error.ListRemoteRefsFailed;
        }

        var j: usize = 0;
        while (j < refs_ptr.*.len) : (j += 1) {
            const raw: *rawflatpak.FlatpakRef = @ptrCast(@alignCast(refs_ptr.*.pdata[j]));
            const flatpak_ref = flatpak.Flatpak.new(raw, scope);
            try list.append(self.allocator, flatpak_ref);
        }

        return list.toOwnedSlice(self.allocator);
    }

    fn get_remote_refs_by_query(self: Manager, query: [:0]const u8, scope: flatpak.Scope, installation: [*c]rawflatpak.FlatpakInstallation) ![]flatpak.Flatpak {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);
        var cancellation_bridge = try CancellationBridge.init(self, cancellable);
        defer cancellation_bridge.deinit();

        const remote_manager = remotes.RemoteManager{ .allocator = self.allocator, .io = self.io };
        const configured_remotes = try remote_manager.listRemotesWithDetails();
        defer remotes.RemoteManager.deinitRemotes(
            self.allocator,
            configured_remotes,
        );

        var list: std.ArrayList(flatpak.Flatpak) = .empty;
        errdefer list.deinit(self.allocator);

        for (configured_remotes) |remote| {
            if (remote.get_scope() == scope and remote.disabled() != true) {
                const refs_ptr = rawflatpak.flatpak_installation_list_remote_refs_sync_full(installation, cStr(remote.name()), 1, cancellable, &g_error);
                if (refs_ptr == null) {
                    if (g_error) |e| std.debug.print("failed to list remote refs: {s}\n", .{e.*.message});
                    return error.ListRemoteRefsFailed;
                }

                var j: usize = 0;
                while (j < refs_ptr.*.len) : (j += 1) {
                    const raw: *rawflatpak.FlatpakRef = @ptrCast(@alignCast(refs_ptr.*.pdata[j]));
                    const flatpak_ref = flatpak.Flatpak.new(raw, scope);
                    const matches_id = if (flatpak_ref.id()) |id| containsIgnoreCase(id, query) else false;

                    if (matches_id) {
                        try list.append(self.allocator, flatpak_ref);
                    }
                }
            }
        }
        return list.toOwnedSlice(self.allocator);
    }

    fn readRefBytes(self: Manager, flatpak_location: []const u8) ![]u8 {
        const ref_data = try std.Io.Dir.readFileAlloc(
            std.Io.Dir.cwd(),
            self.io,
            flatpak_location,
            self.allocator,
            .unlimited,
        );
        return ref_data;
    }

    fn findInSystemInstallations(self: Manager, name_or_id: []const u8) !?InstalledApplication {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        defer rawflatpak.g_object_unref(cancellable);
        var g_error: ?*rawflatpak.GError = null;
        defer if (g_error) |value| rawflatpak.g_error_free(value);
        var cancellation_bridge = try CancellationBridge.init(self, cancellable);
        defer cancellation_bridge.deinit();

        const installations = rawflatpak.flatpak_get_system_installations(cancellable, &g_error);
        if (installations == null or g_error != null) return null;
        defer rawflatpak.g_ptr_array_unref(installations);

        var index: usize = 0;
        while (index < installations.*.len) : (index += 1) {
            try self.checkCancelled();
            const installation: *rawflatpak.FlatpakInstallation = @ptrCast(@alignCast(installations.*.pdata[index]));
            if (try self.findInInstallation(installation, name_or_id, .SYSTEM)) |application| return application;
        }
        return null;
    }

    fn appendSystemInstalledApplications(
        self: Manager,
        applications: *std.ArrayList(InstalledApplication),
    ) !void {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        defer rawflatpak.g_object_unref(cancellable);
        var g_error: ?*rawflatpak.GError = null;
        defer if (g_error) |value| rawflatpak.g_error_free(value);
        var cancellation_bridge = try CancellationBridge.init(self, cancellable);
        defer cancellation_bridge.deinit();

        const installations = rawflatpak.flatpak_get_system_installations(cancellable, &g_error);
        if (installations == null or g_error != null) return;
        defer rawflatpak.g_ptr_array_unref(installations);

        var index: usize = 0;
        while (index < installations.*.len) : (index += 1) {
            try self.checkCancelled();
            const installation: *rawflatpak.FlatpakInstallation = @ptrCast(@alignCast(installations.*.pdata[index]));
            try self.appendInstalledApplications(installation, .SYSTEM, applications);
        }
    }

    fn appendUserInstalledApplications(
        self: Manager,
        applications: *std.ArrayList(InstalledApplication),
    ) !void {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        defer rawflatpak.g_object_unref(cancellable);
        var g_error: ?*rawflatpak.GError = null;
        defer if (g_error) |value| rawflatpak.g_error_free(value);
        var cancellation_bridge = try CancellationBridge.init(self, cancellable);
        defer cancellation_bridge.deinit();

        const installation = rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        if (installation == null or g_error != null) return;
        defer rawflatpak.g_object_unref(installation);
        try self.appendInstalledApplications(installation, .USER, applications);
    }

    fn appendInstalledApplications(
        self: Manager,
        installation: *rawflatpak.FlatpakInstallation,
        scope: flatpak.Scope,
        applications: *std.ArrayList(InstalledApplication),
    ) !void {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        defer rawflatpak.g_object_unref(cancellable);
        var g_error: ?*rawflatpak.GError = null;
        defer if (g_error) |value| rawflatpak.g_error_free(value);
        var cancellation_bridge = try CancellationBridge.init(self, cancellable);
        defer cancellation_bridge.deinit();

        const refs = rawflatpak.flatpak_installation_list_installed_refs(installation, cancellable, &g_error);
        if (refs == null or g_error != null) return;
        defer rawflatpak.g_ptr_array_unref(refs);

        var index: usize = 0;
        while (index < refs.*.len) : (index += 1) {
            try self.checkCancelled();
            const installed: *rawflatpak.FlatpakInstalledRef = @ptrCast(@alignCast(refs.*.pdata[index]));
            var application = try self.copyInstalledApplication(installed, scope);
            applications.append(self.allocator, application) catch |err| {
                application.deinit(self.allocator);
                return err;
            };
        }
    }

    fn findInUserInstallation(self: Manager, name_or_id: []const u8) !?InstalledApplication {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        defer rawflatpak.g_object_unref(cancellable);
        var g_error: ?*rawflatpak.GError = null;
        defer if (g_error) |value| rawflatpak.g_error_free(value);
        var cancellation_bridge = try CancellationBridge.init(self, cancellable);
        defer cancellation_bridge.deinit();

        const installation = rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        if (installation == null or g_error != null) return null;
        defer rawflatpak.g_object_unref(installation);
        return self.findInInstallation(installation, name_or_id, .USER);
    }

    fn findInInstallation(
        self: Manager,
        installation: *rawflatpak.FlatpakInstallation,
        name_or_id: []const u8,
        scope: flatpak.Scope,
    ) !?InstalledApplication {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        defer rawflatpak.g_object_unref(cancellable);
        var g_error: ?*rawflatpak.GError = null;
        defer if (g_error) |value| rawflatpak.g_error_free(value);
        var cancellation_bridge = try CancellationBridge.init(self, cancellable);
        defer cancellation_bridge.deinit();

        const refs = rawflatpak.flatpak_installation_list_installed_refs(installation, cancellable, &g_error);
        if (refs == null or g_error != null) return null;
        defer rawflatpak.g_ptr_array_unref(refs);

        var index: usize = 0;
        while (index < refs.*.len) : (index += 1) {
            try self.checkCancelled();
            const installed: *rawflatpak.FlatpakInstalledRef = @ptrCast(@alignCast(refs.*.pdata[index]));
            const ref: *rawflatpak.FlatpakRef = @ptrCast(installed);
            const id = spanOrEmpty(rawflatpak.flatpak_ref_get_name(ref));
            const appdata_name = spanOrEmpty(rawflatpak.flatpak_installed_ref_get_appdata_name(installed));
            const display_name = if (appdata_name.len == 0) id else appdata_name;
            if (!matchesInstalled(id, display_name, name_or_id)) continue;
            return @as(?InstalledApplication, try self.copyInstalledApplication(installed, scope));
        }
        return null;
    }

    fn copyInstalledApplication(
        self: Manager,
        installed: *rawflatpak.FlatpakInstalledRef,
        scope: flatpak.Scope,
    ) !InstalledApplication {
        const ref: *rawflatpak.FlatpakRef = @ptrCast(installed);
        const id = spanOrEmpty(rawflatpak.flatpak_ref_get_name(ref));
        const appdata_name = spanOrEmpty(rawflatpak.flatpak_installed_ref_get_appdata_name(installed));
        const branch = spanOrEmpty(rawflatpak.flatpak_ref_get_branch(ref));
        const appdata_version = spanOrEmpty(rawflatpak.flatpak_installed_ref_get_appdata_version(installed));

        var result: InstalledApplication = .{
            .id = try self.allocator.dupeSentinel(u8, id, 0),
            .name = undefined,
            .arch = undefined,
            .branch = undefined,
            .summary = undefined,
            .version = undefined,
            .latest_commit = undefined,
            .origin = undefined,
            .kind = @intCast(rawflatpak.flatpak_ref_get_kind(ref)),
            .installed_size = rawflatpak.flatpak_installed_ref_get_installed_size(installed),
            .scope = scope,
        };
        errdefer self.allocator.free(result.id);
        result.name = try self.allocator.dupeSentinel(u8, if (appdata_name.len == 0) id else appdata_name, 0);
        errdefer self.allocator.free(result.name);
        result.arch = try self.allocator.dupeSentinel(u8, spanOrEmpty(rawflatpak.flatpak_ref_get_arch(ref)), 0);
        errdefer self.allocator.free(result.arch);
        result.branch = try self.allocator.dupeSentinel(u8, branch, 0);
        errdefer self.allocator.free(result.branch);
        result.summary = try self.allocator.dupeSentinel(u8, spanOrEmpty(rawflatpak.flatpak_installed_ref_get_appdata_summary(installed)), 0);
        errdefer self.allocator.free(result.summary);
        result.version = try self.allocator.dupeSentinel(u8, if (appdata_version.len == 0) branch else appdata_version, 0);
        errdefer self.allocator.free(result.version);
        result.latest_commit = try self.allocator.dupeSentinel(
            u8,
            spanOrEmpty(rawflatpak.flatpak_installed_ref_get_latest_commit(installed)),
            0,
        );
        errdefer self.allocator.free(result.latest_commit);
        result.origin = try self.allocator.dupeSentinel(u8, spanOrEmpty(rawflatpak.flatpak_installed_ref_get_origin(installed)), 0);
        if (flatpak.str(rawflatpak.flatpak_installed_ref_get_eol(installed))) |value| {
            result.eol = try self.allocator.dupeSentinel(u8, value, 0);
            errdefer self.allocator.free(result.eol.?);
        }
        if (flatpak.str(rawflatpak.flatpak_installed_ref_get_eol_rebase(installed))) |value| {
            result.eol_rebase = try self.allocator.dupeSentinel(u8, value, 0);
            errdefer self.allocator.free(result.eol_rebase.?);
        }
        return result;
    }

    fn get_ref_id_and_installation(self: Manager, flatpak_id: [:0]const u8, installation: [*c]rawflatpak.FlatpakInstallation) !flatpak.Flatpak {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);
        var cancellation_bridge = try CancellationBridge.init(self, cancellable);
        defer cancellation_bridge.deinit();

        const ref_ptrs = rawflatpak.flatpak_installation_list_installed_refs(installation, cancellable, &g_error);
        if (ref_ptrs == null or g_error != null) return error.FlatpakError;
        defer rawflatpak.g_ptr_array_unref(ref_ptrs);
        var j: usize = 0;
        while (j < ref_ptrs.*.len) : (j += 1) {
            const raw: *rawflatpak.FlatpakRef = @ptrCast(@alignCast(ref_ptrs.*.pdata[j]));
            const flatpak_struct = flatpak.Flatpak.new(raw, flatpak.Scope.SYSTEM);
            const id = flatpak_struct.id() orelse return error.FlatpakError;
            if (std.mem.eql(u8, id, flatpak_id)) {
                _ = rawflatpak.g_object_ref(raw);
                return flatpak_struct;
            }
        }

        return error.FlatpakError;
    }

    fn upgrade_installation(
        self: Manager,
        installation: [*c]rawflatpak.FlatpakInstallation,
        scope: flatpak.Scope,
    ) !bool {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);
        var cancellation_bridge = try CancellationBridge.init(self, cancellable);
        defer cancellation_bridge.deinit();

        const update_refs_ptr = rawflatpak.flatpak_installation_list_installed_refs_for_update(installation, cancellable, &g_error);
        if (update_refs_ptr == null or g_error != null) {
            self.emitGError(g_error, "Failed to list Flatpak updates");
            return error.ListUpdatesFailed;
        }
        defer rawflatpak.g_ptr_array_unref(update_refs_ptr);
        if (update_refs_ptr.*.len == 0) {
            self.emitStatus(.information, upgradeNoUpdatesMessage(scope));
            return true;
        }

        const trans_ptr = rawflatpak.flatpak_transaction_new_for_installation(installation, cancellable, &g_error);
        if (trans_ptr == null or g_error != null) {
            self.emitGError(g_error, "Failed to create the Flatpak transaction");
            return error.TransactionCreateFailed;
        }
        defer rawflatpak.g_object_unref(trans_ptr);

        var j: usize = 0;
        while (j < update_refs_ptr.*.len) : (j += 1) {
            const raw: *rawflatpak.FlatpakRef = @ptrCast(@alignCast(update_refs_ptr.*.pdata[j]));
            const ref_string = try flatpak.refToString(self.allocator, raw);
            defer self.allocator.free(ref_string);

            if (rawflatpak.flatpak_transaction_add_update(trans_ptr, ref_string, null, null, &g_error) == 0) {
                self.emitGError(g_error, "Failed to add a Flatpak update operation");
                return error.AddUpdateFailed;
            }
        }

        var callback_context = self.transactionCallbackContext(cancellable);
        connectTransactionCallbacks(trans_ptr, &callback_context);

        const result = rawflatpak.flatpak_transaction_run(trans_ptr, cancellable, &g_error);
        return self.finishTransaction(result, g_error, upgradeCompletedMessage(scope));
    }

    /// Return the exact unused refs that a Flatpak purify operation would
    /// remove, preserving the installation scope for display and confirmation.
    pub fn list_unused_dependencies(self: Manager) ![]UnusedDependency {
        var operation_scope = OperationScope.init(self, .cleanup, null);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();

        var dependencies: std.ArrayList(UnusedDependency) = .empty;
        errdefer {
            for (dependencies.items) |*dependency| dependency.deinit(self.allocator);
            dependencies.deinit(self.allocator);
        }

        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |value| rawflatpak.g_error_free(value);

        const system_installations = rawflatpak.flatpak_get_system_installations(cancellable, &g_error);
        if (system_installations == null or g_error != null) {
            self.emitGError(g_error, "Failed to open system Flatpak installations");
            return error.InstallationCreateFailed;
        }
        defer rawflatpak.g_ptr_array_unref(system_installations);
        var index: usize = 0;
        while (index < system_installations.*.len) : (index += 1) {
            const installation: *rawflatpak.FlatpakInstallation = @ptrCast(@alignCast(system_installations.*.pdata[index]));
            try self.appendUnusedDependencies(installation, flatpak.Scope.SYSTEM, &dependencies);
        }

        const user_installation = rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        if (user_installation == null or g_error != null) {
            self.emitGError(g_error, "Failed to open the user Flatpak installation");
            return error.InstallationCreateFailed;
        }
        defer rawflatpak.g_object_unref(user_installation);
        try self.appendUnusedDependencies(user_installation, flatpak.Scope.USER, &dependencies);

        return dependencies.toOwnedSlice(self.allocator);
    }

    /// Remove unused dependencies from every system installation and the user
    /// installation. This is the mutation backend for `flatpak purify`.
    pub fn remove_unused_dependencies(self: Manager) !bool {
        var operation_scope = OperationScope.init(self, .cleanup, null);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try self.checkCancelled();
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        var succeeded = true;
        const system_installations = rawflatpak.flatpak_get_system_installations(cancellable, &g_error);
        if (system_installations != null and g_error == null) {
            defer rawflatpak.g_ptr_array_unref(system_installations);
            var index: usize = 0;
            while (index < system_installations.*.len) : (index += 1) {
                const installation: *rawflatpak.FlatpakInstallation = @ptrCast(@alignCast(system_installations.*.pdata[index]));
                succeeded = (try self.removed_unused(installation)) and succeeded;
            }
        } else {
            self.emitGError(g_error, "Failed to open system Flatpak installations");
            succeeded = false;
        }

        if (g_error) |value| {
            rawflatpak.g_error_free(value);
            g_error = null;
        }
        const installation_user = rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        if (installation_user != null and g_error == null) {
            defer rawflatpak.g_object_unref(installation_user);
            succeeded = (try self.removed_unused(installation_user)) and succeeded;
        } else {
            self.emitGError(g_error, "Failed to open the user Flatpak installation");
            succeeded = false;
        }

        self.emitStatus(if (succeeded) .success else .err, if (succeeded)
            "Unused Flatpak dependency cleanup completed"
        else
            "Unused Flatpak dependency cleanup completed with errors");
        return succeeded;
    }

    fn appendUnusedDependencies(
        self: Manager,
        installation: [*c]rawflatpak.FlatpakInstallation,
        scope: flatpak.Scope,
        dependencies: *std.ArrayList(UnusedDependency),
    ) !void {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |value| rawflatpak.g_error_free(value);
        var cancellation_bridge = try CancellationBridge.init(self, cancellable);
        defer cancellation_bridge.deinit();

        const arch = std.mem.span(rawflatpak.flatpak_get_default_arch());
        const unused_refs = rawflatpak.flatpak_installation_list_unused_refs(installation, arch, cancellable, &g_error);
        if (unused_refs == null or g_error != null) {
            self.emitGError(g_error, "Failed to list unused Flatpak dependencies");
            return error.ListUnusedDependenciesFailed;
        }
        defer rawflatpak.g_ptr_array_unref(unused_refs);

        var index: usize = 0;
        while (index < unused_refs.*.len) : (index += 1) {
            try self.checkCancelled();
            const raw: *rawflatpak.FlatpakRef = @ptrCast(@alignCast(unused_refs.*.pdata[index]));
            const reference = try flatpak.refToString(self.allocator, raw);
            dependencies.append(self.allocator, .{
                .reference = reference,
                .scope = scope,
            }) catch {
                self.allocator.free(reference);
                return error.OutOfMemory;
            };
        }
    }

    fn removed_unused(self: Manager, installation: [*c]rawflatpak.FlatpakInstallation) !bool {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);
        var cancellation_bridge = try CancellationBridge.init(self, cancellable);
        defer cancellation_bridge.deinit();

        const arch = std.mem.span(rawflatpak.flatpak_get_default_arch());
        const unused_ref_ptrs = rawflatpak.flatpak_installation_list_unused_refs(installation, arch, cancellable, &g_error);
        if (unused_ref_ptrs == null or g_error != null) {
            self.emitGError(g_error, "Failed to list unused Flatpak dependencies");
            return false;
        }
        defer rawflatpak.g_ptr_array_unref(unused_ref_ptrs);
        if (unused_ref_ptrs.*.len == 0) {
            self.emitStatus(.information, "No unused Flatpak dependencies found");
            return true;
        }

        const trans_ptr = rawflatpak.flatpak_transaction_new_for_installation(installation, cancellable, &g_error);
        if (trans_ptr == null or g_error != null) {
            self.emitGError(g_error, "Failed to create the Flatpak cleanup transaction");
            return false;
        }
        defer rawflatpak.g_object_unref(trans_ptr);

        var j: usize = 0;
        while (j < unused_ref_ptrs.*.len) : (j += 1) {
            try self.checkCancelled();
            const raw: *rawflatpak.FlatpakRef = @ptrCast(@alignCast(unused_ref_ptrs.*.pdata[j]));
            const ref_string = try flatpak.refToString(self.allocator, raw);
            defer self.allocator.free(ref_string);
            if (rawflatpak.flatpak_transaction_add_uninstall(trans_ptr, ref_string, &g_error) == 0) {
                self.emitGError(g_error, "Failed to add an unused Flatpak dependency to the removal transaction");
                return false;
            }
        }

        var callback_context = self.transactionCallbackContext(cancellable);
        connectTransactionCallbacks(trans_ptr, &callback_context);
        const result = rawflatpak.flatpak_transaction_run(trans_ptr, cancellable, &g_error);
        return self.finishTransaction(result, g_error, "Unused Flatpak dependencies removed");
    }

    const TransactionCallbackContext = struct {
        dispatcher: ?*events.Dispatcher,
        cancellation: ?events.Cancellation,
        cancellable: *rawflatpak.GCancellable,
        current_name: []const u8 = "",
    };

    fn transactionCallbackContext(self: Manager, cancellable: *rawflatpak.GCancellable) TransactionCallbackContext {
        return .{
            .dispatcher = self.dispatcher,
            .cancellation = self.cancellation,
            .cancellable = cancellable,
        };
    }

    fn connectTransactionCallbacks(
        transaction: *rawflatpak.FlatpakTransaction,
        context: *TransactionCallbackContext,
    ) void {
        _ = rawflatpak.g_signal_connect_data(transaction, "new-operation", @ptrCast(&onNewOperation), context, null, 0);
        _ = rawflatpak.g_signal_connect_data(transaction, "ready", @ptrCast(&onReady), context, null, 0);
        _ = rawflatpak.g_signal_connect_data(transaction, "operation-error", @ptrCast(&onOperationError), context, null, 0);
    }

    /// Mirror flatpak's CLI: non-fatal operation errors (e.g. an addon that was
    /// already removed as a related ref earlier in the same transaction) are
    /// reported as warnings instead of aborting the whole transaction.
    fn onOperationError(
        _: *rawflatpak.FlatpakTransaction,
        operation: ?*rawflatpak.FlatpakTransactionOperation,
        g_error: [*c]const rawflatpak.GError,
        detail: rawflatpak.FlatpakTransactionErrorDetails,
        user_data: ?*anyopaque,
    ) callconv(.c) rawflatpak.gboolean {
        const context: *TransactionCallbackContext = @ptrCast(@alignCast(user_data orelse return 0));
        const non_fatal = (detail & rawflatpak.FLATPAK_TRANSACTION_ERROR_DETAILS_NON_FATAL) != 0;
        if (!non_fatal) return 0;

        const ref_ptr = if (operation) |op| rawflatpak.flatpak_transaction_operation_get_ref(op) else null;
        const ref_name = if (ref_ptr == null) "" else std.mem.span(ref_ptr);
        const message = if (g_error != null and g_error.*.message != null)
            std.mem.span(g_error.*.message)
        else
            "Flatpak operation failed";
        if (context.dispatcher) |dispatcher| dispatcher.raiseStatus(.{
            .event_type = .warning,
            .message = if (ref_name.len > 0) ref_name else message,
        });
        return 1;
    }

    fn onProgressChanged(
        progress: *rawflatpak.FlatpakTransactionProgress,
        user_data: ?*anyopaque,
    ) callconv(.c) void {
        const context: *TransactionCallbackContext = @ptrCast(@alignCast(user_data orelse return));
        if (context.dispatcher) |dispatcher| {
            if (dispatcher.operation) |operation| {
                if (operation.isCancelled()) {
                    rawflatpak.g_cancellable_cancel(context.cancellable);
                    return;
                }
            }
        }
        if (context.cancellation) |cancellation| {
            if (cancellation.isCancelled()) {
                rawflatpak.g_cancellable_cancel(context.cancellable);
                return;
            }
        }

        const raw_percent = rawflatpak.flatpak_transaction_progress_get_progress(progress);
        const percent: u8 = @intCast(std.math.clamp(raw_percent, 0, 100));
        const status_ptr = rawflatpak.flatpak_transaction_progress_get_status(progress);
        const status = if (status_ptr == null) "" else std.mem.span(status_ptr);
        if (context.dispatcher) |dispatcher| dispatcher.raiseProgress(.{
            .name = context.current_name,
            .status = status,
            .percentage = percent,
        });
    }

    fn onNewOperation(
        _: *rawflatpak.FlatpakTransaction,
        operation: *rawflatpak.FlatpakTransactionOperation,
        progress: *rawflatpak.FlatpakTransactionProgress,
        user_data: ?*anyopaque,
    ) callconv(.c) void {
        const context: *TransactionCallbackContext = @ptrCast(@alignCast(user_data orelse return));
        const ref_ptr = rawflatpak.flatpak_transaction_operation_get_ref(operation);
        context.current_name = if (ref_ptr == null) "" else std.mem.span(ref_ptr);
        _ = rawflatpak.g_signal_connect_data(progress, "changed", @ptrCast(&onProgressChanged), context, null, 0);
        onProgressChanged(progress, context);
    }

    fn onReady(
        _: *rawflatpak.FlatpakTransaction,
        user_data: ?*anyopaque,
    ) callconv(.c) rawflatpak.gboolean {
        const context: *TransactionCallbackContext = @ptrCast(@alignCast(user_data orelse return 1));
        if (context.dispatcher) |dispatcher| dispatcher.raiseStatus(.{
            .event_type = .information,
            .message = "Flatpak transaction is ready",
        });
        return 1;
    }

    fn checkCancelled(self: Manager) !void {
        if (self.dispatcher) |dispatcher| {
            if (dispatcher.operation) |operation| {
                if (operation.isCancelled()) return error.Cancelled;
            }
        }
        if (self.operation_context) |context| {
            if (context.isCancelled()) return error.Cancelled;
        }
        if (self.cancellation) |cancellation| {
            if (cancellation.isCancelled()) return error.Cancelled;
        }
    }

    fn emitStatus(self: Manager, event_type: events.EventType, message: []const u8) void {
        if (self.dispatcher) |dispatcher| dispatcher.raiseStatus(.{
            .event_type = event_type,
            .message = message,
        });
    }

    fn emitGError(self: Manager, g_error: ?*rawflatpak.GError, fallback: []const u8) void {
        if (g_error) |value| {
            const message = std.mem.span(value.message);
            if (self.dispatcher) |dispatcher| {
                if (dispatcher.operation) |operation| {
                    const domain_ptr = rawflatpak.g_quark_to_string(value.domain);
                    operation.reportError(
                        error.FlatpakError,
                        message,
                        if (domain_ptr == null) "flatpak" else std.mem.span(domain_ptr),
                        value.code,
                        false,
                    );
                }
            }
            self.emitStatus(.err, message);
        } else {
            self.emitStatus(.err, fallback);
        }
    }

    fn finishTransaction(
        self: Manager,
        result: rawflatpak.gboolean,
        g_error: ?*rawflatpak.GError,
        success_message: []const u8,
    ) !bool {
        try self.checkCancelled();
        if (g_error) |value| {
            const message = std.mem.span(value.message);
            self.emitStatus(.err, message);
            return error.FlatpakError;
        }
        if (result == 0) {
            self.emitStatus(.err, "Flatpak transaction failed");
            return false;
        }
        self.emitStatus(.success, success_message);
        return true;
    }

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;

        var i: usize = 0;
        while (i <= haystack.len - needle.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) {
                return true;
            }
        }
        return false;
    }

    fn containsStr(haystack: []const [:0]u8, needle: [:0]u8) bool {
        for (haystack) |h| {
            if (std.mem.eql(u8, h, needle)) return true;
        }
        return false;
    }

    pub fn cStr(s: ?[:0]const u8) [*c]const u8 {
        return if (s) |str| str.ptr else null;
    }

    const DiffContext = struct {
        manager: Manager,
        list: *std.ArrayList(flatpak.InstalledFlatpak),
    };
};

const OperationScope = struct {
    manager: Manager,
    operation: ?operation_api.Operation = null,
    previous: ?*operation_api.Operation = null,
    attached: bool = false,

    fn init(manager: Manager, kind: operation_api.OperationKind, subject: ?[]const u8) OperationScope {
        var scope: OperationScope = .{ .manager = manager };
        if (manager.dispatcher) |dispatcher| scope.previous = dispatcher.operation;
        if (scope.previous) |parent| {
            scope.operation = parent.child(.{ .backend = .flatpak, .kind = kind, .subject = subject });
        } else if (manager.operation_context) |context| {
            scope.operation = context.begin(.{ .backend = .flatpak, .kind = kind, .subject = subject });
        }
        return scope;
    }

    fn attach(self: *OperationScope) void {
        if (self.manager.dispatcher) |dispatcher| {
            if (self.operation) |*operation| dispatcher.setOperation(operation);
        }
        self.attached = true;
    }

    fn fail(self: *OperationScope) void {
        if (self.operation) |*operation| operation.reportError(
            if (operation.isCancelled()) error.Cancelled else error.FlatpakOperationFailed,
            if (operation.isCancelled()) "Flatpak operation cancelled" else "Flatpak operation failed",
            "flatpak",
            null,
            false,
        );
        const status: operation_api.CompletionStatus = if (self.operation) |*operation|
            if (operation.isCancelled()) .cancelled else .failed
        else
            .failed;
        self.finish(status);
    }

    fn finish(self: *OperationScope, status: operation_api.CompletionStatus) void {
        if (self.operation) |*operation| operation.finish(status);
        if (self.attached) {
            if (self.manager.dispatcher) |dispatcher| dispatcher.setOperation(self.previous);
            self.attached = false;
        }
    }
};

const CancellationBridge = struct {
    context: ?*operation_api.OperationContext = null,
    subscription: ?operation_api.SubscriptionId = null,

    fn init(manager: Manager, cancellable: *rawflatpak.GCancellable) !CancellationBridge {
        const context = if (manager.dispatcher) |dispatcher|
            if (dispatcher.operation) |operation| operation.context else manager.operation_context
        else
            manager.operation_context;
        var bridge: CancellationBridge = .{ .context = context };
        if (context) |operation_context| {
            bridge.subscription = try operation_context.subscribeCancellation(.{
                .function = cancelGlib,
                .data = cancellable,
            });
            if (operation_context.isCancelled()) rawflatpak.g_cancellable_cancel(cancellable);
        }
        return bridge;
    }

    fn deinit(self: *CancellationBridge) void {
        if (self.context) |context| {
            if (self.subscription) |subscription| _ = context.unsubscribeCancellation(subscription);
        }
        self.* = undefined;
    }

    fn cancelGlib(data: ?*anyopaque) void {
        const cancellable: *rawflatpak.GCancellable = @ptrCast(@alignCast(data orelse return));
        rawflatpak.g_cancellable_cancel(cancellable);
    }
};

fn spanOrEmpty(pointer: [*c]const u8) []const u8 {
    return if (pointer == null) "" else std.mem.span(pointer);
}

fn duplicateNativeString(allocator: std.mem.Allocator, pointer: [*c]const u8) ![:0]u8 {
    return allocator.dupeSentinel(u8, spanOrEmpty(pointer), 0);
}

fn runningInstanceFromRaw(
    allocator: std.mem.Allocator,
    raw: *rawflatpak.FlatpakInstance,
) !RunningInstance {
    const instance_id = try duplicateNativeString(allocator, rawflatpak.flatpak_instance_get_id(raw));
    errdefer allocator.free(instance_id);
    const application_id = try duplicateNativeString(allocator, rawflatpak.flatpak_instance_get_app(raw));
    errdefer allocator.free(application_id);
    const arch = try duplicateNativeString(allocator, rawflatpak.flatpak_instance_get_arch(raw));
    errdefer allocator.free(arch);
    const branch = try duplicateNativeString(allocator, rawflatpak.flatpak_instance_get_branch(raw));
    errdefer allocator.free(branch);
    return .{
        .instance_id = instance_id,
        .application_id = application_id,
        .arch = arch,
        .branch = branch,
        .pid = rawflatpak.flatpak_instance_get_pid(raw),
        .child_pid = rawflatpak.flatpak_instance_get_child_pid(raw),
    };
}

fn matchesInstalled(id: []const u8, name: []const u8, query: []const u8) bool {
    return std.ascii.eqlIgnoreCase(id, query) or
        containsIgnoreCaseValue(id, query) or
        std.ascii.eqlIgnoreCase(name, query) or
        containsIgnoreCaseValue(name, query);
}

fn containsIgnoreCaseValue(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index <= haystack.len - needle.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn upgradeNoUpdatesMessage(scope: flatpak.Scope) []const u8 {
    return switch (scope) {
        .SYSTEM => "No system Flatpak updates available",
        .USER => "No user Flatpak updates available",
        .UNKNOWN => "No Flatpak updates available",
    };
}

fn upgradeCompletedMessage(scope: flatpak.Scope) []const u8 {
    return switch (scope) {
        .SYSTEM => "System Flatpak upgrade completed",
        .USER => "User Flatpak upgrade completed",
        .UNKNOWN => "Flatpak upgrade completed",
    };
}

test "installed Flatpak resolution matches IDs and friendly names" {
    try std.testing.expect(matchesInstalled("org.mozilla.firefox", "Firefox", "org.mozilla.firefox"));
    try std.testing.expect(matchesInstalled("org.mozilla.firefox", "Firefox", "mozilla"));
    try std.testing.expect(matchesInstalled("org.mozilla.firefox", "Firefox", "fire"));
    try std.testing.expect(!matchesInstalled("org.mozilla.firefox", "Firefox", "chromium"));
}

test "Flatpak upgrade status messages identify installation scope" {
    try std.testing.expectEqualStrings(
        "No system Flatpak updates available",
        upgradeNoUpdatesMessage(.SYSTEM),
    );
    try std.testing.expectEqualStrings(
        "No user Flatpak updates available",
        upgradeNoUpdatesMessage(.USER),
    );
    try std.testing.expectEqualStrings(
        "System Flatpak upgrade completed",
        upgradeCompletedMessage(.SYSTEM),
    );
    try std.testing.expectEqualStrings(
        "User Flatpak upgrade completed",
        upgradeCompletedMessage(.USER),
    );
}

test "Flatpak manager exposes strict-parity operations" {
    _ = Manager.setEventDispatcher;
    _ = Manager.setCancellation;
    _ = Manager.find_installed_flatpak;
    _ = Manager.update_installed_flatpak;
    _ = Manager.uninstall_installed_flatpak;
    _ = Manager.list_unused_dependencies;
    _ = Manager.remove_unused_dependencies;
    _ = Manager.install_flatpak;
    _ = Manager.upgrade_flatpaks;
    _ = Manager.install_from_ref_flatpak;
    _ = Manager.install_from_bundle_flatpak;
    _ = Manager.rebase_flatpak;
    _ = Manager.list_eol_flatpak;

    // Taking a function pointer does not analyze the function body in Zig.
    // Keep these calls behind a runtime-false guard so this test compiles the
    // public workflows without accessing or mutating live Flatpak state.
    var analyze_bodies = false;
    std.mem.doNotOptimizeAway(&analyze_bodies);
    if (analyze_bodies) {
        const manager = Manager{ .allocator = std.testing.allocator, .io = std.testing.io };

        if (try manager.find_installed_flatpak("org.example.Application")) |application| {
            var owned = application;
            owned.deinit(std.testing.allocator);
        }
        _ = try manager.update_installed_flatpak("org.example.Application", null);
        _ = try manager.uninstall_installed_flatpak("org.example.Application", false);
        const unused = try manager.list_unused_dependencies();
        UnusedDependency.deinitSlice(std.testing.allocator, unused);
    }
}

test "shared cancellation propagates to GLib cancellables" {
    var context = operation_api.OperationContext.init(std.testing.allocator, std.testing.io);
    defer context.deinit();
    const manager = Manager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .operation_context = &context,
    };
    const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
    defer rawflatpak.g_object_unref(cancellable);
    var bridge = try CancellationBridge.init(manager, cancellable);
    defer bridge.deinit();

    context.cancel();
    try std.testing.expect(rawflatpak.g_cancellable_is_cancelled(cancellable) != 0);
}

//disabled until uninstall is added.
test "test installFlatpak" {
    // const manager = Manager{ .allocator = std.testing.allocator, .io = std.testing.io };
    // const result = try manager.install_app("it.mijorus.gearlever", "flathub", flatpak.Scope.SYSTEM, "stable", false);
    // try std.testing.expect(result);
}

test "test listFlatpak" {
    // const manager = Manager{ .allocator = std.testing.allocator, .io = std.testing.io };
    // const result = try manager.installed_flatpaks();
    // defer std.testing.allocator.free(result);
    // try std.testing.expectEqualStrings("app.drey.Elastic", result[0].name().?);
}

// test "test removeUnused" {
//     const manager = Manager{ .allocator = std.testing.allocator, .io = std.testing.io };
//     const result = try manager.removed_unused_deps();
//     try std.testing.expect(result);
// }

// test "test upgrade" {
//     const manager = Manager{ .allocator = std.testing.allocator, .io = std.testing.io };
//     const result = try manager.upgrade_flatpaks();
//     try std.testing.expect(result);
// }

// test "test flatById" {
//     const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
//     var g_error: ?*rawflatpak.GError = null;
//     defer rawflatpak.g_object_unref(cancellable);
//     defer if (g_error) |e| rawflatpak.g_error_free(e);

//     const installation_system = rawflatpak.flatpak_installation_new_system(cancellable, &g_error);
//     const manager = Manager{ .allocator = std.testing.allocator, .io = std.testing.io };
//     const result = try manager.get_ref_id_and_installation("app.drey.Elastic", installation_system);
//     try std.testing.expectEqualStrings("app.drey.Elastic", result.id().?);
// }

// test "test removeflatpak" {
//     const manager = Manager{ .allocator = std.testing.allocator, .io = std.testing.io };
//     const result = try manager.uninstall_flatpak("app.drey.Elastic", flatpak.Scope.SYSTEM, false);
//     try std.testing.expect(result);
// }

// test "test flatpakupdate" {
//     const manager = Manager{ .allocator = std.testing.allocator, .io = std.testing.io };
//     const result = try manager.update_flatpak("it.mijorus.gearlever", flatpak.Scope.SYSTEM, "5f08f18ed0e02d1a728ba89403240fdeb5235d7453bbc77c7aa56bea63b74e77");
//     try std.testing.expect(result);
// }

test "test laucnhFlatpak" {
    const manager = Manager{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try manager.launch_flatpak("it.x.gearlever");
    try std.testing.expect(!result);
}

test "test searchremoteref" {
    const manager = Manager{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try manager.search_remote_refs_flatpak("spotify");
    defer std.testing.allocator.free(result);
    try std.testing.expect(result.len > 0);
}

test "test getAllFlatpaksFromRemotes" {
    const manager = Manager{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try manager.get_flatpaks_from_remote("flathub");
    defer std.testing.allocator.free(result);
    try std.testing.expect(result.len > 500);
}

test "test getRemoteRefInfo" {
    const manager = Manager{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try manager.get_remote_ref_info_flatpak("flathub", "it.mijorus.gearlever", "stable", flatpak.Scope.SYSTEM);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.permissions.len > 1);
}

test "test getRemoteRefInfo resolves an empty branch from the remote" {
    const manager = Manager{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try manager.get_remote_ref_info_flatpak("flathub", "it.mijorus.gearlever", "", flatpak.Scope.SYSTEM);
    defer result.deinit(std.testing.allocator);
    const branch_name = result.branch() orelse return error.TestUnexpectedResult;
    try std.testing.expect(branch_name.len > 0);
    try std.testing.expect(result.permissions.len > 1);
}

// test "test updateswithperms" {
//     const manager = Manager{ .allocator = std.testing.allocator, .io = std.testing.io };
//     const result = try manager.get_updates_flatpak();
//     defer {
//         for (result) |item| {
//             if (item.permissions.len > 0) {
//                 for (item.permissions) |p| std.testing.allocator.free(p);
//                 std.testing.allocator.free(item.permissions);
//             }
//             rawflatpak.g_object_unref(item.ptr); // release the ref we took
//         }
//         std.testing.allocator.free(result);
//     }

//     var found: ?flatpak.InstalledFlatpak = null;
//     for (result) |item| {
//         if (std.mem.eql(u8, item.id(), "it.mijorus.gearlever")) {
//             found = item;
//             break;
//         }
//     }

//     const gearlever = found orelse return error.GearleverNotInUpdateList;
//     try std.testing.expect(gearlever.permissions.len > 0);
// }

// test "test killApp" {
//     const manager = Manager{ .allocator = std.testing.allocator, .io = std.testing.io };

//     const result = try manager.kill_flatpak("it.mijorus.gearlever");
//     try std.testing.expect(result);
// }

// test "test flatpakinstances" {
//     const manager = Manager{ .allocator = std.testing.allocator, .io = std.testing.io };
//     const result = try manager.get_running_instances_flatpak();
//     defer std.testing.allocator.free(result);
//     try std.testing.expect(result.len >= 1);
// }

// test "test installfromref" {
//     const manager = Manager{ .allocator = std.testing.allocator, .io = std.testing.io };
//     const result = try manager.install_from_ref_flatpak("/home/caro/Downloads/org.gimp.GIMP.flatpakref", flatpak.Scope.USER);
//     try std.testing.expect(result);
// }

// TODO: revisit bundles later
// test "test installfrombundle" {
//     const manager = Manager{ .allocator = std.testing.allocator, .io = std.testing.io };
//     const result = try manager.install_from_bundle_flatpak("/home/caro/Downloads/deadlock-mod-manager.flatpak", flatpak.Scope.USER);
//     try std.testing.expect(result);
// }
