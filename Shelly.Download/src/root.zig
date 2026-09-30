//! Shared transport extracted from PackageManager; no backend or UI dependency.
const std = @import("std");
const diagnostics = @import("diagnostics");
pub const HttpClient = @import("ShellyHttp");
const Curl = @import("Curl.zig");
const HttpDate = @import("HttpDate.zig");
pub const Sandbox = @import("Sandbox.zig");

pub const AddressFamilyPolicy = HttpClient.AddressFamilyPolicy;

pub const FileDurability = enum {
    /// Synchronize each completed temporary file before its atomic rename.
    sync_before_rename,
    /// The caller owns the durability barrier for a batch of atomic renames.
    caller_managed,
};

pub const DownloadEventType = enum {
    Start,
    Progress,
    Complete,
    Error,
    Skipped,
};

pub const DownloadError = error{
    HttpError,
    NotFound,
    NetworkError,
    FileError,
    InvalidUrl,
    Timeout,
    ConnectTimeout,
    HeaderTimeout,
    BodyTimeout,
    RetryExceeded,
    SslError,
    CertificateBundleError,
    NotModified,
    FailedDownload,
    Cancelled,
    SizeExceeded,
    InvalidRange,
    HostNotFound,
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

const BodyReadRace = union(enum) {
    read: std.Io.Reader.ShortError!usize,
    timeout: std.Io.Cancelable!void,
    cancelled: std.Io.Cancelable!void,
};

pub const DownloadConfiguration = struct {
    user_agent: ?[:0]const u8 = null,
    /// Bounds DNS, TCP, and TLS request setup.
    timeout_in_seconds: u32 = 30,
    /// Bounds sending the request and receiving the final response headers,
    /// including redirects.
    response_header_timeout_in_seconds: u32 = 30,
    response_body_timeout_in_seconds: u32 = 30,
    /// Defaults to IPv4-first Happy Eyeballs without disabling IPv6 fallback.
    /// `ipv4_only` remains an explicit escape hatch for networks or VPNs that
    /// advertise but blackhole IPv6.
    address_family_policy: AddressFamilyPolicy = .prefer_ipv4,
    max_retries: u8 = 3,
    retry_delay_secs: u32 = 1,
    verify_ssl: bool = true,
    file_durability: FileDurability = .sync_before_rename,
    /// When set, completed downloads are normalized to this exact mode. The
    /// default preserves the downloader's historical umask-dependent behavior
    /// for consumers such as AppImage downloads.
    final_permissions: ?std.Io.File.Permissions = null,
    /// Caller-owned, private partial path. Retained on interruption for resuming.
    resume_path: ?[]const u8 = null,
    maximum_size: ?u64 = null,
    conditional_mtime: ?i128 = null,

    pub fn default() DownloadConfiguration {
        return .{ .user_agent = "ShellyPackageManager/2.0" };
    }
};

fn initHttpClient(
    allocator: std.mem.Allocator,
    io: std.Io,
    connect_timeout_seconds: u32,
    address_family_policy: AddressFamilyPolicy,
) HttpClient {
    return .{
        .allocator = allocator,
        .io = io,
        .connect_timeout = connectTimeout(connect_timeout_seconds),
        .address_family_policy = address_family_policy,
    };
}

/// Owns the HTTP connection pool and certificate bundle shared by all
/// downloaders participating in one logical batch.
pub const DownloadSession = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    http_client: HttpClient,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        connect_timeout_seconds: u32,
        address_family_policy: AddressFamilyPolicy,
    ) DownloadSession {
        return .{
            .allocator = allocator,
            .io = io,
            .http_client = initHttpClient(
                allocator,
                io,
                connect_timeout_seconds,
                address_family_policy,
            ),
        };
    }

    pub fn deinit(self: *DownloadSession) void {
        self.http_client.deinit();
        self.* = undefined;
    }

    /// Returns a lightweight downloader borrowing this session. The session
    /// must outlive the downloader and every request made through it.
    pub fn downloader(self: *DownloadSession, config: DownloadConfiguration) CoreDownloader {
        std.debug.assert(config.address_family_policy == self.http_client.address_family_policy);
        return CoreDownloader.initWithSharedHttpClient(
            self.allocator,
            self.io,
            config,
            &self.http_client,
        );
    }
};

const HttpClientStorage = union(enum) {
    owned: HttpClient,
    shared: *HttpClient,

    fn get(self: *HttpClientStorage) *HttpClient {
        return switch (self.*) {
            .owned => |*client| client,
            .shared => |client| client,
        };
    }

    fn deinit(self: *HttpClientStorage) void {
        switch (self.*) {
            .owned => |*client| client.deinit(),
            .shared => {},
        }
    }
};

pub const DownloadEvent = struct {
    event_type: DownloadEventType,
    retrying: ?bool = null,
    progress: ?DownloadProgress = null,
    download_error: ?DownloadError = null,
    destination_path: ?[]const u8 = null,
    url: ?[]const u8 = null,
};

pub fn failureMessage(allocator: std.mem.Allocator, event: DownloadEvent) ![]u8 {
    const err = event.download_error orelse DownloadError.FailedDownload;
    if (err == error.Cancelled) return allocator.dupe(u8, "Operation cancelled.");
    const name = if (event.destination_path) |path| std.fs.path.basename(path) else "the requested file";
    const uri = if (event.url) |url| std.Uri.parse(url) catch null else null;
    const host = if (uri) |value| value.host else null;
    // Only show the hostname, never URL credentials or query tokens.
    const server = if (host) |value| switch (value) {
        .raw => |raw| raw,
        .percent_encoded => |encoded| encoded,
    } else "the selected source";
    const guidance: []const u8 = switch (err) {
        error.FileError => "Could not save the downloaded file. Check the destination directory's permissions and available disk space, then try again.",
        error.InvalidUrl => "The download address is invalid. Check the package source configuration and try again.",
        error.NotFound => "The file is no longer available at this source. Refresh the package lists and try again.",
        error.SslError, error.CertificateBundleError => "Could not establish a secure connection. Check your system clock and trusted certificates, then try again.",
        else => "Check your internet connection and try again. If the problem continues, the server may be unavailable.",
    };
    return std.fmt.allocPrint(allocator, "Could not download \"{s}\" from {s}. {s}\n\nTechnical details: {s}", .{ name, server, guidance, @errorName(err) });
}

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
    http_client: HttpClientStorage,
    event_callback: ?DownloadEventCallback = null,
    event_context: ?*anyopaque = null,
    cancellation_context: ?*anyopaque = null,
    cancellation: ?*const fn (?*anyopaque) bool = null,
    /// Owned final request URL, valid until the next download or deinit.
    effective_url: ?[]u8 = null,
    /// When true, candidate failures and per-attempt operation lifecycle events
    /// are suppressed. Progress may still flow to a logical parent download.
    /// Used for mirrors that can fail over and optional signatures.
    quiet: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: DownloadConfiguration) CoreDownloader {
        return .{
            .allocator = allocator,
            .io = io,
            .configuration = config,
            .http_client = .{ .owned = initHttpClient(
                allocator,
                io,
                config.timeout_in_seconds,
                config.address_family_policy,
            ) },
        };
    }

    fn initWithSharedHttpClient(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: DownloadConfiguration,
        http_client: *HttpClient,
    ) CoreDownloader {
        return .{
            .allocator = allocator,
            .io = io,
            .configuration = config,
            .http_client = .{ .shared = http_client },
        };
    }

    pub fn setEventCallback(self: *CoreDownloader, callback: DownloadEventCallback, context: ?*anyopaque) void {
        self.event_callback = callback;
        self.event_context = context;
    }

    pub fn deinit(self: *CoreDownloader) void {
        if (self.effective_url) |url| self.allocator.free(url);
        self.http_client.deinit();
    }

    fn httpClient(self: *CoreDownloader) *HttpClient {
        return self.http_client.get();
    }

    fn resetHttpClient(self: *CoreDownloader) void {
        switch (self.http_client) {
            .owned => |*client| {
                client.deinit();
                client.* = initHttpClient(
                    self.allocator,
                    self.io,
                    self.configuration.timeout_in_seconds,
                    self.configuration.address_family_policy,
                );
            },
            // A shared client cannot be torn down while sibling downloads are
            // active. The failed TLS request has already discarded its own
            // connection, so its retry opens a fresh connection in the session.
            .shared => {},
        }
    }

    pub fn downloadToFile(self: *CoreDownloader, url: []const u8, destination_path: []const u8, force: bool) DownloadResult {
        if (self.effective_url) |previous| self.allocator.free(previous);
        self.effective_url = null;
        return self.downloadToFileImpl(url, destination_path, force);
    }

    fn downloadToFileImpl(
        self: *CoreDownloader,
        url: []const u8,
        destination_path: []const u8,
        force: bool,
    ) DownloadResult {
        var attempt: u8 = 0;
        var tls_reset_used = false;
        while (true) : (attempt += 1) {
            if (self.isCancelled()) {
                try self.emitEvent(.{ .event_type = .Error, .download_error = DownloadError.Cancelled, .destination_path = destination_path, .url = url });
                return .{ .failure = DownloadError.Cancelled };
            }
            if (attempt > 0) {
                const resuming = if (self.configuration.resume_path) |path| blk: {
                    const st = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch break :blk false;
                    break :blk st.size != 0;
                } else false;
                try self.emitEvent(.{ .event_type = .Start, .retrying = resuming, .destination_path = destination_path, .url = url });
                var ticks: u64 = @as(u64, self.configuration.retry_delay_secs) * 20;
                while (ticks > 0 and !self.isCancelled()) : (ticks -= 1)
                    self.io.sleep(.fromMilliseconds(50), .awake) catch {};
                if (self.isCancelled()) return .{ .failure = error.Cancelled };
            }

            if (self.performDownload(url, destination_path, force)) {
                return .{ .succes = .{ .destination_path = destination_path } };
            } else |err| {
                if (err == DownloadError.NotModified) {
                    self.normalizeExistingPermissions(destination_path) catch |permission_err| {
                        try self.emitEvent(.{
                            .event_type = .Error,
                            .download_error = permission_err,
                            .destination_path = destination_path,
                            .url = url,
                        });
                        return .{ .failure = permission_err };
                    };
                    try self.emitEvent(.{ .event_type = .Skipped, .destination_path = destination_path });
                    return .{ .skipped = .{ .destination_path = destination_path, .reason = .NotModified } };
                }
                switch (retryAction(err, attempt, self.configuration.max_retries, tls_reset_used)) {
                    .retry => {},
                    .reset_tls_and_retry => {
                        // Recreate the client once so the next attempt gets a fresh
                        // connection pool, CA bundle, and cached realtime value.
                        tls_reset_used = true;
                        self.resetHttpClient();
                    },
                    .stop => {
                        // Preserve the final phase-specific error so callers
                        // can distinguish setup, header, and body stalls.
                        const final_err = err;
                        try self.emitEvent(.{
                            .event_type = .Error,
                            .download_error = final_err,
                            .destination_path = destination_path,
                            .url = url,
                        });
                        return .{ .failure = final_err };
                    },
                }
            }
        }
    }

    fn performDownload(self: *CoreDownloader, url: []const u8, destination_path: []const u8, force: bool) DownloadError!void {
        if (self.isCancelled()) return DownloadError.Cancelled;
        const uri = std.Uri.parse(url) catch return DownloadError.InvalidUrl;

        if (std.ascii.eqlIgnoreCase(uri.scheme, "file")) {
            const path = uri.path.toRawMaybeAlloc(self.allocator) catch return error.FileError;
            defer if (uri.path == .percent_encoded and path.ptr != uri.path.percent_encoded.ptr) self.allocator.free(path);
            if (!std.fs.path.isAbsolute(path) or (uri.host != null and !std.ascii.eqlIgnoreCase(uri.host.?.percent_encoded, "localhost"))) return error.InvalidUrl;
            return self.copyLocal(path, destination_path, force);
        }
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return self.curlDownload(url, destination_path, force);
        var resume_offset: u64 = 0;
        if (self.configuration.resume_path) |partial| {
            if (std.Io.Dir.cwd().statFile(self.io, partial, .{})) |st| {
                if (st.kind != .file) return error.FileError;
                resume_offset = st.size;
                if (self.configuration.maximum_size) |max| {
                    if (resume_offset >= max) resume_offset = 0;
                }
            } else |_| {}
        }
        var ims_buf: [64]u8 = undefined;
        var range_buf: [64]u8 = undefined;
        var headers: [2]std.http.Header = undefined;
        var header_count: usize = 0;
        if (resume_offset != 0) {
            headers[header_count] = .{ .name = "range", .value = std.fmt.bufPrint(&range_buf, "bytes={d}-", .{resume_offset}) catch unreachable };
            header_count += 1;
        } else if (!force) {
            const mtime = self.configuration.conditional_mtime orelse blk: {
                const st = std.Io.Dir.cwd().statFile(self.io, destination_path, .{}) catch break :blk -1;
                break :blk st.mtime.nanoseconds;
            };
            if (formatHttpDate(&ims_buf, mtime)) |http_date| {
                headers[header_count] = .{ .name = "if-modified-since", .value = http_date };
                header_count += 1;
            }
        }
        const extra_headers = headers[0..header_count];

        const user_agent: HttpClient.Request.Headers.Value = if (self.configuration.user_agent) |agent|
            .{ .override = agent }
        else
            .default;
        var req = requestWithSetupTimeout(
            self.httpClient(),
            self.io,
            .GET,
            uri,
            downloadRequestOptions(user_agent, extra_headers),
            connectTimeout(self.configuration.timeout_in_seconds),
            self,
        ) catch |err| {
            if (err == error.UnsupportedProxyScheme) return self.curlDownload(url, destination_path, force);
            self.logErr("Could not prepare the download request to {0f} for {1f}. {2s}\n\nTechnical details: {3s}", .{ diagnostics.safe(url), diagnostics.safe(destination_path), diagnostics.cause(err), @errorName(err) });
            return mapRequestError(err);
        };
        defer req.deinit();

        var redirect_buffer: [8 * 1024]u8 = undefined;
        var response = sendAndReceiveHeadWithTimeout(
            &req,
            self.io,
            &redirect_buffer,
            timeoutFromSeconds(self.configuration.response_header_timeout_in_seconds),
            self,
        ) catch |err| {
            if (err == error.UnsupportedUriScheme or err == error.UnsupportedProxyScheme) return self.curlDownload(url, destination_path, force);
            const mapped = mapHeaderExchangeError(err);
            if (mapped == DownloadError.HeaderTimeout) {
                self.logErr("Timed out waiting for response headers from {s}", .{url});
            } else {
                self.logErr("Could not read the download response headers from {0f} for {1f}. {2s}\n\nTechnical details: {3s}", .{ diagnostics.safe(url), diagnostics.safe(destination_path), diagnostics.cause(err), @errorName(err) });
            }
            return mapped;
        };

        if (self.effective_url) |previous| self.allocator.free(previous);
        self.effective_url = null;
        self.effective_url = std.fmt.allocPrint(self.allocator, "{f}", .{req.uri}) catch return error.FileError;
        const status = response.head.status;
        if (status == .not_modified) return DownloadError.NotModified;
        if (status == .not_found) return DownloadError.NotFound;
        if (@intFromEnum(status) == 416 and resume_offset != 0) {
            std.Io.Dir.cwd().deleteFile(self.io, self.configuration.resume_path.?) catch return error.FileError;
            return self.performDownload(url, destination_path, force);
        }
        switch (status.class()) {
            .success => {},
            .server_error => {
                self.logErr("Could not download {0f} from {1f}: the server returned HTTP {2d}.", .{ diagnostics.safe(destination_path), diagnostics.safe(url), @intFromEnum(status) });
                return DownloadError.NetworkError;
            },
            else => {
                self.logErr("HTTP status {d} for {s}", .{ @intFromEnum(status), url });
                return DownloadError.HttpError;
            },
        }

        if (status == .partial_content) {
            if (resume_offset == 0) return error.InvalidRange;
            var iterator = response.head.iterateHeaders();
            var valid = false;
            while (iterator.next()) |header| if (std.ascii.eqlIgnoreCase(header.name, "content-range")) {
                valid = validRange(header.value, resume_offset, response.head.content_length);
            };
            if (!valid) return error.InvalidRange;
        } else resume_offset = 0; // A server ignoring Range requires a complete restart.
        var remote_mtime: ?std.Io.Timestamp = null;
        var response_headers = response.head.iterateHeaders();
        while (response_headers.next()) |header| if (std.ascii.eqlIgnoreCase(header.name, "last-modified")) {
            const now = std.Io.Timestamp.now(self.io, .real).nanoseconds;
            const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divFloor(@max(0, now), std.time.ns_per_s)) };
            remote_mtime = HttpDate.parse(header.value, epoch.getEpochDay().calculateYearDay().year);
        };
        const total: ?u64 = if (response.head.content_length) |length| std.math.add(u64, length, resume_offset) catch return error.SizeExceeded else null;
        if (self.configuration.maximum_size) |max| if (total) |size| if (size > max) return error.SizeExceeded;

        try self.emitEvent(.{
            .event_type = .Start,
            .destination_path = destination_path,
            .progress = .{
                .bytes_downloaded = 0,
                .bytes_total = total,
                .percent = 0,
                .speed_bytes_per_sec = null,
            },
        });

        const part_path = (if (self.configuration.resume_path) |path| self.allocator.dupe(u8, path) else makePartPath(self.allocator, self.io, destination_path)) catch return DownloadError.FileError;
        defer self.allocator.free(part_path);
        var part_exists = false;
        var file = std.Io.Dir.cwd().createFile(self.io, part_path, .{ .exclusive = self.configuration.resume_path == null, .truncate = resume_offset == 0 }) catch |err| {
            self.logErr("Could not create temporary file {0f}: {1s}\n\nTechnical details: {2s}", .{ diagnostics.safe(part_path), diagnostics.cause(err), @errorName(err) });
            return DownloadError.FileError;
        };
        part_exists = true;
        var file_open = true;
        defer {
            if (file_open) file.close(self.io);
            if (part_exists and self.configuration.resume_path == null) std.Io.Dir.cwd().deleteFile(self.io, part_path) catch {};
        }

        const copy_buffer = self.allocator.alloc(u8, copy_buffer_size) catch return DownloadError.FileError;
        defer self.allocator.free(copy_buffer);

        var transfer_buffer: [4 * 1024]u8 = undefined;
        const body_reader = response.reader(&transfer_buffer);

        const start_ns = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
        var downloaded: u64 = resume_offset;
        var last_percent: i16 = -1;
        var last_reported: u64 = 0;

        const body_stall_timeout = timeoutFromSeconds(self.configuration.response_body_timeout_in_seconds);

        while (true) {
            if (self.isCancelled()) return DownloadError.Cancelled;
            const n = readBodyWithTimeout(self, &req, body_reader, copy_buffer, body_stall_timeout) catch |err| switch (err) {
                error.Canceled => return error.Cancelled,
                error.BodyTimeout => {
                    self.logErr("Timed out waiting for body data from {s}", .{url});
                    return DownloadError.BodyTimeout; // retryable -> mirror failover / retry
                },
                else => {
                    self.logErr("Could not finish downloading {0f} from {1f}. {2s}", .{ diagnostics.safe(destination_path), diagnostics.safe(url), if (response.bodyErr()) |failure| diagnostics.cause(failure) else diagnostics.unknown_cause });
                    return DownloadError.NetworkError;
                },
            };
            if (n == 0) break;

            if (self.configuration.maximum_size) |max| if (n > max -| downloaded) return error.SizeExceeded;
            file.writePositionalAll(self.io, copy_buffer[0..n], downloaded) catch |err| {
                self.logErr("Could not write to {0f}: {1s}\n\nTechnical details: {2s}", .{ diagnostics.safe(destination_path), diagnostics.cause(err), @errorName(err) });
                return DownloadError.FileError;
            };

            downloaded += n;

            if (self.shouldEmitProgress(downloaded, total, &last_percent, &last_reported)) {
                try self.emitEvent(.{
                    .event_type = .Progress,
                    .destination_path = destination_path,
                    .progress = makeProgress(downloaded, total, self.speedBytesPerSec(downloaded, start_ns)),
                });
            }
        }

        if (total) |expected| {
            if (downloaded != expected) {
                self.logErr(
                    "Download of {0f} was incomplete: expected {1d} bytes, received {2d}. Download the file again.",
                    .{ diagnostics.safe(url), expected, downloaded },
                );
                return DownloadError.NetworkError;
            }
        }

        if (remote_mtime) |mtime| file.setTimestamps(self.io, .{ .modify_timestamp = .{ .new = mtime } }) catch return error.FileError;
        if (self.configuration.final_permissions) |permissions| {
            file.setPermissions(self.io, permissions) catch |err| {
                self.logErr("Could not set permissions on temporary file {0f}: {1s}\n\nTechnical details: {2s}", .{ diagnostics.safe(part_path), diagnostics.cause(err), @errorName(err) });
                return DownloadError.FileError;
            };
        }

        if (self.configuration.file_durability == .sync_before_rename) {
            file.sync(self.io) catch |err| {
                self.logErr("Could not sync temporary file {0f}: {1s}\n\nTechnical details: {2s}", .{ diagnostics.safe(part_path), diagnostics.cause(err), @errorName(err) });
                return DownloadError.FileError;
            };
        }
        file.close(self.io);
        file_open = false;
        std.Io.Dir.cwd().rename(part_path, std.Io.Dir.cwd(), destination_path, self.io) catch |err| {
            self.logErr("Could not replace {0f} with completed download: {1s}\n\nTechnical details: {2s}", .{ diagnostics.safe(destination_path), diagnostics.cause(err), @errorName(err) });
            return DownloadError.FileError;
        };
        part_exists = false;

        try self.emitEvent(.{
            .event_type = .Complete,
            .destination_path = destination_path,
            .progress = makeProgress(downloaded, total orelse downloaded, self.speedBytesPerSec(downloaded, start_ns)),
        });
    }

    fn curlDownload(self: *CoreDownloader, url: []const u8, destination: []const u8, force: bool) DownloadError!void {
        const url_z = self.allocator.dupeZ(u8, url) catch return error.FileError;
        defer self.allocator.free(url_z);
        const part = (if (self.configuration.resume_path) |path| self.allocator.dupe(u8, path) else makePartPath(self.allocator, self.io, destination)) catch return error.FileError;
        defer self.allocator.free(part);
        const path_z = self.allocator.dupeZ(u8, part) catch return error.FileError;
        defer self.allocator.free(path_z);
        defer if (self.configuration.resume_path == null) std.Io.Dir.cwd().deleteFile(self.io, part) catch {};
        try self.emitEvent(.{ .event_type = .Start, .destination_path = destination });
        const mtime: i128 = if (force) -1 else self.configuration.conditional_mtime orelse blk: {
            const st = std.Io.Dir.cwd().statFile(self.io, destination, .{}) catch break :blk -1;
            break :blk st.mtime.nanoseconds;
        };
        try Curl.download(.{
            .allocator = self.allocator,
            .io = self.io,
            .url = url_z,
            .path = path_z,
            .timeout = self.configuration.timeout_in_seconds,
            .maximum = self.configuration.maximum_size,
            .resumable = self.configuration.resume_path != null,
            .verify_ssl = self.configuration.verify_ssl,
            .mtime = @intCast(@divFloor(mtime, std.time.ns_per_s)),
            .cancelled = curlCancelled,
            .progress = curlProgress,
            .context = self,
            .effective_url = &self.effective_url,
        });
        try self.normalizeExistingPermissions(part);
        std.Io.Dir.cwd().rename(part, .cwd(), destination, self.io) catch return error.FileError;
        try self.emitEvent(.{ .event_type = .Complete, .destination_path = destination });
    }

    fn copyLocal(self: *CoreDownloader, path: []const u8, destination: []const u8, force: bool) DownloadError!void {
        var source = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch |err| return if (err == error.FileNotFound) error.NotFound else error.FileError;
        defer source.close(self.io);
        const st = source.stat(self.io) catch return error.FileError;
        if (st.kind != .file) return error.FileError;
        if (self.configuration.maximum_size) |max| if (st.size > max) return error.SizeExceeded;
        if (!force) {
            const mtime = self.configuration.conditional_mtime orelse blk: {
                const existing = std.Io.Dir.cwd().statFile(self.io, destination, .{}) catch break :blk -1;
                break :blk existing.mtime.nanoseconds;
            };
            if (st.mtime.nanoseconds <= mtime) return error.NotModified;
        }
        const part = makePartPath(self.allocator, self.io, destination) catch return error.FileError;
        defer self.allocator.free(part);
        var out = std.Io.Dir.cwd().createFile(self.io, part, .{ .exclusive = true }) catch return error.FileError;
        defer out.close(self.io);
        defer std.Io.Dir.cwd().deleteFile(self.io, part) catch {};
        try self.emitEvent(.{ .event_type = .Start, .destination_path = destination });
        var buffer: [64 * 1024]u8 = undefined;
        var offset: u64 = 0;
        while (true) {
            if (self.isCancelled()) return error.Cancelled;
            const n = source.readPositional(self.io, &.{&buffer}, offset) catch return error.FileError;
            if (n == 0) break;
            if (self.configuration.maximum_size) |max| if (n > max -| offset) return error.SizeExceeded;
            out.writeStreamingAll(self.io, buffer[0..n]) catch return error.FileError;
            offset += n;
            try self.emitEvent(.{ .event_type = .Progress, .destination_path = destination, .progress = makeProgress(offset, st.size, null) });
        }
        if (offset != st.size) return error.NetworkError;
        out.setTimestamps(self.io, .{ .modify_timestamp = .{ .new = st.mtime } }) catch return error.FileError;
        if (self.configuration.final_permissions) |mode| out.setPermissions(self.io, mode) catch return error.FileError;
        if (self.configuration.file_durability == .sync_before_rename) out.sync(self.io) catch return error.FileError;
        std.Io.Dir.cwd().rename(part, .cwd(), destination, self.io) catch return error.FileError;
        try self.emitEvent(.{ .event_type = .Complete, .destination_path = destination, .progress = makeProgress(offset, st.size, null) });
    }

    fn normalizeExistingPermissions(self: *CoreDownloader, destination_path: []const u8) DownloadError!void {
        const permissions = self.configuration.final_permissions orelse return;
        var file = std.Io.Dir.cwd().openFile(self.io, destination_path, .{ .mode = .read_write }) catch |err| {
            self.logErr("Could not open {0f} while normalizing permissions: {1s}\n\nTechnical details: {2s}", .{ diagnostics.safe(destination_path), diagnostics.cause(err), @errorName(err) });
            return DownloadError.FileError;
        };
        defer file.close(self.io);
        file.setPermissions(self.io, permissions) catch |err| {
            self.logErr("Could not normalize permissions on {0f}: {1s}\n\nTechnical details: {2s}", .{ diagnostics.safe(destination_path), diagnostics.cause(err), @errorName(err) });
            return DownloadError.FileError;
        };
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

    pub fn emitEvent(self: *const CoreDownloader, event: DownloadEvent) !void {
        if (self.quiet and event.event_type == .Error) return;
        if (self.event_callback) |callback| callback(self.event_context, event);
    }

    fn isCancelled(self: *const CoreDownloader) bool {
        return if (self.cancellation) |callback| callback(self.cancellation_context) else false;
    }

    /// Logs at error level unless `quiet` is set, used so best-effort downloads
    /// do not surface expected failures (e.g. a missing optional signature).
    fn logErr(self: *const CoreDownloader, comptime fmt: []const u8, args: anytype) void {
        if (!self.quiet) std.log.err(fmt, args);
    }
};

const RequestSetupRace = union(enum) {
    request: HttpClient.RequestError!HttpClient.Request,
    timeout: std.Io.Cancelable!void,
    cancelled: std.Io.Cancelable!void,
};

const HeaderExchangeError = HttpClient.Request.ReceiveHeadError || error{HeaderTimeout};

const HeaderExchangeRace = union(enum) {
    response: HttpClient.Request.ReceiveHeadError!HttpClient.Response,
    timeout: std.Io.Cancelable!void,
    cancelled: std.Io.Cancelable!void,
};

fn sendAndReceiveHeadWithTimeout(
    req: *HttpClient.Request,
    io: std.Io,
    redirect_buffer: []u8,
    timeout: std.Io.Timeout,
    cancellation: ?*CoreDownloader,
) HeaderExchangeError!HttpClient.Response {
    if (timeout == .none and cancellation == null) return sendAndReceiveHead(req, redirect_buffer);

    var result_buffer: [3]HeaderExchangeRace = undefined;
    var select = std.Io.Select(HeaderExchangeRace).init(io, &result_buffer);
    var interrupt_on_cleanup = false;
    // A timeout branch may sleep for seconds. Require real concurrency so a
    // saturated async pool cannot run it inline ahead of a ready response.
    select.concurrent(.response, sendAndReceiveHead, .{ req, redirect_buffer }) catch
        return error.Unexpected;
    defer {
        if (interrupt_on_cleanup) req.interrupt();
        while (select.cancel()) |_| {}
        if (interrupt_on_cleanup) req.markConnectionClosing();
    }
    if (timeout != .none) select.concurrent(.timeout, waitForRequestSetupTimeout, .{ io, timeout }) catch {
        interrupt_on_cleanup = true;
        return error.Unexpected;
    };

    if (cancellation) |core| select.concurrent(.cancelled, waitForCancellation, .{core}) catch return error.Unexpected;
    return switch (try select.await()) {
        .cancelled => {
            interrupt_on_cleanup = true;
            return error.Canceled;
        },
        .response => |result| result,
        .timeout => |result| {
            try result;
            interrupt_on_cleanup = true;
            return error.HeaderTimeout;
        },
    };
}

fn sendAndReceiveHead(
    req: *HttpClient.Request,
    redirect_buffer: []u8,
) HttpClient.Request.ReceiveHeadError!HttpClient.Response {
    try req.sendBodiless();
    return req.receiveHead(redirect_buffer);
}

fn readBody(reader: *std.Io.Reader, buffer: []u8) std.Io.Reader.ShortError!usize {
    var vectors: [1][]u8 = .{buffer};
    while (true) {
        const read = reader.readVec(&vectors) catch |err| switch (err) {
            error.EndOfStream => return 0,
            error.ReadFailed => return error.ReadFailed,
        };
        // Reader.readVec documents that zero does not indicate EOF. HTTP
        // framing can make an internal state transition without yielding body
        // bytes, so keep reading until data or EndOfStream is observed.
        if (read != 0) return read;
    }
}

fn readBodyWithTimeout(
    self: *CoreDownloader,
    req: *HttpClient.Request,
    reader: *std.Io.Reader,
    buffer: []u8,
    timeout: std.Io.Timeout,
) (std.Io.Reader.ShortError || std.Io.Cancelable || error{ BodyTimeout, Unexpected })!usize {
    if (timeout == .none and self.cancellation == null) return readBody(reader, buffer);

    var result_buffer: [3]BodyReadRace = undefined;
    var select = std.Io.Select(BodyReadRace).init(self.io, &result_buffer);
    var interrupt_on_cleanup = false;
    select.concurrent(.read, readBody, .{ reader, buffer }) catch
        return error.Unexpected;
    defer {
        if (interrupt_on_cleanup) req.interrupt();
        while (select.cancel()) |_| {}
        if (interrupt_on_cleanup) req.markConnectionClosing();
    }
    if (timeout != .none) select.concurrent(.timeout, waitForRequestSetupTimeout, .{ self.io, timeout }) catch {
        interrupt_on_cleanup = true;
        return error.Unexpected;
    };

    if (self.cancellation != null) select.concurrent(.cancelled, waitForCancellation, .{self}) catch return error.Unexpected;
    return switch (try select.await()) {
        .cancelled => {
            interrupt_on_cleanup = true;
            return error.Canceled;
        },
        .read => |result| result,
        .timeout => |result| {
            try result;
            interrupt_on_cleanup = true;
            return error.BodyTimeout;
        },
    };
}

/// Bounds DNS, TCP, and TLS initialization together. The response body is not
/// part of this deadline, so a mirror that successfully starts responding can
/// finish at normal transfer speed.
fn requestWithSetupTimeout(
    client: *HttpClient,
    io: std.Io,
    method: std.http.Method,
    uri: std.Uri,
    options: HttpClient.RequestOptions,
    timeout: std.Io.Timeout,
    cancellation: ?*CoreDownloader,
) HttpClient.RequestError!HttpClient.Request {
    if (timeout == .none and cancellation == null) return client.request(method, uri, options);

    var result_buffer: [3]RequestSetupRace = undefined;
    var select = std.Io.Select(RequestSetupRace).init(io, &result_buffer);
    // Both sides must run beside the caller; `async` is allowed to run either
    // branch inline when its worker pool is saturated.
    select.concurrent(.request, beginRequest, .{ client, method, uri, options }) catch
        return error.Unexpected;
    defer while (select.cancel()) |remaining| closeRequestSetupRace(remaining);
    // Timeout.none.sleep returns immediately. A disabled deadline must have
    // no timer branch, even when cancellation still requires a race.
    if (timeout != .none) select.concurrent(.timeout, waitForRequestSetupTimeout, .{ io, timeout }) catch
        return error.Unexpected;

    if (cancellation) |core| select.concurrent(.cancelled, waitForCancellation, .{core}) catch return error.Unexpected;
    return switch (try select.await()) {
        .cancelled => return error.Canceled,
        .request => |result| result,
        .timeout => |result| {
            try result;
            return error.Timeout;
        },
    };
}

fn beginRequest(
    client: *HttpClient,
    method: std.http.Method,
    uri: std.Uri,
    options: HttpClient.RequestOptions,
) HttpClient.RequestError!HttpClient.Request {
    return client.request(method, uri, options);
}

fn waitForCancellation(core: *CoreDownloader) std.Io.Cancelable!void {
    while (!core.isCancelled()) try core.io.sleep(.fromMilliseconds(20), .awake);
}
fn waitForRequestSetupTimeout(io: std.Io, timeout: std.Io.Timeout) std.Io.Cancelable!void {
    return timeout.sleep(io);
}

fn closeRequestSetupRace(completed: RequestSetupRace) void {
    switch (completed) {
        .request => |result| if (result) |request| {
            var loser = request;
            loser.deinit();
        } else |_| {},
        .timeout, .cancelled => {},
    }
}

fn timeoutFromSeconds(seconds: u32) std.Io.Timeout {
    if (seconds == 0) return .none;
    return .{ .duration = .{
        .clock = .awake,
        .raw = .fromSeconds(seconds),
    } };
}

fn connectTimeout(seconds: u32) std.Io.Timeout {
    return timeoutFromSeconds(seconds);
}

fn makePartPath(allocator: std.mem.Allocator, io: std.Io, destination_path: []const u8) ![]u8 {
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const nonce = std.mem.readInt(u64, &random_bytes, .little);
    return std.fmt.allocPrint(allocator, "{s}.part.{x}", .{ destination_path, nonce });
}

fn downloadRequestOptions(
    user_agent: HttpClient.Request.Headers.Value,
    extra_headers: []const std.http.Header,
) HttpClient.RequestOptions {
    return .{
        .headers = .{ .user_agent = user_agent, .accept_encoding = .{ .override = "identity" } },
        .extra_headers = extra_headers,
        .redirect_behavior = .init(10),
        // The HTTP client normalizes bodyless responses such as 304 before
        // cleanup, allowing successful connections to return to the pool.
        .keep_alive = true,
    };
}

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
        error.NetworkError,
        error.Timeout,
        error.ConnectTimeout,
        error.HeaderTimeout,
        error.BodyTimeout,
        => true,
        else => false,
    };
}

const RetryAction = enum {
    stop,
    retry,
    reset_tls_and_retry,
};

fn retryAction(err: DownloadError, attempt: u8, max_retries: u8, tls_reset_used: bool) RetryAction {
    if (attempt >= max_retries) return .stop;
    if (err == DownloadError.SslError and !tls_reset_used) return .reset_tls_and_retry;
    if (isRetryable(err)) return .retry;
    return .stop;
}

fn mapRequestError(err: HttpClient.RequestError) DownloadError {
    return switch (err) {
        error.UnknownHostName => DownloadError.HostNotFound,
        error.UnsupportedUriScheme, error.UriMissingHost => DownloadError.InvalidUrl,
        error.Canceled => DownloadError.Cancelled,
        error.Timeout => DownloadError.ConnectTimeout,
        error.TlsInitializationFailed => DownloadError.SslError,
        error.CertificateBundleLoadFailure => DownloadError.CertificateBundleError,
        else => DownloadError.NetworkError,
    };
}

fn mapReceiveHeadError(err: HttpClient.Request.ReceiveHeadError) DownloadError {
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
        error.Canceled => DownloadError.Cancelled,
        error.TlsInitializationFailed => DownloadError.SslError,
        error.CertificateBundleLoadFailure => DownloadError.CertificateBundleError,
        else => DownloadError.NetworkError,
    };
}

fn mapHeaderExchangeError(err: HeaderExchangeError) DownloadError {
    return switch (err) {
        error.HeaderTimeout => DownloadError.HeaderTimeout,
        else => mapReceiveHeadError(@errorCast(err)),
    };
}

fn parseFileUri(uri: []const u8) DownloadError![]const u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return DownloadError.InvalidUrl;

    const path = uri[prefix.len..];
    if (!std.fs.path.isAbsolute(path)) return DownloadError.InvalidUrl;
    return path;
}

fn copyFile(
    io: std.Io,
    source_path: []const u8,
    destination_path: []const u8,
    final_permissions: ?std.Io.File.Permissions,
) !void {
    var source = try std.Io.Dir.cwd().openFile(io, source_path, .{});
    defer source.close(io);

    var destination = try std.Io.Dir.cwd().createFile(io, destination_path, .{});
    defer destination.close(io);

    var read_buffer: [64 * 1024]u8 = undefined;
    var reader = source.readerStreaming(io, &read_buffer);

    var write_buffer: [64 * 1024]u8 = undefined;
    var writer = destination.writerStreaming(io, &write_buffer);

    _ = try reader.interface.streamRemaining(&writer.interface);
    try writer.interface.flush();
    if (final_permissions) |permissions| try destination.setPermissions(io, permissions);
}

// Unit tests for downloader.zig
test "DownloadConfiguration.default() returns correct default values" {
    const config = DownloadConfiguration.default();
    try std.testing.expectEqualStrings("ShellyPackageManager/2.0", config.user_agent.?);
    try std.testing.expectEqual(@as(u32, 30), config.timeout_in_seconds);
    try std.testing.expectEqual(@as(u32, 30), config.response_header_timeout_in_seconds);
    try std.testing.expectEqual(@as(u32, 30), config.response_body_timeout_in_seconds);
    try std.testing.expectEqual(AddressFamilyPolicy.prefer_ipv4, config.address_family_policy);
    try std.testing.expectEqual(@as(u8, 3), config.max_retries);
    try std.testing.expectEqual(@as(u32, 1), config.retry_delay_secs);
    try std.testing.expectEqual(true, config.verify_ssl);
    try std.testing.expectEqual(FileDurability.sync_before_rename, config.file_durability);
    try std.testing.expect(config.final_permissions == null);
}

test "connect timeout uses the configured duration" {
    const timeout = connectTimeout(30);
    switch (timeout) {
        .duration => |duration| {
            try std.testing.expectEqual(std.Io.Clock.awake, duration.clock);
            try std.testing.expectEqual(std.Io.Duration.fromSeconds(30), duration.raw);
        },
        else => return error.TestExpectedDuration,
    }
    try std.testing.expect(connectTimeout(0) == .none);
}

test "address-family policy is forwarded to the HTTP client" {
    var downloader = CoreDownloader.init(std.testing.allocator, std.testing.io, .{
        .address_family_policy = .ipv4_only,
    });
    defer downloader.deinit();

    try std.testing.expectEqual(AddressFamilyPolicy.ipv4_only, downloader.httpClient().address_family_policy);
}

test "download requests participate in connection reuse" {
    const options = downloadRequestOptions(.default, &.{});
    try std.testing.expect(options.keep_alive);
}

test "download session lends one HTTP client without transferring ownership" {
    var session = DownloadSession.init(
        std.testing.allocator,
        std.testing.io,
        3,
        .prefer_ipv4,
    );
    defer session.deinit();

    var first = session.downloader(.{});
    defer first.deinit();
    var second = session.downloader(.{});
    defer second.deinit();

    try std.testing.expect(first.httpClient() == second.httpClient());
    try std.testing.expect(first.httpClient() == &session.http_client);
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
    try std.testing.expect(isRetryable(DownloadError.ConnectTimeout));
    try std.testing.expect(isRetryable(DownloadError.HeaderTimeout));
    try std.testing.expect(isRetryable(DownloadError.BodyTimeout));
}

test "isRetryable returns false for other errors" {
    try std.testing.expect(!isRetryable(DownloadError.HttpError));
    try std.testing.expect(!isRetryable(DownloadError.NotFound));
    try std.testing.expect(!isRetryable(DownloadError.FileError));
    try std.testing.expect(!isRetryable(DownloadError.InvalidUrl));
    try std.testing.expect(!isRetryable(DownloadError.RetryExceeded));
    try std.testing.expect(!isRetryable(DownloadError.SslError));
    try std.testing.expect(!isRetryable(DownloadError.CertificateBundleError));
}

test "retryAction resets TLS once before stopping" {
    try std.testing.expectEqual(RetryAction.reset_tls_and_retry, retryAction(DownloadError.SslError, 0, 3, false));
    try std.testing.expectEqual(RetryAction.stop, retryAction(DownloadError.SslError, 1, 3, true));
    try std.testing.expectEqual(RetryAction.stop, retryAction(DownloadError.SslError, 0, 0, false));
}

test "retryAction retries transient errors without resetting TLS" {
    try std.testing.expectEqual(RetryAction.retry, retryAction(DownloadError.NetworkError, 0, 3, false));
    try std.testing.expectEqual(RetryAction.retry, retryAction(DownloadError.Timeout, 2, 3, false));
    try std.testing.expectEqual(RetryAction.stop, retryAction(DownloadError.NetworkError, 3, 3, false));
}

test "retryAction does not retry certificate bundle failures" {
    try std.testing.expectEqual(
        RetryAction.stop,
        retryAction(DownloadError.CertificateBundleError, 0, 3, false),
    );
}

test "mapRequestError maps UnsupportedUriScheme and UriMissingHost to InvalidUrl" {
    try std.testing.expectEqual(DownloadError.InvalidUrl, mapRequestError(error.UnsupportedUriScheme));
    try std.testing.expectEqual(DownloadError.InvalidUrl, mapRequestError(error.UriMissingHost));
}

test "mapRequestError distinguishes TLS initialization from certificate bundle failures" {
    try std.testing.expectEqual(DownloadError.SslError, mapRequestError(error.TlsInitializationFailed));
    try std.testing.expectEqual(DownloadError.CertificateBundleError, mapRequestError(error.CertificateBundleLoadFailure));
}

test "mapRequestError maps other errors to NetworkError" {
    try std.testing.expectEqual(DownloadError.NetworkError, mapRequestError(error.ConnectionRefused));
}

test "mapRequestError preserves setup timeouts and cancellation" {
    try std.testing.expectEqual(DownloadError.ConnectTimeout, mapRequestError(error.Timeout));
    try std.testing.expectEqual(DownloadError.Cancelled, mapRequestError(error.Canceled));
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

test "mapReceiveHeadError distinguishes TLS initialization from certificate bundle failures" {
    try std.testing.expectEqual(DownloadError.SslError, mapReceiveHeadError(error.TlsInitializationFailed));
    try std.testing.expectEqual(DownloadError.CertificateBundleError, mapReceiveHeadError(error.CertificateBundleLoadFailure));
}

test "mapReceiveHeadError maps other errors to NetworkError" {
    try std.testing.expectEqual(DownloadError.NetworkError, mapReceiveHeadError(error.ConnectionRefused));
}

const TestServerMode = enum {
    raw,
    stall_headers,
    stall_body,
    delayed_response,
    not_found,
    x_gzip_ignoring_identity,
    reuse_with_not_modified,
};

const test_x_gzip_body =
    "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\x2b\x4a" ++
    "\x2d\xc8\x2f\xce\x2c\xc9\x2f\xaa\x54\x48\x49\x2c" ++
    "\x49\x4c\x4a\x2c\x4e\x05\x00\x82\xd8\xef\x91\x13" ++
    "\x00\x00\x00";

const TestHttpServer = struct {
    io: std.Io,
    server: std.Io.net.Server,
    mode: TestServerMode,
    response: []const u8 = "",
    second_response: ?[]const u8 = null,
    required_header: ?[]const u8 = null,

    fn init(io: std.Io, mode: TestServerMode) !TestHttpServer {
        var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        return .{
            .io = io,
            .server = try address.listen(io, .{ .reuse_address = true }),
            .mode = mode,
        };
    }

    fn deinit(self: *TestHttpServer) void {
        self.server.deinit(self.io);
    }

    fn url(self: *const TestHttpServer, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "http://127.0.0.1:{d}/repository.db",
            .{self.server.socket.address.getPort()},
        );
    }

    fn serveRaw(self: *TestHttpServer) !void {
        const responses = [_]?[]const u8{ self.response, self.second_response };
        for (responses) |entry| {
            const response_bytes = entry orelse break;
            var stream = try self.server.accept(self.io);
            defer stream.close(self.io);
            var read_buffer: [4096]u8 = undefined;
            var reader = stream.reader(self.io, &read_buffer);
            var saw_header = self.required_header == null;
            while (try reader.interface.takeDelimiter('\n')) |line| {
                if (std.mem.eql(u8, line, "\r")) break;
                if (self.required_header) |header| if (std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, line, "\r"), header)) {
                    saw_header = true;
                };
            }
            if (!saw_header) return error.MissingRangeRequest;
            var write_buffer: [4096]u8 = undefined;
            var writer = stream.writer(self.io, &write_buffer);
            try writer.interface.writeAll(response_bytes);
            try writer.interface.flush();
        }
    }
    fn serve(self: *TestHttpServer) !void {
        if (self.mode == .raw) return self.serveRaw();
        var stream = try self.server.accept(self.io);
        defer stream.close(self.io);

        var write_buffer: [512]u8 = undefined;
        var stream_writer = stream.writer(self.io, &write_buffer);
        const writer = &stream_writer.interface;

        switch (self.mode) {
            .raw => unreachable,
            .stall_headers => try self.io.sleep(std.Io.Duration.fromSeconds(10), .awake),
            .stall_body => {
                var read_buffer: [2048]u8 = undefined;
                var stream_reader = stream.reader(self.io, &read_buffer);
                try consumeTestRequest(&stream_reader.interface);
                try writer.writeAll(
                    "HTTP/1.1 200 OK\r\n" ++
                        "Content-Length: 5\r\n" ++
                        "Connection: keep-alive\r\n\r\n",
                );
                try writer.flush();
                try self.io.sleep(std.Io.Duration.fromSeconds(10), .awake);
            },
            .delayed_response => {
                var read_buffer: [2048]u8 = undefined;
                var stream_reader = stream.reader(self.io, &read_buffer);
                try consumeTestRequest(&stream_reader.interface);
                try self.io.sleep(.fromMilliseconds(50), .awake);
                try writer.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\n");
                try writer.flush();
                try self.io.sleep(.fromMilliseconds(50), .awake);
                try writer.writeAll("hello");
                try writer.flush();
            },
            .not_found => {
                var read_buffer: [2048]u8 = undefined;
                var stream_reader = stream.reader(self.io, &read_buffer);
                try consumeTestRequest(&stream_reader.interface);
                try writer.writeAll(
                    "HTTP/1.1 404 Not Found\r\n" ++
                        "Content-Length: 0\r\n" ++
                        "Connection: close\r\n\r\n",
                );
                try writer.flush();
            },
            .x_gzip_ignoring_identity => {
                var read_buffer: [2048]u8 = undefined;
                var stream_reader = stream.reader(self.io, &read_buffer);
                try consumeTestRequestExpectIdentityEncoding(&stream_reader.interface);
                try writer.print(
                    "HTTP/1.1 200 OK\r\n" ++
                        "Content-Length: {d}\r\n" ++
                        "Content-Encoding: x-gzip\r\n" ++
                        "Connection: close\r\n\r\n",
                    .{test_x_gzip_body.len},
                );
                try writer.writeAll(test_x_gzip_body);
                try writer.flush();
            },
            .reuse_with_not_modified => {
                var read_buffer: [2048]u8 = undefined;
                var stream_reader = stream.reader(self.io, &read_buffer);
                const reader = &stream_reader.interface;

                try consumeTestRequest(reader);
                try writer.writeAll(
                    "HTTP/1.1 200 OK\r\n" ++
                        "Content-Length: 5\r\n" ++
                        "Connection: keep-alive\r\n\r\n" ++
                        "first",
                );
                try writer.flush();

                try consumeTestRequest(reader);
                // A 304 may advertise the selected representation's length,
                // but no body follows the header block.
                try writer.writeAll(
                    "HTTP/1.1 304 Not Modified\r\n" ++
                        "Content-Length: 5\r\n" ++
                        "Connection: keep-alive\r\n\r\n",
                );
                try writer.flush();

                try consumeTestRequest(reader);
                try writer.writeAll(
                    "HTTP/1.1 200 OK\r\n" ++
                        "Content-Length: 5\r\n" ++
                        "Connection: close\r\n\r\n" ++
                        "third",
                );
                try writer.flush();
            },
        }
    }
};

fn consumeTestRequest(reader: *std.Io.Reader) !void {
    while (true) {
        const line = (try reader.takeDelimiter('\n')) orelse return error.EndOfStream;
        if (std.mem.eql(u8, line, "\r")) return;
    }
}

fn consumeTestRequestExpectIdentityEncoding(reader: *std.Io.Reader) !void {
    var saw_identity_encoding = false;
    while (true) {
        const line = (try reader.takeDelimiter('\n')) orelse return error.EndOfStream;
        if (std.mem.eql(u8, line, "\r")) break;

        const trimmed = std.mem.trimEnd(u8, line, "\r");
        const separator = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const name = trimmed[0..separator];
        const value = std.mem.trim(u8, trimmed[separator + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "accept-encoding") and
            std.ascii.eqlIgnoreCase(value, "identity"))
        {
            saw_identity_encoding = true;
        }
    }
    if (!saw_identity_encoding) return error.ExpectedIdentityAcceptEncoding;
}

fn testDestinationPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    temporary: *std.testing.TmpDir,
) ![]u8 {
    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_length = try temporary.dir.realPath(io, &absolute_buffer);
    return std.fs.path.join(allocator, &.{ absolute_buffer[0..absolute_length], "repository.db" });
}

fn timeoutTestConfiguration() DownloadConfiguration {
    return .{
        .timeout_in_seconds = 2,
        .response_header_timeout_in_seconds = 1,
        .max_retries = 0,
        .retry_delay_secs = 0,
    };
}

test "downloadToFile copies a file URI to the destination" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;

    {
        var source_file = try temporary.dir.createFile(io, "nutcase.db", .{});
        defer source_file.close(io);
        try source_file.writeStreamingAll(io, "nutcase repository database");
        try source_file.setPermissions(io, .fromMode(0o600));
    }

    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_length = try temporary.dir.realPath(io, &absolute_buffer);
    const root = absolute_buffer[0..absolute_length];
    const source_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "nutcase.db" },
    );
    defer std.testing.allocator.free(source_path);
    const destination_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "downloaded.db" },
    );
    defer std.testing.allocator.free(destination_path);
    const file_uri = try std.fmt.allocPrint(
        std.testing.allocator,
        "file://{s}",
        .{source_path},
    );
    defer std.testing.allocator.free(file_uri);

    var downloader = CoreDownloader.init(std.testing.allocator, io, .{
        .max_retries = 0,
        .final_permissions = .fromMode(0o644),
    });
    defer downloader.deinit();
    downloader.quiet = true;

    switch (downloader.downloadToFile(file_uri, destination_path, true)) {
        .succes => {},
        else => return error.ExpectedSuccessfulFileDownload,
    }

    const contents = try std.Io.Dir.cwd().readFileAlloc(
        io,
        destination_path,
        std.testing.allocator,
        .limited(1024),
    );
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("nutcase repository database", contents);
    const downloaded_stat = try std.Io.Dir.cwd().statFile(io, destination_path, .{});
    try std.testing.expectEqual(@as(u32, 0o644), downloaded_stat.permissions.toMode() & 0o7777);
}

test "downloadToFile reports HTTP 404 as NotFound" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try TestHttpServer.init(io, .not_found);
    defer server.deinit();
    var server_future = try io.concurrent(TestHttpServer.serve, .{&server});
    defer _ = server_future.cancel(io) catch {};

    const url = try server.url(std.testing.allocator);
    defer std.testing.allocator.free(url);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const destination = try testDestinationPath(std.testing.allocator, io, &temporary);
    defer std.testing.allocator.free(destination);

    var downloader = CoreDownloader.init(std.testing.allocator, io, timeoutTestConfiguration());
    defer downloader.deinit();
    downloader.quiet = true;
    switch (downloader.downloadToFile(url, destination, true)) {
        .failure => |err| try std.testing.expectEqual(DownloadError.NotFound, err),
        else => return error.ExpectedNotFound,
    }
    try server_future.await(io);
}

test "downloadToFile preserves unsolicited x-gzip response bytes" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try TestHttpServer.init(io, .x_gzip_ignoring_identity);
    defer server.deinit();
    var server_future = try io.concurrent(TestHttpServer.serve, .{&server});
    defer _ = server_future.cancel(io) catch {};

    const url = try server.url(std.testing.allocator);
    defer std.testing.allocator.free(url);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const destination = try testDestinationPath(std.testing.allocator, io, &temporary);
    defer std.testing.allocator.free(destination);

    var downloader = CoreDownloader.init(std.testing.allocator, io, timeoutTestConfiguration());
    defer downloader.deinit();
    downloader.quiet = true;
    switch (downloader.downloadToFile(url, destination, true)) {
        .succes => {},
        else => return error.ExpectedSuccessfulDownload,
    }
    try server_future.await(io);

    const contents = try std.Io.Dir.cwd().readFileAlloc(
        io,
        destination,
        std.testing.allocator,
        .limited(1024),
    );
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualSlices(u8, test_x_gzip_body, contents);
}

test "response header timeout interrupts a server that never responds" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try TestHttpServer.init(io, .stall_headers);
    defer server.deinit();
    var server_future = try io.concurrent(TestHttpServer.serve, .{&server});
    defer _ = server_future.cancel(io) catch {};

    const url = try server.url(std.testing.allocator);
    defer std.testing.allocator.free(url);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const destination = try testDestinationPath(std.testing.allocator, io, &temporary);
    defer std.testing.allocator.free(destination);

    var downloader = CoreDownloader.init(std.testing.allocator, io, timeoutTestConfiguration());
    defer downloader.deinit();
    downloader.quiet = true;
    const started = std.Io.Timestamp.now(io, .awake);
    const result = downloader.downloadToFile(url, destination, true);
    const elapsed = started.durationTo(std.Io.Timestamp.now(io, .awake));

    switch (result) {
        .failure => |err| try std.testing.expectEqual(DownloadError.HeaderTimeout, err),
        else => return error.ExpectedHeaderTimeout,
    }
    try std.testing.expect(elapsed.nanoseconds < std.Io.Duration.fromSeconds(3).nanoseconds);
}

test "response body timeout interrupts a server that stalls after headers" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try TestHttpServer.init(io, .stall_body);
    defer server.deinit();
    var server_future = try io.concurrent(TestHttpServer.serve, .{&server});
    defer _ = server_future.cancel(io) catch {};

    const url = try server.url(std.testing.allocator);
    defer std.testing.allocator.free(url);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const destination = try testDestinationPath(std.testing.allocator, io, &temporary);
    defer std.testing.allocator.free(destination);

    var config = timeoutTestConfiguration();
    config.response_header_timeout_in_seconds = 2;
    config.response_body_timeout_in_seconds = 1;
    var downloader = CoreDownloader.init(std.testing.allocator, io, config);
    defer downloader.deinit();
    downloader.quiet = true;

    const started = std.Io.Timestamp.now(io, .awake);
    const result = downloader.downloadToFile(url, destination, true);
    const elapsed = started.durationTo(std.Io.Timestamp.now(io, .awake));

    switch (result) {
        .failure => |err| try std.testing.expectEqual(DownloadError.BodyTimeout, err),
        else => return error.ExpectedBodyTimeout,
    }
    try std.testing.expect(elapsed.nanoseconds < std.Io.Duration.fromSeconds(3).nanoseconds);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(io, destination, .{}),
    );
}

test "shared session reuses one connection across a bodyless 304 response" {
    // Force `Io.async` to execute inline. Timeout races must use the stronger
    // concurrent contract so their sleeping branches cannot stall fast I/O.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    const io = threaded.io();

    var server = try TestHttpServer.init(io, .reuse_with_not_modified);
    defer server.deinit();
    var server_future = try io.concurrent(TestHttpServer.serve, .{&server});
    defer _ = server_future.cancel(io) catch {};

    const url = try server.url(std.testing.allocator);
    defer std.testing.allocator.free(url);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const destination = try testDestinationPath(std.testing.allocator, io, &temporary);
    defer std.testing.allocator.free(destination);

    var session = DownloadSession.init(std.testing.allocator, io, 2, .prefer_ipv4);
    defer session.deinit();
    var config = timeoutTestConfiguration();
    config.file_durability = .caller_managed;
    const started = std.Io.Timestamp.now(io, .awake);

    var first = session.downloader(config);
    defer first.deinit();
    switch (first.downloadToFile(url, destination, true)) {
        .succes => {},
        else => return error.ExpectedSuccessfulDownload,
    }
    {
        var destination_file = try std.Io.Dir.cwd().openFile(io, destination, .{ .mode = .read_write });
        defer destination_file.close(io);
        try destination_file.setPermissions(io, .fromMode(0o600));
    }
    config.final_permissions = .fromMode(0o644);

    var second = session.downloader(config);
    defer second.deinit();
    switch (second.downloadToFile(url, destination, false)) {
        .skipped => |skipped| try std.testing.expectEqual(SkippedReason.NotModified, skipped.reason),
        else => return error.ExpectedNotModified,
    }
    const repaired_stat = try std.Io.Dir.cwd().statFile(io, destination, .{});
    try std.testing.expectEqual(@as(u32, 0o644), repaired_stat.permissions.toMode() & 0o7777);

    var third = session.downloader(config);
    defer third.deinit();
    switch (third.downloadToFile(url, destination, true)) {
        .succes => {},
        else => return error.ExpectedSuccessfulDownload,
    }
    const elapsed = started.durationTo(std.Io.Timestamp.now(io, .awake));

    try server_future.await(io);
    try std.testing.expect(elapsed.nanoseconds < std.Io.Duration.fromMilliseconds(1500).nanoseconds);
    const contents = try std.Io.Dir.cwd().readFileAlloc(io, destination, std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("third", contents);
}

test "quiet mirror candidates suppress error callbacks" {
    var callback_called = false;
    var downloader = CoreDownloader.init(std.testing.allocator, std.testing.io, .{});
    defer downloader.deinit();
    downloader.quiet = true;
    downloader.setEventCallback(struct {
        fn callback(context: ?*anyopaque, _: DownloadEvent) void {
            const called: *bool = @ptrCast(@alignCast(context.?));
            called.* = true;
        }
    }.callback, &callback_called);

    try downloader.emitEvent(.{
        .event_type = .Error,
        .download_error = DownloadError.NetworkError,
    });
    try std.testing.expect(!callback_called);
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

test "download failure explains the resource without exposing URL credentials" {
    const message = try failureMessage(std.testing.allocator, .{
        .event_type = .Error,
        .download_error = error.NetworkError,
        .destination_path = "/tmp/firefox.pkg.tar.zst",
        .url = "https://user:secret@mirror.example.org/firefox?token=private",
    });
    defer std.testing.allocator.free(message);
    try std.testing.expect(std.mem.startsWith(u8, message, "Could not download \"firefox.pkg.tar.zst\" from mirror.example.org."));
    try std.testing.expect(std.mem.indexOf(u8, message, "Check your internet connection") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, message, "private") == null);
    const file_error = try failureMessage(std.testing.allocator, .{ .event_type = .Error, .download_error = error.FileError });
    defer std.testing.allocator.free(file_error);
    try std.testing.expect(std.mem.indexOf(u8, file_error, "permissions") != null);
    try std.testing.expect(std.mem.indexOf(u8, file_error, "internet") == null);
}

pub const Queue = @import("queue.zig");
test {
    _ = Queue;
    _ = Sandbox;
    _ = HttpDate;
}

fn validRange(value: []const u8, start: u64, length: ?u64) bool {
    if (!std.mem.startsWith(u8, value, "bytes ")) return false;
    var parts = std.mem.tokenizeAny(u8, value[6..], "-/");
    const first = std.fmt.parseInt(u64, parts.next() orelse return false, 10) catch return false;
    const last = std.fmt.parseInt(u64, parts.next() orelse return false, 10) catch return false;
    const total = std.fmt.parseInt(u64, parts.next() orelse return false, 10) catch return false;
    return parts.next() == null and first == start and last >= first and last < total and last + 1 == total and length != null and length.? == last - first + 1;
}

pub const LockedAllocator = @import("LockedAllocator.zig");

fn curlCancelled(ctx: ?*anyopaque) callconv(.c) c_int {
    const self: *CoreDownloader = @ptrCast(@alignCast(ctx.?));
    return @intFromBool(self.isCancelled());
}
fn curlProgress(ctx: ?*anyopaque, downloaded: u64, total: u64) callconv(.c) void {
    const self: *CoreDownloader = @ptrCast(@alignCast(ctx.?));
    self.emitEvent(.{ .event_type = .Progress, .progress = makeProgress(downloaded, if (total == 0) null else total, null) }) catch {};
}

pub const WorkerProtocol = @import("worker_protocol.zig");

test "HTTP partials resume, restart on 200, reject invalid ranges, and preserve old files on truncation" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    const cases = .{
        .{ "HTTP/1.1 206 Partial Content\r\nContent-Length: 3\r\nContent-Range: bytes 2-4/5\r\nConnection: close\r\n\r\nllo", @as(?DownloadError, null) },
        .{ "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello", @as(?DownloadError, null) },
        .{ "HTTP/1.1 206 Partial Content\r\nContent-Length: 3\r\nContent-Range: bytes 1-3/5\r\nConnection: close\r\n\r\nllo", @as(?DownloadError, error.InvalidRange) },
        .{ "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nh", @as(?DownloadError, error.NetworkError) },
    };
    inline for (cases) |case| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const destination = try testDestinationPath(a, io, &temporary);
        defer a.free(destination);
        const partial = try std.fmt.allocPrint(a, "{s}.part", .{destination});
        defer a.free(partial);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = partial, .data = "he" });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = destination, .data = "old" });
        var server = try TestHttpServer.init(io, .raw);
        defer server.deinit();
        server.response = case[0];
        server.required_header = "range: bytes=2-";
        var serving = try io.concurrent(TestHttpServer.serve, .{&server});
        defer _ = serving.cancel(io) catch {};
        const url = try server.url(a);
        defer a.free(url);
        var core = CoreDownloader.init(a, io, .{ .resume_path = partial, .maximum_size = 5, .max_retries = 0 });
        defer core.deinit();
        core.quiet = true;
        const result = core.downloadToFile(url, destination, true);
        if (case[1]) |err| try std.testing.expectEqual(err, result.failure) else try std.testing.expect(result == .succes);
        try serving.await(io);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, destination, a, .limited(100));
        defer a.free(bytes);
        try std.testing.expectEqualStrings(if (case[1] == null) "hello" else "old", bytes);
    }
}

test "redirects preserve bytes and disk-full injection preserves the previous destination" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const destination = try testDestinationPath(a, io, &temporary);
    defer a.free(destination);
    var server = try TestHttpServer.init(io, .raw);
    defer server.deinit();
    server.response = "HTTP/1.1 302 Found\r\nLocation: /next.pkg.tar.zst\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    server.second_response = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nLast-Modified: Sun, 13 Sep 2020 12:26:40 GMT\r\nConnection: close\r\n\r\nhello";
    var serving = try io.concurrent(TestHttpServer.serve, .{&server});
    defer _ = serving.cancel(io) catch {};
    const url = try server.url(a);
    defer a.free(url);
    var core = CoreDownloader.init(a, io, .{ .max_retries = 0 });
    defer core.deinit();
    core.quiet = true;
    try std.testing.expect(core.downloadToFile(url, destination, true) == .succes);
    try std.testing.expect(std.mem.endsWith(u8, core.effective_url.?, "/next.pkg.tar.zst"));
    try std.testing.expectEqual(1600000000000000000, (try std.Io.Dir.cwd().statFile(io, destination, .{})).mtime.nanoseconds);
    try serving.await(io);
    const file_url = try std.fmt.allocPrint(a, "file://{s}", .{destination});
    defer a.free(file_url);
    const target = try std.fmt.allocPrint(a, "{s}.other", .{destination});
    defer a.free(target);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = target, .data = "old" });
    var vtable = io.vtable.*;
    vtable.operate = struct {
        fn operate(ctx: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
            if (operation == .file_write_streaming) return .{ .file_write_streaming = error.NoSpaceLeft };
            return std.testing.io.vtable.operate(ctx, operation);
        }
    }.operate;
    const failing: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var disk_full = CoreDownloader.init(a, failing, .{});
    defer disk_full.deinit();
    disk_full.quiet = true;
    try std.testing.expectEqual(error.FileError, disk_full.downloadToFile(file_url, target, true).failure);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, target, a, .limited(100));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("old", bytes);
}

test "disabled timeouts allow cancellable downloads with owned and shared clients" {
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    for ([_]bool{ false, true }) |shared| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const destination = try testDestinationPath(a, io, &temporary);
        defer a.free(destination);
        var server = try TestHttpServer.init(io, .delayed_response);
        defer server.deinit();
        var serving = try io.concurrent(TestHttpServer.serve, .{&server});
        defer _ = serving.cancel(io) catch {};
        const url = try server.url(a);
        defer a.free(url);
        var session = DownloadSession.init(a, io, 0, .prefer_ipv4);
        defer session.deinit();
        const config: DownloadConfiguration = .{
            .timeout_in_seconds = 0,
            .response_header_timeout_in_seconds = 0,
            .response_body_timeout_in_seconds = 0,
            .max_retries = 0,
        };
        var core = if (shared) session.downloader(config) else CoreDownloader.init(a, io, config);
        defer core.deinit();
        core.quiet = true;
        core.cancellation = struct {
            fn cancelled(_: ?*anyopaque) bool {
                return false;
            }
        }.cancelled;
        const result = core.downloadToFile(url, destination, true);
        if (result == .failure) return result.failure;
        try std.testing.expect(result == .succes);
        try serving.await(io);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, destination, a, .limited(100));
        defer a.free(bytes);
        try std.testing.expectEqualStrings("hello", bytes);
    }
}

test "cancellation interrupts stalled headers and bodies even with timeouts disabled" {
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    for ([_]TestServerMode{ .stall_headers, .stall_body }) |mode| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const destination = try testDestinationPath(a, io, &temporary);
        defer a.free(destination);
        var server = try TestHttpServer.init(io, mode);
        defer server.deinit();
        var serving = try io.concurrent(TestHttpServer.serve, .{&server});
        defer _ = serving.cancel(io) catch {};
        const url = try server.url(a);
        defer a.free(url);
        var flag: std.atomic.Value(bool) = .init(false);
        var core = CoreDownloader.init(a, io, .{ .timeout_in_seconds = 0, .response_header_timeout_in_seconds = 0, .response_body_timeout_in_seconds = 0 });
        defer core.deinit();
        core.quiet = true;
        core.cancellation_context = &flag;
        core.cancellation = struct {
            fn cancelled(ctx: ?*anyopaque) bool {
                const value: *std.atomic.Value(bool) = @ptrCast(@alignCast(ctx.?));
                return value.load(.acquire);
            }
        }.cancelled;
        var download = try io.concurrent(CoreDownloader.downloadToFile, .{ &core, url, destination, true });
        defer _ = download.cancel(io);
        try io.sleep(.fromMilliseconds(100), .awake);
        flag.store(true, .release);
        try std.testing.expectEqual(error.Cancelled, download.await(io).failure);
    }
}

pub fn supportsProtocol(protocol: []const u8) bool {
    return Curl.supportsProtocol(protocol);
}
test "curl adapter retains the pinned downloader protocol families" {
    for ([_][]const u8{ "dict", "file", "ftp", "ftps", "gopher", "gophers", "http", "https", "imap", "imaps", "mqtt", "mqtts", "pop3", "pop3s", "rtsp", "scp", "sftp", "smtp", "smtps", "telnet", "tftp", "ws", "wss" }) |protocol| try std.testing.expect(supportsProtocol(protocol));
}

const TestFtpServer = struct {
    io: std.Io,
    control: std.Io.net.Server,
    data: std.Io.net.Server,
    offset: usize = 0,
    missing: bool = false,
    fn serve(self: *TestFtpServer) !void {
        var stream = try self.control.accept(self.io);
        defer stream.close(self.io);
        var rb: [1024]u8 = undefined;
        var wb: [1024]u8 = undefined;
        var reader = stream.reader(self.io, &rb);
        var writer = stream.writer(self.io, &wb);
        try writer.interface.writeAll("220 private fixture\r\n");
        try writer.interface.flush();
        while (try reader.interface.takeDelimiter('\n')) |line| {
            if (std.mem.startsWith(u8, line, "USER")) try writer.interface.writeAll("331 password\r\n") else if (std.mem.startsWith(u8, line, "PASS")) try writer.interface.writeAll("230 ready\r\n") else if (std.mem.startsWith(u8, line, "PWD")) try writer.interface.writeAll("257 \"/\"\r\n") else if (std.mem.startsWith(u8, line, "EPSV")) {
                try writer.interface.print("229 Entering Extended Passive Mode (|||{d}|)\r\n", .{self.data.socket.address.getPort()});
            } else if (std.mem.startsWith(u8, line, "TYPE")) try writer.interface.writeAll("200 binary\r\n") else if (std.mem.startsWith(u8, line, "SIZE")) try writer.interface.writeAll("213 5\r\n") else if (std.mem.startsWith(u8, line, "MDTM")) try writer.interface.writeAll("213 20200913122640\r\n") else if (std.mem.startsWith(u8, line, "REST ")) {
                self.offset = try std.fmt.parseInt(usize, std.mem.trim(u8, line[5..], "\r "), 10);
                try writer.interface.writeAll("350 resume accepted\r\n");
            } else if (std.mem.startsWith(u8, line, "RETR")) {
                if (self.missing) {
                    try writer.interface.writeAll("550 file not found\r\n");
                    try writer.interface.flush();
                    continue;
                }
                try writer.interface.writeAll("150 data follows\r\n");
                try writer.interface.flush();
                var data = try self.data.accept(self.io);
                var buffer: [64]u8 = undefined;
                var output = data.writer(self.io, &buffer);
                try output.interface.writeAll("hello"[self.offset..]);
                try output.interface.flush();
                data.close(self.io);
                try writer.interface.writeAll("226 done\r\n");
            } else if (std.mem.startsWith(u8, line, "QUIT")) {
                try writer.interface.writeAll("221 bye\r\n");
                try writer.interface.flush();
                return;
            } else try writer.interface.writeAll("502 unsupported\r\n");
            try writer.interface.flush();
        }
    }
};
test "non-HTTP adapter downloads from a private FTP fixture" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server: TestFtpServer = .{ .io = io, .control = try address.listen(io, .{}), .data = try address.listen(io, .{}) };
    defer server.control.deinit(io);
    defer server.data.deinit(io);
    var serving = try io.concurrent(TestFtpServer.serve, .{&server});
    defer _ = serving.cancel(io) catch {};
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try testDestinationPath(a, io, &temporary);
    defer a.free(path);
    const url = try std.fmt.allocPrint(a, "ftp://127.0.0.1:{d}/package", .{server.control.socket.address.getPort()});
    defer a.free(url);
    var core = CoreDownloader.init(a, io, .{ .max_retries = 0 });
    defer core.deinit();
    core.quiet = true;
    try std.testing.expect(core.downloadToFile(url, path, true) == .succes);
    try std.testing.expectEqualStrings(url, core.effective_url.?);
    try serving.await(io);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(100));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("hello", bytes);
    try std.testing.expectEqual(1600000000000000000, (try std.Io.Dir.cwd().statFile(io, path, .{})).mtime.nanoseconds);
}

test "Zig curl adapter resumes FTP and preserves destinations on size and missing-file failures" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    for (0..3) |mode| {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var server: TestFtpServer = .{ .io = io, .control = try address.listen(io, .{}), .data = try address.listen(io, .{}), .missing = mode == 2 };
        defer server.control.deinit(io);
        defer server.data.deinit(io);
        var serving = try io.concurrent(TestFtpServer.serve, .{&server});
        defer _ = serving.cancel(io) catch {};
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const path = try testDestinationPath(a, io, &temporary);
        defer a.free(path);
        const partial = try std.fmt.allocPrint(a, "{s}.part", .{path});
        defer a.free(partial);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "old" });
        if (mode == 0) try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = partial, .data = "he" });
        const url = try std.fmt.allocPrint(a, "ftp://127.0.0.1:{d}/package", .{server.control.socket.address.getPort()});
        defer a.free(url);
        var core = CoreDownloader.init(a, io, .{ .max_retries = 0, .resume_path = if (mode == 0) partial else null, .maximum_size = if (mode == 1) 0 else 5 });
        defer core.deinit();
        core.quiet = true;
        const result = core.downloadToFile(url, path, true);
        switch (mode) {
            0 => try std.testing.expect(result == .succes),
            1 => try std.testing.expectEqual(error.SizeExceeded, result.failure),
            2 => try std.testing.expectEqual(error.NotFound, result.failure),
            else => unreachable,
        }
        try serving.await(io);
        if (mode == 0) try std.testing.expectEqual(2, server.offset);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(100));
        defer a.free(bytes);
        try std.testing.expectEqualStrings(if (mode == 0) "hello" else "old", bytes);
    }
}
