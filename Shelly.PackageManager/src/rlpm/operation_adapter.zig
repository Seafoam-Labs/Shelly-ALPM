//! RLPM callback adapter used by the selected PackageManager backend.
//! Initialize at its final address before a transaction; release the transaction
//! before deinit. Context and operation outlive the adapter. UI question payloads
//! are owned here through the deferred response, then expire when ask returns.
const Adapter = @This();
const std = @import("std");
const rlpm = @import("Shelly_Rlpm");
const op = @import("operation_context");
const output = @import("native_output");
owner: *rlpm.Owner,
operation: *op.Operation,
previous: rlpm.Callbacks,
cancellation_subscription: op.SubscriptionId,
active_package: ?[]u8 = null,
active_reference: ?rlpm.PackageRef = null,
active_action: ?output.PackageAction = null,
downloads: std.StringHashMapUnmanaged(op.Operation) = .empty,
failure_handler: ?struct {
    function: *const fn (?*anyopaque, []const u8) void,
    data: ?*anyopaque,
} = null,

pub fn init(self: *Adapter, owner: *rlpm.Owner, operation: *op.Operation) !void {
    const subscription = try operation.context.subscribeCancellation(.{ .function = cancel, .data = owner });
    errdefer {
        _ = operation.context.unsubscribeCancellation(subscription);
        operation.context.waitForCancellationCallbacks();
    }
    const previous = owner.options().callbacks;
    self.* = .{ .owner = owner, .operation = operation, .previous = previous, .cancellation_subscription = subscription };
    var callbacks = previous;
    callbacks.question = null;
    callbacks.question_with_error = question;
    callbacks.question_context = self;
    callbacks.event = event;
    callbacks.event_context = self;
    callbacks.log = log;
    callbacks.log_context = self;
    callbacks.progress = progress;
    callbacks.progress_context = self;
    callbacks.download = download;
    callbacks.download_context = self;
    try owner.setCallbacks(callbacks);
    if (operation.isCancelled()) owner.requestCancellation();
}
pub fn deinit(self: *Adapter) !void {
    try self.owner.setCallbacks(self.previous);
    _ = self.operation.context.unsubscribeCancellation(self.cancellation_subscription);
    self.operation.context.waitForCancellationCallbacks();
    self.clearPackage();
    var downloads = self.downloads.iterator();
    while (downloads.next()) |entry| {
        entry.value_ptr.finish(if (self.operation.isCancelled()) .cancelled else .failed);
        self.operation.context.allocator.free(entry.key_ptr.*);
    }
    self.downloads.deinit(self.operation.context.allocator);
    self.* = undefined;
}
fn clearPackage(self: *Adapter) void {
    if (self.active_package) |package| self.operation.context.allocator.free(package);
    self.active_package = null;
    self.active_reference = null;
    self.active_action = null;
}
fn from(data: ?*anyopaque) *Adapter {
    return @ptrCast(@alignCast(data.?));
}
fn cancel(data: ?*anyopaque) void {
    const owner: *rlpm.Owner = @ptrCast(@alignCast(data.?));
    owner.requestCancellation();
}
fn cancelled(data: ?*anyopaque) bool {
    const owner: *rlpm.Owner = @ptrCast(@alignCast(data.?));
    owner.checkCancelled() catch return true;
    return false;
}
fn name(a: std.mem.Allocator, q: rlpm.Callbacks.Question, ref: rlpm.PackageRef) ![]const u8 {
    switch (q) {
        inline else => |value| if (@hasField(@TypeOf(value), "views")) {
            for (value.views) |view| if (std.meta.eql(view.reference, ref)) return view.package.name;
        },
    }
    return std.fmt.allocPrint(a, "package {d}:{d}:{d}", .{ @intFromEnum(ref.database.id), ref.generation, @intFromEnum(ref.id) });
}
fn question(data: ?*anyopaque, borrowed: *rlpm.Callbacks.Question) !void {
    const self = from(data);
    const allocator = self.operation.context.allocator;
    var owned = try rlpm.OwnedQuestion.init(allocator, borrowed.*);
    defer owned.deinit();
    const a = owned.arena.allocator();
    const q = &owned.question;
    var request: op.QuestionRequest = .{ .kind = .confirmation, .prompt = "", .default_response = .declined, .cancellation = .{ .data = self.owner, .check = cancelled } };
    switch (q.*) {
        .install_ignored => |value| request.prompt = try std.fmt.allocPrint(a, "Install ignored package {s}?", .{try name(a, q.*, value.package)}),
        .replace => |value| request.prompt = try std.fmt.allocPrint(a, "Replace {s} with {s}?", .{ try name(a, q.*, value.old), try name(a, q.*, value.new) }),
        .conflict => |value| {
            request.purpose = .package_conflict;
            request.prompt = try std.fmt.allocPrint(a, "Remove {s}, which conflicts with {s} ({s})?", .{ try name(a, q.*, value.second), try name(a, q.*, value.first), value.reason.name });
        },
        .corrupted => |value| request.prompt = try std.fmt.allocPrint(a, "Remove corrupted package file {s} ({s})?", .{ value.path, @errorName(value.reason) }),
        .remove_packages => |value| {
            request.prompt = "Skip targets whose dependencies cannot be resolved?";
            const arguments = try a.alloc([]const u8, value.packages.len);
            for (arguments, value.packages) |*argument, ref| argument.* = try name(a, q.*, ref);
            request.arguments = arguments;
        },
        .select_provider => |value| {
            request.kind = .select_provider;
            request.prompt = try std.fmt.allocPrint(a, "Select a provider for {s}", .{value.dependency.name});
            request.dependency_name = value.dependency.name;
            const options = try a.alloc(op.QuestionOption, value.candidates.len);
            for (options, value.candidates, 0..) |*option, ref, index| {
                const label = try name(a, q.*, ref);
                option.* = .{ .id = try std.fmt.allocPrint(a, "{d}", .{index}), .label = label, .is_selected = index == value.selected };
            }
            request.options = options;
            request.default_response = .{ .choice = value.selected };
        },
        .import_key => |value| {
            request.kind = .import_pgp_key;
            request.prompt = try std.fmt.allocPrint(a, "Import signing key {s} ({s})?", .{ value.key.fingerprint, value.key.user_id orelse "unknown user" });
            request.pgp_key_import = .{ .package_name = self.operation.envelope.subject orelse "", .fingerprint = value.key.fingerprint };
        },
    }
    var response = try self.operation.ask(request);
    defer response.deinit(allocator);
    try self.operation.checkCancelled();
    try self.owner.checkCancelled();
    const answer = if (response.response == .default) request.default_response else response.response;
    if (q.* == .select_provider) {
        if (answer != .choice) return error.InvalidAnswer;
        q.select_provider.selected = answer.choice;
    } else {
        const accepted = switch (answer) {
            .accepted => true,
            .declined => false,
            else => return error.InvalidAnswer,
        };
        switch (q.*) {
            .install_ignored => |*value| value.install = accepted,
            .replace => |*value| value.replace = accepted,
            .conflict => |*value| value.remove = accepted,
            .corrupted => |*value| value.remove = accepted,
            .remove_packages => |*value| value.skip = accepted,
            .import_key => |*value| value.import = accepted,
            .select_provider => unreachable,
        }
    }
    try rlpm.OwnedQuestion.applyAnswer(borrowed, q.*);
}
fn reportFailure(self: *Adapter, err: anyerror) void {
    var operation = self.operation.*;
    const issue = if (self.owner.transaction()) |tx| blk: {
        const manifest = tx.manifest() orelse break :blk null;
        const failure = manifest.failure orelse break :blk null;
        if (failure.package) |id| if (tx.plan()) |plan| {
            operation.envelope.subject = plan.package(id).name;
        };
        break :blk failure;
    } else null;
    const diagnostics = @import("diagnostics");
    const allocator = operation.context.allocator;
    const message = diagnostics.format(allocator, err, .{
        .operation = diagnostics.operationDescription(operation.envelope.kind),
        .subject = operation.envelope.subject,
        .path = if (issue) |failure| failure.path else null,
    }) catch {
        operation.reportError(err, @errorName(err), "rlpm", null, false);
        if (self.failure_handler) |handler| handler.function(handler.data, @errorName(err));
        return;
    };
    defer allocator.free(message);
    operation.reportError(err, message, "rlpm", null, false);
    if (self.failure_handler) |handler| handler.function(handler.data, message);
}
fn event(data: ?*anyopaque, value: rlpm.Callbacks.Event) void {
    const self = from(data);
    switch (value) {
        .lifecycle => |result| switch (result.state) {
            .completed => self.operation.finish(.success),
            .interrupted => self.operation.finish(.cancelled),
            .failed => {
                if (result.cause) |err| self.reportFailure(err);
                self.operation.finish(.failed);
            },
            .released => self.operation.finish(if (result.cause != null and result.cause.? != error.Cancelled) .failed else .cancelled),
            else => {},
        },
        .phase => |phase| {
            if (phaseEvent(phase.phase, phase.boundary)) |event_type| self.information(event_type);
        },
        .package_operation => |package_event| {
            const action = std.meta.stringToEnum(output.PackageAction, @tagName(package_event.operation)).?;
            const old = packageView(package_event.views, package_event.old);
            const package = packageView(package_event.views, package_event.new) orelse old;
            const package_name = if (package) |pkg| pkg.name else "unknown";
            switch (package_event.boundary) {
                .start => {
                    self.clearPackage();
                    // Callback views are borrowed. Progress arrives after this
                    // callback returns, so retain our own copy of the name.
                    self.active_package = self.operation.context.allocator.dupe(u8, package_name) catch null;
                    self.active_reference = package_event.new orelse package_event.old;
                    self.active_action = action;
                    const message = output.packageMessage(self.operation.context.allocator, action, package_name, if (package) |pkg| pkg.version.raw else "?", if (old) |pkg| pkg.version.raw else null) catch null;
                    defer if (message) |text| self.operation.context.allocator.free(text);
                    self.operation.status(.information, message orelse package_name, "alpm.information", @intFromEnum(output.EventType.package_operation_start));
                },
                .done => {
                    self.operation.packageStatus(.information, output.information(.package_operation_done).?, action.completionCode(), @intFromEnum(output.EventType.package_operation_done), package_name);
                    self.clearPackage();
                },
                .failed => self.clearPackage(),
            }
        },
        .hook => |hook| switch (hook.boundary) {
            .start => self.information(.hook_start),
            .done => self.information(.hook_done),
            .failed => {},
        },
        .database_missing => self.information(.database_missing),
        .optional_dependency_removed => self.information(.optdep_removal),
        .scriptlet_output => |message| self.operation.status(.information, message, "alpm.scriptlet", null),
        .pacnew_created => |backup| self.operation.status(.warning, backup.path, "alpm.pacnew", null),
        .pacsave_created => |backup| self.operation.status(.warning, backup.path, "alpm.pacsave", null),
        .hook_run => |hook| switch (hook.boundary) {
            .start => {
                var buffer: [512]u8 = undefined;
                const message = output.hookMessage(&buffer, hook.name, hook.description, hook.position, hook.total);
                self.operation.progress(.{
                    .stage = "hook",
                    .message = message,
                    .completed = hook.position,
                    .total = hook.total,
                    .percentage = if (hook.total == 0) 100 else @as(f64, @floatFromInt(hook.position)) * 100 / @as(f64, @floatFromInt(hook.total)),
                });
                self.operation.status(.information, message, "alpm.information", @intFromEnum(output.EventType.hook_run_start));
            },
            .done => self.information(.hook_run_done),
            .failed => {},
        },
        .diagnostic => |diagnostic| self.operation.reportError(diagnostic.cause, @errorName(diagnostic.cause), "rlpm", null, false),
    }
    if (self.previous.event) |callback| callback(self.previous.event_context, value);
}
fn packageView(views: []const rlpm.Callbacks.PackageView, ref: ?rlpm.PackageRef) ?*const rlpm.Package {
    const identity = ref orelse return null;
    for (views) |view| if (std.meta.eql(view.reference, identity)) return view.package;
    return null;
}
fn information(self: *Adapter, event_type: output.EventType) void {
    self.operation.status(.information, output.information(event_type) orelse return, "alpm.information", @intFromEnum(event_type));
}
fn phaseEvent(phase: rlpm.Callbacks.Phase, boundary: rlpm.Callbacks.Boundary) ?output.EventType {
    if (boundary == .failed) return switch (phase) {
        .database_retrieve => .db_retrieve_failed,
        .package_retrieve => .pkg_retrieve_failed,
        else => null,
    };
    const start = boundary == .start;
    return switch (phase) {
        .dependencies => if (start) .checkdeps_start else .checkdeps_done,
        .resolve_dependencies => if (start) .resolvedeps_start else .resolvedeps_done,
        .conflicts, .inter_conflicts => if (start) .interconflicts_start else .interconflicts_done,
        .file_conflicts => if (start) .fileconflicts_start else .fileconflicts_done,
        .transaction => if (start) .transaction_start else .transaction_done,
        .integrity => if (start) .integrity_start else .integrity_done,
        .load_packages => if (start) .load_start else .load_done,
        .disk_space => if (start) .diskspace_start else .diskspace_done,
        .keyring => if (start) .keyring_start else .keyring_done,
        .key_download => if (start) .key_download_start else .key_download_done,
        .database_retrieve => if (start) .db_retrieve_start else .db_retrieve_done,
        .package_retrieve => if (start) .pkg_retrieve_start else .pkg_retrieve_done,
    };
}
fn log(data: ?*anyopaque, value: rlpm.Callbacks.Log) void {
    const self = from(data);
    self.operation.status(switch (value.level) {
        .err => .warning,
        .warning => .warning,
        .debug => .debug,
        .function => .information,
    }, value.message, "rlpm.log", null);
    if (self.previous.log) |callback| callback(self.previous.log_context, value);
}

fn progress(data: ?*anyopaque, value: rlpm.Callbacks.Progress) void {
    const self = from(data);
    const package_matches = value.package != null and self.active_reference != null and std.meta.eql(value.package.?, self.active_reference.?);
    const code: ?i64 = switch (value.phase) {
        .transaction => if (package_matches and self.active_action != null) @intFromEnum(self.active_action.?) else null,
        .conflicts, .inter_conflicts, .file_conflicts => 5,
        .disk_space => 6,
        .integrity => 7,
        .load_packages => 8,
        .keyring => 9,
        else => null,
    };
    self.operation.progress(.{
        .stage = if (code != null) "transaction" else output.information(phaseEvent(value.phase, .start).?).?,
        .percentage = @floatFromInt(value.percent),
        .completed = value.position,
        .total = value.total,
        .message = if (package_matches) self.active_package else "",
        .native_code = code,
    });
    if (self.previous.progress) |callback| callback(self.previous.progress_context, value);
}
fn download(data: ?*anyopaque, value: rlpm.Callbacks.Download) void {
    const self = from(data);
    switch (value) {
        .init => {},
        .started => |update| downloadStatus(self.downloadOperation(update.name), update.name, "Retrieving package", "download.start"),
        .progress => |update| self.downloadOperation(update.name).progress(.{
            .stage = "download",
            .message = update.name,
            .bytes_completed = update.downloaded,
            .bytes_total = update.total,
            .native_code = downloadCode(update.name),
        }),
        .retry => |update| {
            const operation = self.downloadOperation(update.name);
            downloadStatus(operation, update.name, "Retrying download", if (update.resuming) "download.resume" else "download.retry");
            if (!update.resuming) operation.progress(.{ .stage = "download", .message = update.name, .bytes_completed = 0, .native_code = downloadCode(update.name) });
        },
        .transferred => |update| {
            const operation = self.downloadOperation(update.name);
            if (update.result == .updated) operation.progress(.{
                .stage = "download",
                .message = update.name,
                .bytes_completed = update.downloaded,
                .bytes_total = update.downloaded,
                .percentage = 100,
                .native_code = downloadCode(update.name),
            });
            if (update.result != .failed) downloadStatus(operation, update.name, if (update.result == .updated) "Package retrieval completed" else "Download skipped", if (update.result == .updated) "download.complete" else "download.skipped");
            self.finishDownload(update.name, update.result != .failed);
        },
        .processing => |update| {
            const stage: []const u8 = switch (update.stage) {
                .verification => "Verifying downloads",
                .publication => "Publishing downloads",
            };
            if (update.boundary == .start) downloadStatus(self.operation, update.name, stage, "acquisition.processing");
            self.operation.progress(.{
                .stage = stage,
                .message = update.name,
                .completed = if (update.boundary == .done) update.position else update.position -| 1,
                .total = update.total,
            });
        },
        .completed => |update| {
            // Acceptance failures never reopen an already completed transfer.
            // The transaction/sync caller supplies the detailed error.
            if (update.result == .failed) self.finishDownload(update.name, false);
        },
    }
    if (self.previous.download) |callback| callback(self.previous.download_context, value);
}
fn downloadStatus(operation: *op.Operation, file: []const u8, label: []const u8, code: []const u8) void {
    const message = std.fmt.allocPrint(operation.context.allocator, "{s}: {s}", .{ label, file }) catch return;
    defer operation.context.allocator.free(message);
    operation.status(.information, message, code, null);
}
fn finishDownload(self: *Adapter, file: []const u8, success: bool) void {
    if (self.downloads.fetchRemove(file)) |removed| {
        var child = removed.value;
        child.finish(if (success) .success else if (self.operation.isCancelled()) .cancelled else .failed);
        self.operation.context.allocator.free(removed.key);
    }
}
fn downloadCode(name_value: []const u8) i64 {
    return if (std.mem.endsWith(u8, name_value, ".db") or std.mem.endsWith(u8, name_value, ".db.sig")) 101 else 100;
}
fn downloadOperation(self: *Adapter, file: []const u8) *op.Operation {
    if (self.downloads.getPtr(file)) |operation| return operation;
    const allocator = self.operation.context.allocator;
    const owned_name = allocator.dupe(u8, file) catch return self.operation;
    const entry = self.downloads.getOrPut(allocator, owned_name) catch {
        allocator.free(owned_name);
        return self.operation;
    };
    entry.value_ptr.* = self.operation.child(.{ .backend = .download, .kind = .download, .subject = owned_name });
    return entry.value_ptr;
}

test "adapter owns all seven deferred question payloads and copies only answers" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var owner = try rlpm.Owner.init(std.testing.io, std.testing.allocator, .{ .root = path, .database_path = path }, &.{});
    defer owner.deinit() catch unreachable;
    var context = op.OperationContext.init(std.testing.allocator, std.testing.io);
    defer context.deinit();
    var operation = context.begin(.{ .backend = .alpm, .kind = .install });
    defer operation.finish(.success);
    var adapter: Adapter = undefined;
    try adapter.init(&owner, &operation);
    defer adapter.deinit() catch unreachable;
    const Handler = struct {
        fn answer(data: ?*anyopaque, q: op.Question) op.QuestionResponse {
            const ctx: *op.OperationContext = @ptrCast(@alignCast(data.?));
            ctx.respond(q.question_id, if (q.kind == .select_provider) .{ .choice = 0 } else .accepted) catch unreachable;
            return .deferred;
        }
    };
    context.setQuestionHandler(.{ .function = Handler.answer, .data = &context });
    const ref: rlpm.PackageRef = .{ .database = .{ .owner = @enumFromInt(1), .id = .local }, .generation = 1, .id = @enumFromInt(0) };
    var questions = [_]rlpm.Callbacks.Question{
        .{ .install_ignored = .{ .package = ref } },
        .{ .replace = .{ .old = ref, .new = ref, .database = ref.database } },
        .{ .conflict = .{ .first = ref, .second = ref, .reason = try rlpm.PackageRelation.parse("virtual>=1") } },
        .{ .corrupted = .{ .path = "cached.tar", .reason = error.ChecksumMismatch } },
        .{ .remove_packages = .{ .packages = &.{ref} } },
        .{ .select_provider = .{ .dependency = try rlpm.PackageRelation.parse("virtual"), .candidates = &.{ref} } },
        .{ .import_key = .{ .key = .{ .fingerprint = "0123456789" } } },
    };
    for (&questions) |*q| try owner.ask(q);
    try std.testing.expect(questions[0].install_ignored.install and questions[1].replace.replace and questions[2].conflict.remove and questions[3].corrupted.remove and questions[4].remove_packages.skip and questions[6].import_key.import);
    try std.testing.expectEqual(0, questions[5].select_provider.selected);
}

test "deferred answers survive the handler and both cancellation sources wake the wait" {
    const Pending = struct {
        ready: std.Io.Event = .unset,
        question: ?op.Question = null,
        owner: *rlpm.Owner,
        result: ?anyerror = null,
        answer_value: bool = false,
        fn handle(data: ?*anyopaque, q: op.Question) op.QuestionResponse {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.question = q;
            self.ready.set(std.testing.io);
            return .deferred;
        }
        fn run(self: *@This()) void {
            var q: rlpm.Callbacks.Question = .{ .import_key = .{ .key = .{ .fingerprint = "owned-fingerprint", .user_id = "key owner" } } };
            self.owner.ask(&q) catch |err| {
                self.result = err;
                return;
            };
            self.answer_value = q.import_key.import;
        }
    };
    for (0..3) |scenario| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(path);
        var owner = try rlpm.Owner.init(std.testing.io, std.testing.allocator, .{ .root = path, .database_path = path }, &.{});
        defer owner.deinit() catch unreachable;
        var context = op.OperationContext.init(std.testing.allocator, std.testing.io);
        defer context.deinit();
        var operation = context.begin(.{ .backend = .alpm, .kind = .install });
        defer operation.finish(.cancelled);
        var adapter: Adapter = undefined;
        try adapter.init(&owner, &operation);
        defer adapter.deinit() catch unreachable;
        var pending: Pending = .{ .owner = &owner };
        context.setQuestionHandler(.{ .function = Pending.handle, .data = &pending });
        const worker = try std.Thread.spawn(.{}, Pending.run, .{&pending});
        // Always wake and join the borrower, including on a failed expectation.
        var joined = false;
        defer if (!joined) {
            context.cancel();
            worker.join();
        };
        try pending.ready.wait(std.testing.io);
        const q = pending.question.?;
        try std.testing.expectEqualStrings("owned-fingerprint", q.pgp_key_import.?.fingerprint);
        try std.testing.expect(std.mem.indexOf(u8, q.prompt, "key owner") != null);
        switch (scenario) {
            0 => try context.respond(q.question_id, .accepted),
            1 => context.cancel(),
            2 => owner.requestCancellation(),
            else => unreachable,
        }
        worker.join();
        joined = true;
        if (scenario == 0) {
            try std.testing.expect(pending.result == null and pending.answer_value);
        } else try std.testing.expectEqual(error.Cancelled, pending.result.?);
        try std.testing.expectError(error.UnknownQuestion, context.respond(q.question_id, .accepted));
    }
}

test "lifecycle completion reports failures and abandonment once" {
    const Capture = struct {
        completions: usize = 0,
        status: ?op.CompletionStatus = null,
        fn event(data: ?*anyopaque, value: op.Event) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            if (value == .completed) {
                self.completions += 1;
                self.status = value.completed.status;
            }
        }
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var owner = try rlpm.Owner.init(std.testing.io, std.testing.allocator, .{ .root = path, .database_path = path }, &.{});
    defer owner.deinit() catch unreachable;
    var context = op.OperationContext.init(std.testing.allocator, std.testing.io);
    defer context.deinit();
    var capture: Capture = .{};
    _ = try context.subscribe(.{ .function = Capture.event, .data = &capture });
    for (0..2) |scenario| {
        var operation = context.begin(.{ .backend = .alpm, .kind = .install });
        defer operation.finish(.cancelled);
        var adapter: Adapter = undefined;
        try adapter.init(&owner, &operation);
        defer adapter.deinit() catch unreachable;
        const tx = try owner.initializeTransaction(std.testing.io, .{});
        if (scenario == 0) {
            try tx.addTarget("missing");
            try std.testing.expectError(error.TargetNotFound, tx.prepare());
        }
        try owner.releaseTransaction();
        try std.testing.expectEqual(scenario + 1, capture.completions);
        try std.testing.expectEqual(if (scenario == 0) op.CompletionStatus.failed else .cancelled, capture.status.?);
    }
}

test "archive inventory failures report the package and mismatched path" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "fixture.pkg.tar" });
    defer a.free(path);
    {
        var file = try temporary.dir.createFile(io, "fixture.pkg.tar", .{});
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &buffer);
        var tar: std.tar.Writer = .{ .underlying_writer = &writer.interface };
        try tar.writeFileBytes(".PKGINFO", "pkgname = archive-fixture\npkgver = 1-1\narch = any\n", .{ .mode = 0o644 });
        try tar.writeFileBytes(".MTREE", "#mtree\n./missing type=file\n", .{ .mode = 0o644 });
        try tar.writeFileBytes("present", "payload", .{ .mode = 0o644 });
        try tar.finishPedantically();
        try writer.interface.flush();
    }
    var owner = try rlpm.Owner.init(io, a, .{ .root = root, .database_path = root }, &.{});
    defer owner.deinit() catch unreachable;
    var context = op.OperationContext.init(a, io);
    defer context.deinit();
    const Capture = struct {
        failures: usize = 0,
        package: bool = false,
        path: bool = false,
        explanation: bool = false,
        fn event(data: ?*anyopaque, value: op.Event) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            if (value == .failure and value.failure.err == error.ArchiveInventoryMismatch) {
                self.failures += 1;
                self.package = std.mem.eql(u8, value.failure.envelope.subject orelse "", "archive-fixture");
                self.path = std.mem.indexOf(u8, value.failure.message, "Path: missing") != null;
                self.explanation = std.mem.indexOf(u8, value.failure.message, "file list does not match") != null;
            }
        }
    };
    var capture: Capture = .{};
    _ = try context.subscribe(.{ .function = Capture.event, .data = &capture });
    var operation = context.begin(.{ .backend = .alpm, .kind = .update, .subject = "rlpm" });
    defer operation.finish(.failed);
    var adapter: Adapter = undefined;
    try adapter.init(&owner, &operation);
    defer adapter.deinit() catch unreachable;
    const tx = try owner.initializeTransaction(io, .{});
    defer owner.releaseTransaction() catch unreachable;
    var package: ?rlpm.Package = try owner.loadPackage(io, path, .local_file, .{});
    defer if (package) |*value| value.deinit();
    try tx.takeArchive(&package);
    try tx.prepare();
    try std.testing.expectError(error.ArchiveInventoryMismatch, tx.preflight());
    try std.testing.expectEqual(1, capture.failures);
    try std.testing.expect(capture.package and capture.path and capture.explanation);
}

test "payload finishing and download progress reach operation subscribers" {
    const Capture = struct {
        status_seen: bool = false,
        progress_seen: bool = false,
        download_seen: bool = false,
        fn event(data: ?*anyopaque, value: op.Event) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            switch (value) {
                .status => |status| {
                    if (status.level == .information and std.mem.eql(u8, status.message, "Finishing writes for headers")) self.status_seen = true;
                },
                .progress => |update| {
                    if (update.update.percentage == 99) self.progress_seen = true;
                    if (update.update.bytes_completed == 4 and update.update.bytes_total == 8) self.download_seen = true;
                },
                else => {},
            }
        }
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var owner = try rlpm.Owner.init(std.testing.io, std.testing.allocator, .{ .root = path, .database_path = path }, &.{});
    defer owner.deinit() catch unreachable;
    var context = op.OperationContext.init(std.testing.allocator, std.testing.io);
    defer context.deinit();
    var capture: Capture = .{};
    _ = try context.subscribe(.{ .function = Capture.event, .data = &capture });
    var operation = context.begin(.{ .backend = .alpm, .kind = .install });
    defer operation.finish(.cancelled);
    var adapter: Adapter = undefined;
    try adapter.init(&owner, &operation);
    defer adapter.deinit() catch unreachable;
    const callbacks = owner.configuration.callbacks;
    callbacks.log.?(callbacks.log_context, .{ .level = .function, .message = "Finishing writes for headers" });
    callbacks.progress.?(callbacks.progress_context, .{ .phase = .transaction, .package = null, .percent = 99, .position = 1, .total = 1 });
    callbacks.download.?(callbacks.download_context, .{ .progress = .{ .name = "fixture.pkg.tar", .downloaded = 4, .total = 8 } });
    try std.testing.expect(capture.status_seen and capture.progress_seen and capture.download_seen);
}

test "native presentation preserves actions hook numbering and per-file download completion" {
    const t = std.testing;
    const Capture = struct {
        writer: *std.Io.Writer,
        fn receive(data: ?*anyopaque, value: op.Event) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            switch (value) {
                .status => |status| self.writer.print("{s}|{?d}|{s}|{s}\n", .{ status.code orelse "", status.native_code, status.package_name orelse "", status.message }) catch unreachable,
                .progress => |p| self.writer.print("progress|{s}|{?d}|{s}|{?d}\n", .{ p.update.stage orelse "", p.update.native_code, p.update.message orelse "", p.update.percentage }) catch unreachable,
                .completed => |c| self.writer.print("completed|{s}|{t}\n", .{ c.envelope.subject orelse "", c.status }) catch unreachable,
                else => {},
            }
        }
    };
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporary.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(path);
    var owner = try rlpm.Owner.init(t.io, t.allocator, .{ .root = path, .database_path = path }, &.{});
    defer owner.deinit() catch unreachable;
    var context = op.OperationContext.init(t.allocator, t.io);
    defer context.deinit();
    var transcript: std.Io.Writer.Allocating = .init(t.allocator);
    defer transcript.deinit();
    var capture: Capture = .{ .writer = &transcript.writer };
    _ = try context.subscribe(.{ .function = Capture.receive, .data = &capture });
    var operation = context.begin(.{ .backend = .alpm, .kind = .install, .subject = "batch" });
    defer operation.finish(.success);
    var adapter: Adapter = undefined;
    try adapter.init(&owner, &operation);
    defer adapter.deinit() catch unreachable;
    const cb = owner.options().callbacks;
    const old_ref: rlpm.PackageRef = .{ .database = .{ .owner = @enumFromInt(1), .id = .local }, .generation = 1, .id = @enumFromInt(0) };
    var new_ref = old_ref;
    new_ref.id = @enumFromInt(1);
    var old_version = try rlpm.Version.init("1-1", t.allocator);
    defer old_version.deinit(t.allocator);
    var new_version = try rlpm.Version.init("2-1", t.allocator);
    defer new_version.deinit(t.allocator);
    const old: rlpm.Package = .{ .name = "demo", .version = old_version, .database_name = "local" };
    var package: rlpm.Package = .{ .name = "demo", .version = new_version, .database_name = "core" };
    const views = [_]rlpm.Callbacks.PackageView{ .{ .reference = old_ref, .package = &old }, .{ .reference = new_ref, .package = &package } };
    const actions = [_]rlpm.Callbacks.PackageOperation{ .install, .upgrade, .downgrade, .reinstall, .remove };
    const expected = [_][]const u8{
        "Installing package: demo-2-1", "Upgrading package: demo 1-1 -> 2-1", "Downgrading package: demo 1-1 -> 2-1", "Reinstalling package: demo-2-1", "Removing package: demo-1-1",
    };
    const codes = [_][]const u8{ "installed", "upgraded", "downgraded", "reinstalled", "removed" };
    for (actions, expected, codes, 0..) |action, message, code, index| {
        transcript.clearRetainingCapacity();
        var event_value: rlpm.Callbacks.Event = .{ .package_operation = .{ .operation = action, .boundary = .start, .old = if (action == .install) null else old_ref, .new = if (action == .remove) null else new_ref, .views = &views } };
        cb.event.?(cb.event_context, event_value);
        // Mutating the borrowed view must not change the retained progress name.
        package.name = "borrowed-view-expired";
        cb.progress.?(cb.progress_context, .{ .phase = .transaction, .package = if (action == .remove) old_ref else new_ref, .percent = 100, .position = 1, .total = 1 });
        package.name = "demo";
        event_value.package_operation.boundary = .done;
        cb.event.?(cb.event_context, event_value);
        const wanted = try std.fmt.allocPrint(t.allocator, "alpm.information|11||{s}\nprogress|transaction|{d}|demo|100\nalpm.package_{s}|12|demo|Package operation completed.\n", .{ message, index, code });
        defer t.allocator.free(wanted);
        try t.expectEqualStrings(wanted, transcript.written());
    }
    transcript.clearRetainingCapacity();
    cb.event.?(cb.event_context, .{ .lifecycle = .{ .state = .prepared } });
    cb.event.?(cb.event_context, .{ .phase = .{ .phase = .integrity, .boundary = .start } });
    cb.event.?(cb.event_context, .{ .phase = .{ .phase = .integrity, .boundary = .done } });
    cb.event.?(cb.event_context, .{ .hook_run = .{ .name = "cache.hook", .description = "Updating cache", .position = 2, .total = 3, .boundary = .start } });
    cb.event.?(cb.event_context, .{ .hook_run = .{ .name = "cache.hook", .description = "Updating cache", .position = 2, .total = 3, .boundary = .done } });
    cb.event.?(cb.event_context, .{ .scriptlet_output = "setup output" });
    cb.event.?(cb.event_context, .{ .pacnew_created = .{ .path = "/etc/demo.pacnew", .old = old_ref, .new = new_ref, .from_no_upgrade = false } });
    cb.event.?(cb.event_context, .{ .pacsave_created = .{ .path = "/etc/demo.pacsave", .old = old_ref } });
    try t.expect(std.mem.indexOf(u8, transcript.written(), "prepared") == null);
    try t.expect(std.mem.indexOf(u8, transcript.written(), "Checking package integrity...") != null);
    try t.expect(std.mem.indexOf(u8, transcript.written(), "Package integrity check finished.") != null);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, transcript.written(), "progress|hook|"));
    try t.expect(std.mem.indexOf(u8, transcript.written(), "(2/3) Updating cache") != null);
    try t.expect(std.mem.indexOf(u8, transcript.written(), "alpm.scriptlet|null||setup output") != null);
    try t.expect(std.mem.indexOf(u8, transcript.written(), "alpm.pacnew|null||/etc/demo.pacnew") != null);
    try t.expect(std.mem.indexOf(u8, transcript.written(), "alpm.pacsave|null||/etc/demo.pacsave") != null);

    transcript.clearRetainingCapacity();
    for ([_][]const u8{ "core.db", "demo.pkg.tar", "failed.pkg.tar", "cached.pkg.tar" }) |file| {
        cb.download.?(cb.download_context, .{ .init = .{ .name = file, .optional = false } });
        try t.expectEqual(0, adapter.downloads.count());
    }
    for ([_][]const u8{ "core.db", "demo.pkg.tar", "failed.pkg.tar", "cached.pkg.tar" }) |file| cb.download.?(cb.download_context, .{ .started = .{ .name = file, .attempt = 1 } });
    cb.download.?(cb.download_context, .{ .retry = .{ .name = "demo.pkg.tar", .resuming = true } });
    cb.download.?(cb.download_context, .{ .progress = .{ .name = "failed.pkg.tar", .downloaded = 2, .total = 8 } });
    cb.download.?(cb.download_context, .{ .transferred = .{ .name = "core.db", .attempt = 1, .downloaded = 8, .result = .updated } });
    cb.download.?(cb.download_context, .{ .transferred = .{ .name = "demo.pkg.tar", .attempt = 1, .downloaded = 16, .result = .updated } });
    cb.download.?(cb.download_context, .{ .transferred = .{ .name = "failed.pkg.tar", .attempt = 1, .downloaded = 2, .result = .failed } });
    cb.download.?(cb.download_context, .{ .transferred = .{ .name = "cached.pkg.tar", .attempt = 1, .downloaded = 0, .result = .unchanged } });
    const transfer_length = transcript.written().len;
    cb.download.?(cb.download_context, .{ .completed = .{ .name = "demo.pkg.tar", .downloaded = 16, .result = .failed } });
    try t.expectEqual(transfer_length, transcript.written().len);
    const text = transcript.written();
    try t.expectEqual(@as(usize, 0), adapter.downloads.count());
    try t.expectEqual(@as(usize, 2), std.mem.count(u8, text, "|100\n"));
    try t.expect(std.mem.indexOf(u8, text, "progress|download|101|core.db|100") != null);
    try t.expect(std.mem.indexOf(u8, text, "progress|download|100|demo.pkg.tar|100") != null);
    try t.expect(std.mem.indexOf(u8, text, "completed|core.db|success") != null);
    try t.expect(std.mem.indexOf(u8, text, "completed|failed.pkg.tar|failed") != null);
    try t.expect(std.mem.indexOf(u8, text, "download.skipped|") != null);
    try t.expect(std.mem.indexOf(u8, text, "completed|batch|") == null);
}
