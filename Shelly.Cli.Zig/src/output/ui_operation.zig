const std = @import("std");
const Zigalpm = @import("Zigalpm");
const output = @import("config.zig");
const runtime = @import("../runtime/context.zig");

pub const Reporter = struct {
    context: *runtime.RuntimeContext,
    mutex: std.Io.Mutex = .init,
    write_failed: std.atomic.Value(bool) = .init(false),

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
            .failure => |failure| try output.writeErrorFrame(self.context, failure.message),
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
                self.writeAutomaticReview(question) catch return .declined;
                return safeReviewDefault(question);
            }
            return automaticResponse(question.kind);
        }

        switch (question.kind) {
            .confirmation => output.writeYesNoQuestionFrame(self.context, question) catch return .declined,
            .review_changes => output.writePkgbuildQuestionFrame(self.context, question) catch return .declined,
            else => return question.default_response,
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
        const accepted = switch (kind) {
            .confirmation => self.readBooleanAnswer(question_id, "a.yesno", "Accept") catch false,
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

fn automaticResponse(kind: Zigalpm.OperationQuestionKind) Zigalpm.OperationQuestionResponse {
    return switch (kind) {
        .confirmation => .accepted,
        .review_changes => .declined,
        .select_one, .select_provider => .{ .choice = 0 },
        .select_many, .select_optional_dependencies => .{ .choices = &.{} },
    };
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
    alpm.progress(.{ .completed = 37, .total = 100, .percentage = 37, .native_code = 100 });
    alpm.finish(.success);
    var flatpak = operation_context.begin(.{ .backend = .flatpak, .kind = .install, .subject = "org.demo.App" });
    flatpak.progress(.{ .stage = "Downloading", .percentage = 64 });
    flatpak.finish(.success);
    var appimage = operation_context.begin(.{ .backend = .appimage, .kind = .download, .subject = "demo.AppImage" });
    appimage.progress(.{ .bytes_completed = 25, .bytes_total = 100 });
    appimage.finish(.success);

    var frame_iterator = std.mem.splitSequence(u8, stdout.writer.buffered(), "[/JSON]\n");
    const expected = [_][]const []const u8{
        &.{
            "\"$kind\":\"alpm.progress\"",
            "\"CurrentDownload\":37",
            "\"TotalDownload\":100",
            "\"ProgressType\":\"PackageDownload\"",
            "\"Percent\":37",
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

test "UI PKGBUILD review emits C# compatible frame and waits for matching answer" {
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
        .no_confirm = false,
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
