const std = @import("std");
const bindings = @import("bindings.zig");
const c = bindings.libalpm;

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
    options: []const []const u8,
    response: ?c_int = null,
    provider_options: ?[]ProviderOption = null,
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
    event_type: c_int,
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
        };
    }

    pub fn deinit(self: *Dispatcher) void {
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
        self.dispatch(ProgressArgs, &self.progress, args);
    }

    pub fn raiseQuestion(self: *Dispatcher, io: std.Io, args: QuestionArgs) QuestionResponse {
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
        while (self.question_response.answer == null) {
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

    pub fn raiseError(self: *Dispatcher, args: ErrorArgs) void {
        self.dispatch(ErrorArgs, &self.errorEvents, args);
    }

    pub fn raiseInformational(self: *Dispatcher, args: InformationalArgs) void {
        self.dispatch(InformationalArgs, &self.informational, args);
    }

    pub fn raiseScriptlet(self: *Dispatcher, args: ScriptletArgs) void {
        self.dispatch(ScriptletArgs, &self.scriptlet, args);
    }

    pub fn raiseHook(self: *Dispatcher, args: HookArgs) void {
        self.dispatch(HookArgs, &self.hook, args);
    }

    pub fn raisePacnew(self: *Dispatcher, args: PacnewArgs) void {
        self.dispatch(PacnewArgs, &self.pacnew, args);
    }

    pub fn raisePacsave(self: *Dispatcher, args: PacsaveArgs) void {
        self.dispatch(PacsaveArgs, &self.pacsave, args);
    }

    pub fn raiseReplaces(self: *Dispatcher, args: ReplacesArgs) void {
        self.dispatch(ReplacesArgs, &self.replaces, args);
    }
};

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

    disp.raiseInformational(.{ .event_type = 0, .message = "info" });
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
