const std = @import("std");
const operation_api = @import("operation_context");

/// Values mirror PackageManager.Alpm.Enums.AlpmEventType for API parity.
pub const EventType = enum(u32) {
    informational_output = 256,
    debug_output = 257,
    trace_output = 258,
    transaction_failed = 259,
    aur_download_start = 512,
    aur_download_done = 513,
    aur_build_start = 514,
    aur_build_done = 515,
    aur_install_start = 516,
    aur_install_done = 517,
    aur_cleanup_start = 518,
    aur_cleanup_done = 519,
    aur_package_failed = 520,
    aur_package_completed = 521,
    aur_build_output = 522,
    aur_build_error = 523,
};

pub const ProgressType = enum(c_int) {
    makepkg_build = 200,
    makepkg_package = 201,
    aur_download = 202,
};

pub const InformationalArgs = struct {
    event_type: EventType,
    message: []const u8,
    package_name: ?[]const u8 = null,
    current: ?usize = null,
    total: ?usize = null,
};

pub const ProgressArgs = struct {
    progress_type: ProgressType,
    package_name: []const u8,
    percent: u8,
    message: ?[]const u8 = null,
};

pub const ErrorArgs = struct {
    message: []const u8,
};

pub const ProviderOption = struct {
    name: []const u8,
    description: []const u8,
    is_installed: bool = false,
};

pub const QuestionType = enum {
    select_optional_dependencies,
    select_provider,
};

pub const QuestionArgs = struct {
    question_type: QuestionType,
    question: []const u8,
    options: []const ProviderOption,
    dependency_name: ?[]const u8 = null,
};

/// The returned indices borrow storage from the question handler and are
/// consumed before the handler returns to application code again.
pub const QuestionResponse = struct {
    selected_indices: []const usize = &.{},
};

fn Handler(comptime Args: type) type {
    return struct {
        function: *const fn (data: ?*anyopaque, args: Args) void,
        data: ?*anyopaque = null,

        fn call(self: @This(), args: Args) void {
            self.function(self.data, args);
        }
    };
}

pub const InformationalHandler = Handler(InformationalArgs);
pub const ProgressHandler = Handler(ProgressArgs);
pub const ErrorHandler = Handler(ErrorArgs);
pub const QuestionHandler = struct {
    function: *const fn (data: ?*anyopaque, args: QuestionArgs) QuestionResponse,
    data: ?*anyopaque = null,
};

pub const Dispatcher = struct {
    allocator: std.mem.Allocator,
    informational: std.ArrayList(InformationalHandler) = .empty,
    progress: std.ArrayList(ProgressHandler) = .empty,
    errors: std.ArrayList(ErrorHandler) = .empty,
    question: ?QuestionHandler = null,
    operation: ?*operation_api.Operation = null,
    common_question_response: ?operation_api.OwnedQuestionResponse = null,
    common_choice: [1]usize = .{0},

    pub fn init(allocator: std.mem.Allocator) Dispatcher {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Dispatcher) void {
        if (self.common_question_response) |*response| response.deinit(self.allocator);
        self.informational.deinit(self.allocator);
        self.progress.deinit(self.allocator);
        self.errors.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn setOperation(self: *Dispatcher, operation: ?*operation_api.Operation) void {
        self.operation = operation;
    }

    pub fn addInformationalHandler(self: *Dispatcher, handler: InformationalHandler) !usize {
        try self.informational.append(self.allocator, handler);
        return self.informational.items.len - 1;
    }

    pub fn removeInformationalHandler(self: *Dispatcher, index: usize) void {
        removeHandler(InformationalHandler, &self.informational, index);
    }

    pub fn addProgressHandler(self: *Dispatcher, handler: ProgressHandler) !usize {
        try self.progress.append(self.allocator, handler);
        return self.progress.items.len - 1;
    }

    pub fn removeProgressHandler(self: *Dispatcher, index: usize) void {
        removeHandler(ProgressHandler, &self.progress, index);
    }

    pub fn addErrorHandler(self: *Dispatcher, handler: ErrorHandler) !usize {
        try self.errors.append(self.allocator, handler);
        return self.errors.items.len - 1;
    }

    pub fn removeErrorHandler(self: *Dispatcher, index: usize) void {
        removeHandler(ErrorHandler, &self.errors, index);
    }

    pub fn setQuestionHandler(self: *Dispatcher, handler: ?QuestionHandler) void {
        self.question = handler;
    }

    pub fn raiseInformational(self: *Dispatcher, args: InformationalArgs) void {
        if (self.operation) |operation| {
            const level: operation_api.StatusLevel = switch (args.event_type) {
                .debug_output, .trace_output => .debug,
                .aur_package_failed, .aur_build_error, .transaction_failed => .warning,
                .aur_download_done, .aur_build_done, .aur_install_done, .aur_cleanup_done, .aur_package_completed => .success,
                else => .information,
            };
            operation.status(level, args.message, @tagName(args.event_type), @intFromEnum(args.event_type));
            if (args.current != null or args.total != null) operation.progress(.{
                .stage = @tagName(args.event_type),
                .completed = if (args.current) |value| @intCast(value) else null,
                .total = if (args.total) |value| @intCast(value) else null,
                .message = args.package_name orelse args.message,
                .native_code = @intFromEnum(args.event_type),
            });
        }
        dispatch(self, InformationalArgs, InformationalHandler, self.informational.items, args);
    }

    pub fn raiseProgress(self: *Dispatcher, args: ProgressArgs) void {
        if (self.operation) |operation| operation.progress(.{
            .stage = @tagName(args.progress_type),
            .percentage = @floatFromInt(args.percent),
            .message = args.message orelse args.package_name,
            .native_code = @intFromEnum(args.progress_type),
        });
        dispatch(self, ProgressArgs, ProgressHandler, self.progress.items, args);
    }

    pub fn raiseError(self: *Dispatcher, args: ErrorArgs) void {
        if (self.operation) |operation| operation.reportError(error.AurOperationFailed, args.message, "aur", null, false);
        dispatch(self, ErrorArgs, ErrorHandler, self.errors.items, args);
    }

    pub fn ask(self: *Dispatcher, args: QuestionArgs) QuestionResponse {
        if (self.common_question_response) |*response| {
            response.deinit(self.allocator);
            self.common_question_response = null;
        }
        if (self.operation) |operation| {
            const common_options = self.allocator.alloc(operation_api.QuestionOption, args.options.len) catch null;
            if (common_options) |options| {
                defer self.allocator.free(options);
                for (args.options, options) |option, *target| target.* = .{
                    .id = option.name,
                    .label = option.name,
                    .description = option.description,
                    .is_installed = option.is_installed,
                };
                var answer = operation.ask(.{
                    .kind = switch (args.question_type) {
                        .select_optional_dependencies => .select_optional_dependencies,
                        .select_provider => .select_provider,
                    },
                    .prompt = args.question,
                    .options = options,
                    .dependency_name = args.dependency_name,
                }) catch |err| {
                    if (err != error.Cancelled) operation.reportError(err, "Failed to obtain an AUR question response", "aur", null, false);
                    return .{};
                };
                switch (answer.response) {
                    .choice => |choice| {
                        self.common_choice[0] = choice;
                        answer.deinit(self.allocator);
                        return .{ .selected_indices = &self.common_choice };
                    },
                    .choices => |choices| {
                        self.common_question_response = answer;
                        return .{ .selected_indices = choices };
                    },
                    .declined => {
                        answer.deinit(self.allocator);
                        return .{};
                    },
                    .accepted => {
                        const indices = self.allocator.alloc(usize, args.options.len) catch {
                            answer.deinit(self.allocator);
                            return .{};
                        };
                        for (indices, 0..) |*index, value| index.* = value;
                        answer.deinit(self.allocator);
                        self.common_question_response = operation_api.OwnedQuestionResponse.init(self.allocator, .{ .choices = indices }) catch {
                            self.allocator.free(indices);
                            return .{};
                        };
                        self.allocator.free(indices);
                        return .{ .selected_indices = self.common_question_response.?.response.choices };
                    },
                    .default, .package, .deferred => answer.deinit(self.allocator),
                }
            }
        }
        const handler = self.question orelse return .{};
        return handler.function(handler.data, args);
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

    fn removeHandler(comptime HandlerType: type, handlers: *std.ArrayList(HandlerType), index: usize) void {
        if (index >= handlers.items.len) return;
        _ = handlers.swapRemove(index);
    }
};

test "AUR dispatcher forwards package stages and build progress" {
    const Capture = struct {
        info: ?InformationalArgs = null,
        progress_value: ?ProgressArgs = null,

        fn infoCallback(data: ?*anyopaque, args: InformationalArgs) void {
            const self: *@This() = @ptrCast(@alignCast(data));
            self.info = args;
        }

        fn progressCallback(data: ?*anyopaque, args: ProgressArgs) void {
            const self: *@This() = @ptrCast(@alignCast(data));
            self.progress_value = args;
        }
    };

    var dispatcher = Dispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();
    var capture = Capture{};
    _ = try dispatcher.addInformationalHandler(.{ .function = Capture.infoCallback, .data = &capture });
    _ = try dispatcher.addProgressHandler(.{ .function = Capture.progressCallback, .data = &capture });

    dispatcher.raiseInformational(.{
        .event_type = .aur_build_start,
        .message = "building",
        .package_name = "demo",
        .current = 1,
        .total = 2,
    });
    dispatcher.raiseProgress(.{
        .progress_type = .makepkg_build,
        .package_name = "demo",
        .percent = 42,
        .message = "compiling",
    });

    try std.testing.expectEqual(EventType.aur_build_start, capture.info.?.event_type);
    try std.testing.expectEqual(@as(?usize, 2), capture.info.?.total);
    try std.testing.expectEqual(@as(u8, 42), capture.progress_value.?.percent);
}

test "AUR dispatcher returns provider selections" {
    const HandlerContext = struct {
        selected: [1]usize = .{1},
        fn answer(data: ?*anyopaque, _: QuestionArgs) QuestionResponse {
            const self: *@This() = @ptrCast(@alignCast(data));
            return .{ .selected_indices = &self.selected };
        }
    };
    var dispatcher = Dispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();
    var context = HandlerContext{};
    dispatcher.setQuestionHandler(.{ .function = HandlerContext.answer, .data = &context });
    const options = [_]ProviderOption{
        .{ .name = "one", .description = "", .is_installed = false },
        .{ .name = "two", .description = "", .is_installed = false },
    };
    const response = dispatcher.ask(.{
        .question_type = .select_provider,
        .question = "choose",
        .options = &options,
    });
    try std.testing.expectEqualSlices(usize, &.{1}, response.selected_indices);
}

test "AUR handlers can be removed through the manager-facing dispatcher" {
    const Capture = struct {
        called: bool = false,
        fn onError(data: ?*anyopaque, _: ErrorArgs) void {
            const self: *@This() = @ptrCast(@alignCast(data));
            self.called = true;
        }
    };
    var dispatcher = Dispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();
    var capture = Capture{};
    const index = try dispatcher.addErrorHandler(.{ .function = Capture.onError, .data = &capture });
    dispatcher.removeErrorHandler(index);
    dispatcher.raiseError(.{ .message = "ignored" });
    try std.testing.expect(!capture.called);
}
