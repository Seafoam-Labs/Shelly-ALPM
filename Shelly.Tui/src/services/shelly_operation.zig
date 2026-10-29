//! Frontend-neutral operation protocol baseline, adapted from the GTK client.
const std = @import("std");
const diagnostics = @import("diagnostics");
const JsonPackFrame = @import("ui_decode.zig").JsonPackFrame;
const flatpak_models = @import("../models/flatpak.zig");
const Scope = @import("../models/flatpak.zig").InstallLevel;
const UpdateType = @import("../models/appimage.zig").UpdateType;

pub const Action = enum {
    install,
    remove,
    upgrade,

    pub fn verb(self: Action) []const u8 {
        return switch (self) {
            .install => "Install",
            .remove => "Remove",
            .upgrade => "Upgrade",
        };
    }

    pub fn ongoing(self: Action) []const u8 {
        return switch (self) {
            .install => "Installing",
            .remove => "Removing",
            .upgrade => "Upgrading",
        };
    }

    pub fn completed(self: Action) []const u8 {
        return switch (self) {
            .install => "Installed",
            .remove => "Removed",
            .upgrade => "Upgraded",
        };
    }
};

pub const FlatpakTarget = struct {
    scope: Scope,
    remote: []const u8 = "",
    arch: []const u8 = "",
    branch: []const u8 = "",
    reference: []const u8 = "",
    kind: flatpak_models.FlatpakKind = .app,

    pub fn clone(self: FlatpakTarget, alloc: std.mem.Allocator) !FlatpakTarget {
        var result = self;
        result.remote = if (self.remote.len > 0) try alloc.dupe(u8, self.remote) else "";
        errdefer if (result.remote.len > 0) alloc.free(result.remote);
        result.arch = if (self.arch.len > 0) try alloc.dupe(u8, self.arch) else "";
        errdefer if (result.arch.len > 0) alloc.free(result.arch);
        result.branch = if (self.branch.len > 0) try alloc.dupe(u8, self.branch) else "";
        errdefer if (result.branch.len > 0) alloc.free(result.branch);
        result.reference = if (self.reference.len > 0) try alloc.dupe(u8, self.reference) else "";
        return result;
    }

    pub fn deinit(self: FlatpakTarget, alloc: std.mem.Allocator) void {
        inline for (.{ "remote", "arch", "branch", "reference" }) |field| {
            if (@field(self, field).len > 0) alloc.free(@field(self, field));
        }
    }
};

pub fn flatpakNeedsElevation(action: Action, target: ?FlatpakTarget) bool {
    return action != .upgrade and target != null and target.?.scope == .system;
}

pub const OperationRequest = struct {
    action: Action = .install,
    sudo_bin: []const u8 = "sudo",
    shelly_bin: []const u8,
    environ_map: *const std.process.Environ.Map,
    name: []const u8,
    backend: []const u8,
    password: []const u8,
    flatpak: ?FlatpakTarget = null,
};

/// Fixed-size, owned display data; safe to copy between the worker and UI.
pub const Progress = struct {
    status: [512]u8 = @splat(0),
    status_len: usize = 0,
    percent: ?i64 = null,
    messages: [4][512]u8 = @splat(@splat(0)),
    lengths: [4]usize = @splat(0),

    pub fn text(self: *const Progress) []const u8 {
        return self.status[0..self.status_len];
    }

    fn update(self: *Progress, text_value: []const u8, percent: ?i64) void {
        self.percent = percent;
        self.status_len = @min(text_value.len, self.status.len);
        @memcpy(self.status[0..self.status_len], text_value[0..self.status_len]);
    }

    fn log(self: *Progress, value: []const u8) void {
        if (value.len == 0) return;
        for (0..3) |i| {
            self.messages[i] = self.messages[i + 1];
            self.lengths[i] = self.lengths[i + 1];
        }
        self.lengths[3] = @min(value.len, 512);
        @memcpy(self.messages[3][0..self.lengths[3]], value[0..self.lengths[3]]);
    }
};

const ProgressStream = struct {
    const max_frame_bytes = 8 * 1024 * 1024;
    payload: std.ArrayList(u8) = .empty,
    len: usize = 0,
    matched: usize = 0,
    in_frame: bool = false,
    failed: bool = false,
    error_text: [512]u8 = @splat(0),
    error_len: usize = 0,
    transaction_done: bool = false,
    transaction_cancelled: bool = false,

    fn deinit(self: *ProgressStream) void {
        self.payload.deinit(std.heap.page_allocator);
    }

    fn feed(self: *ProgressStream, bytes: []const u8, operation: ?*Operation, io: std.Io) void {
        for (bytes) |byte| {
            if (!self.in_frame) {
                const marker = "[JSON]";
                if (byte == marker[self.matched]) {
                    self.matched += 1;
                    if (self.matched == marker.len) {
                        self.in_frame = true;
                        self.matched = 0;
                        self.len = 0;
                        self.payload.clearRetainingCapacity();
                    }
                } else self.matched = if (byte == '[') 1 else 0;
                continue;
            }
            if (self.len == max_frame_bytes) {
                self.failed = true;
                if (operation) |op| op.closeInput(io);
                self.in_frame = false;
                self.len = 0;
                continue;
            }
            self.payload.append(std.heap.page_allocator, byte) catch {
                self.failed = true;
                if (operation) |op| op.closeInput(io);
                return;
            };
            self.len += 1;
            if (!std.mem.endsWith(u8, self.payload.items, "[/JSON]")) continue;
            self.in_frame = false;
            var message = decodePayload(std.heap.page_allocator, self.payload.items[0 .. self.len - 7]) catch {
                self.failed = true;
                if (operation) |op| op.closeInput(io);
                continue;
            };
            var transferred = false;
            defer if (!transferred) message.deinit();
            switch (message.value) {
                .question => {
                    if (operation) |op| {
                        op.queueQuestion(io, message) catch {
                            self.failed = true;
                            op.closeInput(io);
                            continue;
                        };
                        transferred = true;
                    } else self.failed = true;
                },
                .event => |event| {
                    if (event == .info) {
                        if (std.mem.eql(u8, event.info.event_type, "TransactionDone")) self.transaction_done = true;
                        if (std.mem.eql(u8, event.info.event_type, "TransactionFailed")) {
                            self.failed = true;
                            if (self.error_len == 0) {
                                self.error_len = @min(event.info.message.len, self.error_text.len);
                                @memcpy(self.error_text[0..self.error_len], event.info.message[0..self.error_len]);
                            }
                        }
                        if (std.mem.eql(u8, event.info.event_type, "TransactionCancelled")) self.transaction_cancelled = true;
                    }
                    if (event == .err) {
                        self.failed = true;
                        self.error_len = @min(event.err.message.len, self.error_text.len);
                        @memcpy(self.error_text[0..self.error_len], event.err.message[0..self.error_len]);
                    }
                    if (operation) |op| op.record(io, event);
                },
            }
        }
    }
};

pub const Operation = struct {
    arena: std.heap.ArenaAllocator,
    request: OperationRequest,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    result: OperationResult = .{},
    progress_mutex: std.Io.Mutex = .init,
    progress: Progress = .{},
    input: ?std.Io.File = null,
    input_closing: bool = false,
    pending: ?OwnedMessage = null,
    expected_id: [20]u8 = undefined,
    expected_len: usize = 0,
    expected_answer: ?enum { yes_no, transaction, optional_dependencies, pkgbuild, provider } = null,
    user_declined: bool = false,

    fn queueQuestion(self: *Operation, io: std.Io, message: OwnedMessage) !void {
        const question = message.value.question;
        const id = questionId(question);
        self.progress_mutex.lockUncancelable(io);
        defer self.progress_mutex.unlock(io);
        if (!interactive(self.request) or self.input == null or self.input_closing) return error.InputClosed;
        if (self.expected_answer != null or self.pending != null) return error.QuestionAlreadyPending;
        if (id.len > self.expected_id.len) return error.InvalidQuestionId;
        @memcpy(self.expected_id[0..id.len], id);
        self.expected_len = id.len;
        self.expected_answer = switch (question) {
            .yes_no => .yes_no,
            .transaction => .transaction,
            .pkgbuild => .pkgbuild,
            .select_one => .provider,
            .select_many => .optional_dependencies,
        };
        self.pending = message;
    }

    /// Transfers ownership to the UI. Answers remain tied to this question ID.
    pub fn takeQuestion(self: *Operation, io: std.Io) ?OwnedMessage {
        self.progress_mutex.lockUncancelable(io);
        defer self.progress_mutex.unlock(io);
        const message = self.pending;
        self.pending = null;
        return message;
    }

    pub fn sendAnswer(self: *Operation, io: std.Io, id: []const u8, answer: Answer) !void {
        const encoded = try encodeAnswer(std.heap.page_allocator, id, answer);
        defer std.heap.page_allocator.free(encoded);
        self.progress_mutex.lockUncancelable(io);
        defer self.progress_mutex.unlock(io);
        const expected = self.expected_answer orelse return error.NoPendingQuestion;
        if (!std.mem.eql(u8, id, self.expected_id[0..self.expected_len])) return error.StaleQuestion;
        if (!std.mem.eql(u8, @tagName(answer), @tagName(expected))) return error.WrongAnswerKind;
        if (self.pending != null) return error.QuestionNotDelivered;
        const input = self.input orelse return error.InputClosed;
        var buffer: [4096]u8 = undefined;
        var writer = input.writer(io, &buffer);
        try writer.interface.writeAll(encoded);
        try writer.interface.flush();
        switch (answer) {
            .yes_no, .transaction, .pkgbuild => |accepted| {
                if (!accepted) self.user_declined = true;
            },
            else => {},
        }
        self.expected_answer = null;
        self.expected_len = 0;
    }

    pub fn closeInput(self: *Operation, io: std.Io) void {
        self.progress_mutex.lockUncancelable(io);
        defer self.progress_mutex.unlock(io);
        self.input_closing = true;
        if (self.input) |input| input.close(io);
        self.input = null;
    }

    fn registerInput(self: *Operation, io: std.Io, input: std.Io.File) void {
        self.progress_mutex.lockUncancelable(io);
        defer self.progress_mutex.unlock(io);
        if (self.input_closing) input.close(io) else self.input = input;
    }

    pub fn snapshot(self: *Operation, io: std.Io) Progress {
        self.progress_mutex.lockUncancelable(io);
        defer self.progress_mutex.unlock(io);
        return self.progress;
    }

    fn record(self: *Operation, io: std.Io, event: Event) void {
        self.progress_mutex.lockUncancelable(io);
        defer self.progress_mutex.unlock(io);
        var buffer: [512]u8 = undefined;
        switch (event) {
            .info => |info| {
                self.progress.update(info.message, null);
                self.progress.log(info.message);
            },
            .err => |err| {
                self.progress.update(err.message, null);
                self.progress.log(err.message);
            },
            .alpm_progress => |progress| {
                const text_value = std.fmt.bufPrint(&buffer, "{s}: {s}", .{
                    progress.stage orelse progress.progress_type,
                    if (progress.package_name.len > 0) progress.package_name else progress.message orelse "",
                }) catch buffer[0..];
                self.progress.update(text_value, progress.percent);
            },
            inline .flatpak_progress, .appimage_progress => |progress| {
                self.progress.update(progress.status orelse "Installing…", progress.percentage);
            },
            .unknown => {},
        }
    }

    pub fn start(request: OperationRequest) !*Operation {
        const self = try std.heap.page_allocator.create(Operation);
        errdefer std.heap.page_allocator.destroy(self);
        self.* = .{
            .arena = .init(std.heap.page_allocator),
            .request = request,
        };
        errdefer self.arena.deinit();
        const alloc = self.arena.allocator();
        self.request.sudo_bin = try alloc.dupe(u8, request.sudo_bin);
        self.request.shelly_bin = try alloc.dupe(u8, request.shelly_bin);
        self.request.name = try alloc.dupe(u8, request.name);
        self.request.backend = try alloc.dupe(u8, request.backend);
        if (request.flatpak) |target| self.request.flatpak = try target.clone(alloc);
        self.request.password = try alloc.dupe(u8, request.password);
        errdefer @memset(@constCast(self.request.password), 0);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    fn run(self: *Operation) void {
        {
            var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
            defer threaded.deinit();
            self.result = runInstall(threaded.io(), std.heap.page_allocator, self.request, self);
            @memset(@constCast(self.request.password), 0);
        }
        self.done.store(true, .release);
    }

    pub fn poll(self: *Operation) ?*const OperationResult {
        if (!self.done.load(.acquire)) return null;
        return &self.result;
    }

    pub fn deinit(self: *Operation) void {
        if (!self.done.load(.acquire)) {
            var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
            defer threaded.deinit();
            self.closeInput(threaded.io());
        }
        if (self.thread) |thread| thread.join();
        if (self.pending) |*pending| pending.deinit();
        self.result.deinit(std.heap.page_allocator);
        self.arena.deinit();
        std.heap.page_allocator.destroy(self);
    }
};

pub const OperationResult = struct {
    failed: bool = false,
    declined: bool = false,
    error_detail: []const u8 = "",

    pub fn deinit(self: *OperationResult, allocator: std.mem.Allocator) void {
        if (self.error_detail.len > 0) allocator.free(self.error_detail);
        self.* = undefined;
    }
};

/// Blocking package operation using the current sudo password flow.
/// The worker streams feedback; CLI questions still use automatic confirmation.
pub fn elevatedInstall(io: std.Io, alloc: std.mem.Allocator, request: OperationRequest) OperationResult {
    return runInstall(io, alloc, request, null);
}

fn interactive(request: OperationRequest) bool {
    return (std.mem.eql(u8, request.backend, "aur") and request.action != .remove) or isFlatpak(request);
}

fn isFlatpak(request: OperationRequest) bool {
    return std.mem.eql(u8, request.backend, "flatpak");
}

fn elevated(request: OperationRequest) bool {
    return !isFlatpak(request) or flatpakNeedsElevation(request.action, request.flatpak);
}

fn operationArgv(alloc: std.mem.Allocator, request: OperationRequest) ![][]const u8 {
    const keep_dependencies = request.action == .remove and std.mem.eql(u8, request.backend, "standard");
    if (request.action == .upgrade and !std.mem.eql(u8, request.backend, "standard") and !std.mem.eql(u8, request.backend, "aur") and !isFlatpak(request))
        return error.UnsupportedUpgradeSource;
    if (isFlatpak(request) and request.action != .upgrade) {
        const target = request.flatpak orelse return error.MissingFlatpakTarget;
        if (request.action == .install and (target.remote.len == 0 or target.arch.len > 0)) return error.UnsupportedFlatpakInstallTarget;
    }
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(alloc);
    if (elevated(request)) {
        if (interactive(request)) try argv.appendSlice(alloc, &.{ request.sudo_bin, "-n" }) else try argv.appendSlice(alloc, &.{ request.sudo_bin, "-S", "-p", "" });
    }
    try argv.appendSlice(alloc, &.{ request.shelly_bin, @tagName(request.action), request.backend });
    if (request.action != .upgrade) try argv.append(alloc, request.name);
    if (isFlatpak(request) and request.action == .install) {
        const target = request.flatpak.?;
        if (target.scope == .user) try argv.append(alloc, "--user");
        try argv.appendSlice(alloc, &.{ "--remote", target.remote });
        if (target.branch.len > 0) try argv.appendSlice(alloc, &.{ "--branch", target.branch });
        if (target.kind == .runtime) try argv.append(alloc, "--runtime");
    }
    if (!interactive(request)) try argv.append(alloc, "--no-confirm");
    try argv.append(alloc, "--ui-mode");
    if (keep_dependencies) try argv.append(alloc, "--no-cascade");
    return argv.toOwnedSlice(alloc);
}

/// Authenticate with a password-only stdin.
fn authorize(io: std.Io, alloc: std.mem.Allocator, request: OperationRequest) !?[]const u8 {
    var child = try std.process.spawn(io, .{
        .argv = &.{ request.sudo_bin, "-S", "-p", "", "-v" },
        .environ_map = request.environ_map,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .pipe,
    });
    defer child.kill(io);
    var write_buffer: [1024]u8 = undefined;
    var writer = child.stdin.?.writer(io, &write_buffer);
    writer.interface.writeAll(request.password) catch {};
    writer.interface.writeByte('\n') catch {};
    writer.interface.flush() catch {};
    child.stdin.?.close(io);
    child.stdin = null;
    var read_buffer: [4096]u8 = undefined;
    var reader = child.stderr.?.reader(io, &read_buffer);
    const stderr = try reader.interface.allocRemaining(alloc, .limited(16 * 1024));
    defer alloc.free(stderr);
    const term = try child.wait(io);
    if (term == .exited and term.exited == 0) return null;
    return try diagnostics.sanitizeAlloc(alloc, if (stderr.len > 0) stderr else "Authorization failed.");
}

fn runInstall(io: std.Io, alloc: std.mem.Allocator, request: OperationRequest, operation: ?*Operation) OperationResult {
    var result: OperationResult = .{};
    if (interactive(request) and operation == null) {
        result.failed = true;
        result.error_detail = alloc.dupe(u8, "Interactive operations require an operation handle.") catch "";
        return result;
    }
    if (request.action == .remove and !std.mem.eql(u8, request.backend, "standard") and !std.mem.eql(u8, request.backend, "aur") and !isFlatpak(request)) {
        result.failed = true;
        result.error_detail = alloc.dupe(u8, "Removal currently supports system, AUR and Flatpak packages only.") catch "";
        return result;
    }
    if (interactive(request) and elevated(request)) {
        const failure = authorize(io, alloc, request) catch {
            result.failed = true;
            result.error_detail = alloc.dupe(u8, "Could not validate authorization for the operation.") catch "";
            return result;
        };
        if (failure) |detail| {
            result.failed = true;
            result.error_detail = detail;
            return result;
        }
        if (operation) |op| @memset(@constCast(op.request.password), 0);
    }
    const argv = operationArgv(alloc, request) catch {
        result.failed = true;
        result.error_detail = alloc.dupe(u8, "Could not prepare the requested package operation.") catch "";
        return result;
    };
    defer alloc.free(argv);

    var child = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = request.environ_map,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch {
        result.error_detail = alloc.dupe(u8, "Could not start the requested package operation.") catch "";
        result.failed = true;
        return result;
    };
    defer child.kill(io);

    if (operation != null and interactive(request)) {
        operation.?.registerInput(io, child.stdin.?);
        child.stdin = null;
    } else {
        var stdin_buffer: [1024]u8 = undefined;
        var stdin_writer = child.stdin.?.writer(io, &stdin_buffer);
        stdin_writer.interface.writeAll(request.password) catch {};
        stdin_writer.interface.writeByte('\n') catch {};
        stdin_writer.interface.flush() catch {};
        child.stdin.?.close(io);
        child.stdin = null;
    }

    defer if (operation) |op| op.closeInput(io);

    // Drain both streams concurrently, mirroring std.process.run
    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(alloc, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    var stream: ProgressStream = .{};
    defer stream.deinit();
    var stderr_tail: [4096]u8 = undefined;
    var stderr_len: usize = 0;
    var read_failed = false;
    while (true) {
        var eof = false;
        multi_reader.fill(4096, .none) catch |err| {
            if (err != error.EndOfStream) read_failed = true;
            eof = true;
        };
        const stdout_reader = multi_reader.reader(0);
        stream.feed(stdout_reader.buffered(), operation, io);
        stdout_reader.seek = stdout_reader.end;
        const stderr_reader = multi_reader.reader(1);
        const bytes = stderr_reader.buffered();
        if (bytes.len > 0) {
            const take = @min(bytes.len, stderr_tail.len);
            const keep = @min(stderr_len, stderr_tail.len - take);
            std.mem.copyForwards(u8, stderr_tail[0..keep], stderr_tail[stderr_len - keep .. stderr_len]);
            @memcpy(stderr_tail[keep .. keep + take], bytes[bytes.len - take ..]);
            stderr_len = keep + take;
        }
        stderr_reader.seek = stderr_reader.end;
        if (eof) break;
    }
    multi_reader.checkAnyError() catch {
        read_failed = true;
    };
    if (stream.in_frame) stream.failed = true;

    if (operation) |op| op.closeInput(io);
    const term = child.wait(io) catch {
        result.error_detail = alloc.dupe(u8, "Could not collect the operation result for the requested package. Its final status could not be confirmed.") catch "";
        result.failed = true;
        return result;
    };

    if (operation) |op| {
        op.progress_mutex.lockUncancelable(io);
        defer op.progress_mutex.unlock(io);
        result.declined = op.user_declined;
        if (op.expected_answer != null) stream.failed = true;
    }
    const missing_completion = (request.action == .upgrade or interactive(request)) and !stream.transaction_done;
    if (term != .exited or term.exited != 0 or read_failed or stream.failed or stream.transaction_cancelled or missing_completion or result.declined) {
        const detail = if (stream.transaction_cancelled)
            "The operation was cancelled. Refresh package state before retrying."
        else if (stream.error_len > 0)
            stream.error_text[0..stream.error_len]
        else if (read_failed)
            "Could not read operation output; the final status could not be confirmed."
        else if (stream.failed)
            "Operation output contained an invalid, incomplete, or unsupported message. Check package state before retrying."
        else if (missing_completion and term == .exited and term.exited == 0)
            "The command exited without confirming completion. Check package state before retrying."
        else if (stderr_len > 0)
            std.mem.trim(u8, stderr_tail[0..stderr_len], " \t\r\n")
        else
            "The requested package operation failed. Shelly returned no error details.";
        result.error_detail = diagnostics.sanitizeAlloc(alloc, detail) catch "";
        result.failed = true;
    }
    return result;
}

pub const Event = union(enum) {
    info: struct {
        event_type: []const u8,
        message: []const u8,
        package_name: ?[]const u8,
        current: ?i64,
        total: ?i64,
    },
    err: struct {
        message: []const u8,
    },
    alpm_progress: struct {
        package_name: []const u8,
        current_download: i64,
        total_download: i64,
        progress_type: []const u8,
        percent: i64,
        stage: ?[]const u8,
        message: ?[]const u8,
    },
    flatpak_progress: struct {
        status: ?[]const u8,
        percentage: i64,
    },
    appimage_progress: struct {
        status: ?[]const u8,
        percentage: i64,
    },
    unknown: []const u8,
};

const AlpmInfo = struct {
    @"$kind": []const u8 = "",
    EventType: []const u8 = "",
    Message: []const u8 = "",
    PackageName: ?[]const u8 = null,
    CurrentIndex: ?i64 = null,
    TotalCount: ?i64 = null,
};

const AlpmError = struct {
    @"$kind": []const u8 = "",
    ErrorMessage: []const u8 = "",
    Level: []const u8 = "Error",
    Recoverable: bool = false,
};

const AlpmProgress = struct {
    @"$kind": []const u8 = "",
    PackageName: []const u8 = "",
    CurrentDownload: i64 = 0,
    TotalDownload: i64 = 0,
    ProgressType: []const u8 = "",
    Percent: i64 = 0,
    Stage: ?[]const u8 = null,
    Message: ?[]const u8 = null,
};

const SimpleProgress = struct {
    @"$kind": []const u8 = "",
    Status: ?[]const u8 = null,
    Percentage: i64 = 0,
};

pub const Question = union(enum) {
    yes_no: struct {
        question_id: []const u8,
        question_kind: []const u8,
        question_text: []const u8,
        arguments: []const []const u8,
    },
    select_many: struct {
        question_id: []const u8,
        prompt: []const u8,
        options: []Option,
    },
    select_one: struct {
        question_id: []const u8,
        prompt: []const u8,
        options: []Option,
    },
    pkgbuild: struct {
        question_id: []const u8,
        package_name: []const u8,
        old_pkgbuild: []const u8,
        new_pkgbuild: []const u8,
        warnings: []const Warning = &.{},
        diff_lines: []const []const u8 = &.{},
        source_files: []const SourceFile = &.{},
    },
    transaction: TransactionQuestion,
};

pub const TransactionMigration = struct {
    path: []const u8,
    destination: []const u8,
    source: ?[]const u8 = null,
    origin: []const u8,
};

pub const TransactionQuestion = struct {
    migrations: []const TransactionMigration = &.{},
    question_id: []const u8,
    question_text: []const u8,
    action: []const u8,
    packages: []TransactionPackage,
    total_download_size: ?u64,
    total_installed_size: ?u64,
    net_installed_size: ?i64,
};

pub const TransactionPackage = struct {
    name: []const u8,
    version: ?[]const u8,
    repository: ?[]const u8,
    package_base: ?[]const u8,
    revision: ?[]const u8,
    source: []const u8,
    role: []const u8,
    download_size: ?u64,
    installed_size: ?u64,
};

pub const Option = struct {
    index: usize,
    name: []const u8,
    description: []const u8,
    is_installed: bool,
    is_selected: bool,
};

const SelectionRequest = struct {
    @"$kind": []const u8 = "",
    QuestionId: []const u8,
    DependencyName: []const u8 = "",
    QuestionText: []const u8 = "",
    Options: []OptionWire = &.{},
};

pub const SourceFile = struct {
    name: []const u8,
    content: []const u8,
};

pub const PkgbuildDiff = struct {
    @"$kind": []const u8 = "",
    QuestionId: []const u8,
    PackageName: []const u8,
    OldPkgbuild: []const u8,
    NewPkgbuild: []const u8,
    Warnings: []const Warning = &.{},
    DiffLines: []const []const u8 = &.{},
    SourceFiles: ?std.json.ArrayHashMap([]const u8) = null,
};

pub const Warning = struct {
    Tool: []const u8 = "",
    Severity: []const u8 = "",
    Hook: []const u8 = "",
    MatchedLine: []const u8 = "",
    Message: []const u8 = "",
};

const OptionWire = struct {
    Index: usize = 0,
    Name: []const u8 = "",
    Description: []const u8 = "",
    IsInstalled: bool = false,
    IsSelected: bool = false,
};

const YesNoRequest = struct {
    @"$kind": []const u8 = "",
    QuestionId: []const u8,
    QuestionKind: []const u8 = "",
    QuestionText: []const u8 = "",
    Arguments: []const []const u8 = &.{},
};

pub const TransactionRequest = struct {
    @"$kind": []const u8 = "",
    QuestionId: []const u8,
    QuestionText: []const u8 = "",
    Action: []const u8 = "",
    Packages: []TransactionPackageWire = &.{},
    Migrations: []TransactionMigration = &.{},
    TotalDownloadSize: ?u64 = null,
    TotalInstalledSize: ?u64 = null,
    NetInstalledSize: ?i64 = null,
};

const TransactionPackageWire = struct {
    Name: []const u8 = "",
    Version: ?[]const u8 = null,
    Repository: ?[]const u8 = null,
    PackageBase: ?[]const u8 = null,
    Revision: ?[]const u8 = null,
    Source: []const u8 = "",
    Role: []const u8 = "",
    DownloadSize: ?u64 = null,
    InstalledSize: ?u64 = null,
};

pub const Message = union(enum) {
    event: Event,
    question: Question,
};

pub const OwnedMessage = struct {
    arena: std.heap.ArenaAllocator,
    value: Message,

    pub fn deinit(self: *OwnedMessage) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn parseWire(comptime T: type, allocator: std.mem.Allocator, json: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

pub fn questionId(question: Question) []const u8 {
    return switch (question) {
        inline else => |q| q.question_id,
    };
}

pub fn decodePayload(allocator: std.mem.Allocator, payload: []const u8) !OwnedMessage {
    const json = try JsonPackFrame.decodeBase64(allocator, payload);
    defer allocator.free(json);
    return decodeJson(allocator, json);
}

pub fn decodeJson(allocator: std.mem.Allocator, json: []const u8) !OwnedMessage {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    const envelope = try parseWire(struct { @"$kind": []const u8 }, alloc, json);
    const kind = envelope.@"$kind";
    const value: Message = if (std.mem.startsWith(u8, kind, "q.")) blk: {
        const question = try decodeQuestion(alloc, json, kind);
        const id = questionId(question);
        // The CLI parses question IDs as decimal u64 strings.
        if (id.len == 0) return error.InvalidQuestionId;
        for (id) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidQuestionId;
        _ = std.fmt.parseInt(u64, id, 10) catch return error.InvalidQuestionId;
        break :blk .{ .question = question };
    } else .{ .event = try decodeEvent(alloc, json, kind) };
    return .{ .arena = arena, .value = value };
}

fn decodeQuestion(alloc: std.mem.Allocator, json: []const u8, kind: []const u8) !Question {
    if (std.mem.eql(u8, kind, "q.yesno")) {
        const q = try parseWire(YesNoRequest, alloc, json);
        return .{ .yes_no = .{
            .question_id = q.QuestionId,
            .question_kind = q.QuestionKind,
            .question_text = q.QuestionText,
            .arguments = q.Arguments,
        } };
    }
    if (std.mem.eql(u8, kind, "q.transaction")) {
        const q = try parseWire(TransactionRequest, alloc, json);
        const packages = try alloc.alloc(TransactionPackage, q.Packages.len);
        for (q.Packages, packages) |package, *target| target.* = .{
            .name = package.Name,
            .version = package.Version,
            .repository = package.Repository,
            .package_base = package.PackageBase,
            .revision = package.Revision,
            .source = package.Source,
            .role = package.Role,
            .download_size = package.DownloadSize,
            .installed_size = package.InstalledSize,
        };
        return .{ .transaction = .{
            .question_id = q.QuestionId,
            .question_text = q.QuestionText,
            .action = q.Action,
            .packages = packages,
            .migrations = q.Migrations,
            .total_download_size = q.TotalDownloadSize,
            .total_installed_size = q.TotalInstalledSize,
            .net_installed_size = q.NetInstalledSize,
        } };
    }
    if (std.mem.eql(u8, kind, "q.provider") or std.mem.eql(u8, kind, "q.optdeps")) {
        const q = try parseWire(SelectionRequest, alloc, json);
        const options = try alloc.alloc(Option, q.Options.len);
        for (q.Options, options) |option, *target| target.* = .{
            .index = option.Index,
            .name = option.Name,
            .description = option.Description,
            .is_installed = option.IsInstalled,
            .is_selected = option.IsSelected,
        };
        if (std.mem.eql(u8, kind, "q.provider")) return .{ .select_one = .{
            .question_id = q.QuestionId,
            .prompt = q.DependencyName,
            .options = options,
        } };
        return .{ .select_many = .{
            .question_id = q.QuestionId,
            .prompt = q.QuestionText,
            .options = options,
        } };
    }
    if (std.mem.eql(u8, kind, "q.pkgbuilddiff")) {
        const q = try parseWire(PkgbuildDiff, alloc, json);
        const count = if (q.SourceFiles) |files| files.map.count() else 0;
        const files = try alloc.alloc(SourceFile, count);
        if (q.SourceFiles) |source| {
            var iterator = source.map.iterator();
            var index: usize = 0;
            while (iterator.next()) |entry| : (index += 1) {
                files[index] = .{ .name = entry.key_ptr.*, .content = entry.value_ptr.* };
            }
        }
        return .{ .pkgbuild = .{
            .question_id = q.QuestionId,
            .package_name = q.PackageName,
            .old_pkgbuild = q.OldPkgbuild,
            .new_pkgbuild = q.NewPkgbuild,
            .warnings = q.Warnings,
            .diff_lines = q.DiffLines,
            .source_files = files,
        } };
    }
    return error.UnsupportedQuestion;
}

fn decodeEvent(alloc: std.mem.Allocator, json: []const u8, kind: []const u8) !Event {
    if (std.mem.eql(u8, kind, "alpm.info")) {
        const e = try parseWire(AlpmInfo, alloc, json);
        return .{ .info = .{
            .event_type = e.EventType,
            .message = e.Message,
            .package_name = e.PackageName,
            .current = e.CurrentIndex,
            .total = e.TotalCount,
        } };
    }
    if (std.mem.eql(u8, kind, "alpm.error")) {
        const e = try parseWire(AlpmError, alloc, json);
        if (e.Recoverable or !std.mem.eql(u8, e.Level, "Error")) return .{ .info = .{
            .event_type = "Warning",
            .message = e.ErrorMessage,
            .package_name = null,
            .current = null,
            .total = null,
        } };
        return .{ .err = .{ .message = e.ErrorMessage } };
    }
    if (std.mem.eql(u8, kind, "alpm.progress")) {
        const e = try parseWire(AlpmProgress, alloc, json);
        return .{ .alpm_progress = .{
            .package_name = e.PackageName,
            .current_download = e.CurrentDownload,
            .total_download = e.TotalDownload,
            .progress_type = e.ProgressType,
            .percent = std.math.clamp(e.Percent, 0, 100),
            .stage = e.Stage,
            .message = e.Message,
        } };
    }
    if (std.mem.eql(u8, kind, "flatpak.progress") or std.mem.eql(u8, kind, "appimage.progress")) {
        const e = try parseWire(SimpleProgress, alloc, json);
        if (std.mem.eql(u8, kind, "flatpak.progress")) return .{ .flatpak_progress = .{
            .status = e.Status,
            .percentage = std.math.clamp(e.Percentage, 0, 100),
        } };
        return .{ .appimage_progress = .{
            .status = e.Status,
            .percentage = std.math.clamp(e.Percentage, 0, 100),
        } };
    }
    return .{ .unknown = kind };
}

pub const Answer = union(enum) {
    yes_no: bool,
    transaction: bool,
    optional_dependencies: []const usize,
    pkgbuild: bool,
    provider: usize,
};

pub fn encodeAnswer(allocator: std.mem.Allocator, question_id: []const u8, answer: Answer) ![]u8 {
    if (question_id.len == 0) return error.InvalidQuestionId;
    for (question_id) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidQuestionId;
    _ = std.fmt.parseInt(u64, question_id, 10) catch return error.InvalidQuestionId;
    const json = switch (answer) {
        .yes_no => |accept| try std.json.Stringify.valueAlloc(allocator, .{ .@"$kind" = "a.yesno", .QuestionId = question_id, .Accept = accept }, .{}),
        .transaction => |accept| try std.json.Stringify.valueAlloc(allocator, .{ .@"$kind" = "a.transaction", .QuestionId = question_id, .Accept = accept }, .{}),
        .optional_dependencies => |selected| try std.json.Stringify.valueAlloc(allocator, .{ .@"$kind" = "a.optdeps", .QuestionId = question_id, .SelectedIndices = selected }, .{}),
        .pkgbuild => |accept| try std.json.Stringify.valueAlloc(allocator, .{ .@"$kind" = "a.pkgbuilddiff", .QuestionId = question_id, .ProceedWithUpdate = accept }, .{}),
        .provider => |selected| try std.json.Stringify.valueAlloc(allocator, .{ .@"$kind" = "a.provider", .QuestionId = question_id, .SelectedIndex = selected }, .{}),
    };
    defer allocator.free(json);
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(json.len));
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, json);
    return std.fmt.allocPrint(allocator, "[JSON]{s}[/JSON]\n", .{encoded});
}

pub const ShellyCommands = struct {
    pub fn install(alloc: std.mem.Allocator, names: []const []const u8) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);
        try argv.append(alloc, "install");
        try argv.append(alloc, "standard");
        for (names) |n| try argv.append(alloc, n);
        return argv.toOwnedSlice(alloc);
    }

    pub fn upgrade(alloc: std.mem.Allocator, flatpak: bool, aur: bool, standard: bool) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);

        try argv.append(alloc, "upgrade");
        try argv.append(alloc, "all");
        if (!flatpak) try argv.append(alloc, "--no-flatpak");
        if (!aur) try argv.append(alloc, "--no-aur");
        if (!standard) try argv.append(alloc, "--no-repo");
        return argv.toOwnedSlice(alloc);
    }

    pub fn sync_db(alloc: std.mem.Allocator) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);
        try argv.append(alloc, "sync");
        try argv.append(alloc, "--force");
        return argv.toOwnedSlice(alloc);
    }

    pub fn installFlatpak(alloc: std.mem.Allocator, names: []const u8, remote: Scope, remote_name: []const u8) ![]const []const u8 {
        return installFlatpakEx(alloc, names, remote, remote_name, false);
    }

    pub fn installFlatpakEx(alloc: std.mem.Allocator, names: []const u8, remote: Scope, remote_name: []const u8, is_runtime: bool) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);
        try argv.append(alloc, "install");
        try argv.append(alloc, "flatpak");
        if (names.len > 0) try argv.append(alloc, names);
        if (remote == .user) try argv.append(alloc, "--user");
        if (remote_name.len > 0) {
            try argv.append(alloc, "--remote");
            try argv.append(alloc, remote_name);
        }
        if (is_runtime) try argv.append(alloc, "--runtime");
        return argv.toOwnedSlice(alloc);
    }

    pub fn removeFlatpak(alloc: std.mem.Allocator, names: []const u8, config_removal: bool) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);
        try argv.append(alloc, "remove");
        try argv.append(alloc, "flatpak");
        if (names.len > 0) try argv.append(alloc, names);
        if (config_removal) try argv.append(alloc, "--remove-config");
        try argv.append(alloc, "--remove-unused");
        return argv.toOwnedSlice(alloc);
    }

    pub fn remove_remote(alloc: std.mem.Allocator, name: []const u8, remote: Scope) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);
        try argv.append(alloc, "sync");
        try argv.append(alloc, "flatpak");
        try argv.append(alloc, "remote");
        try argv.append(alloc, "remove");
        if (name.len > 0) try argv.append(alloc, name);
        try argv.append(alloc, "--system");
        try argv.append(alloc, if (remote == .system) "true" else "false");
        return argv.toOwnedSlice(alloc);
    }

    pub fn add_remote(alloc: std.mem.Allocator, name: []const u8, url: []const u8, scope: [:0]const u8) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);
        try argv.append(alloc, "sync");
        try argv.append(alloc, "flatpak");
        try argv.append(alloc, "remote");
        try argv.append(alloc, "add");
        if (name.len > 0) try argv.append(alloc, name);
        try argv.append(alloc, "--remote-url");
        try argv.append(alloc, url);
        if (!std.mem.eql(u8, scope, "system")) try argv.append(alloc, "--system");
        if (!std.mem.eql(u8, scope, "system")) try argv.append(alloc, "false");
        return argv.toOwnedSlice(alloc);
    }

    pub fn install_local_flatpak_ref(alloc: std.mem.Allocator, path: []const u8, user: bool) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);
        try argv.append(alloc, "install");
        try argv.append(alloc, "flatpak");
        if (path.len > 0) try argv.append(alloc, path);
        try argv.append(alloc, "--ref-file");
        if (user) try argv.append(alloc, "--user");
        return argv.toOwnedSlice(alloc);
    }

    pub fn install_local_flatpak_bundle(alloc: std.mem.Allocator, path: []const u8, user: bool) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);
        try argv.append(alloc, "install");
        try argv.append(alloc, "flatpak");
        if (path.len > 0) try argv.append(alloc, path);
        try argv.append(alloc, "--bundle");
        if (user) try argv.append(alloc, "--user");
        return argv.toOwnedSlice(alloc);
    }

    pub fn fix_permissions(alloc: std.mem.Allocator) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);
        try argv.append(alloc, "utility");
        try argv.append(alloc, "--fix-permissions");
        return argv.toOwnedSlice(alloc);
    }

    pub fn purify(alloc: std.mem.Allocator) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);
        try argv.append(alloc, "purify");
        try argv.append(alloc, "standard");
        try argv.append(alloc, "--orphans");
        return argv.toOwnedSlice(alloc);
    }

    pub fn clean_cache(alloc: std.mem.Allocator, keep_str: []const u8) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);
        try argv.append(alloc, "purify");
        try argv.append(alloc, "standard");
        try argv.append(alloc, "--cache");
        try argv.append(alloc, keep_str);
        try argv.append(alloc, "--aur-cache");
        return argv.toOwnedSlice(alloc);
    }

    pub fn install_aur(alloc: std.mem.Allocator, names: []const []const u8) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);
        try argv.append(alloc, "install");
        try argv.append(alloc, "aur");
        for (names) |n| try argv.append(alloc, n);
        return argv.toOwnedSlice(alloc);
    }

    pub fn install_appimage(
        alloc: std.mem.Allocator,
        path: []const u8,
    ) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);
        try argv.append(alloc, "install");
        try argv.append(alloc, "appimage");
        if (path.len > 0) try argv.append(alloc, path);
        return argv.toOwnedSlice(alloc);
    }

    pub fn remove_appimage(alloc: std.mem.Allocator, name: []const u8, remove_config: bool) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);
        try argv.append(alloc, "remove");
        try argv.append(alloc, "appimage");
        if (name.len > 0) try argv.append(alloc, name);
        if (remove_config) try argv.append(alloc, "--remove-config");
        return argv.toOwnedSlice(alloc);
    }

    pub fn upgrade_appimages(alloc: std.mem.Allocator) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);
        try argv.append(alloc, "upgrade");
        try argv.append(alloc, "appimage");
        return argv.toOwnedSlice(alloc);
    }

    pub fn sync_appimage(alloc: std.mem.Allocator, name: ?[]const u8) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);
        try argv.append(alloc, "sync");
        try argv.append(alloc, "appimage");
        if (name) |n| if (n.len > 0) try argv.append(alloc, n);
        return argv.toOwnedSlice(alloc);
    }

    pub fn configure_appimage_environment(alloc: std.mem.Allocator, name: []const u8, json: []const u8) ![]const []const u8 {
        return alloc.dupe([]const u8, &.{ "config", "appimage", name, "--replace-env", json });
    }

    pub fn configure_appimage(
        alloc: std.mem.Allocator,
        name: []const u8,
        url: []const u8,
        update_type: UpdateType,
        prerelease: bool,
    ) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);
        try argv.append(alloc, "sync");
        try argv.append(alloc, "appimage");
        try argv.append(alloc, name);
        try argv.append(alloc, url);
        try argv.append(alloc, update_type.toCliString());
        if (prerelease) try argv.append(alloc, "--prerelease");
        return argv.toOwnedSlice(alloc);
    }
};

test "operation questions own their data after input is released" {
    const allocator = std.testing.allocator;
    const fixtures = [_][]const u8{
        \\{"$kind":"q.yesno","QuestionId":"1","QuestionKind":"PackageConflict","QuestionText":"Continue?","Arguments":["editor"]}
        ,
        \\{"$kind":"q.transaction","QuestionId":"2","Action":"install","Packages":[{"Name":"editor","Repository":"extra","Source":"standard","Role":"requested"}],"Migrations":[{"path":"old","destination":"new","origin":"test"}]}
        ,
        \\{"$kind":"q.provider","QuestionId":"3","DependencyName":"java-runtime","Options":[{"Index":0,"Name":"jdk","IsInstalled":true}]}
        ,
        \\{"$kind":"q.optdeps","QuestionId":"4","QuestionText":"Optional dependencies","Options":[{"Index":1,"Name":"plugin","IsSelected":true}]}
        ,
        \\{"$kind":"q.pkgbuilddiff","QuestionId":"5","PackageName":"editor","OldPkgbuild":"old","NewPkgbuild":"new","Warnings":[{"Message":"Review this"}],"SourceFiles":{"editor.install":"post_install() {}"}}
        ,
    };
    for (fixtures, 1..) |fixture, id| {
        const input = try allocator.dupe(u8, fixture);
        var message = decodeJson(allocator, input) catch |err| {
            allocator.free(input);
            return err;
        };
        allocator.free(input);
        defer message.deinit();
        var buffer: [20]u8 = undefined;
        const expected = try std.fmt.bufPrint(&buffer, "{d}", .{id});
        try std.testing.expectEqualStrings(expected, questionId(message.value.question));
        switch (message.value.question) {
            .yes_no => |q| try std.testing.expectEqualStrings("editor", q.arguments[0]),
            .transaction => |q| {
                try std.testing.expectEqualStrings("extra", q.packages[0].repository.?);
                try std.testing.expectEqualStrings("new", q.migrations[0].destination);
            },
            .select_one => |q| try std.testing.expect(q.options[0].is_installed),
            .select_many => |q| try std.testing.expect(q.options[0].is_selected),
            .pkgbuild => |q| {
                try std.testing.expectEqualStrings("Review this", q.warnings[0].Message);
                try std.testing.expectEqualStrings("post_install() {}", q.source_files[0].content);
            },
        }
    }
}

test "operation events preserve outcomes and distinguish warnings from errors" {
    const allocator = std.testing.allocator;
    var cancelled = try decodeJson(allocator, "{\"$kind\":\"alpm.info\",\"EventType\":\"TransactionCancelled\",\"Message\":\"Cancelled\"}");
    defer cancelled.deinit();
    try std.testing.expectEqualStrings("TransactionCancelled", cancelled.value.event.info.event_type);
    var warning = try decodeJson(allocator, "{\"$kind\":\"alpm.error\",\"ErrorMessage\":\"Warning\",\"Recoverable\":true}");
    defer warning.deinit();
    try std.testing.expectEqualStrings("Warning", warning.value.event.info.message);
    var failure = try decodeJson(allocator, "{\"$kind\":\"alpm.error\",\"ErrorMessage\":\"Failed\"}");
    defer failure.deinit();
    try std.testing.expectEqualStrings("Failed", failure.value.event.err.message);
    var progress = try decodeJson(allocator, "{\"$kind\":\"alpm.progress\",\"Percent\":120,\"Stage\":\"download\"}");
    defer progress.deinit();
    try std.testing.expectEqual(@as(i64, 100), progress.value.event.alpm_progress.percent);
    var flatpak = try decodeJson(allocator, "{\"$kind\":\"flatpak.progress\",\"Percentage\":50}");
    defer flatpak.deinit();
    try std.testing.expectEqual(@as(i64, 50), flatpak.value.event.flatpak_progress.percentage);
    var appimage = try decodeJson(allocator, "{\"$kind\":\"appimage.progress\",\"Percentage\":-1}");
    defer appimage.deinit();
    try std.testing.expectEqual(@as(i64, 0), appimage.value.event.appimage_progress.percentage);
    var unknown = try decodeJson(allocator, "{\"$kind\":\"future.event\"}");
    defer unknown.deinit();
    try std.testing.expectEqualStrings("future.event", unknown.value.event.unknown);
    try std.testing.expectError(error.UnsupportedQuestion, decodeJson(allocator, "{\"$kind\":\"q.future\",\"QuestionId\":\"1\"}"));
    try std.testing.expectError(error.InvalidQuestionId, decodeJson(allocator, "{\"$kind\":\"q.yesno\",\"QuestionId\":\"bad\"}"));
    try std.testing.expectError(error.MissingField, decodeJson(allocator, "{\"$kind\":\"q.yesno\"}"));
    try std.testing.expectError(error.UnexpectedEndOfInput, decodeJson(allocator, "{"));
}

test "operation answers match CLI framing and answer fields" {
    const allocator = std.testing.allocator;
    const answers = [_]Answer{ .{ .yes_no = true }, .{ .transaction = false }, .{ .optional_dependencies = &.{ 0, 2 } }, .{ .pkgbuild = true }, .{ .provider = 1 } };
    const kinds = [_][]const u8{ "a.yesno", "a.transaction", "a.optdeps", "a.pkgbuilddiff", "a.provider" };
    const fields = [_][]const u8{ "Accept", "Accept", "SelectedIndices", "ProceedWithUpdate", "SelectedIndex" };
    for (answers, kinds, fields) |answer, kind, field| {
        const frame = try encodeAnswer(allocator, "42", answer);
        defer allocator.free(frame);
        try std.testing.expect(std.mem.endsWith(u8, frame, "[/JSON]\n"));
        const payload = JsonPackFrame.extractPayload(frame).?;
        const json = try JsonPackFrame.decodeBase64(allocator, payload);
        defer allocator.free(json);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
        defer parsed.deinit();
        const object = parsed.value.object;
        try std.testing.expectEqualStrings(kind, object.get("$kind").?.string);
        try std.testing.expectEqualStrings("42", object.get("QuestionId").?.string);
        const value = object.get(field).?;
        switch (answer) {
            .yes_no, .transaction, .pkgbuild => |accept| try std.testing.expectEqual(accept, value.bool),
            .provider => |index| try std.testing.expectEqual(@as(i64, @intCast(index)), value.integer),
            .optional_dependencies => |indices| {
                try std.testing.expectEqual(indices.len, value.array.items.len);
                for (indices, value.array.items) |index, item| try std.testing.expectEqual(@as(i64, @intCast(index)), item.integer);
            },
        }
    }
    try std.testing.expectError(error.InvalidQuestionId, encodeAnswer(allocator, "1\"", .{ .yes_no = true }));
}

test "operation payload decoding accepts framed transaction events" {
    const allocator = std.testing.allocator;
    const json = "{\"$kind\":\"alpm.info\",\"EventType\":\"TransactionDone\"}";
    const payload = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(json.len));
    defer allocator.free(payload);
    _ = std.base64.standard.Encoder.encode(payload, json);
    var message = try decodePayload(allocator, payload);
    defer message.deinit();
    try std.testing.expectEqualStrings("TransactionDone", message.value.event.info.event_type);
}

test "operation builders preserve package operands and source options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const native = try ShellyCommands.install(allocator, &.{ "extra/editor", "package with spaces" });
    try std.testing.expectEqualStrings("extra/editor", native[2]);
    try std.testing.expectEqualStrings("package with spaces", native[3]);
    const flatpak = try ShellyCommands.installFlatpakEx(allocator, "org.example.Runtime", .user, "flathub", true);
    try std.testing.expectEqualStrings("--user", flatpak[3]);
    try std.testing.expectEqualStrings("--remote", flatpak[4]);
    try std.testing.expectEqualStrings("--runtime", flatpak[6]);
    const environment = try ShellyCommands.configure_appimage_environment(allocator, "Editor", "{\"KEY\":\" a=b \"}");
    try std.testing.expectEqualStrings("{\"KEY\":\" a=b \"}", environment[4]);
    const source = try ShellyCommands.configure_appimage(allocator, "Editor", "owner/repo", .GitHub, true);
    try std.testing.expectEqualStrings("GitHub", source[4]);
    try std.testing.expectEqualStrings("--prerelease", source[5]);
}

test "operation worker owns inputs and joins on launch failure" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    // No real sudo or package operation can be launched by this test.
    try env.put("PATH", "/nonexistent-shelly-operation-test");
    var name = [_]u8{ 't', 'e', 's', 't' };
    const operation = try Operation.start(.{
        .sudo_bin = "/nonexistent-shelly-sudo",
        .shelly_bin = "/nonexistent-shelly",
        .environ_map = &env,
        .name = &name,
        .backend = "standard",
        .password = "",
    });
    defer operation.deinit();
    @memset(&name, 'x');
    try std.testing.expectEqualStrings("test", operation.request.name);
    operation.thread.?.join();
    operation.thread = null;
    const result = operation.poll() orelse return error.ExpectedCompletion;
    try std.testing.expect(result.failed);
    try std.testing.expect(result.error_detail.len > 0);

    // Cleanup must also join a worker whose result has never been polled.
    const unpolled = try Operation.start(operation.request);
    unpolled.deinit();
}

test "operation progress stream handles fragmented frames and owns display data" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var operation: Operation = .{
        .arena = .init(std.testing.allocator),
        .request = undefined,
    };
    defer operation.arena.deinit();
    const json = "{\"$kind\":\"alpm.progress\",\"PackageName\":\"dependency\",\"ProgressType\":\"PackageDownload\",\"Percent\":37,\"Stage\":\"Downloading\"}";
    var encoded: [std.base64.standard.Encoder.calcSize(json.len)]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&encoded, json);
    var stream: ProgressStream = .{};
    defer stream.deinit();
    stream.feed("noise[JS", &operation, threaded.io());
    stream.feed("ON]", &operation, threaded.io());
    for (encoded) |byte| stream.feed(&.{byte}, &operation, threaded.io());
    stream.feed("[/JSON]", &operation, threaded.io());
    @memset(&encoded, 0);
    const progress = operation.snapshot(threaded.io());
    try std.testing.expectEqualStrings("Downloading: dependency", progress.text());
    try std.testing.expectEqual(@as(?i64, 37), progress.percent);
    try std.testing.expect(!stream.failed);
    stream.feed("[JSON]invalid[/JSON]", &operation, threaded.io());
    try std.testing.expect(stream.failed);
}

test "operation progress retains only bounded recent messages" {
    var progress: Progress = .{};
    for ([_][]const u8{ "one", "two", "three", "four", "five" }) |line| progress.log(line);
    try std.testing.expectEqualStrings("two", progress.messages[0][0..progress.lengths[0]]);
    try std.testing.expectEqualStrings("five", progress.messages[3][0..progress.lengths[3]]);
    var stream: ProgressStream = .{};
    defer stream.deinit();
    stream.feed("[JSON]", null, undefined);
    for (0..ProgressStream.max_frame_bytes + 1) |_| stream.feed("a", null, undefined);
    try std.testing.expect(stream.failed);
}

test "operation rejects removal from unsupported sources before launching" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    var result = elevatedInstall(undefined, std.testing.allocator, .{
        .action = .remove,
        .shelly_bin = "unused",
        .environ_map = &env,
        .name = "test",
        .backend = "appimage",
        .password = "",
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.failed);
    try std.testing.expectEqualStrings("Removal currently supports system, AUR and Flatpak packages only.", result.error_detail);
}

test "operation native upgrade has no package operand or other sources" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    var request: OperationRequest = .{
        .action = .upgrade,
        .shelly_bin = "shelly",
        .environ_map = &env,
        .name = "system packages",
        .backend = "standard",
        .password = "",
    };
    const args = try operationArgv(std.testing.allocator, request);
    defer std.testing.allocator.free(args);
    const expected = [_][]const u8{ "sudo", "-S", "-p", "", "shelly", "upgrade", "standard", "--no-confirm", "--ui-mode" };
    try std.testing.expectEqual(expected.len, args.len);
    for (expected, args) |want, actual| try std.testing.expectEqualStrings(want, actual);
    request.backend = "all";
    try std.testing.expectError(error.UnsupportedUpgradeSource, operationArgv(std.testing.allocator, request));
}

test "operation stream distinguishes transaction done failure and cancellation" {
    for ([_][]const u8{ "TransactionDone", "TransactionFailed", "TransactionCancelled" }) |event_type| {
        const json = try std.fmt.allocPrint(std.testing.allocator, "{{\"$kind\":\"alpm.info\",\"EventType\":\"{s}\"}}", .{event_type});
        defer std.testing.allocator.free(json);
        const encoded = try std.testing.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(json.len));
        defer std.testing.allocator.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, json);
        var stream: ProgressStream = .{};
        defer stream.deinit();
        stream.feed("[JSON]", null, undefined);
        stream.feed(encoded, null, undefined);
        stream.feed("[/JSON]", null, undefined);
        try std.testing.expectEqual(std.mem.eql(u8, event_type, "TransactionDone"), stream.transaction_done);
        try std.testing.expectEqual(std.mem.eql(u8, event_type, "TransactionFailed"), stream.failed);
        try std.testing.expectEqual(std.mem.eql(u8, event_type, "TransactionCancelled"), stream.transaction_cancelled);
    }
}

test "operation AUR installs and upgrades require interactive review" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    var request: OperationRequest = .{
        .action = .install,
        .shelly_bin = "shelly",
        .environ_map = &env,
        .name = "demo",
        .backend = "aur",
        .password = "",
    };
    const install = try operationArgv(std.testing.allocator, request);
    defer std.testing.allocator.free(install);
    const expected_install = [_][]const u8{ "sudo", "-n", "shelly", "install", "aur", "demo", "--ui-mode" };
    try std.testing.expectEqual(expected_install.len, install.len);
    for (expected_install, install) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    request.action = .upgrade;
    const upgrade = try operationArgv(std.testing.allocator, request);
    defer std.testing.allocator.free(upgrade);
    const expected_upgrade = [_][]const u8{ "sudo", "-n", "shelly", "upgrade", "aur", "--ui-mode" };
    try std.testing.expectEqual(expected_upgrade.len, upgrade.len);
    for (expected_upgrade, upgrade) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
}

test "operation questions reject stale duplicate and wrong-kind answers" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    var operation: Operation = .{
        .arena = .init(std.testing.allocator),
        .request = .{ .shelly_bin = "unused", .environ_map = &env, .name = "demo", .backend = "aur", .password = "" },
        // Validation failures must occur before this sentinel descriptor is used.
        .input = .{ .handle = -1, .flags = .{ .nonblocking = false } },
    };
    defer operation.arena.deinit();
    const json =
        \\{"$kind":"q.yesno","QuestionId":"1","QuestionText":"Continue?"}
    ;
    const first = try decodeJson(std.testing.allocator, json);
    try operation.queueQuestion(threaded.io(), first);
    var question = operation.takeQuestion(threaded.io()).?;
    defer question.deinit();
    var duplicate = try decodeJson(std.testing.allocator, json);
    defer duplicate.deinit();
    try std.testing.expectError(error.QuestionAlreadyPending, operation.queueQuestion(threaded.io(), duplicate));
    try std.testing.expectError(error.StaleQuestion, operation.sendAnswer(threaded.io(), "2", .{ .yes_no = true }));
    try std.testing.expectError(error.WrongAnswerKind, operation.sendAnswer(threaded.io(), "1", .{ .pkgbuild = true }));
    operation.expected_answer = null;
    try std.testing.expectError(error.NoPendingQuestion, operation.sendAnswer(threaded.io(), "1", .{ .yes_no = true }));
}

test "operation Flatpak arguments preserve install scope and keep user and upgrade processes unprivileged" {
    const allocator = std.testing.allocator;
    var env: std.process.Environ.Map = .init(allocator);
    defer env.deinit();
    var request: OperationRequest = .{
        .shelly_bin = "shelly",
        .environ_map = &env,
        .name = "org.example.App",
        .backend = "flatpak",
        .password = "",
        .flatpak = .{ .scope = .user, .remote = "chosen remote", .branch = "beta", .kind = .runtime },
    };
    const user = try operationArgv(allocator, request);
    defer allocator.free(user);
    const expected = [_][]const u8{ "shelly", "install", "flatpak", "org.example.App", "--user", "--remote", "chosen remote", "--branch", "beta", "--runtime", "--ui-mode" };
    try std.testing.expectEqual(expected.len, user.len);
    for (expected, user) |want, actual| try std.testing.expectEqualStrings(want, actual);
    request.flatpak.?.scope = .system;
    const system = try operationArgv(allocator, request);
    defer allocator.free(system);
    try std.testing.expectEqualStrings("sudo", system[0]);
    try std.testing.expectEqualStrings("-n", system[1]);
    for (system) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "--user") and !std.mem.eql(u8, arg, "--no-confirm"));
    request.action = .remove;
    request.flatpak.?.scope = .user;
    const remove = try operationArgv(allocator, request);
    defer allocator.free(remove);
    const expected_remove = [_][]const u8{ "shelly", "remove", "flatpak", "org.example.App", "--ui-mode" };
    try std.testing.expectEqual(expected_remove.len, remove.len);
    for (expected_remove, remove) |want, actual| try std.testing.expectEqualStrings(want, actual);
    request.action = .upgrade;
    request.flatpak = null;
    const upgrade = try operationArgv(allocator, request);
    defer allocator.free(upgrade);
    const expected_upgrade = [_][]const u8{ "shelly", "upgrade", "flatpak", "--ui-mode" };
    try std.testing.expectEqual(expected_upgrade.len, upgrade.len);
    for (expected_upgrade, upgrade) |want, actual| try std.testing.expectEqualStrings(want, actual);
    request.action = .install;
    try std.testing.expectError(error.MissingFlatpakTarget, operationArgv(allocator, request));
}

test "operation Flatpak target owns its reference fields" {
    const allocator = std.testing.allocator;
    var remote = [_]u8{ 't', 'e', 's', 't' };
    const copy = try (FlatpakTarget{ .scope = .user, .remote = &remote, .arch = "x86_64", .branch = "beta", .reference = "app/org.example.App/x86_64/beta" }).clone(allocator);
    defer copy.deinit(allocator);
    remote[0] = 'X';
    try std.testing.expectEqualStrings("test", copy.remote);
    try std.testing.expectEqualStrings("app/org.example.App/x86_64/beta", copy.reference);
}
