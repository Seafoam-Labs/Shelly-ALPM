const bindings = @import("bindings.zig");
const std = @import("std");
const events = @import("events.zig");
const operation_api = @import("operation_context");
const HttpClient = @import("../shared/http_client.zig");

const flatpak = bindings.libflatpak;
const rawflatpak = bindings.libflatpak.flatpak;

pub const RemoteManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    operation_context: ?*operation_api.OperationContext = null,
    parent_operation: ?*const operation_api.Operation = null,

    /// Borrows a context for direct remote-management operations.
    pub fn setOperationContext(self: *RemoteManager, context: ?*operation_api.OperationContext) void {
        self.operation_context = context;
    }

    pub fn setParentOperation(self: *RemoteManager, parent: ?*const operation_api.Operation) void {
        self.parent_operation = parent;
        if (parent) |operation| self.operation_context = operation.context;
    }

    pub fn listRemotesWithDetails(self: RemoteManager) ![]flatpak.Remote {
        var scope = events.OperationScope.init(self.operation_context, self.parent_operation, null, .search, null);
        scope.attach();
        defer scope.finish(.success);
        errdefer scope.fail();
        try scope.checkCancelled();
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);
        var cancellation_bridge = try events.CancellationBridge.init(self.operation_context, cancellable);
        defer cancellation_bridge.deinit();

        //TODO: Maybe make a shared function but who cares ill mention bob ross in 3 months after our 4th refactor :)

        var list: std.ArrayList(flatpak.Remote) = .empty;
        errdefer list.deinit(self.allocator);

        {
            const installation = rawflatpak.flatpak_installation_new_system(cancellable, &g_error);
            if (installation == null or g_error != null) return error.FlatpakError;
            defer rawflatpak.g_object_unref(installation);
            const ptr_remotes = rawflatpak.flatpak_installation_list_remotes(installation, cancellable, &g_error);
            if (ptr_remotes == null or g_error != null) return error.FlatpakError;

            var index: usize = 0;
            while (index < ptr_remotes.*.len) : (index += 1) {
                try scope.checkCancelled();
                const raw: *rawflatpak.FlatpakRemote = @ptrCast(@alignCast(ptr_remotes.*.pdata[index]));
                try list.append(self.allocator, flatpak.Remote.new(raw, flatpak.Scope.SYSTEM));
            }
        }

        {
            const installation = rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
            if (installation == null or g_error != null) return error.FlatpakError;
            defer rawflatpak.g_object_unref(installation);
            const ptr_remotes = rawflatpak.flatpak_installation_list_remotes(installation, cancellable, &g_error);
            if (ptr_remotes == null or g_error != null) return error.FlatpakError;

            var index: usize = 0;
            while (index < ptr_remotes.*.len) : (index += 1) {
                try scope.checkCancelled();
                const raw: *rawflatpak.FlatpakRemote = @ptrCast(@alignCast(ptr_remotes.*.pdata[index]));
                try list.append(self.allocator, flatpak.Remote.new(raw, flatpak.Scope.USER));
            }
        }

        scope.status(.success, "Flatpak remotes listed", "flatpak.remotes.listed");
        return list.toOwnedSlice(self.allocator);
    }

    pub fn addRemote(self: RemoteManager, remoteName: [:0]const u8, remoteUrl: [:0]const u8, scope: flatpak.Scope, gpgVerify: bool) !bool {
        var operation_scope = events.OperationScope.init(self.operation_context, self.parent_operation, null, .configure, remoteName);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try operation_scope.checkCancelled();
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);
        var cancellation_bridge = try events.CancellationBridge.init(self.operation_context, cancellable);
        defer cancellation_bridge.deinit();

        var installation: ?*rawflatpak.FlatpakInstallation = null;

        if (scope == flatpak.Scope.SYSTEM) {
            installation = rawflatpak.flatpak_installation_new_system(cancellable, &g_error);
        } else {
            installation = rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        }
        if (installation == null or g_error != null) return error.FlatpakError;
        defer rawflatpak.g_object_unref(installation);

        var actual_url: [:0]const u8 = remoteUrl;
        var actual_gpg_verify: bool = gpgVerify;
        var actual_gpg_key: ?[:0]const u8 = null;

        if (std.ascii.endsWithIgnoreCase(remoteUrl, ".flatpakrepo")) {
            const repo_config = try downloadParseFlatpakRepo(
                self.allocator,
                self.io,
                remoteUrl,
                self.operation_context,
                operation_scope.childParent(),
            );

            actual_url = repo_config.url orelse {
                if (repo_config.gpg_key) |key| self.allocator.free(key);
                return error.FlatpakrepoMissingUrl;
            };
            actual_gpg_verify = repo_config.gpg_verify orelse gpgVerify;
            actual_gpg_key = repo_config.gpg_key;
        }

        defer if (actual_url.ptr != remoteUrl.ptr) self.allocator.free(actual_url);
        defer if (actual_gpg_key) |k| self.allocator.free(k);

        const remote_ptr = rawflatpak.flatpak_remote_new(remoteName);
        if (remote_ptr == null) return error.FlatpakError;
        defer rawflatpak.g_object_unref(remote_ptr);
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
        if (result == 0) operation_scope.finish(.failed);
        return result != 0;
    }

    pub fn removeRemote(self: RemoteManager, remote_name: [:0]const u8, scope: flatpak.Scope) !bool {
        var operation_scope = events.OperationScope.init(self.operation_context, self.parent_operation, null, .configure, remote_name);
        operation_scope.attach();
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try operation_scope.checkCancelled();
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);
        var cancellation_bridge = try events.CancellationBridge.init(self.operation_context, cancellable);
        defer cancellation_bridge.deinit();

        var installation: ?*rawflatpak.FlatpakInstallation = null;

        if (scope == flatpak.Scope.SYSTEM) {
            installation = rawflatpak.flatpak_installation_new_system(cancellable, &g_error);
        } else {
            installation = rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        }
        if (installation == null or g_error != null) return error.FlatpakError;
        defer rawflatpak.g_object_unref(installation);

        const result = rawflatpak.flatpak_installation_remove_remote(installation, remote_name, cancellable, &g_error);
        if (result == 0) operation_scope.finish(.failed);
        return result != 0;
    }

    pub fn highestPriorityRemote(self: RemoteManager) !?flatpak.Remote {
        var scope = events.OperationScope.init(self.operation_context, self.parent_operation, null, .search, null);
        scope.attach();
        defer scope.finish(.success);
        errdefer scope.fail();
        try scope.checkCancelled();
        var nested = self;
        nested.setParentOperation(scope.childParent());
        const remotes = try nested.listRemotesWithDetails();
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

    fn downloadParseFlatpakRepo(
        allocator: std.mem.Allocator,
        io: std.Io,
        url: []const u8,
        operation_context: ?*operation_api.OperationContext,
        parent_operation: ?*const operation_api.Operation,
    ) !flatpak.RepoConfig {
        var operation_scope = DownloadScope.init(operation_context, parent_operation, url);
        defer operation_scope.finish(.success);
        errdefer operation_scope.fail();
        try operation_scope.checkCancelled();
        var client: HttpClient = .{ .allocator = allocator, .io = io };
        defer client.deinit();

        const uri = try std.Uri.parse(url);

        var req = try client.request(.GET, uri, .{});
        defer req.deinit();

        try req.sendBodiless();

        var redirect_buffer: [8 * 1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);
        if (response.head.status.class() != .success) return error.FlatpakrepoHttpStatus;

        var transfer_buffer: [8 * 1024]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(allocator);
        var read_buffer: [16 * 1024]u8 = undefined;
        while (true) {
            try operation_scope.checkCancelled();
            const amount = try reader.readSliceShort(&read_buffer);
            if (amount == 0) break;
            if (body.items.len + amount > 4 * 1024 * 1024) return error.FlatpakrepoTooLarge;
            try body.appendSlice(allocator, read_buffer[0..amount]);
            operation_scope.progress(body.items.len, response.head.content_length);
        }

        var config: flatpak.RepoConfig = .{};

        var lines = std.mem.splitScalar(u8, body.items, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '[' or trimmed[0] == '#') continue;

            const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
            const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            const value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

            if (std.mem.eql(u8, key, "Url")) {
                config.url = try allocator.dupeSentinel(u8, value, 0);
            } else if (std.mem.eql(u8, key, "GPGVerify")) {
                config.gpg_verify = std.ascii.eqlIgnoreCase(value, "true");
            } else if (std.mem.eql(u8, key, "GPGKey")) {
                config.gpg_key = try allocator.dupeSentinel(u8, value, 0);
            }
        }

        if (config.gpg_key != null and config.gpg_verify == null) {
            config.gpg_verify = true;
        }

        return config;
    }
};

const DownloadScope = struct {
    operation: ?operation_api.Operation = null,

    fn init(
        context: ?*operation_api.OperationContext,
        parent: ?*const operation_api.Operation,
        subject: []const u8,
    ) DownloadScope {
        if (parent) |active_parent| return .{ .operation = active_parent.child(.{
            .backend = .download,
            .kind = .download,
            .subject = subject,
        }) };
        if (context) |operation_context| return .{ .operation = operation_context.begin(.{
            .backend = .download,
            .kind = .download,
            .subject = subject,
        }) };
        return .{};
    }

    fn checkCancelled(self: *const DownloadScope) error{Cancelled}!void {
        if (self.operation) |*operation| try operation.checkCancelled();
    }

    fn progress(self: *const DownloadScope, completed: usize, total: ?u64) void {
        if (self.operation) |*operation| operation.progress(.{
            .stage = "flatpakrepo",
            .completed = @intCast(completed),
            .total = total,
            .percentage = if (total) |value| if (value == 0) 100 else @as(f64, @floatFromInt(completed)) * 100.0 / @as(f64, @floatFromInt(value)) else null,
            .bytes_completed = @intCast(completed),
            .bytes_total = total,
        });
    }

    fn fail(self: *DownloadScope) void {
        if (self.operation) |*operation| operation.reportError(
            if (operation.isCancelled()) error.Cancelled else error.FlatpakrepoDownloadFailed,
            if (operation.isCancelled()) "Flatpak repository download cancelled" else "Flatpak repository download failed",
            "download",
            null,
            false,
        );
        self.finish(if (self.operation) |*operation| if (operation.isCancelled()) .cancelled else .failed else .failed);
    }

    fn finish(self: *DownloadScope, status: operation_api.CompletionStatus) void {
        if (self.operation) |*operation| operation.finish(status);
    }
};

test "Flatpak remote operations honor shared cancellation" {
    var context = operation_api.OperationContext.init(std.testing.allocator, std.testing.io);
    defer context.deinit();
    var manager = RemoteManager{ .allocator = std.testing.allocator, .io = std.testing.io };
    manager.setOperationContext(&context);

    context.cancel();
    try std.testing.expectError(error.Cancelled, manager.listRemotesWithDetails());
}

test "Flatpak remote operation-hooked public APIs compile" {
    var run = false;
    std.mem.doNotOptimizeAway(&run);
    if (!run) return;

    const manager = RemoteManager{ .allocator = std.testing.allocator, .io = std.testing.io };
    _ = try manager.listRemotesWithDetails();
    _ = try manager.addRemote("example", "https://example.invalid/example.flatpakrepo", .USER, true);
    _ = try manager.removeRemote("example", .USER);
    _ = try manager.highestPriorityRemote();
}

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
        null,
        null,
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
