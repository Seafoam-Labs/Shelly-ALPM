const std = @import("std");
const Zigalpm = @import("Zigalpm");

const log_path = "/var/log/shelly.log";
const rotated_log_path = "/var/log/shelly.log.1";
const max_log_size = 5 * 1024 * 1024;

pub const SessionLog = struct {
    io: std.Io,
    file: std.Io.File,
    offset: u64,
    mutex: std.Io.Mutex = .init,

    pub fn tryOpen(io: std.Io) ?SessionLog {
        return tryOpenAt(io, log_path, rotated_log_path);
    }

    pub fn tryOpenAt(io: std.Io, path: []const u8, rotated_path: []const u8) ?SessionLog {
        rotateIfNeeded(io, path, rotated_path);
        const file = std.Io.Dir.createFileAbsolute(io, path, .{
            .read = true,
            .truncate = false,
        }) catch return null;
        const stat = file.stat(io) catch {
            file.close(io);
            return null;
        };
        return .{ .io = io, .file = file, .offset = stat.size };
    }

    pub fn close(self: *SessionLog) void {
        self.file.close(self.io);
        self.* = undefined;
    }

    pub fn writeSessionHeader(
        self: *SessionLog,
        allocator: std.mem.Allocator,
        arguments: []const []const u8,
    ) void {
        var buffer = std.Io.Writer.Allocating.init(allocator);
        defer buffer.deinit();
        const timestamp = std.Io.Clock.real.now(self.io).toSeconds();
        buffer.writer.writeAll("=====================================\n") catch return;
        buffer.writer.print("[{d}] SESSION START\n", .{timestamp}) catch return;
        buffer.writer.print("[{d}] Command: shelly", .{timestamp}) catch return;
        for (arguments) |argument| buffer.writer.print(" {s}", .{argument}) catch return;
        buffer.writer.writeAll("\n=====================================\n") catch return;
        self.append(buffer.writer.buffered());
    }

    pub fn writeSessionFooter(
        self: *SessionLog,
        allocator: std.mem.Allocator,
        exit_code: u8,
    ) void {
        var buffer = std.Io.Writer.Allocating.init(allocator);
        defer buffer.deinit();
        const timestamp = std.Io.Clock.real.now(self.io).toSeconds();
        buffer.writer.print(
            "[{d}] SESSION END — exit code: {d}\n",
            .{ timestamp, exit_code },
        ) catch return;
        self.append(buffer.writer.buffered());
    }

    fn append(self: *SessionLog, bytes: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.file.writePositionalAll(self.io, bytes, self.offset) catch return;
        self.offset += bytes.len;
    }
};

pub const LogLevel = enum {
    info,
    warning,
    exception,
};

pub const Source = enum {
    standard,
    aur,
    flatpak,
    appimage,
    local,
    download,
};

pub const TransactionLog = struct {
    session: *SessionLog,
    allocator: std.mem.Allocator,

    pub fn init(
        session: *SessionLog,
        allocator: std.mem.Allocator,
    ) TransactionLog {
        return .{ .session = session, .allocator = allocator };
    }

    pub fn attach(
        self: *TransactionLog,
        operation_context: *Zigalpm.OperationContext,
    ) !u64 {
        return operation_context.subscribe(.{
            .function = handleEvent,
            .data = self,
        });
    }

    pub fn writeEntry(self: *TransactionLog, allocator: std.mem.Allocator, level: LogLevel, source: Source, message: []const u8) void {
        const timestamp = std.Io.Clock.real.now(self.session.io).toSeconds();
        var buffer = std.Io.Writer.Allocating.init(allocator);
        defer buffer.deinit();
        const level_str: []const u8 = switch (level) {
            .info => "INFO",
            .warning => "WARNING",
            .exception => "EXCEPTION",
        };
        const source_str: []const u8 = switch (source) {
            .standard => "standard",
            .aur => "aur",
            .flatpak => "flatpak",
            .appimage => "appimage",
            .local => "local",
            .download => "download",
        };
        buffer.writer.print("[{d}] Level: {s}  Source: {s} Message: {s}\n", .{ timestamp, level_str, source_str, message }) catch return;
        self.session.append(buffer.writer.buffered());
    }

    fn handleEvent(data: ?*anyopaque, event: Zigalpm.OperationEvent) void {
        const self: *TransactionLog = @ptrCast(@alignCast(data.?));
        self.writeEvent(event);
    }

    fn writeEvent(self: *TransactionLog, event: Zigalpm.OperationEvent) void {
        const envelope = switch (event) {
            inline else => |payload| payload.envelope,
        };
        if (!logsTransactionKind(envelope.kind)) return;

        const source = sourceForBackend(envelope.backend);
        switch (event) {
            .started => {
                if (envelope.parent_id == null)
                    self.writeEntry(self.allocator, .info, source, "transaction started");
            },
            .progress => {},
            .status => |status| switch (status.level) {
                .debug => {},
                .information, .success => self.writeEntry(self.allocator, .info, source, status.message),
                .warning => self.writeEntry(self.allocator, .warning, source, status.message),
            },
            .failure => |failure| self.writeEntry(self.allocator, .exception, source, failure.message),
            .completed => |completed| {
                if (envelope.parent_id != null) return;
                const message: []const u8 = switch (completed.status) {
                    .success => "transaction completed",
                    .failed => "transaction failed",
                    .cancelled => "transaction cancelled",
                };
                self.writeEntry(
                    self.allocator,
                    if (completed.status == .success) .info else .warning,
                    source,
                    message,
                );
            },
        }
    }
};

fn sourceForBackend(backend: Zigalpm.operation.Backend) Source {
    return switch (backend) {
        .alpm => .standard,
        .aur => .aur,
        .flatpak => .flatpak,
        .appimage => .appimage,
        .local_package => .local,
        .download => .download,
    };
}

fn logsTransactionKind(kind: Zigalpm.operation.OperationKind) bool {
    return switch (kind) {
        .install, .remove, .update, .sync, .build, .cleanup, .configure => true,
        .search, .download, .inspect, .launch => false,
    };
}

fn rotateIfNeeded(io: std.Io, path: []const u8, rotated_path: []const u8) void {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return;
    const stat = file.stat(io) catch {
        file.close(io);
        return;
    };
    file.close(io);
    if (stat.size < max_log_size) return;
    std.Io.Dir.deleteFileAbsolute(io, rotated_path) catch {};
    std.Io.Dir.renameAbsolute(path, rotated_path, io) catch {};
}

test "writes a complete session to an injected log path" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_length = try temporary.dir.realPath(std.testing.io, &absolute_buffer);
    const allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(
        allocator,
        "{s}/shelly.log",
        .{absolute_buffer[0..absolute_length]},
    );
    defer allocator.free(path);
    const rotated_path = try std.fmt.allocPrint(allocator, "{s}.1", .{path});
    defer allocator.free(rotated_path);

    var session = SessionLog.tryOpenAt(std.testing.io, path, rotated_path) orelse
        return error.CouldNotOpenTestLog;
    session.writeSessionHeader(allocator, &.{ "query", "firefox" });
    session.writeSessionFooter(allocator, 7);
    session.close();

    const contents = try temporary.dir.readFileAlloc(
        std.testing.io,
        "shelly.log",
        allocator,
        .limited(4096),
    );
    defer allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "Command: shelly query firefox") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "SESSION END — exit code: 7") != null);
}

test "transaction log writes every level and source" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_length = try temporary.dir.realPath(std.testing.io, &absolute_buffer);
    const allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(
        allocator,
        "{s}/transaction.log",
        .{absolute_buffer[0..absolute_length]},
    );
    defer allocator.free(path);

    const cases = [_]struct {
        level: LogLevel,
        source: Source,
        level_text: []const u8,
        source_text: []const u8,
        message: []const u8,
    }{
        .{ .level = .info, .source = .standard, .level_text = "INFO", .source_text = "standard", .message = "standard message" },
        .{ .level = .warning, .source = .aur, .level_text = "WARNING", .source_text = "aur", .message = "aur message" },
        .{ .level = .exception, .source = .flatpak, .level_text = "EXCEPTION", .source_text = "flatpak", .message = "flatpak message" },
        .{ .level = .info, .source = .appimage, .level_text = "INFO", .source_text = "appimage", .message = "appimage message" },
        .{ .level = .warning, .source = .local, .level_text = "WARNING", .source_text = "local", .message = "local message" },
        .{ .level = .info, .source = .download, .level_text = "INFO", .source_text = "download", .message = "download message" },
    };

    const rotated_path = try std.fmt.allocPrint(allocator, "{s}.1", .{path});
    defer allocator.free(rotated_path);
    var session = SessionLog.tryOpenAt(std.testing.io, path, rotated_path) orelse
        return error.CouldNotOpenTestLog;
    var transaction = TransactionLog.init(&session, allocator);
    for (cases) |case| {
        transaction.writeEntry(allocator, case.level, case.source, case.message);
    }
    session.close();

    const contents = try temporary.dir.readFileAlloc(
        std.testing.io,
        "transaction.log",
        allocator,
        .limited(4096),
    );
    defer allocator.free(contents);

    for (cases) |case| {
        const expected = try std.fmt.allocPrint(
            allocator,
            "Level: {s}  Source: {s} Message: {s}\n",
            .{ case.level_text, case.source_text, case.message },
        );
        defer allocator.free(expected);
        try std.testing.expect(std.mem.indexOf(u8, contents, expected) != null);
    }
    try std.testing.expectEqual(cases.len, std.mem.count(u8, contents, "\n"));
}

test "transaction log appends after existing content" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_length = try temporary.dir.realPath(std.testing.io, &absolute_buffer);
    const allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(
        allocator,
        "{s}/transaction.log",
        .{absolute_buffer[0..absolute_length]},
    );
    defer allocator.free(path);

    const seed = try std.Io.Dir.createFileAbsolute(std.testing.io, path, .{});
    try seed.writeStreamingAll(std.testing.io, "existing entry\n");
    seed.close(std.testing.io);

    const rotated_path = try std.fmt.allocPrint(allocator, "{s}.1", .{path});
    defer allocator.free(rotated_path);
    var session = SessionLog.tryOpenAt(std.testing.io, path, rotated_path) orelse
        return error.CouldNotOpenTestLog;
    var transaction = TransactionLog.init(&session, allocator);
    transaction.writeEntry(allocator, .info, .standard, "new entry");
    session.close();

    const contents = try temporary.dir.readFileAlloc(
        std.testing.io,
        "transaction.log",
        allocator,
        .limited(4096),
    );
    defer allocator.free(contents);
    try std.testing.expect(std.mem.startsWith(u8, contents, "existing entry\n"));
    try std.testing.expect(std.mem.endsWith(u8, contents, "Source: standard Message: new entry\n"));
}

test "transaction log records operation lifecycle without progress noise" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_length = try temporary.dir.realPath(std.testing.io, &absolute_buffer);
    const allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(
        allocator,
        "{s}/shelly.log",
        .{absolute_buffer[0..absolute_length]},
    );
    defer allocator.free(path);
    const rotated_path = try std.fmt.allocPrint(allocator, "{s}.1", .{path});
    defer allocator.free(rotated_path);

    var session = SessionLog.tryOpenAt(std.testing.io, path, rotated_path) orelse
        return error.CouldNotOpenTestLog;
    var transaction = TransactionLog.init(&session, allocator);
    var operation_context = Zigalpm.OperationContext.init(allocator, std.testing.io);
    defer operation_context.deinit();
    _ = try transaction.attach(&operation_context);

    var operation = operation_context.begin(.{ .backend = .alpm, .kind = .install });
    operation.status(.information, "installed example (1.0-1)", "alpm.information", null);
    operation.progress(.{ .percentage = 50, .message = "ignored progress" });
    operation.finish(.success);
    session.close();

    const contents = try temporary.dir.readFileAlloc(
        std.testing.io,
        "shelly.log",
        allocator,
        .limited(4096),
    );
    defer allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "Message: transaction started") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "Message: installed example (1.0-1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "Message: transaction completed") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "ignored progress") == null);
}
