//! RLPM callback adapter used by the selected PackageManager backend.
//! Initialize at its final address before a transaction; release the transaction
//! before deinit. Context and operation outlive the adapter. UI question payloads
//! are owned here through the deferred response, then expire when ask returns.
const Adapter = @This();
const std = @import("std");
const rlpm = @import("Shelly_Rlpm");
const op = @import("operation_context");
const output = @import("native_output");
const ProcessingUpdate = @FieldType(rlpm.Callbacks.Download, "processing");
owner: *rlpm.Owner,
operation: *op.Operation,
previous: rlpm.Callbacks,
cancellation_subscription: op.SubscriptionId,
last_failure: ?anyerror = null,
active_package: ?[]u8 = null,
active_reference: ?rlpm.PackageRef = null,
active_action: ?output.PackageAction = null,
downloads: std.StringHashMapUnmanaged(op.Operation) = .empty,
// Acceptance runs serially on the owner thread after transfer workers join.
processing: ?struct {
    operation: op.Operation,
    stage: @FieldType(ProcessingUpdate, "stage"),
} = null,
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
    self.finishProcessing(self.processingFailureStatus());
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
    return std.fmt.allocPrint(a, "package {d}:{d}:{d}", .{ @backingInt(ref.database.id), ref.generation, @backingInt(ref.id) });
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
// Read resolution and preflight issues while the transaction still owns the plan.
fn formatFailure(
    allocator: std.mem.Allocator,
    err: anyerror,
    operation: op.Operation,
    plan: ?*const rlpm.TransactionPlan,
    path: ?[]const u8,
) ![]u8 {
    const diagnostics = @import("diagnostics");
    var text: std.Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    if (plan) |resolution| {
        for (resolution.issues) |issue| switch (issue) {
            .missing => |missing| {
                const relation = try missing.dependency.formatAlloc(allocator);
                defer allocator.free(relation);
                try text.writer.print("\"{f}\" requires \"{f}\", which could not be satisfied", .{
                    diagnostics.safe(resolution.package(missing.requiring).name), diagnostics.safe(relation),
                });
                if (missing.causing) |id| try text.writer.print(" (affected by \"{f}\")", .{diagnostics.safe(resolution.package(id).name)});
                try text.writer.writeAll(".\n");
            },
            .target => |target| if (resolution.failure == .target_not_found) {
                try text.writer.print("Requested package \"{f}\" could not be found in the configured repositories.\n", .{diagnostics.safe(target)});
            } else if (resolution.failure == .ignored) {
                try text.writer.print("Requested package \"{f}\" is excluded by the ignore configuration.\n", .{diagnostics.safe(target)});
            },
            .conflict => |conflict| {
                const relation = try conflict.reason.formatAlloc(allocator);
                defer allocator.free(relation);
                try text.writer.print("\"{f}\" conflicts with \"{f}\" (conflict: {f}).\n", .{
                    diagnostics.safe(resolution.package(conflict.first).name), diagnostics.safe(resolution.package(conflict.second).name), diagnostics.safe(relation),
                });
            },
            .file_conflict => |conflict| {
                const first = resolution.package(conflict.first).name;
                if (conflict.second) |second| {
                    const relationship = switch (conflict.kind) {
                        .target => "also provided by",
                        .filesystem => "owned by",
                    };
                    try text.writer.print("\"{f}\": \"{f}\" conflicts with a file {s} \"{f}\".\n", .{
                        diagnostics.safe(conflict.path), diagnostics.safe(first), relationship, diagnostics.safe(resolution.package(second).name),
                    });
                } else {
                    try text.writer.print("\"{f}\": \"{f}\" conflicts with an existing filesystem entry.\n", .{
                        diagnostics.safe(conflict.path), diagnostics.safe(first),
                    });
                }
            },
            .architecture => |id| {
                const package = resolution.package(id);
                try text.writer.print("Package \"{f}\" has architecture \"{f}\", which is not accepted by the configured architectures.\n", .{ diagnostics.safe(package.name), diagnostics.safe(package.architecture orelse "unknown") });
            },
            .duplicate => |duplicate| try text.writer.print("Packages \"{f}\" and \"{f}\" select a duplicate transaction target.\n", .{ diagnostics.safe(resolution.package(duplicate.first).name), diagnostics.safe(resolution.package(duplicate.second).name) }),
            .filename => |duplicate| try text.writer.print("Packages \"{f}\" and \"{f}\" share archive filename \"{f}\".\n", .{ diagnostics.safe(resolution.package(duplicate.first).name), diagnostics.safe(resolution.package(duplicate.second).name), diagnostics.safe(duplicate.filename) }),
        };
    }
    if (text.written().len != 0) {
        try text.writer.print("\nTechnical details: {s}", .{@errorName(err)});
        return allocator.dupe(u8, text.written());
    }
    return rlpm.Diagnostic.init(.transaction, err, null).userMessage(allocator, .{
        .operation = diagnostics.operationDescription(operation.envelope.kind),
        .subject = operation.envelope.subject,
        .path = path,
    });
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
    const allocator = operation.context.allocator;
    const message = formatFailure(allocator, err, operation, if (self.owner.transaction()) |tx| tx.plan() else null, if (issue) |failure| failure.path else null) catch {
        var buffer: [512]u8 = undefined;
        const fallback = rlpm.Diagnostic.fallback(&buffer, err);
        operation.reportError(err, fallback, "rlpm", null, false);
        self.last_failure = err;
        if (self.failure_handler) |handler| handler.function(handler.data, fallback);
        return;
    };
    defer allocator.free(message);
    operation.reportError(err, message, "rlpm", null, false);
    self.last_failure = err;
    if (self.failure_handler) |handler| handler.function(handler.data, message);
}
fn event(data: ?*anyopaque, value: rlpm.Callbacks.Event) void {
    const self = from(data);
    switch (value) {
        .lifecycle => |result| switch (result.state) {
            .completed => self.finishTransaction(.success),
            .interrupted => self.finishTransaction(.cancelled),
            .failed => {
                if (result.cause) |err| {
                    if (self.last_failure == null or self.last_failure.? != err) self.reportFailure(err);
                }
                self.finishTransaction(.failed);
            },
            .released => self.finishTransaction(if (result.cause != null and result.cause.? != error.Cancelled) .failed else .cancelled),
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
                    self.operation.status(.information, message orelse package_name, "alpm.information", @backingInt(output.EventType.package_operation_start));
                },
                .done => {
                    self.operation.packageStatus(.information, output.information(.package_operation_done).?, action.completionCode(), @backingInt(output.EventType.package_operation_done), package_name);
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
                self.operation.status(.information, message, "alpm.information", @backingInt(output.EventType.hook_run_start));
            },
            .done => self.information(.hook_run_done),
            .failed => {},
        },
        .diagnostic => |diagnostic| {
            const allocator = self.operation.context.allocator;
            const message = formatDiagnostic(self.owner, allocator, diagnostic) catch null;
            defer if (message) |owned| allocator.free(owned);
            var buffer: [512]u8 = undefined;
            const rendered = message orelse rlpm.Diagnostic.fallback(&buffer, diagnostic.cause);
            self.operation.reportError(diagnostic.cause, rendered, "rlpm", null, false);
            self.last_failure = diagnostic.cause;
            if (self.failure_handler) |handler| {
                handler.function(handler.data, rendered);
                return; // Already delivered to the legacy handler with the same details.
            }
        },
    }
    if (self.previous.event) |callback| callback(self.previous.event_context, value);
}
fn formatDiagnostic(owner: *rlpm.Owner, allocator: std.mem.Allocator, diagnostic: rlpm.Diagnostic) ![]u8 {
    if (owner.transaction()) |tx| if (tx.actions()) |actions| if (actions.outcomes.items.len != 0) {
        const outcome = actions.outcomes.items[actions.outcomes.items.len - 1];
        if (outcome.cause != null and outcome.cause.? == diagnostic.cause) return formatActionFailure(allocator, outcome);
    };
    return diagnostic.userMessage(allocator, .{ .operation = "the RLPM operation" });
}

pub fn formatActionFailure(allocator: std.mem.Allocator, outcome: anytype) ![]u8 {
    const diagnostics = @import("diagnostics");
    const err = outcome.cause.?;
    var text: std.Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    try text.writer.print("Package setup {t} failed: {f}.\n{s}", .{ outcome.kind, diagnostics.safe(outcome.name), rlpm.Diagnostic.explanation(err) orelse "The action failed; review its output and technical details." });
    if (outcome.function) |function| try text.writer.print("\nScriptlet function: {t}", .{function});
    if (outcome.line != 0) try text.writer.print("\nHook line: {d}", .{outcome.line});
    if (outcome.process) |process| {
        switch (process.term) {
            .exited => |code| try text.writer.print("\nExit status: {d}", .{code}),
            else => try text.writer.print("\nProcess termination: {any}", .{process.term}),
        }
        if (process.setup_failure) |failure| try text.writer.print("\nWorker setup: {t} (errno {d})", .{ failure.stage, failure.errno });
        if (process.network_warning) |code| try text.writer.print("\nNetwork setup warning: errno {d}", .{code});
    }
    return rlpm.Diagnostic.init(.transaction, err, null).userMessage(allocator, .{ .detail = text.written(), .stage = "package setup" });
}

fn packageView(views: []const rlpm.Callbacks.PackageView, ref: ?rlpm.PackageRef) ?*const rlpm.Package {
    const identity = ref orelse return null;
    for (views) |view| if (std.meta.eql(view.reference, identity)) return view.package;
    return null;
}
fn information(self: *Adapter, event_type: output.EventType) void {
    self.operation.status(.information, output.information(event_type) orelse return, "alpm.information", @backingInt(event_type));
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
        .transaction => if (package_matches and self.active_action != null) @backingInt(self.active_action.?) else null,
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
        .processing => |update| self.processingProgress(update),
        .completed => |update| {
            // Acceptance failures never reopen an already completed transfer.
            // The transaction/sync caller supplies the detailed error.
            if (update.result == .failed) self.finishDownload(update.name, false);
        },
    }
    if (self.previous.download) |callback| callback(self.previous.download_context, value);
}
fn processingProgress(self: *Adapter, update: ProcessingUpdate) void {
    const stage: []const u8 = switch (update.stage) {
        .verification => "Verifying downloads",
        .publication => "Publishing downloads",
    };
    if (update.boundary == .start) {
        self.finishProcessing(self.processingFailureStatus());
        const name_copy = self.operation.context.allocator.dupe(u8, update.name) catch return;
        self.processing = .{
            .operation = self.operation.child(.{
                .backend = .alpm,
                .kind = self.operation.envelope.kind,
                .subject = name_copy,
            }),
            .stage = update.stage,
        };
    }
    const active = if (self.processing) |*value| value else return;
    if (active.stage != update.stage or
        !std.mem.eql(u8, active.operation.envelope.subject.?, update.name)) return;

    if (update.boundary == .start) downloadStatus(&active.operation, update.name, stage, "acquisition.processing");
    active.operation.progress(.{
        .stage = stage,
        .message = update.name,
        .completed = if (update.boundary == .done) update.position else update.position -| 1,
        .total = update.total,
    });
    // Counts describe the batch, so a finished file can still be below 100%.
    // End its operation explicitly instead of retaining the bar until the
    // enclosing install/update transaction (including hooks) completes.
    if (update.boundary != .start)
        self.finishProcessing(if (update.boundary == .done) .success else self.processingFailureStatus());
}
fn processingFailureStatus(self: *const Adapter) op.CompletionStatus {
    return if (self.operation.isCancelled()) .cancelled else .failed;
}
fn finishProcessing(self: *Adapter, status: op.CompletionStatus) void {
    if (self.processing) |*active| {
        active.operation.finish(status);
        self.operation.context.allocator.free(active.operation.envelope.subject.?);
        self.processing = null;
    }
}
fn finishTransaction(self: *Adapter, status: op.CompletionStatus) void {
    self.finishProcessing(if (status == .cancelled) .cancelled else self.processingFailureStatus());
    self.operation.finish(status);
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
    const ref: rlpm.PackageRef = .{ .database = .{ .owner = @fromBackingInt(@intCast(1)), .id = .local }, .generation = 1, .id = @fromBackingInt(@intCast(0)) };
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
    const old_ref: rlpm.PackageRef = .{ .database = .{ .owner = @fromBackingInt(@intCast(1)), .id = .local }, .generation = 1, .id = @fromBackingInt(@intCast(0)) };
    var new_ref = old_ref;
    new_ref.id = @fromBackingInt(@intCast(1));
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

test "resolution failures preserve dependency details through lifecycle and legacy output" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const Capture = struct {
        operation_message: std.Io.Writer.Allocating,
        legacy_message: std.Io.Writer.Allocating,
        failures: usize = 0,
        legacy_failures: usize = 0,
        fn event(data: ?*anyopaque, value: op.Event) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            if (value == .failure) {
                self.failures += 1;
                self.operation_message.writer.writeAll(value.failure.message) catch unreachable;
            }
        }
        fn legacy(data: ?*anyopaque, message: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.legacy_failures += 1;
            self.legacy_message.writer.writeAll(message) catch unreachable;
        }
    };
    for (0..3) |scenario| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const root = try temporary.dir.realPathFileAlloc(io, ".", a);
        defer a.free(root);
        var owner = try rlpm.Owner.init(io, a, .{ .root = root, .database_path = root }, &.{});
        defer owner.deinit() catch unreachable;
        var context = op.OperationContext.init(a, io);
        defer context.deinit();
        var capture: Capture = .{ .operation_message = .init(a), .legacy_message = .init(a) };
        defer capture.operation_message.deinit();
        defer capture.legacy_message.deinit();
        _ = try context.subscribe(.{ .function = Capture.event, .data = &capture });
        var operation = context.begin(.{ .backend = .alpm, .kind = .install });
        defer operation.finish(.failed);
        var adapter: Adapter = undefined;
        try adapter.init(&owner, &operation);
        adapter.failure_handler = .{ .function = Capture.legacy, .data = &capture };
        defer adapter.deinit() catch unreachable;
        const tx = try owner.initializeTransaction(io, .{});
        if (scenario == 0) {
            try tx.addTarget("missing-target");
        } else {
            for (0..2) |index| {
                const metadata = if (index == 0)
                    (if (scenario == 1) "pkgname = first\npkgver = 1-1\narch = any\ndepend = missing-lib>=2.0\n" else "pkgname = first\npkgver = 1-1\narch = any\nconflict = second<2\n")
                else
                    (if (scenario == 1) "pkgname = second\npkgver = 1-1\narch = any\ndepend = other-lib=3\n" else "pkgname = second\npkgver = 1-1\narch = any\n");
                const filename = if (index == 0) "first.pkg.tar" else "second.pkg.tar";
                {
                    var file = try temporary.dir.createFile(io, filename, .{});
                    defer file.close(io);
                    var buffer: [4096]u8 = undefined;
                    var writer = file.writer(io, &buffer);
                    var tar: std.tar.Writer = .{ .underlying_writer = &writer.interface };
                    try tar.writeFileBytes(".PKGINFO", metadata, .{ .mode = 0o644 });
                    try tar.finishPedantically();
                    try writer.interface.flush();
                }
                const path = try std.fs.path.join(a, &.{ root, filename });
                defer a.free(path);
                var package: ?rlpm.Package = try owner.loadPackage(io, path, .local_file, .{});
                defer if (package) |*value| value.deinit();
                try tx.takeArchive(&package);
            }
        }
        const expected_error = switch (scenario) {
            0 => error.TargetNotFound,
            1 => error.UnsatisfiedDependencies,
            else => error.ConflictingDependencies,
        };
        try std.testing.expectError(expected_error, tx.prepare());
        try owner.releaseTransaction();
        try std.testing.expectEqual(1, capture.failures);
        try std.testing.expectEqual(1, capture.legacy_failures);
        const message = capture.operation_message.written();
        try std.testing.expectEqualStrings(message, capture.legacy_message.written());
        const expected: []const []const u8 = switch (scenario) {
            0 => &.{ "Requested package \"missing-target\"", "Technical details: TargetNotFound" },
            1 => &.{ "\"first\" requires \"missing-lib>=2.0\"", "\"second\" requires \"other-lib=3\"", "Technical details: UnsatisfiedDependencies" },
            else => &.{ "\"first\" conflicts with \"second\"", "second<2", "Technical details: ConflictingDependencies" },
        };
        for (expected) |fragment| try std.testing.expect(std.mem.indexOf(u8, message, fragment) != null);
        try std.testing.expect(std.mem.indexOf(u8, message, "more specific reason") == null);
    }
}

test "resolution failure without plan retains a useful cause and technical code" {
    var context = op.OperationContext.init(std.testing.allocator, std.testing.io);
    defer context.deinit();
    var operation = context.begin(.{ .backend = .alpm, .kind = .install });
    defer operation.finish(.failed);
    for ([_]anyerror{ error.UnsatisfiedDependencies, error.TargetNotFound, error.ConflictingDependencies }) |err| {
        const message = try formatFailure(std.testing.allocator, err, operation, null, null);
        defer std.testing.allocator.free(message);
        try std.testing.expect(std.mem.indexOf(u8, message, @errorName(err)) != null);
        try std.testing.expect(std.mem.indexOf(u8, message, "more specific reason") == null);
    }
}

test "preflight file conflicts reach operation and legacy error handlers" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    try temporary.dir.writeFile(io, .{ .sub_path = "unowned", .data = "local" });
    const path = try std.fs.path.join(a, &.{ root, "fixture.pkg.tar" });
    defer a.free(path);
    {
        var file = try temporary.dir.createFile(io, "fixture.pkg.tar", .{});
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &buffer);
        var tar: std.tar.Writer = .{ .underlying_writer = &writer.interface };
        try tar.writeFileBytes(".PKGINFO", "pkgname = demo\npkgver = 1-1\narch = any\n", .{ .mode = 0o644 });
        try tar.writeFileBytes("unowned", "new", .{ .mode = 0o644 });
        try tar.finishPedantically();
        try writer.interface.flush();
    }
    var owner = try rlpm.Owner.init(io, a, .{ .root = root, .database_path = root }, &.{});
    defer owner.deinit() catch unreachable;
    var context = op.OperationContext.init(a, io);
    defer context.deinit();
    const Capture = struct {
        operation_message: std.Io.Writer.Allocating,
        legacy_message: std.Io.Writer.Allocating,
        failures: usize = 0,
        legacy_failures: usize = 0,
        fn event(data: ?*anyopaque, value: op.Event) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            if (value == .failure) {
                self.failures += 1;
                self.operation_message.writer.writeAll(value.failure.message) catch unreachable;
            }
        }
        fn legacy(data: ?*anyopaque, message: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.legacy_failures += 1;
            self.legacy_message.writer.writeAll(message) catch unreachable;
        }
    };
    var capture: Capture = .{ .operation_message = .init(a), .legacy_message = .init(a) };
    defer capture.operation_message.deinit();
    defer capture.legacy_message.deinit();
    _ = try context.subscribe(.{ .function = Capture.event, .data = &capture });
    var operation = context.begin(.{ .backend = .alpm, .kind = .install });
    defer operation.finish(.failed);
    var adapter: Adapter = undefined;
    try adapter.init(&owner, &operation);
    adapter.failure_handler = .{ .function = Capture.legacy, .data = &capture };
    defer adapter.deinit() catch unreachable;
    const tx = try owner.initializeTransaction(io, .{});
    defer owner.releaseTransaction() catch unreachable;
    var package: ?rlpm.Package = try owner.loadPackage(io, path, .local_file, .{});
    defer if (package) |*value| value.deinit();
    try tx.takeArchive(&package);
    try tx.prepare();
    try std.testing.expectError(error.FileConflicts, tx.preflight());
    try std.testing.expectEqual(null, tx.plan().?.failure);
    try std.testing.expectEqual(1, capture.failures);
    try std.testing.expectEqual(1, capture.legacy_failures);
    try std.testing.expectEqualStrings(capture.operation_message.written(), capture.legacy_message.written());
    try std.testing.expectEqualStrings(
        "\"unowned\": \"demo\" conflicts with an existing filesystem entry.\n\nTechnical details: FileConflicts",
        capture.operation_message.written(),
    );
}

test "processing children finish on failure cancellation teardown and terminal lifecycle" {
    const t = std.testing;
    const Capture = struct {
        live: usize = 0,
        completed: usize = 0,
        status: ?op.CompletionStatus = null,
        child_id: ?op.OperationId = null,
        progress_id: ?op.OperationId = null,
        parent_finished_with_child: bool = false,
        fn receive(data: ?*anyopaque, value: op.Event) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            switch (value) {
                .started => |started| if (started.envelope.parent_id != null) {
                    self.live += 1;
                    self.child_id = started.envelope.operation_id;
                },
                .progress => |p| self.progress_id = p.envelope.operation_id,
                .completed => |completed| {
                    if (completed.envelope.parent_id != null) {
                        self.live -= 1;
                        self.completed += 1;
                        self.status = completed.status;
                    } else if (self.live != 0) self.parent_finished_with_child = true;
                },
                else => {},
            }
        }
    };
    const Mode = enum { done, failed, cancel_failed, teardown, cancel_teardown, completed, interrupted, released, transaction_failed };
    for (std.enums.values(Mode)) |mode| {
        var temporary = t.tmpDir(.{});
        defer temporary.cleanup();
        const path = try temporary.dir.realPathFileAlloc(t.io, ".", t.allocator);
        defer t.allocator.free(path);
        var owner = try rlpm.Owner.init(t.io, t.allocator, .{ .root = path, .database_path = path }, &.{});
        defer owner.deinit() catch unreachable;
        var context = op.OperationContext.init(t.allocator, t.io);
        defer context.deinit();
        var capture: Capture = .{};
        _ = try context.subscribe(.{ .function = Capture.receive, .data = &capture });
        var operation = context.begin(.{ .backend = .alpm, .kind = .update });
        defer operation.finish(.success);
        var adapter: Adapter = undefined;
        try adapter.init(&owner, &operation);
        var attached = true;
        defer if (attached) adapter.deinit() catch unreachable;
        const cb = owner.options().callbacks;
        var borrowed_name = "demo.pkg.tar".*;
        cb.download.?(cb.download_context, .{ .processing = .{ .name = &borrowed_name, .stage = .verification, .boundary = .start, .position = 1, .total = 29 } });
        try t.expectEqual(@as(usize, 1), capture.live);
        try t.expectEqual(capture.child_id, capture.progress_id);
        try t.expect(capture.child_id.? != operation.envelope.operation_id);
        @memset(&borrowed_name, 'x');
        try t.expectEqualStrings("demo.pkg.tar", adapter.processing.?.operation.envelope.subject.?);
        if (mode == .cancel_failed or mode == .cancel_teardown) context.cancel();
        switch (mode) {
            .done, .failed, .cancel_failed => cb.download.?(cb.download_context, .{ .processing = .{ .name = "demo.pkg.tar", .stage = .verification, .boundary = if (mode == .done) .done else .failed, .position = 1, .total = 29 } }),
            .teardown, .cancel_teardown => {
                try adapter.deinit();
                attached = false;
            },
            .completed, .interrupted, .released, .transaction_failed => cb.event.?(cb.event_context, .{ .lifecycle = .{
                .state = switch (mode) {
                    .completed => .completed,
                    .interrupted => .interrupted,
                    .released => .released,
                    else => .failed,
                },
            } }),
        }
        try t.expectEqual(@as(usize, 0), capture.live);
        try t.expectEqual(@as(usize, 1), capture.completed);
        const expected: op.CompletionStatus = switch (mode) {
            .done => .success,
            .cancel_failed, .cancel_teardown, .interrupted, .released => .cancelled,
            else => .failed,
        };
        try t.expectEqual(expected, capture.status.?);
        try t.expect(!capture.parent_finished_with_child);
        if (mode == .done or mode == .failed or mode == .cancel_failed or mode == .teardown or mode == .cancel_teardown)
            try t.expect(!operation.completed);
    }
}

test "processing retry uses a fresh child and skipped transfers create no processing child" {
    const t = std.testing;
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporary.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(path);
    var owner = try rlpm.Owner.init(t.io, t.allocator, .{ .root = path, .database_path = path }, &.{});
    defer owner.deinit() catch unreachable;
    var context = op.OperationContext.init(t.allocator, t.io);
    defer context.deinit();
    var operation = context.begin(.{ .backend = .alpm, .kind = .sync });
    defer operation.finish(.success);
    var adapter: Adapter = undefined;
    try adapter.init(&owner, &operation);
    defer adapter.deinit() catch unreachable;
    const cb = owner.options().callbacks;
    cb.download.?(cb.download_context, .{ .transferred = .{ .name = "cached.db", .attempt = 1, .downloaded = 0, .result = .unchanged } });
    try t.expect(adapter.processing == null);
    try t.expectEqual(@as(usize, 0), adapter.downloads.count());
    var previous_id: ?op.OperationId = null;
    for (0..2) |attempt| {
        cb.download.?(cb.download_context, .{ .processing = .{ .name = "core.db", .stage = .verification, .boundary = .start, .position = 1, .total = 2 } });
        const id = adapter.processing.?.operation.envelope.operation_id;
        try t.expect(previous_id == null or previous_id.? != id);
        previous_id = id;
        // A mismatched completion must not finish the current step.
        cb.download.?(cb.download_context, .{ .processing = .{ .name = "core.db", .stage = .publication, .boundary = .done, .position = 1, .total = 2 } });
        try t.expect(adapter.processing != null);
        cb.download.?(cb.download_context, .{ .processing = .{ .name = "core.db", .stage = .verification, .boundary = if (attempt == 0) .failed else .done, .position = 1, .total = 2 } });
        try t.expect(adapter.processing == null);
    }
    try t.expect(!operation.completed);
    try t.expectEqual(@as(usize, 1), context.active_operations.load(.acquire));
}

test "action diagnostics preserve long names exit status and worker setup details" {
    const padding: [4096]u8 = @splat('a');
    const action_name = try std.fmt.allocPrint(std.testing.allocator, "{s}\x1b https://user:secret@example.test/private?token=hidden", .{padding});
    defer std.testing.allocator.free(action_name);
    const outcome: rlpm.TransactionActions.Outcome = .{
        .kind = .scriptlet,
        .name = action_name,
        .function = .post_install,
        .cause = error.ScriptletFailed,
        .line = 42,
        .process = .{ .term = .{ .exited = 7 }, .setup_failure = .{ .stage = .execute, .errno = 13 } },
    };
    const message = try formatActionFailure(std.testing.allocator, outcome);
    defer std.testing.allocator.free(message);
    for ([_][]const u8{ "ScriptletFailed", "post_install", "Exit status: 7", "Hook line: 42", "execute (errno 13)", "\\x1b", "Backend: rlpm" }) |part|
        try std.testing.expect(std.mem.indexOf(u8, message, part) != null);
    for ([_][]const u8{ "secret", "private", "hidden", "\x1b" }) |part|
        try std.testing.expect(std.mem.indexOf(u8, message, part) == null);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var buffer: [512]u8 = undefined;
    const fallback = formatActionFailure(failing.allocator(), outcome) catch rlpm.Diagnostic.fallback(&buffer, outcome.cause.?);
    try std.testing.expect(std.mem.indexOf(u8, fallback, "ScriptletFailed") != null);
}

test "RLPM diagnostic events keep database context and share one explanation with legacy handlers" {
    const t = std.testing;
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporary.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(path);
    var owner = try rlpm.Owner.init(t.io, t.allocator, .{ .root = path, .database_path = path }, &.{});
    defer owner.deinit() catch unreachable;
    var context = op.OperationContext.init(t.allocator, t.io);
    defer context.deinit();
    const Capture = struct {
        events: usize = 0,
        legacy_events: usize = 0,
        message: std.Io.Writer.Allocating = .init(t.allocator),
        legacy_message: std.Io.Writer.Allocating = .init(t.allocator),
        original_cause: bool = false,
        fn event(data: ?*anyopaque, value: op.Event) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            if (value == .failure) {
                self.events += 1;
                self.original_cause = value.failure.err == error.InvalidDatabaseEntry;
                self.message.writer.writeAll(value.failure.message) catch unreachable;
            }
        }
        fn legacy(data: ?*anyopaque, message: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.legacy_events += 1;
            self.legacy_message.writer.writeAll(message) catch unreachable;
        }
    };
    var capture: Capture = .{};
    defer capture.message.deinit();
    defer capture.legacy_message.deinit();
    _ = try context.subscribe(.{ .function = Capture.event, .data = &capture });
    var operation = context.begin(.{ .backend = .alpm, .kind = .inspect });
    defer operation.finish(.failed);
    var adapter: Adapter = undefined;
    try adapter.init(&owner, &operation);
    adapter.failure_handler = .{ .function = Capture.legacy, .data = &capture };
    defer adapter.deinit() catch unreachable;
    const callbacks = owner.options().callbacks;
    callbacks.event.?(callbacks.event_context, .{ .diagnostic = rlpm.Diagnostic.init(.load_database, error.InvalidDatabaseEntry, owner.localDatabase()) });
    callbacks.event.?(callbacks.event_context, .{ .lifecycle = .{ .state = .failed, .cause = error.InvalidDatabaseEntry } });
    try t.expectEqual(@as(usize, 1), capture.events);
    try t.expectEqual(@as(usize, 1), capture.legacy_events);
    try t.expect(capture.original_cause);
    try t.expectEqualStrings(capture.message.written(), capture.legacy_message.written());
    for ([_][]const u8{ "Stage: load_database", "Database ID: 0", "Diagnostic category: database", "invalid metadata" }) |part|
        try t.expect(std.mem.indexOf(u8, capture.message.written(), part) != null);
    const rendered = try @import("diagnostics").format(t.allocator, error.InvalidDatabaseEntry, .{ .detail = capture.message.written(), .domain = "rlpm" });
    defer t.allocator.free(rendered);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, "Backend: rlpm"));
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, "Technical details:"));
}
