const std = @import("std");
const protocol = @import("Shelly_Flatpak_Protocol");
const wire = protocol.wire;
const options = @import("abi_test_options");

const EventCapture = struct {
    started: std.atomic.Value(u64) = .init(0),
    status: std.atomic.Value(u64) = .init(0),
    progress: std.atomic.Value(u64) = .init(0),
    failure: std.atomic.Value(u64) = .init(0),
    completed: std.atomic.Value(u64) = .init(0),
    saw_half_progress: std.atomic.Value(bool) = .init(false),
};

const OpenedApi = struct {
    library: std.DynLib,
    api: protocol.BackendApiV1,

    fn deinit(self: *OpenedApi) void {
        self.library.close();
    }
};

const ExecuteContext = struct {
    api: *const protocol.BackendApiV1,
    handle: ?*anyopaque,
    request: protocol.RequestBuffer,
    response: protocol.ResponseBuffer = .{},
    status: protocol.Status = .internal_error,

    fn run(self: *ExecuteContext) void {
        self.status = self.api.execute.?(
            self.handle,
            self.request,
            &self.response,
        );
    }
};

fn captureEvent(
    user_data: ?*anyopaque,
    event_buffer: protocol.EventBuffer,
) callconv(.c) void {
    const capture: *EventCapture = @ptrCast(@alignCast(user_data orelse return));
    var parsed = std.json.parseFromSlice(
        wire.EventEnvelope,
        std.heap.c_allocator,
        event_buffer.slice(),
        .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
            .ignore_unknown_fields = false,
        },
    ) catch return;
    defer parsed.deinit();
    switch (parsed.value.kind) {
        .started => _ = capture.started.fetchAdd(1, .acq_rel),
        .status => _ = capture.status.fetchAdd(1, .acq_rel),
        .progress => {
            _ = capture.progress.fetchAdd(1, .acq_rel);
            if (parsed.value.percentage == 50)
                capture.saw_half_progress.store(true, .release);
        },
        .failure => _ = capture.failure.fetchAdd(1, .acq_rel),
        .completed => _ = capture.completed.fetchAdd(1, .acq_rel),
    }
}

fn hostFor(capture: *EventCapture) protocol.HostApiV1 {
    return .{
        .struct_size = @sizeOf(protocol.HostApiV1),
        .abi_version = protocol.abi_version,
        .user_data = capture,
        .emit_event = captureEvent,
    };
}

fn openApi(
    path: []const u8,
    host: *const protocol.HostApiV1,
) !OpenedApi {
    var library = try std.DynLib.open(path);
    errdefer library.close();
    const get_api = library.lookup(
        protocol.GetApiFn,
        protocol.get_api_symbol,
    ) orelse return error.MissingBackendEntryPoint;
    var api: protocol.BackendApiV1 = undefined;
    try std.testing.expectEqual(
        protocol.Status.success,
        get_api(protocol.abi_version, host, &api),
    );
    try std.testing.expect(protocol.backendApiValid(&api));
    return .{ .library = library, .api = api };
}

fn requestBytes(operation_id: u64, method: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(std.testing.allocator, .{
        .schema = wire.schema_version,
        .operation_id = operation_id,
        .method = method,
        .arguments = .{},
    }, .{});
}

fn execute(
    api: *const protocol.BackendApiV1,
    handle: ?*anyopaque,
    operation_id: u64,
    method: []const u8,
) !protocol.ResponseBuffer {
    const request = try requestBytes(operation_id, method);
    defer std.testing.allocator.free(request);
    var response: protocol.ResponseBuffer = .{};
    try std.testing.expectEqual(
        protocol.Status.success,
        api.execute.?(
            handle,
            .{ .ptr = request.ptr, .len = request.len },
            &response,
        ),
    );
    try std.testing.expect(response.ptr != null);
    return response;
}

fn parseHeader(
    bytes: []const u8,
) !std.json.Parsed(wire.ResponseHeader) {
    return std.json.parseFromSlice(
        wire.ResponseHeader,
        std.testing.allocator,
        bytes,
        .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
            .ignore_unknown_fields = false,
        },
    );
}

test "fake shared backend covers the complete loader and ownership contract" {
    var capture: EventCapture = .{};
    const host = hostFor(&capture);

    var library = try std.DynLib.open(options.fake_backend_path);
    defer library.close();
    const get_api = library.lookup(
        protocol.GetApiFn,
        protocol.get_api_symbol,
    ) orelse return error.MissingBackendEntryPoint;

    var api: protocol.BackendApiV1 = undefined;
    try std.testing.expectEqual(
        protocol.Status.incompatible,
        get_api(protocol.abi_version - 1, &host, &api),
    );
    try std.testing.expectEqual(
        protocol.Status.incompatible,
        get_api(protocol.abi_version + 1, &host, &api),
    );
    try std.testing.expectEqual(
        protocol.Status.success,
        get_api(protocol.abi_version, &host, &api),
    );
    try std.testing.expect(protocol.backendApiValid(&api));

    var handle: ?*anyopaque = null;
    try std.testing.expectEqual(
        protocol.Status.success,
        api.create.?(&host, &handle),
    );
    try std.testing.expect(handle != null);
    defer api.destroy.?(handle);

    var response = try execute(&api, handle, 11, "fake.success");
    var header = try parseHeader(response.slice());
    try std.testing.expectEqual(@as(u64, 11), header.value.operation_id);
    try std.testing.expect(header.value.result != null);
    try std.testing.expect(header.value.@"error" == null);
    header.deinit();
    api.free_response.?(handle, response);

    try std.testing.expectEqual(@as(u64, 1), capture.started.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), capture.status.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), capture.progress.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), capture.completed.load(.acquire));
    try std.testing.expect(capture.saw_half_progress.load(.acquire));

    response = try execute(&api, handle, 12, "fake.error");
    header = try parseHeader(response.slice());
    try std.testing.expect(header.value.result == null);
    try std.testing.expectEqualStrings(
        "fake.failure",
        header.value.@"error".?.code,
    );
    try std.testing.expectEqual(@as(?i64, 77), header.value.@"error".?.native_code);
    header.deinit();
    api.free_response.?(handle, response);

    response = try execute(&api, handle, 13, "fake.malformed");
    if (parseHeader(response.slice())) |unexpected| {
        unexpected.deinit();
        return error.TestExpectedMalformedResponse;
    } else |_| {}
    api.free_response.?(handle, response);

    response = try execute(&api, handle, 14, "fake.stats");
    header = try parseHeader(response.slice());
    const released = header.value.result.?.object.get("released") orelse
        return error.MissingReleaseCount;
    try std.testing.expectEqual(@as(i64, 3), released.integer);
    header.deinit();
    api.free_response.?(handle, response);

    const waiting_request = try requestBytes(15, "fake.wait");
    defer std.testing.allocator.free(waiting_request);
    var waiting: ExecuteContext = .{
        .api = &api,
        .handle = handle,
        .request = .{
            .ptr = waiting_request.ptr,
            .len = waiting_request.len,
        },
    };
    const started_before = capture.started.load(.acquire);
    const waiting_thread = try std.Thread.spawn(.{}, ExecuteContext.run, .{&waiting});
    var spins: usize = 0;
    while (capture.started.load(.acquire) == started_before and spins < 1_000_000) : (spins += 1) {
        std.atomic.spinLoopHint();
        std.Thread.yield() catch {};
    }
    try std.testing.expect(capture.started.load(.acquire) > started_before);
    try std.testing.expectEqual(
        protocol.Status.success,
        api.cancel.?(handle, 15),
    );
    waiting_thread.join();
    try std.testing.expectEqual(protocol.Status.success, waiting.status);
    header = try parseHeader(waiting.response.slice());
    try std.testing.expectEqualStrings(
        "flatpak.cancelled",
        header.value.@"error".?.code,
    );
    header.deinit();
    api.free_response.?(handle, waiting.response);
    try std.testing.expectEqual(
        protocol.Status.success,
        api.cancel.?(handle, 15),
    );

    var second_handle: ?*anyopaque = null;
    try std.testing.expectEqual(
        protocol.Status.success,
        api.create.?(&host, &second_handle),
    );
    defer api.destroy.?(second_handle);

    const first_request = try requestBytes(16, "fake.success");
    defer std.testing.allocator.free(first_request);
    const second_request = try requestBytes(17, "fake.success");
    defer std.testing.allocator.free(second_request);
    var first: ExecuteContext = .{
        .api = &api,
        .handle = handle,
        .request = .{ .ptr = first_request.ptr, .len = first_request.len },
    };
    var second: ExecuteContext = .{
        .api = &api,
        .handle = second_handle,
        .request = .{ .ptr = second_request.ptr, .len = second_request.len },
    };
    const first_thread = try std.Thread.spawn(.{}, ExecuteContext.run, .{&first});
    const second_thread = try std.Thread.spawn(.{}, ExecuteContext.run, .{&second});
    first_thread.join();
    second_thread.join();
    try std.testing.expectEqual(protocol.Status.success, first.status);
    try std.testing.expectEqual(protocol.Status.success, second.status);
    api.free_response.?(handle, first.response);
    api.free_response.?(second_handle, second.response);
}

test "loader rejects missing, incompatible, short, and null API tables" {
    var capture: EventCapture = .{};
    const host = hostFor(&capture);

    var missing = try std.DynLib.open(options.missing_backend_path);
    defer missing.close();
    try std.testing.expect(missing.lookup(
        protocol.GetApiFn,
        protocol.get_api_symbol,
    ) == null);

    var incompatible = try std.DynLib.open(options.incompatible_backend_path);
    defer incompatible.close();
    const incompatible_get = incompatible.lookup(
        protocol.GetApiFn,
        protocol.get_api_symbol,
    ) orelse return error.MissingBackendEntryPoint;
    var api: protocol.BackendApiV1 = undefined;
    try std.testing.expectEqual(
        protocol.Status.incompatible,
        incompatible_get(protocol.abi_version, &host, &api),
    );

    var short = try std.DynLib.open(options.short_backend_path);
    defer short.close();
    const short_get = short.lookup(
        protocol.GetApiFn,
        protocol.get_api_symbol,
    ) orelse return error.MissingBackendEntryPoint;
    try std.testing.expectEqual(
        protocol.Status.success,
        short_get(protocol.abi_version, &host, &api),
    );
    try std.testing.expect(!protocol.backendApiValid(&api));

    var null_backend = try std.DynLib.open(options.null_backend_path);
    defer null_backend.close();
    const null_get = null_backend.lookup(
        protocol.GetApiFn,
        protocol.get_api_symbol,
    ) orelse return error.MissingBackendEntryPoint;
    try std.testing.expectEqual(
        protocol.Status.success,
        null_get(protocol.abi_version, &host, &api),
    );
    try std.testing.expect(!protocol.backendApiValid(&api));
}

test "real backend exports a valid versioned function table" {
    var capture: EventCapture = .{};
    const host = hostFor(&capture);
    var opened = try openApi(options.real_backend_path, &host);
    defer opened.deinit();
    try std.testing.expectEqual(protocol.abi_version, opened.api.abi_version);
    try std.testing.expectEqual(
        @sizeOf(protocol.BackendApiV1),
        opened.api.struct_size,
    );
}
