const std = @import("std");

pub const wire = @import("wire.zig");
pub const abi_version: u32 = 1;

pub const Status = enum(i32) {
    success = 0,
    invalid_argument = 1,
    incompatible = 2,
    unavailable = 3,
    cancelled = 4,
    internal_error = 5,
};

pub const RequestBuffer = extern struct {
    ptr: [*]const u8,
    len: usize,

    pub fn slice(self: RequestBuffer) []const u8 {
        return self.ptr[0..self.len];
    }
};

pub const ResponseBuffer = extern struct {
    ptr: ?[*]u8 = null,
    len: usize = 0,

    pub fn slice(self: ResponseBuffer) []u8 {
        const ptr = self.ptr orelse return &.{};
        return ptr[0..self.len];
    }
};

pub const EventBuffer = extern struct {
    ptr: [*]const u8,
    len: usize,

    pub fn slice(self: EventBuffer) []const u8 {
        return self.ptr[0..self.len];
    }
};

pub const HostApiV1 = extern struct {
    struct_size: usize,
    abi_version: u32,
    user_data: ?*anyopaque,
    emit_event: ?*const fn (?*anyopaque, EventBuffer) callconv(.c) void,
};

pub const BackendApiV1 = extern struct {
    struct_size: usize,
    abi_version: u32,
    create: ?*const fn (*const HostApiV1, *?*anyopaque) callconv(.c) Status,
    destroy: ?*const fn (?*anyopaque) callconv(.c) void,
    execute: ?*const fn (
        ?*anyopaque,
        RequestBuffer,
        *ResponseBuffer,
    ) callconv(.c) Status,
    cancel: ?*const fn (?*anyopaque, u64) callconv(.c) Status,
    free_response: ?*const fn (?*anyopaque, ResponseBuffer) callconv(.c) void,
};

pub const GetApiFn = *const fn (
    u32,
    *const HostApiV1,
    *BackendApiV1,
) callconv(.c) Status;

pub const get_api_symbol: [:0]const u8 = "shelly_flatpak_backend_get_api";

pub fn hostApiValid(host: *const HostApiV1) bool {
    return host.struct_size >= @sizeOf(HostApiV1) and
        host.abi_version == abi_version and
        host.emit_event != null;
}

pub fn backendApiValid(api: *const BackendApiV1) bool {
    return api.struct_size >= @sizeOf(BackendApiV1) and
        api.abi_version == abi_version and
        api.create != null and
        api.destroy != null and
        api.execute != null and
        api.cancel != null and
        api.free_response != null;
}

pub fn parseRequest(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !std.json.Parsed(wire.RequestEnvelope) {
    if (bytes.len == 0 or bytes.len > wire.max_message_size)
        return error.InvalidMessageSize;
    const parsed = try std.json.parseFromSlice(
        wire.RequestEnvelope,
        allocator,
        bytes,
        .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
            .ignore_unknown_fields = false,
            .max_value_len = wire.max_message_size,
        },
    );
    errdefer parsed.deinit();
    if (parsed.value.schema != wire.schema_version)
        return error.UnsupportedSchema;
    if (parsed.value.method.len == 0)
        return error.MissingMethod;
    return parsed;
}

pub fn parseArguments(
    comptime T: type,
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !std.json.Parsed(T) {
    const encoded = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(encoded);
    return std.json.parseFromSlice(
        T,
        allocator,
        encoded,
        .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
            .ignore_unknown_fields = false,
            .max_value_len = wire.max_message_size,
        },
    );
}

/// Schema v2 is deliberately strict: unknown fields are rejected rather than
/// silently changing the meaning of a message. Additive fields require a new
/// schema version (or an explicitly optional field in this schema).
pub fn parseResponse(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !std.json.Parsed(wire.ResponseHeader) {
    if (bytes.len == 0 or bytes.len > wire.max_message_size)
        return error.InvalidMessageSize;
    const parsed = try std.json.parseFromSlice(
        wire.ResponseHeader,
        allocator,
        bytes,
        .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
            .ignore_unknown_fields = false,
            .max_value_len = wire.max_message_size,
        },
    );
    errdefer parsed.deinit();
    if (parsed.value.schema != wire.schema_version)
        return error.UnsupportedSchema;
    if ((parsed.value.result == null) == (parsed.value.@"error" == null))
        return error.InvalidResponseShape;
    if (parsed.value.@"error") |backend_error| {
        if (backend_error.code.len == 0 or backend_error.message.len == 0)
            return error.InvalidResponseShape;
    }
    return parsed;
}

pub fn parseEvent(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !std.json.Parsed(wire.EventEnvelope) {
    if (bytes.len == 0 or bytes.len > wire.max_message_size)
        return error.InvalidMessageSize;
    const parsed = try std.json.parseFromSlice(
        wire.EventEnvelope,
        allocator,
        bytes,
        .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
            .ignore_unknown_fields = false,
            .max_value_len = wire.max_message_size,
        },
    );
    errdefer parsed.deinit();
    if (parsed.value.schema != wire.schema_version)
        return error.UnsupportedSchema;
    if (parsed.value.code.len == 0 or parsed.value.message.len == 0)
        return error.InvalidEvent;
    return parsed;
}

test "ABI tables use C-compatible data-only fields" {
    try std.testing.expect(@sizeOf(HostApiV1) >=
        @sizeOf(usize) + @sizeOf(u32) + 2 * @sizeOf(usize));
    try std.testing.expect(@sizeOf(BackendApiV1) >=
        @sizeOf(usize) + @sizeOf(u32) + 5 * @sizeOf(usize));
}

test "request parser accepts schema two and rejects incompatible schemas" {
    var request = try parseRequest(
        std.testing.allocator,
        "{\"schema\":2,\"operation_id\":42,\"method\":\"list_installed\",\"arguments\":{}}",
    );
    defer request.deinit();
    try std.testing.expectEqual(@as(u64, 42), request.value.operation_id);

    try std.testing.expectError(
        error.UnsupportedSchema,
        parseRequest(
            std.testing.allocator,
            "{\"schema\":1,\"operation_id\":42,\"method\":\"list_installed\",\"arguments\":{}}",
        ),
    );
}

test "request parser rejects duplicates, missing fields, and oversized messages" {
    try std.testing.expectError(
        error.DuplicateField,
        parseRequest(
            std.testing.allocator,
            "{\"schema\":2,\"schema\":2,\"operation_id\":1,\"method\":\"list_installed\",\"arguments\":{}}",
        ),
    );
    try std.testing.expectError(
        error.MissingField,
        parseRequest(
            std.testing.allocator,
            "{\"schema\":2,\"operation_id\":1,\"arguments\":{}}",
        ),
    );
    const oversized = try std.testing.allocator.alloc(u8, wire.max_message_size + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(
        error.InvalidMessageSize,
        parseRequest(std.testing.allocator, oversized),
    );
}

test "argument parser rejects invalid enums and unknown fields" {
    var request = try parseRequest(
        std.testing.allocator,
        "{\"schema\":2,\"operation_id\":3,\"method\":\"install\",\"arguments\":{\"id\":\"org.example.App\",\"remote\":\"flathub\",\"scope\":\"system\",\"branch\":\"stable\"}}",
    );
    defer request.deinit();
    var arguments = try parseArguments(wire.InstallArguments, std.testing.allocator, request.value.arguments);
    defer arguments.deinit();
    try std.testing.expectEqual(wire.Scope.system, arguments.value.scope);

    var invalid = try parseRequest(
        std.testing.allocator,
        "{\"schema\":2,\"operation_id\":3,\"method\":\"install\",\"arguments\":{\"id\":\"org.example.App\",\"remote\":\"flathub\",\"scope\":\"machine\",\"branch\":\"stable\"}}",
    );
    defer invalid.deinit();
    try std.testing.expectError(
        error.InvalidEnumTag,
        parseArguments(wire.InstallArguments, std.testing.allocator, invalid.value.arguments),
    );

    var unknown = try parseRequest(
        std.testing.allocator,
        "{\"schema\":2,\"operation_id\":3,\"method\":\"install\",\"arguments\":{\"id\":\"org.example.App\",\"remote\":\"flathub\",\"scope\":\"system\",\"branch\":\"stable\",\"future\":true}}",
    );
    defer unknown.deinit();
    try std.testing.expectError(
        error.UnknownField,
        parseArguments(wire.InstallArguments, std.testing.allocator, unknown.value.arguments),
    );
}

fn expectRoundTrip(comptime T: type, value: T) !void {
    const encoded = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        value,
        .{},
    );
    defer std.testing.allocator.free(encoded);
    var parsed = try std.json.parseFromSlice(
        T,
        std.testing.allocator,
        encoded,
        .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
            .ignore_unknown_fields = false,
        },
    );
    defer parsed.deinit();
    const reencoded = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        parsed.value,
        .{},
    );
    defer std.testing.allocator.free(reencoded);
    try std.testing.expectEqualStrings(encoded, reencoded);
}

test "all request argument families round-trip under schema one" {
    try expectRoundTrip(wire.EmptyArguments, .{});
    try expectRoundTrip(wire.InstallArguments, .{
        .id = "org.example.App",
        .remote = "flathub",
        .scope = .system,
        .branch = "stable",
    });
    try expectRoundTrip(wire.InstallFileArguments, .{
        .path = "/tmp/example.flatpakref",
        .scope = .user,
    });
    try expectRoundTrip(wire.UpdateInstalledArguments, .{
        .name_or_id = "org.example.App",
        .scope = .system,
        .commit = "abc",
    });
    try expectRoundTrip(wire.UninstallInstalledArguments, .{
        .name_or_id = "org.example.App",
        .scope = .user,
        .remove_unused = true,
    });
    try expectRoundTrip(wire.NameArguments, .{ .name_or_id = "org.example.App" });
    try expectRoundTrip(wire.QueryArguments, .{ .query = "example" });
    try expectRoundTrip(wire.ScopeArguments, .{ .scope = .system });
    try expectRoundTrip(wire.RemoteNameArguments, .{ .remote = "flathub" });
    try expectRoundTrip(wire.RemoteMutationArguments, .{
        .name = "flathub",
        .scope = .user,
    });
    try expectRoundTrip(wire.AddRemoteArguments, .{
        .name = "flathub",
        .url = "https://dl.flathub.org/repo/",
        .scope = .system,
        .gpg_key = "key",
    });
    try expectRoundTrip(wire.RemoteRefArguments, .{
        .remote = "flathub",
        .name = "org.example.App",
        .branch = "stable",
        .scope = .system,
    });
    try expectRoundTrip(wire.CatalogArguments, .{
        .remote = "flathub",
        .arch = "x86_64",
    });
    try expectRoundTrip(wire.CatalogsArguments, .{ .arch = "x86_64" });
    try expectRoundTrip(wire.UpdateAppstreamArguments, .{
        .scope = .user,
        .remote = "flathub",
    });
    try expectRoundTrip(wire.LoadCatalogArguments, .{
        .remote = "flathub",
        .scope = .system,
        .arch = "x86_64",
        .path = "/var/lib/flatpak/appstream/flathub/x86_64/active/appstream.xml.gz",
    });
    try expectRoundTrip(wire.ListInstalledArguments, .{ .mode = .refs });
    try expectRoundTrip(wire.RebaseArguments, .{
        .old_ref = "app/dev.bragefuglseth.Keypunch/x86_64/stable",
        .new_ref = "app/no.bragefuglseth.Keypunch/x86_64/stable",
        .remote = "flathub",
        .scope = .system,
    });
    try expectRoundTrip(wire.RebaseArguments, .{
        .old_ref = "app/dev.bragefuglseth.Keypunch/x86_64/stable",
        .new_ref = "app/no.bragefuglseth.Keypunch/x86_64/stable",
        .remote = "flathub",
        .scope = .system,
        .previous_ids = &.{"dev.bragefuglseth.Keypunch"},
    });
}

test "backend-neutral result records round-trip without native pointers" {
    try expectRoundTrip(wire.InstalledApplication, .{
        .id = "org.example.App",
        .name = "Example",
        .arch = "x86_64",
        .branch = "stable",
        .summary = "Example app",
        .version = "1.0",
        .latest_commit = "abc",
        .origin = "flathub",
        .kind = .app,
        .installed_size = 42,
        .scope = .user,
    });
    try expectRoundTrip(wire.InstalledApplication, .{
        .id = "dev.bragefuglseth.Keypunch",
        .name = "Keypunch",
        .arch = "x86_64",
        .branch = "stable",
        .summary = "Practice typing",
        .version = "1.0",
        .latest_commit = "deadbeef",
        .origin = "flathub",
        .kind = .app,
        .installed_size = 1024,
        .scope = .system,
        .eol = "Deprecated, please use the new ID.",
        .eol_rebase = "no.bragefuglseth.Keypunch",
    });
    try expectRoundTrip(wire.InstalledRef, .{
        .id = "org.example.App",
        .name = "Example",
        .arch = "x86_64",
        .branch = "stable",
        .reference = "app/org.example.App/x86_64/stable",
        .origin = "flathub",
        .version = "1.0",
        .summary = "Example app",
        .latest_commit = "abc",
        .installed_size = 42,
        .kind = .app,
        .scope = .system,
        .permissions = &.{ "network", "wayland" },
        .eol = "Deprecated.",
        .eol_rebase = "org.example.NewApp",
    });
    try expectRoundTrip(wire.EolStatus, .{
        .reference = "app/dev.bragefuglseth.Keypunch/x86_64/stable",
        .id = "dev.bragefuglseth.Keypunch",
        .branch = "stable",
        .origin = "flathub",
        .scope = .system,
        .eol = "Deprecated.",
        .eol_rebase = "no.bragefuglseth.Keypunch",
    });
    try expectRoundTrip(wire.EolStatus, .{
        .reference = "app/org.example.Dead/x86_64/stable",
        .id = "org.example.Dead",
        .branch = "stable",
        .origin = "flathub",
        .scope = .user,
        .eol = "No longer maintained.",
    });
    try expectRoundTrip(wire.Remote, .{
        .name = "flathub",
        .url = "https://dl.flathub.org/repo/",
        .priority = 1,
        .scope = .system,
        .gpg_verify = true,
        .nodeps = false,
        .noenumerate = false,
        .remote_type = 0,
        .disabled = false,
    });
    try expectRoundTrip(wire.RunningInstance, .{
        .instance_id = "instance",
        .application_id = "org.example.App",
        .arch = "x86_64",
        .branch = "stable",
        .pid = 10,
        .child_pid = 11,
    });
    try expectRoundTrip(wire.CatalogLocation, .{
        .remote = "flathub",
        .scope = .system,
        .arch = "x86_64",
        .path = "/catalog.xml.gz",
    });
}

test "response and event parsers reject malformed truncated oversized and ambiguous messages" {
    var success = try parseResponse(
        std.testing.allocator,
        "{\"schema\":2,\"operation_id\":9,\"result\":{\"value\":true}}",
    );
    defer success.deinit();
    try std.testing.expectEqual(@as(u64, 9), success.value.operation_id);

    var failure = try parseResponse(
        std.testing.allocator,
        "{\"schema\":2,\"operation_id\":9,\"error\":{\"code\":\"flatpak.failed\",\"message\":\"failed\",\"native_code\":7}}",
    );
    defer failure.deinit();
    try std.testing.expectEqualStrings(
        "flatpak.failed",
        failure.value.@"error".?.code,
    );

    try std.testing.expectError(
        error.InvalidResponseShape,
        parseResponse(
            std.testing.allocator,
            "{\"schema\":2,\"operation_id\":9}",
        ),
    );
    try std.testing.expectError(
        error.InvalidResponseShape,
        parseResponse(
            std.testing.allocator,
            "{\"schema\":2,\"operation_id\":9,\"result\":{},\"error\":{\"code\":\"x\",\"message\":\"x\"}}",
        ),
    );
    try std.testing.expectError(
        error.InvalidResponseShape,
        parseResponse(
            std.testing.allocator,
            "{\"schema\":2,\"operation_id\":9,\"error\":{\"code\":\"\",\"message\":\"failed\"}}",
        ),
    );
    if (parseResponse(std.testing.allocator, "{\"schema\":2")) |parsed| {
        parsed.deinit();
        return error.TestExpectedTruncatedResponse;
    } else |_| {}
    if (parseResponse(
        std.testing.allocator,
        "{\"schema\":2,\"operation_id\":9,\"result\":{},\"future\":true}",
    )) |parsed| {
        parsed.deinit();
        return error.TestExpectedUnknownResponseField;
    } else |_| {}

    var event = try parseEvent(
        std.testing.allocator,
        "{\"schema\":2,\"operation_id\":9,\"kind\":\"progress\",\"code\":\"flatpak.progress\",\"message\":\"Downloading org.example.App\",\"stage\":\"Downloading\",\"subject\":\"runtime/org.example.App/x86_64/stable\",\"percentage\":50}",
    );
    defer event.deinit();
    try std.testing.expectEqual(wire.EventKind.progress, event.value.kind);
    try std.testing.expectEqualStrings("Downloading", event.value.stage.?);
    try std.testing.expectEqualStrings(
        "runtime/org.example.App/x86_64/stable",
        event.value.subject.?,
    );

    if (parseEvent(
        std.testing.allocator,
        "{\"operation_id\":9,\"kind\":\"status\",\"code\":\"x\",\"message\":\"x\"}",
    )) |parsed| {
        parsed.deinit();
        return error.TestExpectedMissingEventSchema;
    } else |_| {}

    const oversized = try std.testing.allocator.alloc(
        u8,
        wire.max_message_size + 1,
    );
    defer std.testing.allocator.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(
        error.InvalidMessageSize,
        parseResponse(std.testing.allocator, oversized),
    );
    try std.testing.expectError(
        error.InvalidMessageSize,
        parseEvent(std.testing.allocator, oversized),
    );
}
