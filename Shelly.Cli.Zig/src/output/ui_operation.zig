const std = @import("std");
const Zigalpm = @import("Zigalpm");
const output = @import("config.zig");
const runtime = @import("../runtime/context.zig");
const parser = @import("../cli/parser.zig");

pub const QuestionMode = enum {
    responder,
    accept_defaults,
};

pub const Transaction = struct {
    opening: []const u8,
    success_message: []const u8,
    failure_message: []const u8,
    failure_label: []const u8,
    question_mode: QuestionMode = .responder,
    cancelled_message: ?[]const u8 = null,
    report_flatpak_unavailable: bool = false,
};

/// Runs a backend operation through the common UI transaction lifecycle:
/// operation context setup, question handling, event reporting, and the
/// TransactionStart/TransactionDone/TransactionFailed frame sequence.
/// The runner must expose
/// `run(context: *runtime.RuntimeContext, operation_context: *Zigalpm.OperationContext, invocation: *const parser.Invocation) anyerror!void`.
pub fn runTransaction(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    config: Transaction,
    runner: anytype,
) anyerror!u8 {
    var operation_context = Zigalpm.OperationContext.init(context.allocator, context.io);
    context.attachTransactionLog(&operation_context);
    defer operation_context.deinit();

    var question_responder: QuestionResponder = .{
        .context = context,
        .operation_context = &operation_context,
        .no_confirm = invocation.globals.no_confirm,
    };
    const use_responder = config.question_mode == .responder;
    if (use_responder) question_responder.attach();
    defer if (use_responder) question_responder.detach();

    const use_defaults = config.question_mode == .accept_defaults and invocation.globals.no_confirm;
    if (use_defaults) operation_context.setQuestionHandler(.{ .function = acceptQuestionDefaults });
    defer if (use_defaults) operation_context.setQuestionHandler(null);

    var reporter: Reporter = .{ .context = context };
    const event_subscription = try operation_context.subscribe(.{
        .function = Reporter.handle,
        .data = &reporter,
    });
    defer _ = operation_context.unsubscribe(event_subscription);

    try output.writeAlpmInfoFrame(context, "TransactionStart", config.opening);
    try flush(context);

    runner.run(context, &operation_context, invocation) catch |err| {
        const failure: anyerror = err;
        if (config.cancelled_message) |cancelled_message| {
            if (failure == error.Cancelled) {
                try output.writeInfoFrame(context, "Operation cancelled.");
                try output.writeAlpmInfoFrame(context, "TransactionCancelled", cancelled_message);
                try flush(context);
                return 0;
            }
        }
        if (!reporter.reported_failure.load(.acquire)) {
            const message = try Zigalpm.user_errors.format(context.allocator, failure, .{
                .subject = if (invocation.positionals.len == 1) invocation.positionals[0] else null,
            });
            defer context.allocator.free(message);
            try output.writeErrorFrame(context, message);
        } else {
            const detail = try std.fmt.allocPrint(context.allocator, "Technical details: {t}", .{failure});
            defer context.allocator.free(detail);
            try output.writeInfoFrame(context, detail);
        }
        try output.writeAlpmInfoFrame(context, "TransactionFailed", config.failure_message);
        try flush(context);
        return 1;
    };

    try output.writeAlpmInfoFrame(context, "TransactionDone", config.success_message);
    try flush(context);
    return if (reporter.failed()) 1 else 0;
}

pub const Reporter = struct {
    context: *runtime.RuntimeContext,
    mutex: std.Io.Mutex = .init,
    write_failed: std.atomic.Value(bool) = .init(false),
    reported_failure: std.atomic.Value(bool) = .init(false),

    pub fn handle(data: ?*anyopaque, event: Zigalpm.OperationEvent) void {
        const self: *Reporter = @ptrCast(@alignCast(data.?));
        self.mutex.lockUncancelable(self.context.io);
        defer self.mutex.unlock(self.context.io);
        self.write(event) catch self.write_failed.store(true, .release);
    }

    pub fn failed(self: *const Reporter) bool {
        return self.write_failed.load(.acquire);
    }

    fn write(self: *Reporter, event: Zigalpm.OperationEvent) !void {
        switch (event) {
            .status => |status| try output.writeAlpmInfoFrame(
                self.context,
                "InformationalOutput",
                status.message,
            ),
            .progress => |progress| try output.writeOperationProgressFrame(self.context, progress),
            .failure => |failure| {
                const message = try Zigalpm.user_errors.format(self.context.allocator, failure.err, .{
                    .subject = failure.envelope.subject,
                    .detail = failure.message,
                });
                defer self.context.allocator.free(message);
                if (failure.recoverable) {
                    try output.writeWarningFrame(self.context, message);
                } else {
                    try output.writeErrorFrame(self.context, message);
                    self.reported_failure.store(true, .release);
                }
            },
            .started, .completed => {},
        }
        try flush(self.context);
    }
};

pub const QuestionResponder = struct {
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    no_confirm: bool,
    future: ?std.Io.Future(void) = null,

    pub fn attach(self: *QuestionResponder) void {
        self.operation_context.setQuestionHandler(.{ .function = handle, .data = self });
    }

    pub fn detach(self: *QuestionResponder) void {
        self.operation_context.setQuestionHandler(null);
        if (self.future) |*future| {
            future.await(self.context.io);
            self.future = null;
        }
    }

    fn handle(
        data: ?*anyopaque,
        question: Zigalpm.OperationQuestion,
    ) Zigalpm.OperationQuestionResponse {
        const self: *QuestionResponder = @ptrCast(@alignCast(data.?));
        if (self.no_confirm) {
            if (question.kind == .review_changes) {
                if (hasSecurityFindings(question)) return self.handleInteractive(question);
                self.writeAutomaticReview(question) catch return .declined;
                return safeReviewDefault(question);
            }
            return automaticResponse(question.kind);
        }

        return self.handleInteractive(question);
    }

    fn handleInteractive(
        self: *QuestionResponder,
        question: Zigalpm.OperationQuestion,
    ) Zigalpm.OperationQuestionResponse {
        switch (question.kind) {
            .confirmation => output.writeYesNoQuestionFrame(self.context, question) catch return .declined,
            .import_pgp_key => output.writeYesNoQuestionFrame(self.context, question) catch return .declined,
            .confirm_transaction => output.writeTransactionQuestionFrame(self.context, question) catch return .declined,
            .review_changes => output.writePkgbuildQuestionFrame(self.context, question) catch return .declined,
            .select_one, .select_provider => output.writeProviderQuestionFrame(self.context, question) catch return .{ .choice = 0 },
            .select_many, .select_optional_dependencies => output.writeOptionalDependenciesQuestionFrame(self.context, question) catch return .{ .choices = &.{} },
        }
        flush(self.context) catch return .declined;
        if (self.future) |*future| future.await(self.context.io);
        self.future = self.context.io.concurrent(readAndRespond, .{ self, question.question_id, question.kind }) catch {
            readAndRespond(self, question.question_id, question.kind);
            return .deferred;
        };
        return .deferred;
    }

    fn writeAutomaticReview(
        self: *QuestionResponder,
        question: Zigalpm.OperationQuestion,
    ) !void {
        const review = question.review orelse return error.MissingReviewPayload;
        for (review.findings) |finding| {
            const message = try std.fmt.allocPrint(self.context.allocator, "[{s}] {s} in {s}: {s}\n{s}", .{
                @tagName(finding.severity),
                finding.tool,
                finding.hook,
                finding.message,
                finding.matched_line,
            });
            defer self.context.allocator.free(message);
            try output.writeErrorFrame(self.context, message);
        }
        for (review.related_files) |file| {
            const message = try std.fmt.allocPrint(
                self.context.allocator,
                "Source file: {s}\n{s}",
                .{ file.name, file.content },
            );
            defer self.context.allocator.free(message);
            try output.writeInfoFrame(self.context, message);
        }
        try flush(self.context);
    }

    fn readAndRespond(
        self: *QuestionResponder,
        question_id: u64,
        kind: Zigalpm.OperationQuestionKind,
    ) void {
        if (kind == .select_many or kind == .select_optional_dependencies) {
            const choices = self.readChoicesAnswer(question_id, "a.optdeps", "SelectedIndices") catch {
                self.operation_context.respond(question_id, .{ .choices = &.{} }) catch {};
                return;
            };
            defer self.context.allocator.free(choices);
            self.operation_context.respond(question_id, .{ .choices = choices }) catch {};
            return;
        }

        if (kind == .select_one or kind == .select_provider) {
            const choice = self.readChoiceAnswer(question_id, "a.provider", "SelectedIndex") catch 0;
            self.operation_context.respond(question_id, .{ .choice = choice }) catch {};
            return;
        }

        const accepted = switch (kind) {
            .confirmation => self.readBooleanAnswer(question_id, "a.yesno", "Accept") catch false,
            .confirm_transaction => self.readBooleanAnswer(question_id, "a.transaction", "Accept") catch false,
            .review_changes => self.readBooleanAnswer(question_id, "a.pkgbuilddiff", "ProceedWithUpdate") catch false,
            else => false,
        };
        self.operation_context.respond(
            question_id,
            if (accepted) .accepted else .declined,
        ) catch {};
    }

    fn readBooleanAnswer(
        self: *QuestionResponder,
        question_id: u64,
        expected_kind: []const u8,
        answer_field: []const u8,
    ) !bool {
        const reader = self.context.stdin orelse return error.EndOfStream;
        while ((try reader.takeDelimiter('\n'))) |line| {
            const prefix = "[JSON]";
            const suffix = "[/JSON]";
            const start_index = std.mem.indexOf(u8, line, prefix) orelse continue;
            const payload_start = start_index + prefix.len;
            const relative_end = std.mem.indexOf(u8, line[payload_start..], suffix) orelse continue;
            const encoded = line[payload_start .. payload_start + relative_end];
            const decoded_length = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch continue;
            const decoded = try self.context.allocator.alloc(u8, decoded_length);
            defer self.context.allocator.free(decoded);
            std.base64.standard.Decoder.decode(decoded, encoded) catch continue;

            var parsed = std.json.parseFromSlice(
                std.json.Value,
                self.context.allocator,
                decoded,
                .{},
            ) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const kind = parsed.value.object.get("$kind") orelse continue;
            if (kind != .string or !std.mem.eql(u8, kind.string, expected_kind)) continue;
            const id_value = parsed.value.object.get("QuestionId") orelse continue;
            if (id_value != .string) continue;
            const actual_id = std.fmt.parseInt(u64, id_value.string, 10) catch continue;
            if (actual_id != question_id) continue;
            const proceed = parsed.value.object.get(answer_field) orelse continue;
            if (proceed != .bool) continue;
            return proceed.bool;
        }
        return error.EndOfStream;
    }

    fn readChoicesAnswer(
        self: *QuestionResponder,
        question_id: u64,
        expected_kind: []const u8,
        answer_field: []const u8,
    ) ![]usize {
        const reader = self.context.stdin orelse return error.EndOfStream;
        while ((try reader.takeDelimiter('\n'))) |line| {
            const prefix = "[JSON]";
            const suffix = "[/JSON]";
            const start_index = std.mem.indexOf(u8, line, prefix) orelse continue;
            const payload_start = start_index + prefix.len;
            const relative_end = std.mem.indexOf(u8, line[payload_start..], suffix) orelse continue;
            const encoded = line[payload_start .. payload_start + relative_end];
            const decoded_length = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch continue;
            const decoded = try self.context.allocator.alloc(u8, decoded_length);
            defer self.context.allocator.free(decoded);
            std.base64.standard.Decoder.decode(decoded, encoded) catch continue;

            var parsed = std.json.parseFromSlice(
                std.json.Value,
                self.context.allocator,
                decoded,
                .{},
            ) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const kind = parsed.value.object.get("$kind") orelse continue;
            if (kind != .string or !std.mem.eql(u8, kind.string, expected_kind)) continue;
            const id_value = parsed.value.object.get("QuestionId") orelse continue;
            if (id_value != .string) continue;
            const actual_id = std.fmt.parseInt(u64, id_value.string, 10) catch continue;
            if (actual_id != question_id) continue;
            const selected = parsed.value.object.get(answer_field) orelse continue;
            if (selected != .array) continue;

            const choices = try self.context.allocator.alloc(usize, selected.array.items.len);
            errdefer self.context.allocator.free(choices);
            for (selected.array.items, choices) |value, *choice| {
                if (value != .integer or value.integer < 0) return error.InvalidAnswer;
                choice.* = std.math.cast(usize, value.integer) orelse return error.InvalidAnswer;
            }
            return choices;
        }
        return error.EndOfStream;
    }

    fn readChoiceAnswer(
        self: *QuestionResponder,
        question_id: u64,
        expected_kind: []const u8,
        answer_field: []const u8,
    ) !usize {
        const reader = self.context.stdin orelse return error.EndOfStream;
        while ((try reader.takeDelimiter('\n'))) |line| {
            const prefix = "[JSON]";
            const suffix = "[/JSON]";
            const start_index = std.mem.indexOf(u8, line, prefix) orelse continue;
            const payload_start = start_index + prefix.len;
            const relative_end = std.mem.indexOf(u8, line[payload_start..], suffix) orelse continue;
            const encoded = line[payload_start .. payload_start + relative_end];
            const decoded_length = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch continue;
            const decoded = try self.context.allocator.alloc(u8, decoded_length);
            defer self.context.allocator.free(decoded);
            std.base64.standard.Decoder.decode(decoded, encoded) catch continue;

            var parsed = std.json.parseFromSlice(
                std.json.Value,
                self.context.allocator,
                decoded,
                .{},
            ) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const kind = parsed.value.object.get("$kind") orelse continue;
            if (kind != .string or !std.mem.eql(u8, kind.string, expected_kind)) continue;
            const id_value = parsed.value.object.get("QuestionId") orelse continue;
            if (id_value != .string) continue;
            const actual_id = std.fmt.parseInt(u64, id_value.string, 10) catch continue;
            if (actual_id != question_id) continue;
            const selected = parsed.value.object.get(answer_field) orelse continue;
            if (selected != .integer or selected.integer < 0) continue;
            return std.math.cast(usize, selected.integer) orelse continue;
        }
        return error.EndOfStream;
    }
};

pub fn acceptQuestionDefaults(
    _: ?*anyopaque,
    question: Zigalpm.OperationQuestion,
) Zigalpm.OperationQuestionResponse {
    if (question.kind == .review_changes) return safeReviewDefault(question);
    return automaticResponse(question.kind);
}

fn safeReviewDefault(question: Zigalpm.OperationQuestion) Zigalpm.OperationQuestionResponse {
    return switch (question.default_response) {
        .accepted => .accepted,
        else => .declined,
    };
}

fn hasSecurityFindings(question: Zigalpm.OperationQuestion) bool {
    const review = question.review orelse return false;
    return review.findings.len != 0;
}

fn automaticResponse(kind: Zigalpm.OperationQuestionKind) Zigalpm.OperationQuestionResponse {
    return switch (kind) {
        .confirmation, .confirm_transaction => .accepted,
        .import_pgp_key, .review_changes => .declined,
        .select_one, .select_provider => .{ .choice = 0 },
        .select_many, .select_optional_dependencies => .{ .choices = &.{} },
    };
}

test "non-interactive UI declines source key imports" {
    try std.testing.expect(automaticResponse(.import_pgp_key) == .declined);
}

pub fn flush(context: *runtime.RuntimeContext) !void {
    try context.stdout.flush();
    try context.stderr.flush();
}

test "UI operation reporter preserves percentages for every progress frame shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    var operation_context = Zigalpm.OperationContext.init(arena.allocator(), std.testing.io);
    defer operation_context.deinit();
    var reporter: Reporter = .{ .context = &context };
    const subscription = try operation_context.subscribe(.{
        .function = Reporter.handle,
        .data = &reporter,
    });
    defer _ = operation_context.unsubscribe(subscription);

    var alpm = operation_context.begin(.{ .backend = .alpm, .kind = .install, .subject = "demo" });
    alpm.progress(.{ .stage = "transaction", .completed = 37, .total = 100, .percentage = 37, .native_code = 100 });
    alpm.finish(.success);
    var flatpak = operation_context.begin(.{ .backend = .flatpak, .kind = .install, .subject = "org.demo.App" });
    flatpak.progress(.{ .stage = "Downloading", .percentage = 64 });
    flatpak.finish(.success);
    var appimage = operation_context.begin(.{ .backend = .appimage, .kind = .download, .subject = "demo.AppImage" });
    appimage.progress(.{ .bytes_completed = 25, .bytes_total = 100 });
    appimage.finish(.success);
    var cleanup = operation_context.begin(.{ .backend = .alpm, .kind = .cleanup, .subject = "build dependencies" });
    cleanup.reportError(error.TestRecoverableFailure, "optional cleanup failed", "test", null, true);
    cleanup.finish(.failed);

    var frame_iterator = std.mem.splitSequence(u8, stdout.writer.buffered(), "[/JSON]\n");
    const expected = [_][]const []const u8{
        &.{
            "\"$kind\":\"alpm.progress\"",
            "\"CurrentDownload\":37",
            "\"TotalDownload\":100",
            "\"ProgressType\":\"PackageDownload\"",
            "\"Percent\":37",
            "\"Stage\":\"transaction\"",
        },
        &.{
            "\"$kind\":\"flatpak.progress\"",
            "\"Status\":\"Downloading\"",
            "\"Percentage\":64",
        },
        &.{
            "\"$kind\":\"appimage.progress\"",
            "\"Status\":\"demo.AppImage\"",
            "\"Percentage\":25",
        },
        &.{
            "\"$kind\":\"alpm.info\"",
            "\"EventType\":\"WarningOutput\"",
            "\"Message\":\"optional cleanup failed\\n\\nTechnical details: TestRecoverableFailure\"",
            "\"Level\":\"Warning\"",
        },
    };
    for (expected) |needles| {
        const frame = frame_iterator.next() orelse return error.MissingProgressFrame;
        const prefix = "[JSON]";
        try std.testing.expect(std.mem.startsWith(u8, frame, prefix));
        const encoded = frame[prefix.len..];
        const decoded_length = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
        const decoded = try arena.allocator().alloc(u8, decoded_length);
        try std.base64.standard.Decoder.decode(decoded, encoded);
        for (needles) |needle|
            try std.testing.expect(std.mem.indexOf(u8, decoded, needle) != null);
    }
    try std.testing.expectEqual(@as(usize, 0), (frame_iterator.next() orelse return error.MissingFrameTerminator).len);
    try std.testing.expect(frame_iterator.next() == null);
    try std.testing.expect(!reporter.failed());
}

test "UI risky PKGBUILD review bypasses no-confirm and waits for matching answer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response_json =
        "{\"$kind\":\"a.pkgbuilddiff\",\"QuestionId\":\"1\",\"ProceedWithUpdate\":true}";
    const encoded_size = std.base64.standard.Encoder.calcSize(response_json.len);
    const encoded = try arena.allocator().alloc(u8, encoded_size);
    const encoded_response = std.base64.standard.Encoder.encode(encoded, response_json);
    const response_frame = try std.fmt.allocPrint(
        arena.allocator(),
        "ignored\n[JSON]{s}[/JSON]\n",
        .{encoded_response},
    );
    var stdin = std.Io.Reader.fixed(response_frame);
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdin = &stdin,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    var operation_context = Zigalpm.OperationContext.init(arena.allocator(), std.testing.io);
    defer operation_context.deinit();
    var responder: QuestionResponder = .{
        .context = &context,
        .operation_context = &operation_context,
        .no_confirm = true,
    };
    responder.attach();
    defer responder.detach();

    const findings = [_]Zigalpm.OperationReviewFinding{.{
        .tool = "curl",
        .severity = .warning,
        .hook = "source: install.sh",
        .matched_line = "curl example.invalid",
        .message = "external download",
    }};
    const files = [_]Zigalpm.OperationQuestionAttachment{.{
        .name = "install.sh",
        .content = "curl example.invalid",
    }};
    var operation = operation_context.begin(.{ .backend = .aur, .kind = .install, .subject = "demo" });
    var answer = try operation.ask(.{
        .kind = .review_changes,
        .prompt = "Proceed with update to demo?",
        .review = .{
            .subject = "demo",
            .old_content = "pkgver=1",
            .new_content = "pkgver=2",
            .findings = &findings,
            .related_files = &files,
        },
        .default_response = .declined,
    });
    defer answer.deinit(arena.allocator());
    operation.finish(.success);

    try std.testing.expect(answer.response == .accepted);
    const rendered = stdout.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[JSON]") != null);
    const prefix_end = (std.mem.indexOf(u8, rendered, "[JSON]") orelse return error.MissingFrame) + "[JSON]".len;
    const suffix_start = std.mem.indexOfPos(u8, rendered, prefix_end, "[/JSON]") orelse return error.MissingFrame;
    const payload = rendered[prefix_end..suffix_start];
    const decoded_size = try std.base64.standard.Decoder.calcSizeForSlice(payload);
    const decoded = try arena.allocator().alloc(u8, decoded_size);
    try std.base64.standard.Decoder.decode(decoded, payload);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "\"$kind\":\"q.pkgbuilddiff\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "\"QuestionId\":\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "\"PackageName\":\"demo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "\"Severity\":\"Warning\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "\"SourceFiles\":{") != null);
}

test "UI transaction plan preserves package roles sizes and unknown AUR sizes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response_json =
        "{\"$kind\":\"a.transaction\",\"QuestionId\":\"1\",\"Accept\":true}";
    const encoded_size = std.base64.standard.Encoder.calcSize(response_json.len);
    const encoded = try arena.allocator().alloc(u8, encoded_size);
    const encoded_response = std.base64.standard.Encoder.encode(encoded, response_json);
    const response_frame = try std.fmt.allocPrint(
        arena.allocator(),
        "[JSON]{s}[/JSON]\n",
        .{encoded_response},
    );
    var stdin = std.Io.Reader.fixed(response_frame);
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdin = &stdin,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    var operation_context = Zigalpm.OperationContext.init(arena.allocator(), std.testing.io);
    defer operation_context.deinit();
    var responder: QuestionResponder = .{
        .context = &context,
        .operation_context = &operation_context,
        .no_confirm = false,
    };
    responder.attach();
    defer responder.detach();

    const packages = [_]Zigalpm.OperationTransactionPackage{
        .{
            .name = "demo",
            .version = "1.0-1",
            .repository = "AUR",
            .package_base = "demo",
            .revision = "deadbeef",
            .source = .aur,
            .role = .requested,
        },
        .{
            .name = "cmake",
            .repository = "extra",
            .source = .repository,
            .role = .build_dependency,
            .download_size = 1024,
            .installed_size = 4096,
        },
    };
    var operation = operation_context.begin(.{ .backend = .aur, .kind = .install, .subject = "demo" });
    var answer = try operation.ask(.{
        .kind = .confirm_transaction,
        .prompt = "Proceed with AUR package installation?",
        .transaction_plan = .{
            .action = .install,
            .packages = &packages,
        },
    });
    defer answer.deinit(arena.allocator());
    operation.finish(.success);

    try std.testing.expect(answer.response == .accepted);
    const rendered = stdout.writer.buffered();
    const prefix_end = (std.mem.indexOf(u8, rendered, "[JSON]") orelse return error.MissingFrame) + "[JSON]".len;
    const suffix_start = std.mem.indexOfPos(u8, rendered, prefix_end, "[/JSON]") orelse return error.MissingFrame;
    const payload = rendered[prefix_end..suffix_start];
    const decoded_size = try std.base64.standard.Decoder.calcSizeForSlice(payload);
    const decoded = try arena.allocator().alloc(u8, decoded_size);
    try std.base64.standard.Decoder.decode(decoded, payload);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "\"$kind\":\"q.transaction\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "\"Role\":\"requested\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "\"DownloadSize\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "\"Role\":\"build_dependency\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "\"DownloadSize\":1024") != null);
}

test "UI optional dependencies emit C# compatible choices and accept selected indices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const response_json =
        "{\"$kind\":\"a.optdeps\",\"QuestionId\":\"1\",\"SelectedIndices\":[0,2]}";
    const encoded_size = std.base64.standard.Encoder.calcSize(response_json.len);
    const encoded = try arena.allocator().alloc(u8, encoded_size);
    const encoded_response = std.base64.standard.Encoder.encode(encoded, response_json);
    const response_frame = try std.fmt.allocPrint(
        arena.allocator(),
        "[JSON]{s}[/JSON]\n",
        .{encoded_response},
    );
    var stdin = std.Io.Reader.fixed(response_frame);
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdin = &stdin,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    var operation_context = Zigalpm.OperationContext.init(arena.allocator(), std.testing.io);
    defer operation_context.deinit();
    var responder: QuestionResponder = .{
        .context = &context,
        .operation_context = &operation_context,
        .no_confirm = false,
    };
    responder.attach();
    defer responder.detach();

    const options = [_]Zigalpm.OperationQuestionOption{
        .{ .id = "spellcheck", .label = "spellcheck", .description = "Spell checking" },
        .{ .id = "templates", .label = "templates", .description = "Templates", .is_installed = true },
        .{ .id = "plugins", .label = "plugins", .description = "Plugin support", .is_selected = true },
    };
    var operation = operation_context.begin(.{ .backend = .aur, .kind = .install, .subject = "demo" });
    var answer = try operation.ask(.{
        .kind = .select_optional_dependencies,
        .prompt = "Select optional dependencies for demo",
        .options = &options,
        .dependency_name = "demo",
    });
    defer answer.deinit(arena.allocator());
    operation.finish(.success);

    try std.testing.expect(answer.response == .choices);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2 }, answer.response.choices);
    const rendered = stdout.writer.buffered();
    const prefix_end = (std.mem.indexOf(u8, rendered, "[JSON]") orelse return error.MissingFrame) + "[JSON]".len;
    const suffix_start = std.mem.indexOfPos(u8, rendered, prefix_end, "[/JSON]") orelse return error.MissingFrame;
    const payload = rendered[prefix_end..suffix_start];
    const decoded_size = try std.base64.standard.Decoder.calcSizeForSlice(payload);
    const decoded = try arena.allocator().alloc(u8, decoded_size);
    try std.base64.standard.Decoder.decode(decoded, payload);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "\"$kind\":\"q.optdeps\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "\"DependencyName\":\"demo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "\"QuestionText\":\"Select optional dependencies for demo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "\"Index\":1,\"Name\":\"templates\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "\"IsInstalled\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "\"IsSelected\":true") != null);
}

test "UI handles provider and generic selection questions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var response_frames = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer response_frames.deinit();
    const responses = [_][]const u8{
        "{\"$kind\":\"a.provider\",\"QuestionId\":\"1\",\"SelectedIndex\":1}",
        "{\"$kind\":\"a.provider\",\"QuestionId\":\"2\",\"SelectedIndex\":0}",
        "{\"$kind\":\"a.optdeps\",\"QuestionId\":\"3\",\"SelectedIndices\":[1]}",
    };
    for (responses) |response_json| {
        const encoded_size = std.base64.standard.Encoder.calcSize(response_json.len);
        const encoded = try arena.allocator().alloc(u8, encoded_size);
        const encoded_response = std.base64.standard.Encoder.encode(encoded, response_json);
        try response_frames.writer.print("[JSON]{s}[/JSON]\n", .{encoded_response});
    }
    var stdin = std.Io.Reader.fixed(response_frames.writer.buffered());
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdin = &stdin,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    var operation_context = Zigalpm.OperationContext.init(arena.allocator(), std.testing.io);
    defer operation_context.deinit();
    var responder: QuestionResponder = .{
        .context = &context,
        .operation_context = &operation_context,
        .no_confirm = false,
    };
    responder.attach();
    defer responder.detach();

    const options = [_]Zigalpm.OperationQuestionOption{
        .{ .id = "first", .label = "First", .description = "First choice" },
        .{ .id = "second", .label = "Second", .description = "Second choice" },
    };
    var operation = operation_context.begin(.{ .backend = .alpm, .kind = .install, .subject = "demo" });
    defer operation.finish(.success);

    var provider_answer = try operation.ask(.{
        .kind = .select_provider,
        .prompt = "Select provider",
        .options = &options,
        .dependency_name = "java-runtime",
    });
    defer provider_answer.deinit(arena.allocator());
    try std.testing.expect(provider_answer.response == .choice);
    try std.testing.expectEqual(@as(usize, 1), provider_answer.response.choice);

    var one_answer = try operation.ask(.{
        .kind = .select_one,
        .prompt = "Select one package",
        .options = &options,
    });
    defer one_answer.deinit(arena.allocator());
    try std.testing.expect(one_answer.response == .choice);
    try std.testing.expectEqual(@as(usize, 0), one_answer.response.choice);

    var many_answer = try operation.ask(.{
        .kind = .select_many,
        .prompt = "Select packages",
        .options = &options,
    });
    defer many_answer.deinit(arena.allocator());
    try std.testing.expect(many_answer.response == .choices);
    try std.testing.expectEqualSlices(usize, &.{1}, many_answer.response.choices);

    var provider_frames: usize = 0;
    var multiple_frames: usize = 0;
    var frame_iterator = std.mem.splitSequence(u8, stdout.writer.buffered(), "[/JSON]\n");
    while (frame_iterator.next()) |frame| {
        if (frame.len == 0) continue;
        const prefix = "[JSON]";
        if (!std.mem.startsWith(u8, frame, prefix)) continue;
        const encoded = frame[prefix.len..];
        const decoded_size = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
        const decoded = try arena.allocator().alloc(u8, decoded_size);
        try std.base64.standard.Decoder.decode(decoded, encoded);
        if (std.mem.indexOf(u8, decoded, "\"$kind\":\"q.provider\"") != null) provider_frames += 1;
        if (std.mem.indexOf(u8, decoded, "\"$kind\":\"q.optdeps\"") != null) multiple_frames += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), provider_frames);
    try std.testing.expectEqual(@as(usize, 1), multiple_frames);
}
