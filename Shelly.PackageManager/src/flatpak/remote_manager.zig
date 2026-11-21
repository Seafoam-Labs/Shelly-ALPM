const std = @import("std");
const operation_api = @import("operation_context");
const protocol = @import("Shelly_Flatpak_Protocol");
const HttpClient = @import("ShellyHttp");
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

    // HttpClient advertises gzip, deflate and zstd, so servers such as GitHub
    // Pages compress the .flatpakrepo body.
    const decompress_size: usize = switch (response.head.content_encoding) {
        .identity => 0,
        .zstd => std.compress.zstd.default_window_len,
        .deflate, .gzip => std.compress.flate.max_window_len,
        .compress => return error.UnsupportedCompressionMethod,
    };
    const decompress_buffer = try allocator.alloc(u8, decompress_size);
    defer allocator.free(decompress_buffer);
    var transfer_buffer: [8 * 1024]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(
        &transfer_buffer,
        &decompress,
        decompress_buffer,
    );
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

const GzipFlatpakrepoServer = struct {
    io: std.Io,
    server: std.Io.net.Server,

    // gzip of "[Flatpak Repo]\nTitle=Example\nUrl=https://example.com/repo/\nGPGKey=AAAA\n"
    const body = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0x8b, 0x76,
        0xcb, 0x49, 0x2c, 0x29, 0x48, 0xcc, 0x56, 0x08, 0x4a, 0x2d, 0xc8, 0x8f,
        0xe5, 0x0a, 0xc9, 0x2c, 0xc9, 0x49, 0xb5, 0x75, 0xad, 0x48, 0xcc, 0x2d,
        0xc8, 0x49, 0xe5, 0x0a, 0x2d, 0xca, 0xb1, 0xcd, 0x28, 0x29, 0x29, 0x28,
        0xb6, 0xd2, 0xd7, 0x4f, 0x85, 0x88, 0xe9, 0x25, 0xe7, 0xe7, 0xea, 0x17,
        0x01, 0xd5, 0xea, 0x73, 0xb9, 0x07, 0xb8, 0x7b, 0xa7, 0x56, 0xda, 0x3a,
        0x02, 0x01, 0x17, 0x00, 0x03, 0x97, 0x7a, 0xf5, 0x47, 0x00, 0x00, 0x00,
    };

    fn serve(self: *GzipFlatpakrepoServer) !void {
        var stream = try self.server.accept(self.io);
        defer stream.close(self.io);
        var read_buffer: [4096]u8 = undefined;
        var reader = stream.reader(self.io, &read_buffer);
        while (try reader.interface.takeDelimiter('\n')) |line| {
            if (std.mem.eql(u8, line, "\r")) break;
        }
        var write_buffer: [256]u8 = undefined;
        var writer = stream.writer(self.io, &write_buffer);
        try writer.interface.print(
            "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n" ++
                "Content-Encoding: gzip\r\nContent-Length: {d}\r\n" ++
                "Connection: close\r\n\r\n",
            .{body.len},
        );
        try writer.interface.writeAll(&body);
        try writer.interface.flush();
    }
};

test "flatpakrepo download decodes a gzip-encoded response" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server: GzipFlatpakrepoServer = .{
        .io = io,
        .server = try address.listen(io, .{ .reuse_address = true }),
    };
    defer server.server.deinit(io);
    var server_future = try io.concurrent(GzipFlatpakrepoServer.serve, .{&server});
    defer _ = server_future.cancel(io) catch {};

    const url = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/example.flatpakrepo",
        .{server.server.socket.address.getPort()},
    );
    defer allocator.free(url);
    var config = try downloadParseFlatpakRepo(allocator, io, url, null, null);
    defer config.deinit(allocator);
    try std.testing.expectEqualStrings("https://example.com/repo/", config.url.?);
    try std.testing.expectEqualStrings("AAAA", config.gpg_key.?);
    try std.testing.expectEqual(true, config.gpg_verify.?);
}

test "Flatpak remote operation-hooked public APIs compile" {
    _ = RemoteManager.listRemotesWithDetails;
    _ = RemoteManager.addRemote;
    _ = RemoteManager.removeRemote;
    _ = RemoteManager.highestPriorityRemote;
}
