const bindings = @import("bindings.zig");
const std = @import("std");
const remotes = @import("remote_manager.zig");

const flatpak = bindings.libflatpak;
const rawflatpak = bindings.libflatpak.flatpak;

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn install_flatpak(self: Manager, flatpak_id: [:0]const u8, remote_name: [:0]const u8, scope: flatpak.Scope, branch: [:0]const u8, runtime: bool) !bool {
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

        const arch = std.mem.span(rawflatpak.flatpak_get_default_arch());
        const ref_str = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/{s}/{s}",
            .{ if (runtime) "runtime" else "app", flatpak_id, arch, branch },
        );
        defer self.allocator.free(ref_str);

        const ref_string = try self.allocator.dupeSentinel(u8, ref_str, 0);
        defer self.allocator.free(ref_string);

        const trans_ptr = rawflatpak.flatpak_transaction_new_for_installation(installation, cancellable, &g_error);

        _ = rawflatpak.flatpak_installation_update_remote_sync(installation, remote_name, cancellable, &g_error);

        _ = rawflatpak.flatpak_transaction_add_install(trans_ptr, remote_name, ref_string, null, &g_error);

        //hook up callback
        _ = rawflatpak.g_signal_connect_data(trans_ptr, "new-operation", @ptrCast(&onNewOperation), null, null, 0);
        _ = rawflatpak.g_signal_connect_data(trans_ptr, "ready", @ptrCast(&onReady), null, null, 0);

        const result = rawflatpak.flatpak_transaction_run(trans_ptr, cancellable, &g_error);

        if (g_error) |err| {
            const msg = std.mem.span(err.message);
            std.log.err("flatpak error: {s}", .{msg});
            return error.FlatpakError;
        }

        return result != 0;
    }

    pub fn list_installed_flatpak(self: Manager) ![]flatpak.Flatpak {
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

    pub fn upgrade_flatpaks(self: Manager) !bool {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        const installation_system = rawflatpak.flatpak_installation_new_system(cancellable, &g_error);
        const sys_result = try upgrade_installation(self, installation_system);

        const installation_user = rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        const user_result = try upgrade_installation(self, installation_user);

        return sys_result and user_result;
    }

    pub fn uninstall_flatpak(self: Manager, flatpak_id: [:0]const u8, scope: flatpak.Scope, remove_unused: bool) !bool {
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

        const trans_ptr = rawflatpak.flatpak_transaction_new_for_installation(installation, cancellable, &g_error);

        const flatpak_struct = try get_ref_id_and_installation(self, flatpak_id, installation);

        const ref_string = try flatpak.refToString(self.allocator, flatpak_struct.ptr);
        defer self.allocator.free(ref_string);

        _ = rawflatpak.flatpak_transaction_add_uninstall(trans_ptr, ref_string, &g_error);

        _ = rawflatpak.g_signal_connect_data(trans_ptr, "new-operation", @ptrCast(&onNewOperation), null, null, 0);
        _ = rawflatpak.g_signal_connect_data(trans_ptr, "ready", @ptrCast(&onReady), null, null, 0);

        const result = rawflatpak.flatpak_transaction_run(trans_ptr, cancellable, &g_error);

        if (remove_unused) {
            _ = try removed_unused(self, installation);
        }

        return result != 0;
    }

    pub fn update_flatpak(self: Manager, flatpak_id: [:0]const u8, scope: flatpak.Scope, commit: ?[:0]const u8) !bool {
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

        const trans_ptr = rawflatpak.flatpak_transaction_new_for_installation(installation, cancellable, &g_error);
        const flatpak_struct = try get_ref_id_and_installation(self, flatpak_id, installation);
        const ref_string = try flatpak.refToString(self.allocator, flatpak_struct.ptr);
        defer self.allocator.free(ref_string);

        const commit_c_safe: ?[:0]u8 = if (commit) |c|
            try self.allocator.dupeSentinel(u8, c, 0)
        else
            null;
        defer if (commit_c_safe) |c| self.allocator.free(c);

        const commit_ptr: [*c]const u8 = if (commit_c_safe) |c| c.ptr else null;

        _ = rawflatpak.flatpak_transaction_add_update(trans_ptr, ref_string, null, commit_ptr, &g_error);
        _ = rawflatpak.g_signal_connect_data(trans_ptr, "new-operation", @ptrCast(&onNewOperation), null, null, 0);
        _ = rawflatpak.g_signal_connect_data(trans_ptr, "ready", @ptrCast(&onReady), null, null, 0);

        const result = rawflatpak.flatpak_transaction_run(trans_ptr, cancellable, &g_error);

        return result != 0;
    }

    pub fn launch_flatpak(self: Manager, flatpak_id: [:0]const u8) !bool {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        const installation_system = rawflatpak.flatpak_installation_new_system(cancellable, &g_error);
        const sys_flatpak: ?flatpak.Flatpak = get_ref_id_and_installation(self, flatpak_id, installation_system) catch null;
        if (sys_flatpak) |sf| {
            const result = rawflatpak.flatpak_installation_launch(installation_system, cStr(sf.id()), cStr(sf.arch()), cStr(sf.branch()), null, cancellable, &g_error);
            if (result != 0) {
                return true;
            }
        }

        const installation_user = rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        const user_flatpak: ?flatpak.Flatpak = get_ref_id_and_installation(self, flatpak_id, installation_user) catch null;
        if (user_flatpak) |uf| {
            const result = rawflatpak.flatpak_installation_launch(installation_user, cStr(uf.id()), cStr(uf.arch()), cStr(uf.branch()), null, cancellable, &g_error);
            if (result != 0) {
                return true;
            }
        }

        return false;
    }

    pub fn install_from_ref_flatpak(self: Manager, flatpak_location: [:0]const u8, scope: flatpak.Scope) !bool {
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
        if (installation == null) {
            if (g_error) |e| std.debug.print("failed to create installation: {s}\n", .{e.*.message});
            return error.InstallationCreateFailed;
        }

        const ref_data = try self.readRefBytes(flatpak_location);
        defer self.allocator.free(ref_data);

        const g_bytes_ptr = rawflatpak.g_bytes_new(ref_data.ptr, ref_data.len);
        defer rawflatpak.g_bytes_unref(g_bytes_ptr);

        const trans_ptr = rawflatpak.flatpak_transaction_new_for_installation(installation, cancellable, &g_error);
        if (trans_ptr == null) {
            if (g_error) |e| std.debug.print("failed to create transaction: {s}\n", .{e.*.message});
            return error.TransactionCreateFailed;
        }

        const added = rawflatpak.flatpak_transaction_add_install_flatpakref(trans_ptr, g_bytes_ptr, &g_error);
        if (added == 0) {
            if (g_error) |e| std.debug.print("failed to add flatpakref to transaction: {s}\n", .{e.*.message});
            return error.AddInstallFailed;
        }

        _ = rawflatpak.g_signal_connect_data(trans_ptr, "new-operation", @ptrCast(&onNewOperation), null, null, 0);
        _ = rawflatpak.g_signal_connect_data(trans_ptr, "ready", @ptrCast(&onReady), null, null, 0);

        const result = rawflatpak.flatpak_transaction_run(trans_ptr, cancellable, &g_error);
        if (result == 0) {
            if (g_error) |e| std.debug.print("transaction run failed: {s}\n", .{e.*.message});
            return false;
        }

        return true;
    }

    pub fn install_from_bundle_flatpak(_: Manager, flatpak_location: [:0]const u8, scope: flatpak.Scope) !bool {
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
        if (installation == null) {
            if (g_error) |e| std.debug.print("failed to create installation: {s}\n", .{e.*.message});
            return error.InstallationCreateFailed;
        }

        const file_ptr = rawflatpak.g_file_new_for_path(flatpak_location);

        const trans_ptr = rawflatpak.flatpak_transaction_new_for_installation(installation, cancellable, &g_error);
        if (trans_ptr == null) {
            if (g_error) |e| std.debug.print("failed to create transaction: {s}\n", .{e.*.message});
            return error.TransactionCreateFailed;
        }

        const added = rawflatpak.flatpak_transaction_add_install_bundle(trans_ptr, file_ptr, null, &g_error);
        if (added == 0) {
            if (g_error) |e| std.debug.print("failed to add flatpakref to transaction: {s}\n", .{e.*.message});
            return error.AddInstallFailed;
        }

        _ = rawflatpak.g_signal_connect_data(trans_ptr, "new-operation", @ptrCast(&onNewOperation), null, null, 0);
        _ = rawflatpak.g_signal_connect_data(trans_ptr, "ready", @ptrCast(&onReady), null, null, 0);

        const result = rawflatpak.flatpak_transaction_run(trans_ptr, cancellable, &g_error);
        if (result == 0) {
            if (g_error) |e| std.debug.print("transaction run failed: {s}\n", .{e.*.message});
            return false;
        }

        return true;
    }

    pub fn search_remote_refs_flatpak(self: Manager, query: [:0]const u8) ![]flatpak.Flatpak {
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
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        var list: std.ArrayList(flatpak.Flatpak) = .empty;
        errdefer list.deinit(self.allocator);

        const remote_manager = remotes.RemoteManager{ .allocator = self.allocator, .io = self.io };
        const configured_remotes = try remote_manager.listRemotesWithDetails();
        defer self.allocator.free(configured_remotes);

        //safe guards against calling in with differently named remotes that wont exist
        for (configured_remotes) |remote| {
            if (remote.name()) |name| {
                if (std.mem.eql(u8, name, remote_name) and !remote.disabled() and remote.get_scope() == flatpak.Scope.SYSTEM) {
                    //collect sys
                    const installation_system = rawflatpak.flatpak_installation_new_system(cancellable, &g_error);
                    const sys_result = try get_all_flatpaks_by_remote(self, remote_name, flatpak.Scope.USER, installation_system);
                    defer self.allocator.free(sys_result);
                    try list.appendSlice(self.allocator, sys_result);
                }
            }

            if (remote.name()) |name| {
                if (std.mem.eql(u8, name, remote_name) and !remote.disabled() and remote.get_scope() == flatpak.Scope.USER) {
                    //collect user
                    const installation_user = rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
                    const user_result = try get_all_flatpaks_by_remote(self, remote_name, flatpak.Scope.USER, installation_user);
                    defer self.allocator.free(user_result);
                    try list.appendSlice(self.allocator, user_result);
                }
            }
        }

        return list.toOwnedSlice(self.allocator);
    }

    pub fn get_remote_ref_info_flatpak(self: Manager, remote_name: [:0]const u8, flatpak_name: [:0]const u8, branch: [:0]const u8, scope: flatpak.Scope) !flatpak.RemoteRef {
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

        const remote_ref_ptr = rawflatpak.flatpak_installation_fetch_remote_ref_sync(installation, cStr(remote_name), 0, cStr(flatpak_name), rawflatpak.flatpak_get_default_arch(), cStr(branch), cancellable, &g_error);
        if (remote_ref_ptr == null) {
            if (g_error) |e| std.debug.print("failed to fetch remote ref: {s}\n", .{e.*.message});
            return error.FetchRemoteRefFailed;
        }

        const permissions = try get_permissions_from_remote_ref(self, remote_ref_ptr);
        return flatpak.RemoteRef.new(remote_ref_ptr, scope, permissions);
    }

    pub fn get_updates_flatpak(self: Manager) ![]flatpak.InstalledFlatpak {
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

    pub fn get_running_instances_flatpak(self: Manager) ![]flatpak.InstalledFlatpak {
        var list: std.ArrayList(flatpak.InstalledFlatpak) = .empty;
        errdefer list.deinit(self.allocator);

        const instances_ptr = rawflatpak.flatpak_instance_get_all();
        var j: usize = 0;
        while (j < instances_ptr.*.len) : (j += 1) {
            const raw: *rawflatpak.FlatpakRef = @ptrCast(@alignCast(instances_ptr.*.pdata[j]));
            const flatpak_ref = flatpak.InstalledFlatpak.new(raw, flatpak.Scope.UNKNOWN);
            try list.append(self.allocator, flatpak_ref);
        }

        return list.toOwnedSlice(self.allocator);
    }

    pub fn kill_flatpak(_: Manager, flatpak_id: [:0]const u8) !bool {
        const instances_ptr = rawflatpak.flatpak_instance_get_all();
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
            return error.InvalidPid;
        };

        if (found_pid <= 0) {
            std.log.err("Invalid PID for running instance of {s}.", .{flatpak_id});
            return error.InvalidPid;
        }

        std.posix.kill(found_pid, std.posix.SIG.KILL) catch |err| {
            std.log.err("Failed to kill instance of {s} with PID {d}: {s}", .{ flatpak_id, found_pid, @errorName(err) });
            return err;
        };

        return true;
    }

    fn get_updates_ptr(self: Manager, installation: [*c]rawflatpak.FlatpakInstallation, scope: flatpak.Scope) ![]flatpak.InstalledFlatpak {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

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

    fn get_all_flatpaks_by_remote(self: Manager, remote: [:0]const u8, scope: flatpak.Scope, installation: [*c]rawflatpak.FlatpakInstallation) ![]flatpak.Flatpak {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

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

        const remote_manager = remotes.RemoteManager{ .allocator = self.allocator, .io = self.io };
        const configured_remotes = try remote_manager.listRemotesWithDetails();
        defer self.allocator.free(configured_remotes);

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

    fn get_ref_id_and_installation(_: Manager, flatpak_id: [:0]const u8, installation: [*c]rawflatpak.FlatpakInstallation) !flatpak.Flatpak {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        const ref_ptrs = rawflatpak.flatpak_installation_list_installed_refs(installation, cancellable, &g_error);
        var j: usize = 0;
        while (j < ref_ptrs.*.len) : (j += 1) {
            const raw: *rawflatpak.FlatpakRef = @ptrCast(@alignCast(ref_ptrs.*.pdata[j]));
            const flatpak_struct = flatpak.Flatpak.new(raw, flatpak.Scope.SYSTEM);
            const id = flatpak_struct.id() orelse return error.FlatpakError;
            if (std.mem.eql(u8, id, flatpak_id)) {
                return flatpak_struct;
            }
        }

        return error.FlatpakError;
    }

    fn upgrade_installation(self: Manager, installation: [*c]rawflatpak.FlatpakInstallation) !bool {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        const update_refs_ptr = rawflatpak.flatpak_installation_list_installed_refs_for_update(installation, cancellable, &g_error);
        const trans_ptr = rawflatpak.flatpak_transaction_new_for_installation(installation, cancellable, &g_error);

        var j: usize = 0;
        while (j < update_refs_ptr.*.len) : (j += 1) {
            const raw: *rawflatpak.FlatpakRef = @ptrCast(@alignCast(update_refs_ptr.*.pdata[j]));
            const ref_string = try flatpak.refToString(self.allocator, raw);
            defer self.allocator.free(ref_string);

            _ = rawflatpak.flatpak_transaction_add_update(trans_ptr, ref_string, null, null, &g_error);
        }

        _ = rawflatpak.g_signal_connect_data(trans_ptr, "new-operation", @ptrCast(&onNewOperation), null, null, 0);
        _ = rawflatpak.g_signal_connect_data(trans_ptr, "ready", @ptrCast(&onReady), null, null, 0);

        const result = rawflatpak.flatpak_transaction_run(trans_ptr, cancellable, &g_error);
        return result != 0;
    }

    fn removed_unused_deps(self: Manager) !bool {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        const installation_system = rawflatpak.flatpak_installation_new_system(cancellable, &g_error);
        const sys_result = try removed_unused(self, installation_system);

        const installation_user = rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        const user_result = try removed_unused(self, installation_user);

        return sys_result and user_result;
    }

    fn removed_unused(self: Manager, installation: [*c]rawflatpak.FlatpakInstallation) !bool {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        const arch = std.mem.span(rawflatpak.flatpak_get_default_arch());
        const unused_ref_ptrs = rawflatpak.flatpak_installation_list_unused_refs(installation, arch, cancellable, &g_error);
        const trans_ptr = rawflatpak.flatpak_transaction_new_for_installation(installation, cancellable, &g_error);

        var j: usize = 0;
        while (j < unused_ref_ptrs.*.len) : (j += 1) {
            const raw: *rawflatpak.FlatpakRef = @ptrCast(@alignCast(unused_ref_ptrs.*.pdata[j]));
            const ref_string = try flatpak.refToString(self.allocator, raw);
            defer self.allocator.free(ref_string);
            _ = rawflatpak.flatpak_transaction_add_uninstall(trans_ptr, ref_string, &g_error);
        }

        const result = rawflatpak.flatpak_transaction_run(trans_ptr, cancellable, &g_error);
        return result != 0;
    }

    fn onProgressChanged(
        progress: *rawflatpak.FlatpakTransactionProgress,
        _: ?*anyopaque,
    ) callconv(.c) void {
        const percent = rawflatpak.flatpak_transaction_progress_get_progress(progress);
        std.log.info("progress: {d}%", .{percent});
    }

    fn onNewOperation(
        _: *rawflatpak.FlatpakTransaction,
        _: *rawflatpak.FlatpakTransactionOperation,
        progress: *rawflatpak.FlatpakTransactionProgress,
        _: ?*anyopaque,
    ) callconv(.c) void {
        _ = rawflatpak.g_signal_connect_data(progress, "changed", @ptrCast(&onProgressChanged), null, null, 0);
    }

    fn onReady(
        _: *rawflatpak.FlatpakTransaction,
        _: ?*anyopaque,
    ) callconv(.c) rawflatpak.gboolean {
        return 1;
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
    defer result.deinitPermissions(std.testing.allocator);
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
