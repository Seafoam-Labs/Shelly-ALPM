const std = @import("std");
const bindings = @import("bindings.zig");
const c = bindings.libalpm;
const operation_api = @import("operation_context");

pub const ProgressArgs = struct {
    progress_type: c_int,
    pkg_name: ?[]const u8,
    percent: c_int,
    howmany: c_ulong,
    current: c_ulong,
};

pub const QuestionArgs = struct {
    question: ?[]const u8,
    question_type: c_int,
    arguments: []const []const u8 = &.{},
    options: []const []const u8,
    response: ?c_int = null,
    provider_options: ?[]const ProviderOption = null,
    dependency_name: ?[]const u8 = null,
};

pub const ProviderOption = struct {
    name: []const u8,
    description: []const u8,
    is_installed: bool,
};

pub const ErrorArgs = struct {
    message: []const u8,
};

pub const InformationalArgs = struct {
    event_type: bindings.libalpm.EventType,
    message: []const u8,
};

pub const ScriptletArgs = struct {
    line: []const u8,
};

pub const HookArgs = struct {
    description: ?[]const u8,
    position: c_ulong,
    total: c_ulong,
};

pub const PacnewArgs = struct {
    file: ?[]const u8,
};

pub const PacsaveArgs = struct {
    pkg_name: ?[]const u8,
    file: ?[]const u8,
};

pub const ReplacesArgs = struct {
    pkg_name: []const u8,
    repository: []const u8,
    replaces: []const []const u8,
};

pub fn Handler(comptime Args: type) type {
    return struct {
        pub const Fn = *const fn (data: ?*anyopaque, args: Args) void;

        pub const T = struct {
            function: Fn,
            data: ?*anyopaque = null,

            pub fn call(self: T, args: Args) void {
                self.function(self.data, args);
            }
        };
    };
}

pub const QuestionResponse = struct {
    answer: ?c_int = null,
    pkg: ?[]const u8 = null,
    choice: ?c_int = null,
    /// Borrowed indices selected by a shared multi-select question response.
    /// The dispatcher keeps the owning response alive until the next question.
    selected_indices: []const usize = &.{},
};

pub const Dispatcher = struct {
    progress: std.ArrayList(Handler(ProgressArgs).T),
    question: std.ArrayList(Handler(QuestionArgs).T),
    errorEvents: std.ArrayList(Handler(ErrorArgs).T),
    informational: std.ArrayList(Handler(InformationalArgs).T),
    scriptlet: std.ArrayList(Handler(ScriptletArgs).T),
    hook: std.ArrayList(Handler(HookArgs).T),
    pacnew: std.ArrayList(Handler(PacnewArgs).T),
    pacsave: std.ArrayList(Handler(PacsaveArgs).T),
    replaces: std.ArrayList(Handler(ReplacesArgs).T),

    question_mutex: std.Io.Mutex,
    question_cv: std.Io.Condition,
    question_response: QuestionResponse,
    operation: ?*operation_api.Operation,
    common_question_response: ?operation_api.OwnedQuestionResponse,
    error_generation: std.atomic.Value(usize),
    recoverable_error_context: ?[]const u8,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Dispatcher {
        return .{
            .allocator = allocator,
            .progress = .empty,
            .question = .empty,
            .errorEvents = .empty,
            .informational = .empty,
            .scriptlet = .empty,
            .hook = .empty,
            .pacnew = .empty,
            .pacsave = .empty,
            .replaces = .empty,
            .question_mutex = .init,
            .question_cv = .init,
            .question_response = .{},
            .operation = null,
            .common_question_response = null,
            .error_generation = .init(0),
            .recoverable_error_context = null,
        };
    }

    pub fn deinit(self: *Dispatcher) void {
        if (self.common_question_response) |*response| response.deinit(self.allocator);
        self.progress.deinit(self.allocator);
        self.question.deinit(self.allocator);
        self.errorEvents.deinit(self.allocator);
        self.informational.deinit(self.allocator);
        self.scriptlet.deinit(self.allocator);
        self.hook.deinit(self.allocator);
        self.pacnew.deinit(self.allocator);
        self.pacsave.deinit(self.allocator);
        self.replaces.deinit(self.allocator);
    }

    pub fn setOperation(self: *Dispatcher, operation: ?*operation_api.Operation) void {
        self.operation = operation;
    }

    pub fn addProgressHandler(self: *Dispatcher, handler: Handler(ProgressArgs).T) !usize {
        try self.progress.append(self.allocator, handler);
        return self.progress.items.len - 1;
    }

    pub fn removeProgressHandler(self: *Dispatcher, index: usize) void {
        if (index >= self.progress.items.len) return;
        const last = self.progress.items.len - 1;
        if (index != last) {
            _ = self.progress.swapRemove(index);
        } else self.progress.shrinkRetainingCapacity(last);
    }

    pub fn addQuestionHandler(self: *Dispatcher, handler: Handler(QuestionArgs).T) !usize {
        try self.question.append(self.allocator, handler);
        return self.question.items.len - 1;
    }

    pub fn removeQuestionHandler(self: *Dispatcher, index: usize) void {
        if (index >= self.question.items.len) return;
        const last = self.question.items.len - 1;
        if (index != last) {
            _ = self.question.swapRemove(index);
        } else self.question.shrinkRetainingCapacity(last);
    }

    pub fn addErrorHandler(self: *Dispatcher, handler: Handler(ErrorArgs).T) !usize {
        try self.errorEvents.append(self.allocator, handler);
        return self.errorEvents.items.len - 1;
    }

    pub fn removeErrorHandler(self: *Dispatcher, index: usize) void {
        if (index >= self.errorEvents.items.len) return;
        const last = self.errorEvents.items.len - 1;
        if (index != last) {
            _ = self.errorEvents.swapRemove(index);
        } else self.errorEvents.shrinkRetainingCapacity(last);
    }

    pub fn addInformationalHandler(self: *Dispatcher, handler: Handler(InformationalArgs).T) !usize {
        try self.informational.append(self.allocator, handler);
        return self.informational.items.len - 1;
    }

    pub fn removeInformationalHandler(self: *Dispatcher, index: usize) void {
        if (index >= self.informational.items.len) return;
        const last = self.informational.items.len - 1;
        if (index != last) {
            _ = self.informational.swapRemove(index);
        } else self.informational.shrinkRetainingCapacity(last);
    }

    pub fn addScriptletHandler(self: *Dispatcher, handler: Handler(ScriptletArgs).T) !usize {
        try self.scriptlet.append(self.allocator, handler);
        return self.scriptlet.items.len - 1;
    }

    pub fn removeScriptletHandler(self: *Dispatcher, index: usize) void {
        if (index >= self.scriptlet.items.len) return;
        const last = self.scriptlet.items.len - 1;
        if (index != last) {
            _ = self.scriptlet.swapRemove(index);
        } else self.scriptlet.shrinkRetainingCapacity(last);
    }

    pub fn addHookHandler(self: *Dispatcher, handler: Handler(HookArgs).T) !usize {
        try self.hook.append(self.allocator, handler);
        return self.hook.items.len - 1;
    }

    pub fn removeHookHandler(self: *Dispatcher, index: usize) void {
        if (index >= self.hook.items.len) return;
        const last = self.hook.items.len - 1;
        if (index != last) {
            _ = self.hook.swapRemove(index);
        } else self.hook.shrinkRetainingCapacity(last);
    }

    pub fn addPacnewHandler(self: *Dispatcher, handler: Handler(PacnewArgs).T) !usize {
        try self.pacnew.append(self.allocator, handler);
        return self.pacnew.items.len - 1;
    }

    pub fn removePacnewHandler(self: *Dispatcher, index: usize) void {
        if (index >= self.pacnew.items.len) return;
        const last = self.pacnew.items.len - 1;
        if (index != last) {
            _ = self.pacnew.swapRemove(index);
        } else self.pacnew.shrinkRetainingCapacity(last);
    }

    pub fn addPacsaveHandler(self: *Dispatcher, handler: Handler(PacsaveArgs).T) !usize {
        try self.pacsave.append(self.allocator, handler);
        return self.pacsave.items.len - 1;
    }

    pub fn removePacsaveHandler(self: *Dispatcher, index: usize) void {
        if (index >= self.pacsave.items.len) return;
        const last = self.pacsave.items.len - 1;
        if (index != last) {
            _ = self.pacsave.swapRemove(index);
        } else self.pacsave.shrinkRetainingCapacity(last);
    }

    pub fn addReplacesHandler(self: *Dispatcher, handler: Handler(ReplacesArgs).T) !usize {
        try self.replaces.append(self.allocator, handler);
        return self.replaces.items.len - 1;
    }

    pub fn removeReplacesHandler(self: *Dispatcher, index: usize) void {
        if (index >= self.replaces.items.len) return;
        const last = self.replaces.items.len - 1;
        if (index != last) {
            _ = self.replaces.swapRemove(index);
        } else self.replaces.shrinkRetainingCapacity(last);
    }

    /// Invoke every handler in `list` with `args`.
    ///
    /// The handlers are copied into a temporary buffer before dispatching so a
    /// handler may add or remove handlers during the callback without
    /// invalidating the iteration (removal poisons the backing storage, so
    /// iterating `list.items` directly is not safe). On allocation failure we
    /// fall back to iterating the live slice.
    fn dispatch(self: *Dispatcher, comptime Args: type, list: *const std.ArrayList(Handler(Args).T), args: Args) void {
        const items = list.items;
        if (items.len == 0) return;
        const snap = self.allocator.dupe(Handler(Args).T, items) catch {
            for (items) |h| h.call(args);
            return;
        };
        defer self.allocator.free(snap);
        for (snap) |h| h.call(args);
    }

    pub fn raiseProgress(self: *Dispatcher, args: ProgressArgs) void {
        if (self.operation) |operation| operation.progress(.{
            .stage = "transaction",
            .completed = @intCast(args.current),
            .total = @intCast(args.howmany),
            .percentage = @floatFromInt(std.math.clamp(args.percent, 0, 100)),
            .message = args.pkg_name,
            .native_code = args.progress_type,
        });
        self.dispatch(ProgressArgs, &self.progress, args);
    }

    pub fn raiseQuestion(self: *Dispatcher, io: std.Io, args: QuestionArgs) QuestionResponse {
        if (self.common_question_response) |*response| {
            response.deinit(self.allocator);
            self.common_question_response = null;
        }

        if (self.operation) |operation| {
            const option_count = if (args.provider_options) |options| options.len else args.options.len;
            const common_options_optional = self.allocator.alloc(operation_api.QuestionOption, option_count) catch null;
            if (common_options_optional) |common_options| {
                defer self.allocator.free(common_options);
                if (args.provider_options) |options| {
                    for (options, common_options) |option, *target| target.* = .{
                        .id = option.name,
                        .label = option.name,
                        .description = option.description,
                        .is_installed = option.is_installed,
                    };
                } else {
                    for (args.options, common_options) |option, *target| target.* = .{
                        .id = option,
                        .label = option,
                    };
                }

                const common_kind = commonQuestionKind(args);
                var answer = operation.ask(.{
                    .kind = common_kind,
                    .purpose = commonQuestionPurpose(args),
                    .prompt = args.question orelse "Continue?",
                    .arguments = args.arguments,
                    .options = common_options,
                    .dependency_name = args.dependency_name,
                }) catch |err| {
                    if (err == error.Cancelled) return .{ .answer = 0 };
                    operation.reportError(err, "Failed to obtain an ALPM question response", "alpm", args.question_type, false);
                    return .{};
                };

                const mapped = mapCommonQuestionResponse(common_kind, answer.response, common_options);
                if (mapped) |response| {
                    self.common_question_response = answer;
                    return response;
                }
                answer.deinit(self.allocator);
            }
        }

        if (self.question.items.len == 0) return .{};

        const snap = self.allocator.dupe(Handler(QuestionArgs).T, self.question.items) catch self.question.items;
        defer if (snap.ptr != self.question.items.ptr) self.allocator.free(snap);

        // Reset the pending response before dispatching so handlers observe a
        // fresh question. The lock is released before invoking handlers so a
        // handler may call `respond` synchronously without self-deadlocking.
        self.question_mutex.lockUncancelable(io);
        self.question_response = .{};
        self.question_mutex.unlock(io);

        for (snap) |h| h.call(args);

        self.question_mutex.lockUncancelable(io);
        while (self.question_response.answer == null and
            self.question_response.choice == null and
            self.question_response.pkg == null)
        {
            self.question_cv.waitUncancelable(io, &self.question_mutex);
        }
        const response = self.question_response;
        self.question_mutex.unlock(io);
        return response;
    }

    pub fn respond(self: *Dispatcher, io: std.Io, response: QuestionResponse) void {
        self.question_mutex.lockUncancelable(io);
        self.question_response = response;
        self.question_cv.signal(io);
        self.question_mutex.unlock(io);
    }

    pub fn errorGeneration(self: *const Dispatcher) usize {
        return self.error_generation.load(.monotonic);
    }

    /// Marks synchronous failures raised through this dispatcher as
    /// recoverable and prefixes them with the caller's best-effort context.
    /// The returned scope restores the previous policy when it is deinitialized.
    pub fn beginRecoverableErrors(self: *Dispatcher, context: []const u8) RecoverableErrorScope {
        const previous = self.recoverable_error_context;
        self.recoverable_error_context = context;
        return .{ .dispatcher = self, .previous = previous };
    }

    pub fn recoverableErrorContext(self: *const Dispatcher) ?[]const u8 {
        return self.recoverable_error_context;
    }

    pub fn raiseError(self: *Dispatcher, args: ErrorArgs) void {
        _ = self.error_generation.fetchAdd(1, .monotonic);
        if (self.operation) |operation| {
            if (self.recoverable_error_context) |context| {
                const message = std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ context, args.message }) catch null;
                defer if (message) |owned| self.allocator.free(owned);
                operation.reportError(
                    error.AlpmOperationFailed,
                    message orelse context,
                    "alpm",
                    null,
                    true,
                );
            } else {
                operation.reportError(error.AlpmOperationFailed, args.message, "alpm", null, false);
            }
        }
        self.dispatch(ErrorArgs, &self.errorEvents, args);
    }

    pub fn raiseInformational(self: *Dispatcher, args: InformationalArgs) void {
        if (self.operation) |operation| operation.status(.information, args.message, "alpm.information", @intFromEnum(args.event_type));
        self.dispatch(InformationalArgs, &self.informational, args);
    }

    pub fn raiseScriptlet(self: *Dispatcher, args: ScriptletArgs) void {
        if (self.operation) |operation| operation.status(.information, args.line, "alpm.scriptlet", null);
        self.dispatch(ScriptletArgs, &self.scriptlet, args);
    }

    pub fn raiseHook(self: *Dispatcher, args: HookArgs) void {
        if (self.operation) |operation| operation.progress(.{
            .stage = "hook",
            .completed = @intCast(args.position),
            .total = @intCast(args.total),
            .percentage = if (args.total == 0) 100 else @as(f64, @floatFromInt(args.position)) * 100.0 / @as(f64, @floatFromInt(args.total)),
            .message = args.description,
        });
        self.dispatch(HookArgs, &self.hook, args);
    }

    pub fn raisePacnew(self: *Dispatcher, args: PacnewArgs) void {
        if (self.operation) |operation| operation.status(.warning, args.file orelse "A pacnew file was created", "alpm.pacnew", null);
        self.dispatch(PacnewArgs, &self.pacnew, args);
    }

    pub fn raisePacsave(self: *Dispatcher, args: PacsaveArgs) void {
        if (self.operation) |operation| operation.status(.warning, args.file orelse "A pacsave file was created", "alpm.pacsave", null);
        self.dispatch(PacsaveArgs, &self.pacsave, args);
    }

    pub fn raiseReplaces(self: *Dispatcher, args: ReplacesArgs) void {
        if (self.operation) |operation| {
            const message = replacementMessage(self.allocator, args) catch null;
            defer if (message) |value| self.allocator.free(value);
            operation.status(.information, message orelse args.pkg_name, "alpm.replaces", null);
        }
        self.dispatch(ReplacesArgs, &self.replaces, args);
    }
};

pub const RecoverableErrorScope = struct {
    dispatcher: *Dispatcher,
    previous: ?[]const u8,
    active: bool = true,

    pub fn deinit(self: *RecoverableErrorScope) void {
        if (!self.active) return;
        self.dispatcher.recoverable_error_context = self.previous;
        self.active = false;
    }
};

fn replacementMessage(allocator: std.mem.Allocator, args: ReplacesArgs) ![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    try output.writer.print("{s}/{s} replaces ", .{ args.repository, args.pkg_name });
    for (args.replaces, 0..) |replacement, index| {
        if (index > 0) try output.writer.writeByte(',');
        try output.writer.writeAll(replacement);
    }
    return output.toOwnedSlice();
}

fn commonQuestionKind(args: QuestionArgs) operation_api.QuestionKind {
    const question_type = if (args.question_type < 0)
        bindings.libalpm.QuestionType.unknown
    else
        bindings.libalpm.QuestionType.fromQuestionType(@intCast(args.question_type));

    return switch (question_type) {
        .select_provider => .select_provider,
        .select_optional_dependencies => .select_optional_dependencies,
        .unknown => if (args.provider_options != null)
            .select_provider
        else if (args.options.len != 0)
            .select_one
        else
            .confirmation,
        else => .confirmation,
    };
}

fn mapCommonQuestionResponse(
    kind: operation_api.QuestionKind,
    response: operation_api.QuestionResponse,
    options: []const operation_api.QuestionOption,
) ?QuestionResponse {
    return switch (kind) {
        .confirmation => switch (response) {
            .accepted => .{ .answer = 1 },
            .declined => .{ .answer = 0 },
            .choice => |choice| mapConfirmationChoice(choice, options),
            .choices => |choices| if (choices.len == 0) .{} else mapConfirmationChoice(choices[0], options),
            .default, .deferred => null,
            .package => |pkg| .{ .pkg = pkg },
        },
        .select_optional_dependencies => switch (response) {
            .choice => |choice| mapPackageChoice(choice, options),
            .choices => |choices| .{ .selected_indices = choices },
            .package => |pkg| .{ .pkg = pkg },
            .declined => .{},
            .accepted => if (options.len == 0) .{} else .{ .pkg = options[0].id },
            .default, .deferred => null,
        },
        else => switch (response) {
            .accepted => .{ .answer = 1 },
            .declined => .{ .answer = 0 },
            .choice => |choice| mapIndexChoice(choice, options),
            .choices => |choices| if (choices.len == 0) .{} else mapIndexChoice(choices[0], options),
            .package => |pkg| .{ .pkg = pkg },
            .default, .deferred => null,
        },
    };
}

fn commonQuestionPurpose(args: QuestionArgs) operation_api.QuestionPurpose {
    const question_type = if (args.question_type < 0)
        bindings.libalpm.QuestionType.unknown
    else
        bindings.libalpm.QuestionType.fromQuestionType(
            @intCast(args.question_type),
        );

    return switch (question_type) {
        .conflict_package => .package_conflict,
        else => .generic,
    };
}

fn mapConfirmationChoice(choice: usize, options: []const operation_api.QuestionOption) ?QuestionResponse {
    if (choice >= options.len) return null;
    return .{ .answer = @intFromBool(choice == 0) };
}

fn mapPackageChoice(choice: usize, options: []const operation_api.QuestionOption) ?QuestionResponse {
    if (choice >= options.len) return null;
    return .{ .pkg = options[choice].id };
}

fn mapIndexChoice(choice: usize, options: []const operation_api.QuestionOption) ?QuestionResponse {
    if (choice >= options.len) return null;
    return .{ .choice = std.math.cast(c_int, choice) orelse return null };
}

test {
    @import("std").testing.refAllDecls(@This());
}

test "dispatches to all handlers" {
    var gpa = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = gpa.allocator();
    defer gpa.deinit();

    var disp = Dispatcher.init(allocator);
    defer disp.deinit();

    var called = false;

    const handler = Handler(ProgressArgs).T{
        .function = setBoolCallback(ProgressArgs),
        .data = @ptrCast(&called),
    };
    _ = disp.addProgressHandler(handler) catch unreachable;

    disp.raiseProgress(.{ .progress_type = 0, .pkg_name = null, .percent = 0, .howmany = 0, .current = 0 });
    if (!called) return error.TestFailed;
}

test "remove handler" {
    var gpa = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = gpa.allocator();
    defer gpa.deinit();

    var disp = Dispatcher.init(allocator);
    defer disp.deinit();

    var called = false;
    const handler = Handler(ProgressArgs).T{
        .function = setBoolCallback(ProgressArgs),
        .data = @ptrCast(&called),
    };
    const idx = disp.addProgressHandler(handler) catch unreachable;
    disp.removeProgressHandler(idx);

    disp.raiseProgress(.{ .progress_type = 0, .pkg_name = null, .percent = 0, .howmany = 0, .current = 0 });
    if (called) return error.TestFailed;
}

test "safe iteration during dispatch" {
    var gpa = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = gpa.allocator();
    defer gpa.deinit();

    var disp = Dispatcher.init(allocator);
    defer disp.deinit();

    var call_count: usize = 0;

    const handlerA = Handler(ProgressArgs).T{
        .function = incrementCallback(ProgressArgs),
        .data = @ptrCast(&call_count),
    };
    _ = disp.addProgressHandler(handlerA) catch unreachable;

    const handlerB = Handler(ProgressArgs).T{
        .function = removeHandlerCallback,
        .data = @ptrCast(&disp),
    };
    _ = disp.addProgressHandler(handlerB) catch unreachable;

    const handlerC = Handler(ProgressArgs).T{
        .function = incrementCallback(ProgressArgs),
        .data = @ptrCast(&call_count),
    };
    _ = disp.addProgressHandler(handlerC) catch unreachable;

    disp.raiseProgress(.{ .progress_type = 0, .pkg_name = null, .percent = 0, .howmany = 0, .current = 0 });

    // Handler B removes handler C mid-dispatch, but because the loop iterates
    // over a snapshot taken before dispatch, both incrementing handlers (A and
    // C) still run exactly once.
    if (call_count != 2) return error.TestFailed;
}

test "no handlers" {
    var gpa = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = gpa.allocator();
    defer gpa.deinit();

    var disp = Dispatcher.init(allocator);
    defer disp.deinit();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    disp.raiseProgress(.{ .progress_type = 0, .pkg_name = null, .percent = 0, .howmany = 0, .current = 0 });
    disp.raiseError(.{ .message = "test" });
    _ = disp.raiseQuestion(io, .{ .question = "test?", .question_type = 0, .options = &[_][]const u8{}, .response = null, .provider_options = null, .dependency_name = null });
}

test "question blocking" {
    var gpa = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = gpa.allocator();
    defer gpa.deinit();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var disp = Dispatcher.init(allocator);
    defer disp.deinit();

    var ctx = QuestionContext{ .disp = &disp, .io = io };
    const handler = Handler(QuestionArgs).T{
        .function = questionCallback,
        .data = @ptrCast(&ctx),
    };
    _ = disp.addQuestionHandler(handler) catch unreachable;

    const response = disp.raiseQuestion(io, .{
        .question = "test?",
        .question_type = 0,
        .options = &[_][]const u8{ "yes", "no" },
        .response = null,
        .provider_options = null,
        .dependency_name = null,
    });

    if (response.answer != 0) return error.TestFailed;
}

test "multiple event types" {
    var gpa = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = gpa.allocator();
    defer gpa.deinit();

    var disp = Dispatcher.init(allocator);
    defer disp.deinit();

    var progress_called = false;
    var error_called = false;

    const progress_handler = Handler(ProgressArgs).T{
        .function = setBoolCallback(ProgressArgs),
        .data = @ptrCast(&progress_called),
    };
    _ = disp.addProgressHandler(progress_handler) catch unreachable;

    const error_handler = Handler(ErrorArgs).T{
        .function = setBoolCallback(ErrorArgs),
        .data = @ptrCast(&error_called),
    };
    _ = disp.addErrorHandler(error_handler) catch unreachable;

    disp.raiseProgress(.{ .progress_type = 0, .pkg_name = null, .percent = 0, .howmany = 0, .current = 0 });
    disp.raiseError(.{ .message = "test error" });

    if (!progress_called) return error.TestFailed;
    if (!error_called) return error.TestFailed;
}

test "add returns sequential indices" {
    var gpa = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = gpa.allocator();
    defer gpa.deinit();

    var disp = Dispatcher.init(allocator);
    defer disp.deinit();

    var called = false;
    const handler = Handler(ProgressArgs).T{
        .function = setBoolCallback(ProgressArgs),
        .data = @ptrCast(&called),
    };

    const idx0 = disp.addProgressHandler(handler) catch unreachable;
    const idx1 = disp.addProgressHandler(handler) catch unreachable;
    const idx2 = disp.addProgressHandler(handler) catch unreachable;

    if (idx0 != 0) return error.TestFailed;
    if (idx1 != 1) return error.TestFailed;
    if (idx2 != 2) return error.TestFailed;
}

test "multiple handlers on one event all fire" {
    var gpa = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = gpa.allocator();
    defer gpa.deinit();

    var disp = Dispatcher.init(allocator);
    defer disp.deinit();

    var call_count: usize = 0;
    const handler = Handler(ProgressArgs).T{
        .function = incrementCallback(ProgressArgs),
        .data = @ptrCast(&call_count),
    };
    _ = disp.addProgressHandler(handler) catch unreachable;
    _ = disp.addProgressHandler(handler) catch unreachable;
    _ = disp.addProgressHandler(handler) catch unreachable;

    disp.raiseProgress(.{ .progress_type = 0, .pkg_name = null, .percent = 0, .howmany = 0, .current = 0 });

    if (call_count != 3) return error.TestFailed;
}

test "remove non-last handler keeps the others" {
    var gpa = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = gpa.allocator();
    defer gpa.deinit();

    var disp = Dispatcher.init(allocator);
    defer disp.deinit();

    var called_a = false;
    var called_b = false;
    var called_c = false;

    _ = disp.addProgressHandler(.{ .function = setBoolCallback(ProgressArgs), .data = @ptrCast(&called_a) }) catch unreachable;
    const idx_b = disp.addProgressHandler(.{ .function = setBoolCallback(ProgressArgs), .data = @ptrCast(&called_b) }) catch unreachable;
    _ = disp.addProgressHandler(.{ .function = setBoolCallback(ProgressArgs), .data = @ptrCast(&called_c) }) catch unreachable;

    // Removing the middle handler exercises the `swapRemove` branch (index !=
    // last), which moves the final handler into the freed slot.
    disp.removeProgressHandler(idx_b);

    disp.raiseProgress(.{ .progress_type = 0, .pkg_name = null, .percent = 0, .howmany = 0, .current = 0 });

    if (!called_a) return error.TestFailed;
    if (called_b) return error.TestFailed;
    if (!called_c) return error.TestFailed;
}

test "remove out-of-bounds index is a no-op" {
    var gpa = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = gpa.allocator();
    defer gpa.deinit();

    var disp = Dispatcher.init(allocator);
    defer disp.deinit();

    var called = false;
    _ = disp.addProgressHandler(.{ .function = setBoolCallback(ProgressArgs), .data = @ptrCast(&called) }) catch unreachable;

    // Out-of-range removals should be ignored rather than panic or drop the
    // existing handler.
    disp.removeProgressHandler(99);
    disp.removeProgressHandler(1);

    disp.raiseProgress(.{ .progress_type = 0, .pkg_name = null, .percent = 0, .howmany = 0, .current = 0 });

    if (!called) return error.TestFailed;
}

test "handler receives the raised args" {
    var gpa = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = gpa.allocator();
    defer gpa.deinit();

    var disp = Dispatcher.init(allocator);
    defer disp.deinit();

    var captured = ProgressCapture{};
    _ = disp.addProgressHandler(.{ .function = captureProgressCallback, .data = @ptrCast(&captured) }) catch unreachable;

    disp.raiseProgress(.{ .progress_type = 2, .pkg_name = "pkg", .percent = 42, .howmany = 7, .current = 3 });

    const args = captured.args orelse return error.TestFailed;
    if (args.progress_type != 2) return error.TestFailed;
    if (args.percent != 42) return error.TestFailed;
    if (args.howmany != 7) return error.TestFailed;
    if (args.current != 3) return error.TestFailed;
    const name = args.pkg_name orelse return error.TestFailed;
    if (!std.mem.eql(u8, name, "pkg")) return error.TestFailed;
}

test "question propagates full response" {
    var gpa = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = gpa.allocator();
    defer gpa.deinit();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var disp = Dispatcher.init(allocator);
    defer disp.deinit();

    var ctx = QuestionContext{ .disp = &disp, .io = io };
    _ = disp.addQuestionHandler(.{ .function = questionFullCallback, .data = @ptrCast(&ctx) }) catch unreachable;

    const response = disp.raiseQuestion(io, .{
        .question = "pick?",
        .question_type = 1,
        .options = &[_][]const u8{ "a", "b" },
    });

    if (response.answer != 1) return error.TestFailed;
    if (response.choice != 3) return error.TestFailed;
    const pkg = response.pkg orelse return error.TestFailed;
    if (!std.mem.eql(u8, pkg, "pkgname")) return error.TestFailed;
}

test "question accepts choice-only and package-only responses" {
    var gpa = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = gpa.allocator();
    defer gpa.deinit();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var disp = Dispatcher.init(allocator);
    defer disp.deinit();

    var ctx = QuestionResponseContext{
        .disp = &disp,
        .io = io,
        .response = .{ .choice = 3 },
    };
    _ = disp.addQuestionHandler(.{
        .function = questionResponseCallback,
        .data = @ptrCast(&ctx),
    }) catch unreachable;

    var response = disp.raiseQuestion(io, .{
        .question = "choose?",
        .question_type = 1,
        .options = &[_][]const u8{ "a", "b" },
    });
    if (response.answer != null) return error.TestFailed;
    if (response.choice != 3) return error.TestFailed;
    if (response.pkg != null) return error.TestFailed;

    ctx.response = .{ .pkg = "selected-package" };
    response = disp.raiseQuestion(io, .{
        .question = "package?",
        .question_type = 1,
        .options = &[_][]const u8{"selected-package"},
    });
    if (response.answer != null) return error.TestFailed;
    if (response.choice != null) return error.TestFailed;
    const pkg = response.pkg orelse return error.TestFailed;
    if (!std.mem.eql(u8, pkg, "selected-package")) return error.TestFailed;
}

test "common ALPM confirmation maps accepted and declined answers" {
    const Responder = struct {
        response: operation_api.QuestionResponse,
        calls: usize = 0,

        fn answer(data: ?*anyopaque, question: operation_api.Question) operation_api.QuestionResponse {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            std.testing.expect(question.kind == .confirmation) catch unreachable;
            std.testing.expectEqualStrings("Continue?", question.prompt) catch unreachable;
            self.calls += 1;
            return self.response;
        }
    };

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var context = operation_api.OperationContext.init(std.testing.allocator, threaded.io());
    defer context.deinit();
    var responder: Responder = .{ .response = .accepted };
    context.setQuestionHandler(.{ .function = Responder.answer, .data = &responder });
    var operation = context.begin(.{ .backend = .alpm, .kind = .install });
    defer operation.finish(.success);
    var dispatcher = Dispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();
    dispatcher.setOperation(&operation);

    const options = [_][]const u8{ "yes", "no" };
    var response = dispatcher.raiseQuestion(threaded.io(), .{
        .question = "Continue?",
        .question_type = @intFromEnum(bindings.libalpm.QuestionType.install_ignore),
        .options = &options,
    });
    try std.testing.expectEqual(@as(?c_int, 1), response.answer);

    responder.response = .declined;
    response = dispatcher.raiseQuestion(threaded.io(), .{
        .question = "Continue?",
        .question_type = @intFromEnum(bindings.libalpm.QuestionType.install_ignore),
        .options = &options,
    });
    try std.testing.expectEqual(@as(?c_int, 0), response.answer);
    try std.testing.expectEqual(@as(usize, 2), responder.calls);
}

test "common ALPM optional dependency choices preserve every selected index" {
    const Responder = struct {
        saw_provider_metadata: bool = false,
        response: operation_api.QuestionResponse = .{ .choices = &.{ 0, 1 } },

        fn answer(data: ?*anyopaque, question: operation_api.Question) operation_api.QuestionResponse {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            std.testing.expect(question.kind == .select_optional_dependencies) catch unreachable;
            std.testing.expectEqual(@as(usize, 2), question.options.len) catch unreachable;
            std.testing.expectEqualStrings("second description", question.options[1].description) catch unreachable;
            std.testing.expect(question.options[1].is_installed) catch unreachable;
            self.saw_provider_metadata = true;
            return self.response;
        }
    };

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var context = operation_api.OperationContext.init(std.testing.allocator, threaded.io());
    defer context.deinit();
    var responder: Responder = .{};
    context.setQuestionHandler(.{ .function = Responder.answer, .data = &responder });
    var operation = context.begin(.{ .backend = .alpm, .kind = .install });
    defer operation.finish(.success);
    var dispatcher = Dispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();
    dispatcher.setOperation(&operation);

    const names = [_][]const u8{ "first-package", "second-package" };
    const providers = [_]ProviderOption{
        .{ .name = "first-package", .description = "first description", .is_installed = false },
        .{ .name = "second-package", .description = "second description", .is_installed = true },
    };
    var response = dispatcher.raiseQuestion(threaded.io(), .{
        .question = "Select an optional dependency",
        .question_type = @intFromEnum(bindings.libalpm.QuestionType.select_optional_dependencies),
        .options = &names,
        .provider_options = &providers,
    });

    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, response.selected_indices);
    try std.testing.expect(responder.saw_provider_metadata);

    responder.response = .{ .choice = 1 };
    response = dispatcher.raiseQuestion(threaded.io(), .{
        .question = "Select an optional dependency",
        .question_type = @intFromEnum(bindings.libalpm.QuestionType.select_optional_dependencies),
        .options = &names,
        .provider_options = &providers,
    });
    try std.testing.expectEqualStrings("second-package", response.pkg.?);
}

test "question blocks until answered from another task" {
    var gpa = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = gpa.allocator();
    defer gpa.deinit();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var disp = Dispatcher.init(allocator);
    defer disp.deinit();

    // Unlike the synchronous cases, this handler does NOT respond. It spawns a
    // concurrent task that answers from a different thread, so the wait loop in
    // `raiseQuestion` genuinely blocks and is woken via the condition variable.
    var ctx = AsyncQuestionContext{ .disp = &disp, .io = io };
    _ = disp.addQuestionHandler(.{ .function = asyncQuestionCallback, .data = @ptrCast(&ctx) }) catch unreachable;

    const response = disp.raiseQuestion(io, .{
        .question = "async?",
        .question_type = 0,
        .options = &[_][]const u8{ "yes", "no" },
    });

    // Reap the responder task before its captured pointers go out of scope.
    if (ctx.future) |*f| f.await(io);

    if (!ctx.handler_called) return error.TestFailed;
    if (response.answer != 7) return error.TestFailed;
}

test "informational, scriptlet and hook handlers dispatch" {
    var gpa = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = gpa.allocator();
    defer gpa.deinit();

    var disp = Dispatcher.init(allocator);
    defer disp.deinit();

    var info_called = false;
    var scriptlet_called = false;
    var hook_called = false;

    _ = disp.addInformationalHandler(.{ .function = setBoolCallback(InformationalArgs), .data = @ptrCast(&info_called) }) catch unreachable;
    _ = disp.addScriptletHandler(.{ .function = setBoolCallback(ScriptletArgs), .data = @ptrCast(&scriptlet_called) }) catch unreachable;
    _ = disp.addHookHandler(.{ .function = setBoolCallback(HookArgs), .data = @ptrCast(&hook_called) }) catch unreachable;

    disp.raiseInformational(.{ .event_type = .transaction_start, .message = "info" });
    disp.raiseScriptlet(.{ .line = "line" });
    disp.raiseHook(.{ .description = "hook", .position = 1, .total = 2 });

    if (!info_called) return error.TestFailed;
    if (!scriptlet_called) return error.TestFailed;
    if (!hook_called) return error.TestFailed;
}

test "pacnew, pacsave and replaces handlers dispatch" {
    var gpa = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = gpa.allocator();
    defer gpa.deinit();

    var disp = Dispatcher.init(allocator);
    defer disp.deinit();

    var pacnew_called = false;
    var pacsave_called = false;
    var replaces_called = false;

    _ = disp.addPacnewHandler(.{ .function = setBoolCallback(PacnewArgs), .data = @ptrCast(&pacnew_called) }) catch unreachable;
    _ = disp.addPacsaveHandler(.{ .function = setBoolCallback(PacsaveArgs), .data = @ptrCast(&pacsave_called) }) catch unreachable;
    _ = disp.addReplacesHandler(.{ .function = setBoolCallback(ReplacesArgs), .data = @ptrCast(&replaces_called) }) catch unreachable;

    disp.raisePacnew(.{ .file = "a.pacnew" });
    disp.raisePacsave(.{ .pkg_name = "pkg", .file = "a.pacsave" });
    disp.raiseReplaces(.{ .pkg_name = "old", .repository = "core", .replaces = &[_][]const u8{"new"} });

    if (!pacnew_called) return error.TestFailed;
    if (!pacsave_called) return error.TestFailed;
    if (!replaces_called) return error.TestFailed;
}

test "replacement operation status matches the standard CLI message" {
    const message = try replacementMessage(std.testing.allocator, .{
        .pkg_name = "new-package",
        .repository = "extra",
        .replaces = &.{ "old-package", "older-package" },
    });
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings(
        "extra/new-package replaces old-package,older-package",
        message,
    );
}

test "handlers isolated per event type" {
    var gpa = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = gpa.allocator();
    defer gpa.deinit();

    var disp = Dispatcher.init(allocator);
    defer disp.deinit();

    var error_called = false;
    _ = disp.addErrorHandler(.{ .function = setBoolCallback(ErrorArgs), .data = @ptrCast(&error_called) }) catch unreachable;

    // Raising an unrelated event must not invoke the error handler.
    disp.raiseProgress(.{ .progress_type = 0, .pkg_name = null, .percent = 0, .howmany = 0, .current = 0 });

    if (error_called) return error.TestFailed;
}

test "Handler.call forwards data and args" {
    var captured = ProgressCapture{};
    const handler = Handler(ProgressArgs).T{
        .function = captureProgressCallback,
        .data = @ptrCast(&captured),
    };

    handler.call(.{ .progress_type = 5, .pkg_name = null, .percent = 10, .howmany = 0, .current = 0 });

    const args = captured.args orelse return error.TestFailed;
    if (args.progress_type != 5) return error.TestFailed;
    if (args.percent != 10) return error.TestFailed;
}

fn setBoolCallback(comptime Args: type) *const fn (?*anyopaque, Args) void {
    return struct {
        fn cb(data: ?*anyopaque, args: Args) void {
            _ = args;
            const called: *bool = @ptrCast(@alignCast(data));
            called.* = true;
        }
    }.cb;
}

fn incrementCallback(comptime Args: type) *const fn (?*anyopaque, Args) void {
    return struct {
        fn cb(data: ?*anyopaque, args: Args) void {
            _ = args;
            const count: *usize = @ptrCast(@alignCast(data));
            count.* += 1;
        }
    }.cb;
}

fn removeHandlerCallback(data: ?*anyopaque, args: ProgressArgs) void {
    _ = args;
    const disp: *Dispatcher = @ptrCast(@alignCast(data));
    disp.removeProgressHandler(2);
}

const QuestionContext = struct {
    disp: *Dispatcher,
    io: std.Io,
};

fn questionCallback(data: ?*anyopaque, args: QuestionArgs) void {
    _ = args;
    const ctx: *QuestionContext = @ptrCast(@alignCast(data));
    ctx.disp.respond(ctx.io, .{ .answer = 0, .pkg = null, .choice = null });
}

fn questionFullCallback(data: ?*anyopaque, args: QuestionArgs) void {
    _ = args;
    const ctx: *QuestionContext = @ptrCast(@alignCast(data));
    ctx.disp.respond(ctx.io, .{ .answer = 1, .pkg = "pkgname", .choice = 3 });
}

const QuestionResponseContext = struct {
    disp: *Dispatcher,
    io: std.Io,
    response: QuestionResponse,
};

fn questionResponseCallback(data: ?*anyopaque, args: QuestionArgs) void {
    _ = args;
    const ctx: *QuestionResponseContext = @ptrCast(@alignCast(data));
    ctx.disp.respond(ctx.io, ctx.response);
}

const AsyncQuestionContext = struct {
    disp: *Dispatcher,
    io: std.Io,
    future: ?std.Io.Future(void) = null,
    handler_called: bool = false,
};

fn asyncResponder(disp: *Dispatcher, io: std.Io) void {
    disp.respond(io, .{ .answer = 7, .pkg = null, .choice = null });
}

fn asyncQuestionCallback(data: ?*anyopaque, args: QuestionArgs) void {
    _ = args;
    const ctx: *AsyncQuestionContext = @ptrCast(@alignCast(data));
    ctx.handler_called = true;
    // The response reset in `raiseQuestion` happens before this handler runs, so
    // the concurrent answer can never be clobbered regardless of scheduling.
    ctx.future = ctx.io.concurrent(asyncResponder, .{ ctx.disp, ctx.io }) catch {
        // Concurrency unavailable: fall back to answering inline so the wait
        // still completes.
        asyncResponder(ctx.disp, ctx.io);
        return;
    };
}

const ProgressCapture = struct {
    args: ?ProgressArgs = null,
};

fn captureProgressCallback(data: ?*anyopaque, args: ProgressArgs) void {
    const cap: *ProgressCapture = @ptrCast(@alignCast(data));
    cap.args = args;
}
