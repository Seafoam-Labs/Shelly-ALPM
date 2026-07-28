const std = @import("std");
const protocol = @import("Shelly_Flatpak_Protocol");
const wire = protocol.wire;

const allocator = std.heap.c_allocator;
var released_responses: std.atomic.Value(u64) = .init(0);

const State = struct {
    host: protocol.HostApiV1,
    active_operation: std.atomic.Value(u64) = .init(0),
    pending_cancel_operation: std.atomic.Value(u64) = .init(0),
    cancelled: std.atomic.Value(bool) = .init(false),
};

export fn shelly_flatpak_backend_get_api(
    requested_version: u32,
    host: *const protocol.HostApiV1,
    api: *protocol.BackendApiV1,
) callconv(.c) protocol.Status {
    if (requested_version != protocol.abi_version) return .incompatible;
    if (!protocol.hostApiValid(host)) return .invalid_argument;
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
    if (!protocol.hostApiValid(host)) return .invalid_argument;
    const state = allocator.create(State) catch return .internal_error;
    state.* = .{ .host = host.* };
    output.* = state;
    return .success;
}

fn destroy(handle: ?*anyopaque) callconv(.c) void {
    const state = stateFromHandle(handle) orelse return;
    allocator.destroy(state);
}

fn execute(
    handle: ?*anyopaque,
    request_buffer: protocol.RequestBuffer,
    response: *protocol.ResponseBuffer,
) callconv(.c) protocol.Status {
    const state = stateFromHandle(handle) orelse return .invalid_argument;
    response.* = .{};
    var request = protocol.parseRequest(
        allocator,
        request_buffer.slice(),
    ) catch return .invalid_argument;
    defer request.deinit();

    const operation_id = request.value.operation_id;
    state.active_operation.store(operation_id, .release);
    state.cancelled.store(
        state.pending_cancel_operation.load(.acquire) == operation_id,
        .release,
    );
    if (state.cancelled.load(.acquire))
        state.pending_cancel_operation.store(0, .release);
    defer state.active_operation.store(0, .release);

    const encoded = if (std.mem.eql(u8, request.value.method, "fake.success"))
        success(state, operation_id)
    else if (std.mem.eql(u8, request.value.method, "fake.error"))
        backendError(operation_id)
    else if (std.mem.eql(u8, request.value.method, "fake.malformed"))
        allocator.dupe(u8, "{not-json")
    else if (std.mem.eql(u8, request.value.method, "fake.wait"))
        waitForCancellation(state, operation_id)
    else if (std.mem.eql(u8, request.value.method, "fake.stats"))
        stats(state, operation_id)
    else
        unknownMethod(operation_id);

    const bytes = encoded catch return .internal_error;
    response.* = .{ .ptr = bytes.ptr, .len = bytes.len };
    return .success;
}

fn cancel(
    handle: ?*anyopaque,
    operation_id: u64,
) callconv(.c) protocol.Status {
    const state = stateFromHandle(handle) orelse return .invalid_argument;
    if (state.active_operation.load(.acquire) == operation_id) {
        state.cancelled.store(true, .release);
    } else {
        state.pending_cancel_operation.store(operation_id, .release);
    }
    return .success;
}

fn freeResponse(
    handle: ?*anyopaque,
    response: protocol.ResponseBuffer,
) callconv(.c) void {
    _ = stateFromHandle(handle) orelse return;
    if (response.ptr) |ptr| {
        _ = released_responses.fetchAdd(1, .acq_rel);
        allocator.free(ptr[0..response.len]);
    }
}

fn success(state: *State, operation_id: u64) ![]u8 {
    try emit(
        state,
        operation_id,
        .started,
        "fake.started",
        "Fake operation started",
        null,
    );
    try emit(
        state,
        operation_id,
        .status,
        "fake.status",
        "Fake backend status",
        null,
    );
    try emit(
        state,
        operation_id,
        .progress,
        "fake.progress",
        "Fake backend progress",
        50,
    );
    try emit(
        state,
        operation_id,
        .completed,
        "fake.completed",
        "Fake operation complete",
        100,
    );
    return std.json.Stringify.valueAlloc(allocator, .{
        .schema = wire.schema_version,
        .operation_id = operation_id,
        .result = .{ .ok = true, .value = "fake" },
    }, .{});
}

fn backendError(operation_id: u64) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .schema = wire.schema_version,
        .operation_id = operation_id,
        .@"error" = .{
            .code = "fake.failure",
            .message = "Fake backend failure",
            .native_code = @as(i64, 77),
        },
    }, .{});
}

fn waitForCancellation(state: *State, operation_id: u64) ![]u8 {
    try emit(
        state,
        operation_id,
        .started,
        "fake.waiting",
        "Waiting for cancellation",
        null,
    );
    while (!state.cancelled.load(.acquire)) {
        std.atomic.spinLoopHint();
        std.Thread.yield() catch {};
    }
    try emit(
        state,
        operation_id,
        .failure,
        "flatpak.cancelled",
        "Fake operation cancelled",
        null,
    );
    return std.json.Stringify.valueAlloc(allocator, .{
        .schema = wire.schema_version,
        .operation_id = operation_id,
        .@"error" = .{
            .code = "flatpak.cancelled",
            .message = "Fake operation cancelled",
            .native_code = @as(?i64, null),
        },
    }, .{});
}

fn stats(_: *State, operation_id: u64) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .schema = wire.schema_version,
        .operation_id = operation_id,
        .result = .{
            .released = released_responses.load(.acquire),
        },
    }, .{});
}

fn unknownMethod(operation_id: u64) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .schema = wire.schema_version,
        .operation_id = operation_id,
        .@"error" = .{
            .code = "protocol.unknown_method",
            .message = "Unknown fake method",
            .native_code = @as(?i64, null),
        },
    }, .{});
}

fn emit(
    state: *State,
    operation_id: u64,
    kind: wire.EventKind,
    code: []const u8,
    message: []const u8,
    percentage: ?f64,
) !void {
    const encoded = try std.json.Stringify.valueAlloc(
        allocator,
        wire.EventEnvelope{
            .schema = wire.schema_version,
            .operation_id = operation_id,
            .kind = kind,
            .code = code,
            .message = message,
            .level = if (kind == .failure) .err else .information,
            .percentage = percentage,
        },
        .{},
    );
    defer allocator.free(encoded);
    state.host.emit_event.?(
        state.host.user_data,
        .{ .ptr = encoded.ptr, .len = encoded.len },
    );
}

fn stateFromHandle(handle: ?*anyopaque) ?*State {
    return @ptrCast(@alignCast(handle orelse return null));
}
