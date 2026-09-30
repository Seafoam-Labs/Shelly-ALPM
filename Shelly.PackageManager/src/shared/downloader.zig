//! PackageManager operation adapter over the shared transport.
const std = @import("std");
const operations = @import("operation_context");
const shared = @import("Shelly_Download");
pub const HttpClient = shared.HttpClient;
pub const AddressFamilyPolicy = shared.AddressFamilyPolicy;
pub const FileDurability = shared.FileDurability;
pub const DownloadEventType = shared.DownloadEventType;
pub const DownloadError = shared.DownloadError;
pub const SkippedReason = shared.SkippedReason;
pub const DownloadProgress = shared.DownloadProgress;
pub const DownloadConfiguration = shared.DownloadConfiguration;
pub const DownloadEvent = shared.DownloadEvent;
pub const DownloadEventCallback = shared.DownloadEventCallback;
pub const DownloadResult = shared.DownloadResult;
pub const failureMessage = shared.failureMessage;

pub const DownloadSession = struct {
    core: shared.DownloadSession,
    pub fn init(allocator: std.mem.Allocator, io: std.Io, timeout: u32, policy: AddressFamilyPolicy) DownloadSession {
        return .{ .core = .init(allocator, io, timeout, policy) };
    }
    pub fn deinit(self: *DownloadSession) void {
        self.core.deinit();
    }
    pub fn downloader(self: *DownloadSession, config: DownloadConfiguration) CoreDownloader {
        return .{ .core = self.core.downloader(config), .allocator = self.core.allocator, .io = self.core.io, .configuration = config };
    }
};
pub const CoreDownloader = struct {
    core: shared.CoreDownloader,
    allocator: std.mem.Allocator,
    io: std.Io,
    configuration: DownloadConfiguration,
    operation_context: ?*operations.OperationContext = null,
    parent_operation: ?*const operations.Operation = null,
    active_operation: ?*operations.Operation = null,
    quiet: bool = false,
    event_callback: ?DownloadEventCallback = null,
    event_context: ?*anyopaque = null,
    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: DownloadConfiguration) CoreDownloader {
        return .{ .core = .init(allocator, io, config), .allocator = allocator, .io = io, .configuration = config };
    }
    pub fn deinit(self: *CoreDownloader) void {
        self.core.deinit();
    }
    pub fn setEventCallback(self: *CoreDownloader, callback: DownloadEventCallback, context: ?*anyopaque) void {
        self.event_callback = callback;
        self.event_context = context;
    }
    pub fn setOperationContext(self: *CoreDownloader, context: ?*operations.OperationContext) void {
        self.operation_context = context;
    }
    pub fn setParentOperation(self: *CoreDownloader, parent: ?*const operations.Operation) void {
        self.parent_operation = parent;
        if (parent) |operation| self.operation_context = operation.context;
    }
    pub fn downloadToFile(
        self: *CoreDownloader,
        url: []const u8,
        destination_path: []const u8,
        force: bool,
    ) DownloadResult {
        var operation_storage: operations.Operation = undefined;
        const has_operation = if (self.quiet) false else if (self.parent_operation) |parent| blk: {
            operation_storage = parent.child(.{
                .backend = .download,
                .kind = .download,
                .subject = destination_path,
            });
            break :blk true;
        } else if (self.operation_context) |context| blk: {
            operation_storage = context.begin(.{
                .backend = .download,
                .kind = .download,
                .subject = destination_path,
            });
            break :blk true;
        } else false;

        const previous_operation = self.active_operation;
        if (has_operation) self.active_operation = &operation_storage;
        defer self.active_operation = previous_operation;

        self.core.configuration = self.configuration;
        self.core.quiet = self.quiet;
        self.core.setEventCallback(forward, self);
        self.core.cancellation = cancelled;
        self.core.cancellation_context = self;
        const result = self.core.downloadToFile(url, destination_path, force);
        if (has_operation) switch (result) {
            .succes, .skipped => operation_storage.finish(.success),
            .failure => |err| operation_storage.finish(if (err == DownloadError.Cancelled) .cancelled else .failed),
        };
        return result;
    }
    fn emitEvent(self: *const CoreDownloader, event: DownloadEvent) !void {
        if (self.quiet and event.event_type == .Error) return;
        if (self.event_callback) |callback| callback(self.event_context, event);
        const operation = self.active_operation orelse
            (if (event.event_type == .Progress) self.parent_operation else null) orelse return;
        switch (event.event_type) {
            .Start => operation.status(.information, "Download started", "download.start", null),
            .Progress => if (event.progress) |progress| operation.progress(.{
                .stage = "download",
                .completed = progress.bytes_downloaded,
                .total = progress.bytes_total,
                .percentage = @floatFromInt(progress.percent),
                .bytes_completed = progress.bytes_downloaded,
                .bytes_total = progress.bytes_total,
                .bytes_per_second = progress.speed_bytes_per_sec,
            }),
            .Complete => operation.status(.success, "Download completed", "download.complete", null),
            .Error => if (event.download_error) |download_error| {
                if (download_error == error.Cancelled) return;
                const message = failureMessage(self.allocator, event) catch {
                    operation.reportError(download_error, "Could not download the requested file. Shelly could not allocate memory for the error details.", "download", null, false);
                    return;
                };
                defer self.allocator.free(message);
                operation.reportError(download_error, message, "download", null, false);
            },
            .Skipped => operation.status(.information, "Download skipped", "download.skipped", null),
        }
    }
    fn isCancelled(self: *const CoreDownloader) bool {
        if (self.active_operation) |operation| return operation.isCancelled();
        if (self.parent_operation) |operation| return operation.isCancelled();
        if (self.operation_context) |context| return context.isCancelled();
        return false;
    }
    fn forward(data: ?*anyopaque, value: DownloadEvent) void {
        const self: *CoreDownloader = @ptrCast(@alignCast(data.?));
        self.emitEvent(value) catch {};
    }
    fn cancelled(data: ?*anyopaque) bool {
        const self: *CoreDownloader = @ptrCast(@alignCast(data.?));
        return self.isCancelled();
    }
};
test "quiet downloader forwards rich progress to its logical parent" {
    const Capture = struct {
        progress: ?operations.ProgressEvent = null,
        statuses: usize = 0,
        failures: usize = 0,

        fn receive(data: ?*anyopaque, event: operations.Event) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            switch (event) {
                .progress => |progress| self.progress = progress,
                .status => self.statuses += 1,
                .failure => self.failures += 1,
                else => {},
            }
        }
    };

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var context = operations.OperationContext.init(std.testing.allocator, threaded.io());
    defer context.deinit();
    var capture: Capture = .{};
    _ = try context.subscribe(.{ .function = Capture.receive, .data = &capture });
    var parent = context.begin(.{ .backend = .download, .kind = .download, .subject = "demo.pkg.tar.zst" });
    defer parent.finish(.success);

    var downloader = CoreDownloader.init(std.testing.allocator, threaded.io(), .{});
    defer downloader.deinit();
    downloader.quiet = true;
    downloader.setParentOperation(&parent);
    try downloader.emitEvent(.{ .event_type = .Start, .destination_path = "demo.pkg.tar.zst" });
    try downloader.emitEvent(.{
        .event_type = .Progress,
        .destination_path = "demo.pkg.tar.zst",
        .progress = .{
            .bytes_downloaded = 512,
            .bytes_total = 1024,
            .percent = 50,
            .speed_bytes_per_sec = 256,
        },
    });
    try downloader.emitEvent(.{ .event_type = .Complete, .destination_path = "demo.pkg.tar.zst" });
    try downloader.emitEvent(.{ .event_type = .Error, .download_error = DownloadError.NetworkError });

    const progress = capture.progress orelse return error.MissingProgress;
    try std.testing.expectEqual(operations.Backend.download, progress.envelope.backend);
    try std.testing.expectEqualStrings("download", progress.update.stage orelse return error.MissingStage);
    try std.testing.expectEqual(@as(u64, 512), progress.update.bytes_completed.?);
    try std.testing.expectEqual(@as(u64, 1024), progress.update.bytes_total.?);
    try std.testing.expectEqual(@as(u64, 256), progress.update.bytes_per_second.?);
    try std.testing.expectEqual(@as(f64, 50), progress.update.percentage.?);
    try std.testing.expectEqual(@as(usize, 0), capture.statuses);
    try std.testing.expectEqual(@as(usize, 0), capture.failures);
}

test "shared cancellation stops downloads before network access" {
    const Capture = struct {
        started: usize = 0,
        failures: usize = 0,
        completed: usize = 0,
        completion: ?operations.CompletionStatus = null,

        fn receive(data: ?*anyopaque, event: operations.Event) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            switch (event) {
                .started => self.started += 1,
                .failure => self.failures += 1,
                .completed => |value| {
                    self.completed += 1;
                    self.completion = value.status;
                },
                else => {},
            }
        }
    };

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var context = operations.OperationContext.init(std.testing.allocator, threaded.io());
    defer context.deinit();
    var capture: Capture = .{};
    _ = try context.subscribe(.{ .function = Capture.receive, .data = &capture });
    context.cancel();

    var downloader = CoreDownloader.init(std.testing.allocator, threaded.io(), .{});
    defer downloader.deinit();
    downloader.setOperationContext(&context);
    const result = downloader.downloadToFile("https://example.invalid/package", "/tmp/shelly-cancelled-download", true);
    switch (result) {
        .failure => |err| try std.testing.expectEqual(DownloadError.Cancelled, err),
        else => return error.ExpectedCancelledDownload,
    }

    try std.testing.expectEqual(@as(usize, 1), capture.started);
    try std.testing.expectEqual(@as(usize, 0), capture.failures);
    try std.testing.expectEqual(@as(usize, 1), capture.completed);
    try std.testing.expectEqual(operations.CompletionStatus.cancelled, capture.completion.?);
}
