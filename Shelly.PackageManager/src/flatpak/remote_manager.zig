const std = @import("std");
const operation_api = @import("operation_context");
const protocol = @import("Shelly_Flatpak_Protocol");
const HttpClient = @import("../shared/http_client.zig");
const types = @import("types.zig");
const events = @import("events.zig");
const client_api = @import("client.zig");

const wire = protocol.wire;

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

    pub fn listRemotesWithDetails(
        self: RemoteManager,
    ) ![]types.Remote {
        var parsed = try self.call(
            []wire.Remote,
            wire.Method.list_remotes,
            wire.EmptyArguments{},
            .search,
            null,
        );
        defer parsed.deinit();
        const result = try self.allocator.alloc(
            types.Remote,
            parsed.value.len,
        );
        var initialized: usize = 0;
        errdefer {
            for (result[0..initialized]) |*remote|
                remote.deinit(self.allocator);
            self.allocator.free(result);
        }
        for (parsed.value, result) |value, *output| {
            output.* = try types.Remote.fromWire(
                self.allocator,
                value,
            );
            initialized += 1;
        }
        return result;
    }

    pub fn addRemote(
        self: RemoteManager,
        remote_name: []const u8,
        remote_url: []const u8,
        scope: types.Scope,
        gpg_verify: bool,
    ) !bool {
        var config: RepoConfig = .{};
        defer config.deinit(self.allocator);
        if (std.ascii.endsWithIgnoreCase(
            remote_url,
            ".flatpakrepo",
        )) {
            config = try downloadParseFlatpakRepo(
                self.allocator,
                self.io,
                remote_url,
                self.operation_context,
                self.parent_operation,
            );
        }
        const url = config.url orelse remote_url;
        const verified = config.gpg_verify orelse gpg_verify;
        var parsed = try self.call(
            wire.BoolResult,
            wire.Method.add_remote,
            wire.AddRemoteArguments{
                .name = remote_name,
                .url = url,
                .scope = scope.toWire(),
                .gpg_verify = verified,
                .gpg_key = config.gpg_key,
            },
            .configure,
            remote_name,
        );
        defer parsed.deinit();
        return parsed.value.value;
    }

    pub fn removeRemote(
        self: RemoteManager,
        remote_name: []const u8,
        scope: types.Scope,
    ) !bool {
        var parsed = try self.call(
            wire.BoolResult,
            wire.Method.remove_remote,
            wire.RemoteMutationArguments{
                .name = remote_name,
                .scope = scope.toWire(),
            },
            .configure,
            remote_name,
        );
        defer parsed.deinit();
        return parsed.value.value;
    }

    pub fn highestPriorityRemote(
        self: RemoteManager,
    ) !?types.Remote {
        var parsed = try self.call(
            ?wire.Remote,
            wire.Method.highest_priority_remote,
            wire.EmptyArguments{},
            .search,
            null,
        );
        defer parsed.deinit();
        return if (parsed.value) |value|
            try types.Remote.fromWire(self.allocator, value)
        else
            null;
    }

    fn call(
        self: RemoteManager,
        comptime T: type,
        method: []const u8,
        arguments: anytype,
        kind: operation_api.OperationKind,
        subject: ?[]const u8,
    ) !std.json.Parsed(T) {
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
        return (client_api.Client{
            .allocator = self.allocator,
        }).call(T, method, arguments, .{
            .operation = if (scope.operation) |*operation|
                operation
            else
                null,
            .context = self.operation_context,
            .failure_reported = &scope.failure_reported,
        });
    }
};

const RepoConfig = struct {
    url: ?[]u8 = null,
    gpg_verify: ?bool = null,
    gpg_key: ?[]u8 = null,

    fn deinit(self: *RepoConfig, allocator: std.mem.Allocator) void {
        if (self.url) |value| allocator.free(value);
        if (self.gpg_key) |value| allocator.free(value);
        self.* = .{};
    }
};

fn downloadParseFlatpakRepo(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    operation_context: ?*operation_api.OperationContext,
    parent_operation: ?*const operation_api.Operation,
) !RepoConfig {
    var scope = events.OperationScope.init(
        operation_context,
        parent_operation,
        null,
        .download,
        url,
    );
    scope.attach();
    defer scope.finish(.success);
    errdefer scope.fail();
    try scope.checkCancelled();

    var client: HttpClient = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    var request = try client.request(.GET, try std.Uri.parse(url), .{});
    defer request.deinit();
    try request.sendBodiless();
    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    if (response.head.status.class() != .success)
        return error.FlatpakrepoHttpStatus;

    var transfer_buffer: [8 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    var read_buffer: [16 * 1024]u8 = undefined;
    while (true) {
        try scope.checkCancelled();
        const amount = try reader.readSliceShort(&read_buffer);
        if (amount == 0) break;
        if (body.items.len + amount > 4 * 1024 * 1024)
            return error.FlatpakrepoTooLarge;
        try body.appendSlice(allocator, read_buffer[0..amount]);
        if (scope.operation) |*operation| operation.progress(.{
            .stage = "flatpakrepo",
            .completed = @intCast(body.items.len),
            .total = response.head.content_length,
            .bytes_completed = @intCast(body.items.len),
            .bytes_total = response.head.content_length,
        });
    }

    var config: RepoConfig = .{};
    errdefer config.deinit(allocator);
    var lines = std.mem.splitScalar(u8, body.items, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or
            trimmed[0] == '[' or
            trimmed[0] == '#')
            continue;
        const separator = std.mem.indexOfScalar(
            u8,
            trimmed,
            '=',
        ) orelse continue;
        const key = std.mem.trim(u8, trimmed[0..separator], " \t");
        const value = std.mem.trim(
            u8,
            trimmed[separator + 1 ..],
            " \t",
        );
        if (std.mem.eql(u8, key, "Url")) {
            if (config.url) |old| allocator.free(old);
            config.url = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "GPGVerify")) {
            config.gpg_verify = std.ascii.eqlIgnoreCase(value, "true");
        } else if (std.mem.eql(u8, key, "GPGKey")) {
            if (config.gpg_key) |old| allocator.free(old);
            config.gpg_key = try allocator.dupe(u8, value);
        }
    }
    if (config.url == null) return error.FlatpakrepoMissingUrl;
    if (config.gpg_key != null and config.gpg_verify == null)
        config.gpg_verify = true;
    return config;
}

test "Flatpak remote operation-hooked public APIs compile" {
    _ = RemoteManager.listRemotesWithDetails;
    _ = RemoteManager.addRemote;
    _ = RemoteManager.removeRemote;
    _ = RemoteManager.highestPriorityRemote;
}
