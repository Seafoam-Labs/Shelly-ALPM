const std = @import("std");
const protocol = @import("Shelly_Flatpak_Protocol");
const operation_api = @import("operation_context");
const loader = @import("backend_loader.zig");
const errors = @import("errors.zig");
const events = @import("events.zig");

const wire = protocol.wire;
const callback_allocator = std.heap.c_allocator;

var next_operation_id: std.atomic.Value(u64) = .init(1);

pub const EventTarget = struct {
    operation: ?*operation_api.Operation = null,
    dispatcher: ?*events.Dispatcher = null,
    context: ?*operation_api.OperationContext = null,
    cancellation: ?events.Cancellation = null,
    failure_reported: ?*std.atomic.Value(bool) = null,
};

pub const Client = struct {
    allocator: std.mem.Allocator,

    pub fn call(
        self: Client,
        comptime T: type,
        method: []const u8,
        arguments: anytype,
        target: EventTarget,
    ) !std.json.Parsed(T) {
        const loaded = try loader.acquire();
        const operation_id = next_operation_id.fetchAdd(1, .monotonic);
        const request = try std.json.Stringify.valueAlloc(
            self.allocator,
            .{
                .schema = wire.schema_version,
                .operation_id = operation_id,
                .method = method,
                .arguments = arguments,
            },
            .{},
        );
        defer self.allocator.free(request);
        if (request.len > wire.max_message_size)
            return errors.Error.FlatpakProtocolMessageTooLarge;

        var execute_context: ExecuteContext = .{
            .api = &loaded.api,
            .operation_id = operation_id,
            .target = target,
        };
        const host: protocol.HostApiV1 = .{
            .struct_size = @sizeOf(protocol.HostApiV1),
            .abi_version = protocol.abi_version,
            .user_data = &execute_context,
            .emit_event = emitEvent,
        };
        const create_fn = loaded.api.create orelse
            return errors.Error.FlatpakBackendInvalid;
        try errors.fromStatus(create_fn(&host, &execute_context.handle));
        if (execute_context.handle == null)
            return errors.Error.FlatpakBackendCreateFailed;
        defer (loaded.api.destroy orelse unreachable)(
            execute_context.handle,
        );

        const context = target.context orelse
            if (target.operation) |operation| operation.context else null;
        const subscription = if (context) |operation_context|
            try operation_context.subscribeCancellation(.{
                .function = cancelFromHost,
                .data = &execute_context,
            })
        else
            null;
        defer {
            if (context) |operation_context| {
                if (subscription) |id|
                    _ = operation_context.unsubscribeCancellation(id);
                operation_context.waitForCancellationCallbacks();
            }
        }
        if (context) |operation_context| {
            if (operation_context.isCancelled())
                cancelFromHost(&execute_context);
        }
        if (target.cancellation) |cancellation| {
            if (cancellation.isCancelled())
                cancelFromHost(&execute_context);
        }

        var response: protocol.ResponseBuffer = .{};
        const execute_fn = loaded.api.execute orelse
            return errors.Error.FlatpakBackendInvalid;
        const status = execute_fn(
            execute_context.handle,
            .{ .ptr = request.ptr, .len = request.len },
            &response,
        );
        defer if (response.ptr != null)
            (loaded.api.free_response orelse unreachable)(
                execute_context.handle,
                response,
            );
        try errors.fromStatus(status);
        if (response.ptr == null or response.len == 0)
            return errors.Error.FlatpakProtocolInvalid;
        if (response.len > wire.max_message_size)
            return errors.Error.FlatpakProtocolMessageTooLarge;

        var header = protocol.parseResponse(
            self.allocator,
            response.slice(),
        ) catch return errors.Error.FlatpakProtocolInvalid;
        defer header.deinit();
        if (header.value.operation_id != operation_id)
            return errors.Error.FlatpakProtocolMismatch;
        if (header.value.@"error") |backend_error| {
            reportBackendError(target, backend_error);
            return errors.fromCode(backend_error.code);
        }
        const result = header.value.result orelse
            return errors.Error.FlatpakProtocolInvalid;
        const encoded_result = try std.json.Stringify.valueAlloc(
            self.allocator,
            result,
            .{},
        );
        defer self.allocator.free(encoded_result);
        return std.json.parseFromSlice(
            T,
            self.allocator,
            encoded_result,
            .{
                .allocate = .alloc_always,
                .duplicate_field_behavior = .@"error",
                .ignore_unknown_fields = false,
                .max_value_len = wire.max_message_size,
            },
        ) catch return errors.Error.FlatpakProtocolInvalid;
    }
};

const ExecuteContext = struct {
    api: *const protocol.BackendApiV1,
    handle: ?*anyopaque = null,
    operation_id: u64,
    target: EventTarget,
};

fn cancelFromHost(data: ?*anyopaque) void {
    const context: *ExecuteContext =
        @ptrCast(@alignCast(data orelse return));
    const cancel_fn = context.api.cancel orelse return;
    _ = cancel_fn(context.handle, context.operation_id);
}

fn emitEvent(
    data: ?*anyopaque,
    buffer: protocol.EventBuffer,
) callconv(.c) void {
    const context: *ExecuteContext =
        @ptrCast(@alignCast(data orelse return));
    if (buffer.len == 0 or buffer.len > wire.max_message_size) return;
    var parsed = protocol.parseEvent(
        callback_allocator,
        buffer.slice(),
    ) catch return;
    defer parsed.deinit();
    const event = parsed.value;
    if (event.operation_id != context.operation_id)
        return;
    if (context.target.cancellation) |cancellation| {
        if (cancellation.isCancelled()) cancelFromHost(context);
    }
    const operation_context = context.target.context orelse
        if (context.target.operation) |operation|
            operation.context
        else
            null;
    if (operation_context) |value| {
        if (value.isCancelled()) cancelFromHost(context);
    }
    forwardEvent(context.target, event);
}

fn forwardEvent(target: EventTarget, event: wire.EventEnvelope) void {
    if (event.kind == .failure and !claimFailure(target)) return;
    if (target.dispatcher) |dispatcher| {
        switch (event.kind) {
            .status => dispatcher.raiseStatus(.{
                .event_type = eventType(event.level),
                .message = event.message,
            }),
            .progress => dispatcher.raiseProgress(.{
                .name = event.message,
                .status = event.code,
                .percentage = percentage(event.percentage),
            }),
            .failure => dispatcher.raiseStatus(.{
                .event_type = .err,
                .message = event.message,
            }),
            .started, .completed => {},
        }
        return;
    }
    const operation = target.operation orelse return;
    switch (event.kind) {
        .status => operation.status(
            statusLevel(event.level),
            event.message,
            event.code,
            event.native_code,
        ),
        .progress => operation.progress(.{
            .stage = event.code,
            .completed = event.completed,
            .total = event.total,
            .percentage = event.percentage,
            .message = event.message,
            .native_code = event.native_code,
        }),
        .failure => operation.reportError(
            errors.fromCode(event.code),
            event.message,
            "flatpak",
            event.native_code,
            false,
        ),
        .started, .completed => {},
    }
}

fn reportBackendError(
    target: EventTarget,
    backend_error: wire.ErrorPayload,
) void {
    if (!claimFailure(target)) return;
    if (target.dispatcher) |dispatcher| {
        dispatcher.raiseStatus(.{
            .event_type = .err,
            .message = backend_error.message,
        });
    } else if (target.operation) |operation| {
        operation.reportError(
            errors.fromCode(backend_error.code),
            backend_error.message,
            "flatpak",
            backend_error.native_code,
            false,
        );
    }
}

fn claimFailure(target: EventTarget) bool {
    const reported = target.failure_reported orelse return true;
    return !reported.swap(true, .acq_rel);
}

fn eventType(level: wire.EventLevel) events.EventType {
    return switch (level) {
        .information => .information,
        .warning => .warning,
        .err => .err,
        .success => .success,
    };
}

fn statusLevel(level: wire.EventLevel) operation_api.StatusLevel {
    return switch (level) {
        .information => .information,
        .warning => .warning,
        .err => .warning,
        .success => .success,
    };
}

fn percentage(value: ?f64) u8 {
    const raw = value orelse 0;
    return @intFromFloat(std.math.clamp(raw, 0, 100));
}
