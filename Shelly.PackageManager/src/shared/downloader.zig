const std = @import("std");

pub const DownloadEventType = enum {
    Start,
    Progress,
    Complete,
    Error,
    Skipped,
};

pub const DownloadError = error{
    HttpError,
    NetworkError,
    FileError,
    InvalidUrl,
    Timeout,
    RetryExceeded,
    SslError,
    NotModified,
    FailedDownload,
};

pub const SkippedReason = enum {
    ExistsAndUpToDate,
    ForceDownloadDisabled,
    NotModified,
};

pub const DownloadProgress = struct {
    bytes_downloaded: u64,
    bytes_total: ?u64,
    percent: u8,
    speed_bytes_per_sec: ?u64,
};

pub const DownloadConfiguration = struct {
    user_agent: ?[:0]const u8 = null,
    timeout_in_seconds: u32 = 30,
    max_retries: u8 = 3,
    retry_delay_secs: u32 = 1,
    verify_ssl: bool = true,
    parallel_downloads: u8 = 10,

    pub fn default() DownloadConfiguration {
        return .{ .user_agent = "ShellyPackageManager/2.0" };
    }
};

pub const DownloadEvent = struct {
    event_type: DownloadEventType,
    progress: ?DownloadProgress = null,
    download_error: ?DownloadError = null,
    destination_path: ?[]const u8 = null,
};

pub const DownloadEventCallback = *const fn (ctx: ?*anyopaque, event: DownloadEvent) void;

pub const DownloadResult = union(enum) {
    succes: struct { destination_path: []const u8 },
    failure: DownloadError,
    skipped: struct { destination_path: []const u8, reason: SkippedReason },
};

/// Size of the buffer used to copy body bytes from the socket to disk.
const copy_buffer_size = 64 * 1024;

pub const CoreDownloader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    configuration: DownloadConfiguration,
    http_client: std.http.Client,
    event_callback: ?DownloadEventCallback = null,
    event_context: ?*anyopaque = null,
    /// When true, error-level logging is suppressed for best-effort downloads
    /// (e.g. optional database signatures that may legitimately be absent).
    quiet: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: DownloadConfiguration) CoreDownloader {
        return .{
            .allocator = allocator,
            .io = io,
            .configuration = config,
            .http_client = .{ .allocator = allocator, .io = io },
        };
    }

    pub fn setEventCallback(self: *CoreDownloader, callback: DownloadEventCallback, context: ?*anyopaque) void {
        self.event_callback = callback;
        self.event_context = context;
    }

    pub fn deinit(self: *CoreDownloader) void {
        self.http_client.deinit();
    }

    pub fn downloadToFile(
        self: *CoreDownloader,
        url: []const u8,
        destination_path: []const u8,
        force: bool,
    ) DownloadResult {
        var attempt: u8 = 0;
        while (true) : (attempt += 1) {
            if (attempt > 0) {
                self.io.sleep(
                    std.Io.Duration.fromSeconds(@intCast(self.configuration.retry_delay_secs)),
                    .awake,
                ) catch {};
            }

            if (self.performDownload(url, destination_path, force)) {
                return .{ .succes = .{ .destination_path = destination_path } };
            } else |err| {
                if (err == DownloadError.NotModified) {
                    self.emitEvent(.{ .event_type = .Skipped, .destination_path = destination_path });
                    return .{ .skipped = .{ .destination_path = destination_path, .reason = .NotModified } };
                }
                const can_retry = isRetryable(err) and attempt < self.configuration.max_retries;
                if (!can_retry) {
                    const final_err = if (isRetryable(err)) DownloadError.RetryExceeded else err;
                    self.emitEvent(.{
                        .event_type = .Error,
                        .download_error = final_err,
                        .destination_path = destination_path,
                    });
                    return .{ .failure = final_err };
                }
            }
        }
    }

    fn performDownload(self: *CoreDownloader, url: []const u8, destination_path: []const u8, force: bool) DownloadError!void {
        const uri = std.Uri.parse(url) catch return DownloadError.InvalidUrl;

        var ims_buf: [64]u8 = undefined;
        var ims_header: [1]std.http.Header = undefined;
        var extra_headers: []const std.http.Header = &.{};
        if (!force) {
            if (std.Io.Dir.cwd().statFile(self.io, destination_path, .{})) |st| {
                if (formatHttpDate(&ims_buf, st.mtime.nanoseconds)) |http_date| {
                    ims_header[0] = .{ .name = "if-modified-since", .value = http_date };
                    extra_headers = ims_header[0..1];
                }
            } else |_| {}
        }

        const user_agent: std.http.Client.Request.Headers.Value = if (self.configuration.user_agent) |agent|
            .{ .override = agent }
        else
            .default;
        var req = self.http_client.request(.GET, uri, .{
            .headers = .{ .user_agent = user_agent, .accept_encoding = .{ .override = "identity" } },
            .extra_headers = extra_headers,
            .redirect_behavior = .init(10),
        }) catch |err| {
            self.logErr("HTTP request setup failed for {s}: {}", .{ url, err });
            return mapRequestError(err);
        };
        defer req.deinit();

        req.accept_encoding[@intFromEnum(std.http.ContentEncoding.gzip)] = false;
        req.accept_encoding[@intFromEnum(std.http.ContentEncoding.deflate)] = false;

        req.sendBodiless() catch |err| {
            self.logErr("Failed to send request for {s}: {}", .{ url, err });
            return DownloadError.NetworkError;
        };

        var redirect_buffer: [8 * 1024]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch |err| {
            self.logErr("Failed to receive response head for {s}: {}", .{ url, err });
            return mapReceiveHeadError(err);
        };

        const status = response.head.status;
        if (status == .not_modified) return DownloadError.NotModified;
        switch (status.class()) {
            .success => {},
            .server_error => {
                self.logErr("Server error {d} for {s}", .{ @intFromEnum(status), url });
                return DownloadError.NetworkError;
            },
            else => {
                self.logErr("HTTP status {d} for {s}", .{ @intFromEnum(status), url });
                return DownloadError.HttpError;
            },
        }

        const total: ?u64 = response.head.content_length;

        self.emitEvent(.{
            .event_type = .Start,
            .destination_path = destination_path,
            .progress = .{
                .bytes_downloaded = 0,
                .bytes_total = total,
                .percent = 0,
                .speed_bytes_per_sec = null,
            },
        });

        var file = std.Io.Dir.cwd().createFile(self.io, destination_path, .{}) catch |err| {
            self.logErr("Failed to create file {s}: {}", .{ destination_path, err });
            return DownloadError.FileError;
        };
        defer file.close(self.io);

        const copy_buffer = self.allocator.alloc(u8, copy_buffer_size) catch return DownloadError.FileError;
        defer self.allocator.free(copy_buffer);

        var transfer_buffer: [4 * 1024]u8 = undefined;
        const body_reader = response.reader(&transfer_buffer);

        const start_ns = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
        var downloaded: u64 = 0;
        var last_percent: i16 = -1;
        var last_reported: u64 = 0;

        while (true) {
            const n = body_reader.readSliceShort(copy_buffer) catch {
                self.logErr("Read failed while downloading {s}: {?}", .{ url, response.bodyErr() });
                return DownloadError.NetworkError;
            };
            if (n == 0) break;

            file.writeStreamingAll(self.io, copy_buffer[0..n]) catch |err| {
                self.logErr("Failed to write to {s}: {}", .{ destination_path, err });
                return DownloadError.FileError;
            };

            downloaded += n;

            if (self.shouldEmitProgress(downloaded, total, &last_percent, &last_reported)) {
                self.emitEvent(.{
                    .event_type = .Progress,
                    .destination_path = destination_path,
                    .progress = makeProgress(downloaded, total, self.speedBytesPerSec(downloaded, start_ns)),
                });
            }
        }

        self.emitEvent(.{
            .event_type = .Complete,
            .destination_path = destination_path,
            .progress = makeProgress(downloaded, total orelse downloaded, self.speedBytesPerSec(downloaded, start_ns)),
        });
    }

    /// Decides whether a `Progress` event should be emitted, throttling to
    /// avoid flooding the callback: on each whole-percent change when the total
    /// size is known, or every 256 KiB when it is not.
    fn shouldEmitProgress(
        self: *const CoreDownloader,
        downloaded: u64,
        total: ?u64,
        last_percent: *i16,
        last_reported: *u64,
    ) bool {
        _ = self;
        if (total) |t| {
            const percent: i16 = if (t == 0) 100 else @intCast(@min(@as(u64, 100), downloaded * 100 / t));
            if (percent != last_percent.*) {
                last_percent.* = percent;
                return true;
            }
            return false;
        }
        if (downloaded - last_reported.* >= 256 * 1024) {
            last_reported.* = downloaded;
            return true;
        }
        return false;
    }

    fn speedBytesPerSec(self: *const CoreDownloader, downloaded: u64, start_ns: i96) ?u64 {
        const now_ns = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
        const elapsed_ns = now_ns - start_ns;
        if (elapsed_ns <= 0) return null;
        const elapsed: u128 = @intCast(elapsed_ns);
        const bps = @as(u128, downloaded) * std.time.ns_per_s / elapsed;
        return std.math.cast(u64, bps) orelse std.math.maxInt(u64);
    }

    fn emitEvent(self: *const CoreDownloader, event: DownloadEvent) void {
        if (self.event_callback) |callback| callback(self.event_context, event);
    }

    /// Logs at error level unless `quiet` is set, used so best-effort downloads
    /// do not surface expected failures (e.g. a missing optional signature).
    fn logErr(self: *const CoreDownloader, comptime fmt: []const u8, args: anytype) void {
        if (!self.quiet) std.log.err(fmt, args);
    }
};

fn makeProgress(downloaded: u64, total: ?u64, speed: ?u64) DownloadProgress {
    const percent: u8 = if (total) |t|
        (if (t == 0) 100 else @intCast(@min(@as(u64, 100), downloaded * 100 / t)))
    else
        0;
    return .{
        .bytes_downloaded = downloaded,
        .bytes_total = total,
        .percent = percent,
        .speed_bytes_per_sec = speed,
    };
}

fn formatHttpDate(buf: []u8, mtime_ns: i128) ?[]const u8 {
    if (mtime_ns < 0) return null;
    const total_secs: u64 = @intCast(@divFloor(mtime_ns, std.time.ns_per_s));

    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = total_secs };
    const epoch_day = epoch_secs.getEpochDay();
    const day_secs = epoch_secs.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const weekdays = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
    const months = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };

    return std.fmt.bufPrint(buf, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        weekdays[@intCast(epoch_day.day % 7)],
        @as(u32, month_day.day_index) + 1,
        months[month_day.month.numeric() - 1],
        year_day.year,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch null;
}

fn isRetryable(err: DownloadError) bool {
    return switch (err) {
        error.NetworkError, error.Timeout => true,
        else => false,
    };
}

fn mapRequestError(err: std.http.Client.RequestError) DownloadError {
    return switch (err) {
        error.UnsupportedUriScheme, error.UriMissingHost => DownloadError.InvalidUrl,
        error.TlsInitializationFailed, error.CertificateBundleLoadFailure => DownloadError.SslError,
        else => DownloadError.NetworkError,
    };
}

fn mapReceiveHeadError(err: std.http.Client.Request.ReceiveHeadError) DownloadError {
    return switch (err) {
        error.TooManyHttpRedirects,
        error.RedirectRequiresResend,
        error.HttpRedirectLocationMissing,
        error.HttpRedirectLocationOversize,
        error.HttpRedirectLocationInvalid,
        error.HttpHeadersInvalid,
        error.HttpHeadersOversize,
        error.HttpContentEncodingUnsupported,
        error.HttpChunkInvalid,
        error.HttpChunkTruncated,
        => DownloadError.HttpError,
        error.UnsupportedUriScheme => DownloadError.InvalidUrl,
        error.TlsInitializationFailed, error.CertificateBundleLoadFailure => DownloadError.SslError,
        else => DownloadError.NetworkError,
    };
}

// Unit tests for downloader.zig
test "DownloadConfiguration.default() returns correct default values" {
    const config = DownloadConfiguration.default();
    try std.testing.expectEqualStrings("ShellyPackageManager/2.0", config.user_agent.?);
    try std.testing.expectEqual(@as(u32, 30), config.timeout_in_seconds);
    try std.testing.expectEqual(@as(u8, 3), config.max_retries);
    try std.testing.expectEqual(@as(u32, 1), config.retry_delay_secs);
    try std.testing.expectEqual(true, config.verify_ssl);
    try std.testing.expectEqual(@as(u8, 10), config.parallel_downloads);
}

test "makeProgress calculates progress correctly with total size" {
    const progress = makeProgress(50, 100, null);
    try std.testing.expectEqual(@as(u64, 50), progress.bytes_downloaded);
    try std.testing.expectEqual(@as(?u64, 100), progress.bytes_total);
    try std.testing.expectEqual(@as(u8, 50), progress.percent);
    try std.testing.expectEqual(@as(?u64, null), progress.speed_bytes_per_sec);

    const progress_full = makeProgress(100, 100, null);
    try std.testing.expectEqual(@as(u8, 100), progress_full.percent);

    const progress_zero_total = makeProgress(50, 0, null);
    try std.testing.expectEqual(@as(u8, 100), progress_zero_total.percent);
}

test "makeProgress calculates progress correctly without total size" {
    const progress = makeProgress(50, null, null);
    try std.testing.expectEqual(@as(u64, 50), progress.bytes_downloaded);
    try std.testing.expectEqual(@as(?u64, null), progress.bytes_total);
    try std.testing.expectEqual(@as(u8, 0), progress.percent);
    try std.testing.expectEqual(@as(?u64, null), progress.speed_bytes_per_sec);
}

test "isRetryable returns true for NetworkError and Timeout" {
    try std.testing.expect(isRetryable(DownloadError.NetworkError));
    try std.testing.expect(isRetryable(DownloadError.Timeout));
}

test "isRetryable returns false for other errors" {
    try std.testing.expect(!isRetryable(DownloadError.HttpError));
    try std.testing.expect(!isRetryable(DownloadError.FileError));
    try std.testing.expect(!isRetryable(DownloadError.InvalidUrl));
    try std.testing.expect(!isRetryable(DownloadError.RetryExceeded));
    try std.testing.expect(!isRetryable(DownloadError.SslError));
}

test "mapRequestError maps UnsupportedUriScheme and UriMissingHost to InvalidUrl" {
    try std.testing.expectEqual(DownloadError.InvalidUrl, mapRequestError(error.UnsupportedUriScheme));
    try std.testing.expectEqual(DownloadError.InvalidUrl, mapRequestError(error.UriMissingHost));
}

test "mapRequestError maps TLS errors to SslError" {
    try std.testing.expectEqual(DownloadError.SslError, mapRequestError(error.TlsInitializationFailed));
    try std.testing.expectEqual(DownloadError.SslError, mapRequestError(error.CertificateBundleLoadFailure));
}

test "mapRequestError maps other errors to NetworkError" {
    try std.testing.expectEqual(DownloadError.NetworkError, mapRequestError(error.ConnectionRefused));
}

test "mapReceiveHeadError maps redirect and header errors to HttpError" {
    try std.testing.expectEqual(DownloadError.HttpError, mapReceiveHeadError(error.TooManyHttpRedirects));
    try std.testing.expectEqual(DownloadError.HttpError, mapReceiveHeadError(error.RedirectRequiresResend));
    try std.testing.expectEqual(DownloadError.HttpError, mapReceiveHeadError(error.HttpRedirectLocationMissing));
    try std.testing.expectEqual(DownloadError.HttpError, mapReceiveHeadError(error.HttpHeadersInvalid));
    try std.testing.expectEqual(DownloadError.HttpError, mapReceiveHeadError(error.HttpChunkInvalid));
}

test "mapReceiveHeadError maps UnsupportedUriScheme to InvalidUrl" {
    try std.testing.expectEqual(DownloadError.InvalidUrl, mapReceiveHeadError(error.UnsupportedUriScheme));
}

test "mapReceiveHeadError maps TLS errors to SslError" {
    try std.testing.expectEqual(DownloadError.SslError, mapReceiveHeadError(error.TlsInitializationFailed));
    try std.testing.expectEqual(DownloadError.SslError, mapReceiveHeadError(error.CertificateBundleLoadFailure));
}

test "mapReceiveHeadError maps other errors to NetworkError" {
    try std.testing.expectEqual(DownloadError.NetworkError, mapReceiveHeadError(error.ConnectionRefused));
}

test "shouldEmitProgress emits on percentage change when total is known" {
    var downloader: CoreDownloader = undefined;
    var last_percent: i16 = -1;
    var last_reported: u64 = 0;

    // First call should emit progress (0%)
    try std.testing.expect(downloader.shouldEmitProgress(0, 100, &last_percent, &last_reported));
    try std.testing.expectEqual(@as(i16, 0), last_percent);

    // Second call at 1 byte (1%) should emit (percent changes from 0 to 1)
    try std.testing.expect(downloader.shouldEmitProgress(1, 100, &last_percent, &last_reported));
    try std.testing.expectEqual(@as(i16, 1), last_percent);

    // Call at 50 bytes (50%) should emit (percent changes from 1 to 50)
    try std.testing.expect(downloader.shouldEmitProgress(50, 100, &last_percent, &last_reported));
    try std.testing.expectEqual(@as(i16, 50), last_percent);

    // Call at 100 bytes (100%) should emit (percent changes from 50 to 100)
    try std.testing.expect(downloader.shouldEmitProgress(100, 100, &last_percent, &last_reported));
    try std.testing.expectEqual(@as(i16, 100), last_percent);

    // Call at 100 bytes again should not emit (percent is still 100%)
    try std.testing.expect(!downloader.shouldEmitProgress(100, 100, &last_percent, &last_reported));
}

test "shouldEmitProgress emits every 256KiB when total is unknown" {
    var downloader: CoreDownloader = undefined;
    var last_percent: i16 = -1;
    var last_reported: u64 = 0;

    // Call at 100KiB should not emit (less than 256KiB)
    try std.testing.expect(!downloader.shouldEmitProgress(100 * 1024, null, &last_percent, &last_reported));
    try std.testing.expectEqual(@as(u64, 0), last_reported);

    // Call at 256KiB should emit
    try std.testing.expect(downloader.shouldEmitProgress(256 * 1024, null, &last_percent, &last_reported));
    try std.testing.expectEqual(@as(u64, 256 * 1024), last_reported);

    // Call at 300KiB should not emit (less than 256KiB from last reported)
    try std.testing.expect(!downloader.shouldEmitProgress(300 * 1024, null, &last_percent, &last_reported));

    // Call at 512KiB should emit (256KiB from last reported)
    try std.testing.expect(downloader.shouldEmitProgress(512 * 1024, null, &last_percent, &last_reported));
    try std.testing.expectEqual(@as(u64, 512 * 1024), last_reported);
}

test "DownloadResult union variants are correctly defined" {
    const success_result = DownloadResult{
        .succes = .{ .destination_path = "/tmp/test.zip" },
    };
    switch (success_result) {
        .succes => |s| try std.testing.expectEqualStrings("/tmp/test.zip", s.destination_path),
        else => try std.testing.expect(false),
    }

    const failure_result = DownloadResult{
        .failure = DownloadError.HttpError,
    };
    switch (failure_result) {
        .failure => |f| try std.testing.expectEqual(DownloadError.HttpError, f),
        else => try std.testing.expect(false),
    }

    const skipped_result = DownloadResult{
        .skipped = .{ .destination_path = "/tmp/test.zip", .reason = .ExistsAndUpToDate },
    };
    switch (skipped_result) {
        .skipped => |s| {
            try std.testing.expectEqualStrings("/tmp/test.zip", s.destination_path);
            try std.testing.expectEqual(SkippedReason.ExistsAndUpToDate, s.reason);
        },
        else => try std.testing.expect(false),
    }
}
