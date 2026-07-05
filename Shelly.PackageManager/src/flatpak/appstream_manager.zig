const bindings = @import("bindings.zig");
const std = @import("std");
const remotes = @import("remote_manager.zig");

const flatpak = bindings.libflatpak;
const rawflatpak = bindings.libflatpak.flatpak;

pub const AppstreamManager = struct {
    pub fn updateAllAppstreams(self: AppstreamManager) !void {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        var installation: ?*rawflatpak.FlatpakInstallation = null;
        var remotes_ptrs: ?*rawflatpak.GPtrArray = null;

        installation = rawflatpak.flatpak_installation_new_system(cancellable, &g_error);
        remotes_ptrs = rawflatpak.flatpak_installation_list_remotes(installation, cancellable, &g_error);

        try self.enumerate_appstreams(remotes_ptrs, flatpak.Scope.SYSTEM);

        installation = rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        remotes_ptrs = rawflatpak.flatpak_installation_list_remotes(installation, cancellable, &g_error);

        try self.enumerate_appstreams(remotes_ptrs, flatpak.Scope.USER);
    }

    fn enumerate_appstreams(self: AppstreamManager, remote_ptrs: ?*rawflatpak.GPtrArray, scope: flatpak.Scope) !void {
        if (remote_ptrs) |ptrs| {
            var j: usize = 0;
            while (j < ptrs.len) : (j += 1) {
                const raw: *rawflatpak.FlatpakRemote = @ptrCast(@alignCast(ptrs.pdata[j]));
                const remote = flatpak.Remote.new(raw, scope);
                if (remote.name()) |name| {
                    try self.updateRemoteAppstream(scope, name);
                }
            }
        }
    }

    pub fn updateRemoteAppstream(_: AppstreamManager, scope: flatpak.Scope, remote_name: [:0]const u8) !void {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        const installation = if (scope == .SYSTEM)
            rawflatpak.flatpak_installation_new_system(cancellable, &g_error)
        else
            rawflatpak.flatpak_installation_new_user(cancellable, &g_error);

        const arch = std.mem.span(rawflatpak.flatpak_get_default_arch());
        _ = rawflatpak.flatpak_installation_update_appstream_sync(installation, remote_name, arch, null, cancellable, &g_error);
        if (g_error) |err| {
            std.log.err("appstream update error: {s}", .{std.mem.span(err.message)});
            return error.FlatpakError;
        }
    }
};

test "test updateRemoteAppstream" {
    const manager = AppstreamManager{};
    try manager.updateRemoteAppstream(flatpak.Scope.SYSTEM, "flathub");
}

//test "test updateAllAppstream" {
//  const manager = AppstreamManager{};
//try manager.updateAllAppstreams();
//}
