const bindings = @import("bindings.zig");
const std = @import("std");

const flatpak = bindings.libflatpak;
const rawflatpak = bindings.libflatpak.flatpak;

pub const RemoteManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn listRemotesWithDetails(self: RemoteManager) ![]flatpak.Remote {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        //TODO: Maybe make a shared function but who cares ill mention bob ross in 3 months after our 4th refactor :)

        var list: std.ArrayList(flatpak.Remote) = .empty;
        errdefer list.deinit(self.allocator);

        const system_installation = rawflatpak.flatpak_installation_new_system(cancellable, &g_error);
        if (g_error != null) return error.FlatpakError;

        var ptr_remotes = rawflatpak.flatpak_installation_list_remotes(system_installation, cancellable, &g_error);

        if (g_error != null) return error.FlatpakError;

        var j: usize = 0;
        while (j < ptr_remotes.*.len) : (j += 1) {
            const raw: *rawflatpak.FlatpakRemote = @ptrCast(@alignCast(ptr_remotes.*.pdata[j]));
            try list.append(self.allocator, flatpak.Remote.new(raw, flatpak.Scope.SYSTEM));
        }

        const user_installation = rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        if (g_error != null) return error.FlatpakError;

        ptr_remotes = rawflatpak.flatpak_installation_list_remotes(user_installation, cancellable, &g_error);
        if (g_error != null) return error.FlatpakError;

        j = 0;
        while (j < ptr_remotes.*.len) : (j += 1) {
            const raw: *rawflatpak.FlatpakRemote = @ptrCast(@alignCast(ptr_remotes.*.pdata[j]));
            try list.append(self.allocator, flatpak.Remote.new(raw, flatpak.Scope.USER));
        }

        return list.toOwnedSlice(self.allocator);
    }

    pub fn addRemote(self: RemoteManager, remoteName: [:0]const u8, remoteUrl: [:0]const u8, scope: flatpak.Scope, gpgVerify: bool) !bool {
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

        var actual_url: [:0]const u8 = remoteUrl;
        var actual_gpg_verify: bool = gpgVerify;
        var actual_gpg_key: ?[:0]const u8 = null;

        if (std.ascii.endsWithIgnoreCase(remoteUrl, ".flatpakrepo")) {
            const repo_config = try downloadParseFlatpakRepo(self.allocator, self.io, remoteUrl);

            actual_url = repo_config.url orelse return error.FlatpakrepoMissingUrl;
            actual_gpg_verify = repo_config.gpg_verify orelse gpgVerify;
            actual_gpg_key = repo_config.gpg_key;
        }

        defer if (actual_url.ptr != remoteUrl.ptr) self.allocator.free(actual_url);
        defer if (actual_gpg_key) |k| self.allocator.free(k);

        const remote_ptr = rawflatpak.flatpak_remote_new(remoteName);
        rawflatpak.flatpak_remote_set_url(remote_ptr, actual_url);
        rawflatpak.flatpak_remote_set_gpg_verify(remote_ptr, @intFromBool(actual_gpg_verify));

        if (actual_gpg_key) |gpg_key| {
            const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(gpg_key);
            const decoded_key = try self.allocator.alloc(u8, decoded_len);
            defer self.allocator.free(decoded_key);
            try std.base64.standard.Decoder.decode(decoded_key, gpg_key);
            const g_bytes_ptr = rawflatpak.g_bytes_new(@ptrCast(decoded_key.ptr), decoded_key.len);

            if (g_bytes_ptr != null) {
                rawflatpak.flatpak_remote_set_gpg_key(remote_ptr, g_bytes_ptr);
                defer rawflatpak.g_bytes_unref(g_bytes_ptr);
            }
        }

        const result = rawflatpak.flatpak_installation_add_remote(installation, remote_ptr, 1, cancellable, &g_error);
        return result != 0;
    }

    pub fn removeRemote(_: RemoteManager, remote_name: [:0]const u8, scope: flatpak.Scope) !bool {
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

        const result = rawflatpak.flatpak_installation_remove_remote(installation, remote_name, cancellable, &g_error);
        return result != 0;
    }

    pub fn highestPriorityRemote(self: RemoteManager) !?flatpak.Remote {
        const remotes = try self.listRemotesWithDetails();
        defer self.allocator.free(remotes);

        if (remotes.len == 0) return null;

        var best = remotes[0];
        for (remotes[1..]) |remote| {
            if (remote.priority() > best.priority()) {
                best = remote;
            }
        }

        return best;
    }

    fn downloadParseFlatpakRepo(allocator: std.mem.Allocator, io: std.Io, url: []const u8) !flatpak.RepoConfig {
        var client: std.http.Client = .{ .allocator = allocator, .io = io };
        defer client.deinit();

        const uri = try std.Uri.parse(url);

        var req = try client.request(.GET, uri, .{});
        defer req.deinit();

        try req.sendBodiless();

        var redirect_buffer: [8 * 1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        const body = try response.reader(&.{}).allocRemaining(allocator, .unlimited);
        defer allocator.free(body);

        var config: flatpak.RepoConfig = .{};

        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '[' or trimmed[0] == '#') continue;

            const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
            const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            const value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

            if (std.mem.eql(u8, key, "Url")) {
                config.url = try allocator.dupeZ(u8, value);
            } else if (std.mem.eql(u8, key, "GPGVerify")) {
                config.gpg_verify = std.ascii.eqlIgnoreCase(value, "true");
            } else if (std.mem.eql(u8, key, "GPGKey")) {
                config.gpg_key = try allocator.dupeZ(u8, value);
            }
        }

        if (config.gpg_key != null and config.gpg_verify == null) {
            config.gpg_verify = true;
        }

        return config;
    }
};

test "test listRemotesWithDetails" {
    const manager = RemoteManager{ .allocator = std.testing.allocator, .io = std.testing.io };
    const x = try manager.listRemotesWithDetails();
    defer std.testing.allocator.free(x);
    try std.testing.expectEqualStrings("flathub", x[0].name().?);
    //try std.testing.expectEqualStrings("flathub-user", x[1].name().?); //commented out because user level is not default
}

test "test download_parse_flatpak_repo" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const config = try RemoteManager.downloadParseFlatpakRepo(
        alloc,
        io,
        "https://dl.flathub.org/repo/flathub.flatpakrepo",
    );
    defer {
        if (config.url) |u| alloc.free(u);
        if (config.gpg_key) |k| alloc.free(k);
    }

    try std.testing.expectEqualStrings("https://dl.flathub.org/repo/", config.url.?);
    try std.testing.expect(config.gpg_verify.? == true);
    try std.testing.expect(config.gpg_key != null);
    try std.testing.expect(config.gpg_key.?.len > 0);
}

test "test addRemote" {
    const manager = RemoteManager{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try manager.addRemote("flathub-test", "https://dl.flathub.org/repo/flathub.flatpakrepo", flatpak.Scope.USER, true);
    try std.testing.expect(result);
}

test "test removeRemote" {
    const manager = RemoteManager{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try manager.removeRemote("flathub-test", flatpak.Scope.USER);
    try std.testing.expect(result);
}

test "test highestPriorityRemote" {
    const manager = RemoteManager{ .allocator = std.testing.allocator, .io = std.testing.io };
    const remote = try manager.highestPriorityRemote();
    try std.testing.expect(remote != null);
    try std.testing.expect(remote.?.name() != null);
    try std.testing.expect(remote.?.priority() >= 0);
}
