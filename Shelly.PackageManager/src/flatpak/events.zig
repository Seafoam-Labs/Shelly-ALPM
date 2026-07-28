const std = @import("std");
const operations = @import("operation_context");

/// Values intentionally match the historical Flatpak event ordering.
pub const EventType = enum(u8) {
    information,
    warning,
    err,
    success,
};

/// Message slices are borrowed and remain valid only for the callback.
pub const StatusArgs = struct {
    event_type: EventType,
    message: []const u8,
};

/// Progress slices are borrowed and remain valid only for the callback.
pub const ProgressArgs = struct {
    name: []const u8,
    status: []const u8,
    percentage: u8,
};

pub const StatusHandler = struct {
    pub const Fn = *const fn (data: ?*anyopaque, args: StatusArgs) void;

    function: Fn,
    data: ?*anyopaque = null,

    fn call(self: StatusHandler, args: StatusArgs) void {
        self.function(self.data, args);
    }
};

pub const ProgressHandler = struct {
    pub const Fn = *const fn (data: ?*anyopaque, args: ProgressArgs) void;

    function: Fn,
    data: ?*anyopaque = null,

    fn call(self: ProgressHandler, args: ProgressArgs) void {
        self.function(self.data, args);
    }
};

pub const Cancellation = struct {
    pub const Fn = *const fn (data: ?*anyopaque) bool;

    function: Fn,
    data: ?*anyopaque = null,

    pub fn isCancelled(self: Cancellation) bool {
        return self.function(self.data);
    }
};

pub const Dispatcher = struct {
    allocator: std.mem.Allocator,
    statuses: std.ArrayList(StatusHandler) = .empty,
    progress: std.ArrayList(ProgressHandler) = .empty,
    operation: ?*operations.Operation = null,

    pub fn init(allocator: std.mem.Allocator) Dispatcher {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Dispatcher) void {
        self.statuses.deinit(self.allocator);
        self.progress.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addStatusHandler(
        self: *Dispatcher,
        handler: StatusHandler,
    ) !usize {
        try self.statuses.append(self.allocator, handler);
        return self.statuses.items.len - 1;
    }

    pub fn removeStatusHandler(
        self: *Dispatcher,
        token: usize,
    ) void {
        removeHandler(StatusHandler, &self.statuses, token);
    }

    pub fn addProgressHandler(
        self: *Dispatcher,
        handler: ProgressHandler,
    ) !usize {
        try self.progress.append(self.allocator, handler);
        return self.progress.items.len - 1;
    }

    pub fn removeProgressHandler(
        self: *Dispatcher,
        token: usize,
    ) void {
        removeHandler(ProgressHandler, &self.progress, token);
    }

    pub fn setOperation(
        self: *Dispatcher,
        operation: ?*operations.Operation,
    ) void {
        self.operation = operation;
    }

    pub fn raiseStatus(self: *Dispatcher, args: StatusArgs) void {
        if (self.operation) |operation| switch (args.event_type) {
            .information => operation.status(
                .information,
                args.message,
                "flatpak.status",
                null,
            ),
            .warning => operation.status(
                .warning,
                args.message,
                "flatpak.warning",
                null,
            ),
            .success => operation.status(
                .success,
                args.message,
                "flatpak.success",
                null,
            ),
            .err => operation.reportError(
                error.FlatpakOperationFailed,
                args.message,
                "flatpak",
                null,
                false,
            ),
        };
        dispatch(
            self,
            StatusArgs,
            StatusHandler,
            self.statuses.items,
            args,
        );
    }

    pub fn raiseProgress(self: *Dispatcher, args: ProgressArgs) void {
        if (self.operation) |operation| operation.progress(.{
            .stage = args.status,
            .percentage = @floatFromInt(args.percentage),
            .message = args.name,
        });
        dispatch(
            self,
            ProgressArgs,
            ProgressHandler,
            self.progress.items,
            args,
        );
    }

    fn dispatch(
        self: *Dispatcher,
        comptime Args: type,
        comptime HandlerType: type,
        live: []const HandlerType,
        args: Args,
    ) void {
        if (live.len == 0) return;
        const snapshot = self.allocator.dupe(HandlerType, live) catch {
            for (live) |handler| handler.call(args);
            return;
        };
        defer self.allocator.free(snapshot);
        for (snapshot) |handler| handler.call(args);
    }

    fn removeHandler(
        comptime HandlerType: type,
        handlers: *std.ArrayList(HandlerType),
        token: usize,
    ) void {
        if (token >= handlers.items.len) return;
        _ = handlers.swapRemove(token);
    }
};

pub const OperationScope = struct {
    dispatcher: ?*Dispatcher,
    operation: ?operations.Operation = null,
    previous: ?*operations.Operation = null,
    attached: bool = false,
    failure_reported: std.atomic.Value(bool) = .init(false),

    pub fn init(
        context: ?*operations.OperationContext,
        parent: ?*const operations.Operation,
        dispatcher: ?*Dispatcher,
        kind: operations.OperationKind,
        subject: ?[]const u8,
    ) OperationScope {
        var scope: OperationScope = .{ .dispatcher = dispatcher };
        if (dispatcher) |value| scope.previous = value.operation;
        const effective_parent = parent orelse scope.previous;
        if (effective_parent) |active_parent| {
            scope.operation = active_parent.child(.{
                .backend = .flatpak,
                .kind = kind,
                .subject = subject,
            });
        } else if (context) |operation_context| {
            scope.operation = operation_context.begin(.{
                .backend = .flatpak,
                .kind = kind,
                .subject = subject,
            });
        }
        return scope;
    }

    pub fn attach(self: *OperationScope) void {
        if (self.dispatcher) |dispatcher| {
            if (self.operation) |*operation|
                dispatcher.setOperation(operation);
        }
        self.attached = true;
    }

    pub fn checkCancelled(
        self: *const OperationScope,
    ) error{Cancelled}!void {
        if (self.operation) |*operation|
            try operation.checkCancelled();
    }

    pub fn fail(self: *OperationScope) void {
        if (!self.failure_reported.swap(true, .acq_rel)) {
            if (self.operation) |*operation| operation.reportError(
                if (operation.isCancelled())
                    error.Cancelled
                else
                    error.FlatpakOperationFailed,
                if (operation.isCancelled())
                    "Flatpak operation cancelled"
                else
                    "Flatpak operation failed",
                "flatpak",
                null,
                false,
            );
        }
        self.finish(if (self.operation) |*operation|
            if (operation.isCancelled()) .cancelled else .failed
        else
            .failed);
    }

    pub fn finish(
        self: *OperationScope,
        status: operations.CompletionStatus,
    ) void {
        if (self.operation) |*operation| operation.finish(status);
        if (self.attached) {
            if (self.dispatcher) |dispatcher|
                dispatcher.setOperation(self.previous);
            self.attached = false;
        }
    }

    pub fn childParent(
        self: *OperationScope,
    ) ?*const operations.Operation {
        return if (self.operation) |*operation| operation else null;
    }
};

test "Flatpak dispatcher forwards typed status and progress" {
    const Capture = struct {
        event_type: ?EventType = null,
        percentage: ?u8 = null,

        fn status(data: ?*anyopaque, args: StatusArgs) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.event_type = args.event_type;
        }

        fn update(data: ?*anyopaque, args: ProgressArgs) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.percentage = args.percentage;
        }
    };

    var dispatcher = Dispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();
    var capture: Capture = .{};
    _ = try dispatcher.addStatusHandler(.{
        .function = Capture.status,
        .data = &capture,
    });
    _ = try dispatcher.addProgressHandler(.{
        .function = Capture.update,
        .data = &capture,
    });
    dispatcher.raiseStatus(.{
        .event_type = .success,
        .message = "installed",
    });
    dispatcher.raiseProgress(.{
        .name = "org.example.App",
        .status = "Downloading",
        .percentage = 42,
    });
    try std.testing.expectEqual(EventType.success, capture.event_type.?);
    try std.testing.expectEqual(@as(u8, 42), capture.percentage.?);
}
