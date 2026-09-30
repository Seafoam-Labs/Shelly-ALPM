//! Cache acquisition operates on sealed bytes. Network workers never call Owner.
const std = @import("std");
const transport = @import("Shelly_Download");
const Owner = @import("Owner.zig");
const Package = @import("Package.zig");
const Policy = @import("SignaturePolicy.zig");
const Verification = @import("Verification.zig");
const Immutable = @import("ImmutableFile.zig");
const Callbacks = @import("Callbacks.zig");
const Publication = @import("Publication.zig");
const Sandbox = @import("DownloadSandbox.zig");
const OpenPgp = @import("OpenPgp.zig");
const DatabaseRef = @import("DatabaseRef.zig");
const DatabaseLock = @import("DatabaseLock.zig");
const Diagnostic = @import("Diagnostic.zig");
const Database = @import("Database.zig");

pub const File = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    snapshot: Immutable,
    validation: Package.Validation,
    signature: ?Immutable = null,
    cached: bool,
    transferred: u64,

    pub fn deinit(self: *File) void {
        self.allocator.free(self.path);
        self.snapshot.deinit();
        if (self.signature) |*signature| signature.deinit();
        self.* = undefined;
    }
};

pub const FileSet = struct {
    allocator: std.mem.Allocator,
    files: []File,

    pub fn deinit(self: *FileSet) void {
        for (self.files) |*file|
            file.deinit();
        self.allocator.free(self.files);
        self.* = undefined;
    }
};

pub const Request = struct {
    name: []const u8,
    servers: []const []const u8,
    cache_servers: []const []const u8 = &.{},
    /// Direct URL; servers are ignored.
    url: ?[]const u8 = null,
    package: ?*const Package = null,
    policy: Policy,
};

pub const Sizes = struct {
    bytes: u64 = 0,
    unknown: usize = 0,
    cached: usize = 0,
};

pub fn filename(name: []const u8) !void {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or
        std.mem.indexOfAny(u8, name, "/\\\x00\r\n") != null)
        return error.InvalidPackageFilename;
}

pub fn urlFilename(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    const uri = try std.Uri.parse(url);
    const encoded = switch (uri.path) {
        .raw => |v| v,
        .percent_encoded => |v| v,
    };
    if (encoded.len == 0 or encoded[encoded.len - 1] == '/') return error.InvalidPackageFilename;
    const basename: std.Uri.Component = .{ .percent_encoded = std.fs.path.basename(encoded) };
    const decoded = try basename.toRawMaybeAlloc(allocator);
    defer if (decoded.ptr != encoded.ptr and decoded.ptr != basename.percent_encoded.ptr)
        allocator.free(decoded);
    try filename(decoded);
    return allocator.dupe(u8, decoded);
}

fn check(owner: *Owner, io: std.Io, path: []const u8, request: Request) !File {
    try owner.checkCancelled();
    var snapshot = try Immutable.copy(io, path);
    errdefer snapshot.deinit();
    if (request.package) |pkg|
        if (pkg.compressed_size) |size| {
            const actual = try std.Io.Dir.cwd().statFile(io, snapshot.path(), .{});
            if (size != actual.size) return error.DownloadSizeMismatch;
        };
    const pkg = request.package;
    const embedded = if (pkg) |p| p.base64_signature != null else false;
    const bytes = if (request.policy.package != .disabled and !embedded)
        try OpenPgp.readDetached(
            owner.allocator,
            io,
            path,
        )
    else
        null;
    defer if (bytes) |value| owner.allocator.free(value);
    var signature: ?Immutable = if (bytes) |value| try Immutable.fromBytes(value) else null;
    errdefer if (signature) |*value| value.deinit();
    const validation = try Verification.check(owner.allocator, io, owner.verificationContext(), &snapshot, path, .{
        .requirement = request.policy.package,
        .trust = request.policy.package_trust,
        .detached_signature = .{ .bytes = bytes },
        .md5 = if (pkg) |p| p.md5_sum else null,
        .sha256 = if (pkg) |p| p.sha256_sum else null,
        .base64_signature = if (pkg) |p| p.base64_signature else null,
    }, &owner.last_verification);
    return .{
        .allocator = owner.allocator,
        .path = try owner.allocator.dupe(u8, path),
        .snapshot = snapshot,
        .signature = signature,
        .validation = validation,
        .cached = true,
        .transferred = 0,
    };
}

pub fn cached(owner: *Owner, io: std.Io, request: Request) !?File {
    try filename(request.name);
    const directories = owner.configuration.cache_directories;
    for (0..directories.len + @intFromBool(owner.fallback_cache != null)) |index| {
        const directory = if (index < directories.len) directories[index] else owner.fallback_cache.?;
        try owner.checkCancelled();
        const canonical = std.Io.Dir.cwd().realPathFileAlloc(io, directory, owner.allocator) catch |err| {
            if (err == error.OutOfMemory) return err;
            continue;
        };
        defer owner.allocator.free(canonical);
        const path = try std.fs.path.join(owner.allocator, &.{ canonical, request.name });
        defer owner.allocator.free(path);
        Publication.ensureReadable(io, owner.allocator, path) catch |err| {
            if (err != error.DatabaseRecoveryRequired) return err;
            try Publication.recover(io, owner.allocator, path);
        };
        // Validation can authorize removal of a corrupt pair, so cache lookup
        // needs the writer lock for its entire check/question/removal sequence.
        var guard = Publication.DirectoryLock.acquire(canonical, true, false) catch continue;
        defer guard.deinit();
        try Publication.ensureReadable(io, owner.allocator, path);
        var found = check(owner, io, path, request) catch |err| switch (err) {
            error.FileNotFound => continue,
            error.OutOfMemory,
            error.Cancelled,
            error.KeyImportDeclined,
            error.KeyImportFailed,
            error.KeyAcquisitionUnavailable,
            => return err,
            else => {
                var question: Callbacks.Question = .{ .corrupted = .{ .path = path, .reason = err } };
                try owner.askInternal(&question);
                if (question.corrupted.remove) {
                    try std.Io.Dir.cwd().deleteFile(io, path);
                    const sig = try std.fmt.allocPrint(owner.allocator, "{s}.sig", .{path});
                    defer owner.allocator.free(sig);
                    std.Io.Dir.cwd().deleteFile(io, sig) catch |failure|
                        if (failure != error.FileNotFound)
                            return failure;
                }
                continue;
            },
        };
        errdefer found.deinit();
        try owner.checkCancelled();
        return found;
    }
    return null;
}

const Job = struct {
    request: Request,
    stage: []const u8,
    path: []const u8,
    destination: []const u8,
    stage_lock: ?Publication.DirectoryLock = null,
    result: ?File = null,
    failure: ?anyerror = null,
    downloaded: std.atomic.Value(u64) = .init(0),
    total: std.atomic.Value(u64) = .init(0),
    retries: std.atomic.Value(u32) = .init(0),
    resuming: std.atomic.Value(bool) = .init(false),
    started: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    reported_start: bool = false,
    reported_done: bool = false,
    attempt: u32 = 1,
    next_server: usize = 0,
    force: bool = false,
    mtime: ?i128 = null,
    reported: u64 = 0,
    reported_retries: u32 = 0,
    needs_download: bool = true,
    unchanged: bool = false,
    database: bool = false,
    event_initialized: bool = false,
    event_completed: bool = false,
    effective_url: ?[]u8 = null,
};

pub const ServerState = struct {
    host: []const u8,
    errors: std.atomic.Value(i32) = .init(0),
};

const Batch = struct {
    owner: *Owner,
    allocator: std.mem.Allocator,
    io: std.Io,
    jobs: []Job,
    session: *transport.DownloadSession,
    finished: std.atomic.Value(bool) = .init(false),
    servers: []ServerState = &.{},

    fn serverState(self: *Batch, url: []const u8) ?*ServerState {
        const uri = std.Uri.parse(url) catch return null;
        const host = uri.host orelse return null;
        for (self.servers) |*entry|
            if (std.ascii.eqlIgnoreCase(entry.host, switch (host) {
                .raw => |v| v,
                .percent_encoded => |v| v,
            })) return entry;
        return null;
    }

    fn serverFailure(self: *Batch, url: []const u8, cache_server: bool, err: anyerror) void {
        const state = self.serverState(url) orelse return;
        if (err == error.HostNotFound) {
            state.errors.store(-1, .release);
            return;
        }
        if (!cache_server) {
            var current = state.errors.load(.acquire);
            while (current >= 0 and current < 3) {
                current = state.errors.cmpxchgWeak(current, current + 1, .acq_rel, .acquire) orelse return;
            }
        }
    }

    fn cancelled(ctx: ?*anyopaque) bool {
        const owner: *Owner = @ptrCast(@alignCast(ctx.?));
        return owner.cancelled.load(.acquire);
    }

    fn event(ctx: ?*anyopaque, e: transport.DownloadEvent) void {
        const job: *Job = @ptrCast(@alignCast(ctx.?));
        if (e.retrying) |resuming| {
            job.resuming.store(resuming, .release);
            _ = job.retries.fetchAdd(1, .release);
        }
        if (e.progress) |progress| {
            job.total.store(progress.bytes_total orelse 0, .release);
            job.downloaded.store(progress.bytes_downloaded, .release);
        }
    }

    fn execute(self: *Batch, index: usize) !void {
        const job = &self.jobs[index];
        if (!job.needs_download) return;
        defer job.done.store(true, .release);
        job.started.store(true, .release);
        if (self.owner.configuration.callbacks.fetch != null) self.dispatch();
        self.acquire(job) catch |err| {
            job.failure = err;
            return err;
        };
    }

    fn acquire(self: *Batch, job: *Job) !void {
        if (job.database) return self.acquireDatabase(job);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const sources = if (job.request.url) |url|
            try a.dupe([]const u8, &.{url})
        else
            try std.mem.concat(
                a,
                []const u8,
                &.{
                    job.request.cache_servers,
                    job.request.servers,
                },
            );
        if (sources.len == 0) return error.NoServers;
        var last: anyerror = error.DownloadFailed;
        for (sources, 0..) |source, attempt| {
            try self.owner.checkCancelled();
            const is_cache = job.request.url == null and attempt < job.request.cache_servers.len;
            if (self.serverState(source)) |state| {
                const errors = state.errors.load(.acquire);
                if (errors < 0 or (!is_cache and errors >= 3)) continue;
            }
            if (attempt != 0) {
                const partial = try std.fmt.allocPrint(a, "{s}.part", .{job.path});
                const resumed = if (std.Io.Dir.cwd().statFile(self.io, partial, .{})) |st|
                    st.size != 0
                else |_|
                    false;
                job.resuming.store(resumed, .release);
                _ = job.retries.fetchAdd(1, .release);
            }
            const url = if (job.request.url != null) source else try joinUrl(a, source, job.request.name);
            self.fetch(
                job,
                url,
                job.path,
                true,
                if (job.request.package) |p| p.compressed_size else null,
                null,
            ) catch |err| {
                if (err == error.NotModified) {
                    job.unchanged = true;
                } else {
                    if (err == error.Cancelled) return err;
                    self.serverFailure(source, is_cache, err);
                    last = err;
                    continue;
                }
            };
            const policy = job.request.policy.package;
            const embedded = if (job.request.package) |p| p.base64_signature != null else false;
            if (policy != .disabled and !embedded) {
                const sig = try std.fmt.allocPrint(a, "{s}.sig", .{job.path});
                // A signature from another mirror must never accompany new data.
                std.Io.Dir.cwd().deleteFile(self.io, sig) catch {};
                _ = self.fetch(
                    job,
                    try signatureUrl(
                        a,
                        signatureSource(
                            url,
                            job.effective_url,
                            self.owner.configuration.database_extension,
                        ),
                    ),
                    sig,
                    true,
                    16 * 1024,
                    null,
                ) catch |err| {
                    if (err == error.Cancelled) return err;
                    if (err != error.NotFound or policy == .required) {
                        last = if (err == error.NotFound) error.SignatureMissing else err;
                        continue;
                    }
                };
            }
            return;
        }
        return last;
    }

    fn fetch(
        self: *Batch,
        job: *Job,
        url: []const u8,
        path: []const u8,
        force: bool,
        maximum: ?u64,
        mtime: ?i128,
    ) !void {
        const is_payload = std.mem.eql(u8, path, job.path);
        if (is_payload) {
            if (job.effective_url) |previous| self.allocator.free(previous);
            job.effective_url = null;
        }
        if (self.owner.configuration.callbacks.fetch) |callback| {
            // Custom fetch batches run synchronously on the owning thread.
            self.owner.in_callback = true;
            const result = callback(
                self.owner.configuration.callbacks.fetch_context,
                .{
                    .url = url,
                    .destination_directory = job.stage,
                    .force = if (job.database) force else false,
                },
            ) catch |err| {
                self.owner.in_callback = false;
                return err;
            };
            self.owner.in_callback = false;
            try self.owner.checkCancelled();
            const st = try std.Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false });
            if (st.kind != .file) return error.NotRegularFile;
            if (maximum) |limit|
                if (st.size > limit) return error.DownloadSizeMismatch;
            if (result == .unchanged) return error.NotModified;
            if (std.mem.eql(u8, path, job.path)) job.downloaded.store(st.size, .release);
            return;
        }
        var signature_downloaded: std.atomic.Value(u64) = .init(0);
        if (Sandbox.applicable(self.owner))
            return Sandbox.fetch(
                self.owner,
                self.allocator,
                self.io,
                url,
                path,
                force,
                maximum,
                mtime,
                mtime == null and is_payload,
                if (is_payload)
                    &job.downloaded
                else
                    &signature_downloaded,
                if (is_payload) &job.effective_url else null,
            );
        var downloader = self.session.downloader(
            .{
                .address_family_policy = self.owner.configuration.address_family_policy,
                .timeout_in_seconds = if (self.owner.configuration.disable_download_timeout) 0 else 30,
                .response_header_timeout_in_seconds = if (self.owner.configuration.disable_download_timeout)
                    0
                else
                    30,
                .response_body_timeout_in_seconds = if (self.owner.configuration.disable_download_timeout)
                    0
                else
                    30,
                .max_retries = 1,
                .retry_delay_secs = 0,
                .maximum_size = maximum,
                .conditional_mtime = mtime,
                .resume_path = if (mtime == null and std.mem.eql(u8, path, job.path))
                    try std.fmt.allocPrint(
                        self.allocator,
                        "{s}.part",
                        .{path},
                    )
                else
                    null,
                .final_permissions = .fromMode(0o644),
            },
        );
        defer if (downloader.configuration.resume_path) |partial| self.allocator.free(partial);
        defer downloader.deinit();
        downloader.quiet = true;
        downloader.cancellation = cancelled;
        downloader.cancellation_context = self.owner;
        if (std.mem.eql(u8, path, job.path)) downloader.setEventCallback(event, job);
        const result = downloader.downloadToFile(url, path, force or mtime == null);
        if (is_payload and (result == .succes or result == .skipped)) {
            if (downloader.effective_url) |effective|
                job.effective_url = try self.allocator.dupe(u8, effective);
        }
        switch (result) {
            .succes => {},
            .skipped => return error.NotModified,
            .failure => |err| return err,
        }
    }

    fn acquireDatabase(self: *Batch, job: *Job) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const sig = try std.fmt.allocPrint(a, "{s}.sig", .{job.path});
        var last: anyerror = error.NoServers;
        while (job.next_server < job.request.servers.len) {
            try self.owner.checkCancelled();
            const server = job.request.servers[job.next_server];
            job.next_server += 1;
            if (job.next_server > 1) {
                job.resuming.store(false, .release);
                _ = job.retries.fetchAdd(1, .release);
            }
            job.unchanged = false;
            job.downloaded.store(0, .release);
            job.total.store(0, .release);
            if (job.mtime != null) try Publication.copy(self.io, job.destination, job.path);
            const url = try joinUrl(a, server, job.request.name);
            self.fetch(job, url, job.path, job.force, null, job.mtime) catch |err| {
                if (err == error.NotModified and job.mtime != null) job.unchanged = true else {
                    if (err == error.Cancelled) return err;
                    last = err;
                    continue;
                }
            };
            std.Io.Dir.cwd().deleteFile(self.io, sig) catch {};
            if (job.request.policy.database != .disabled) {
                self.fetch(
                    job,
                    try signatureUrl(
                        a,
                        signatureSource(
                            url,
                            job.effective_url,
                            self.owner.configuration.database_extension,
                        ),
                    ),
                    sig,
                    true,
                    16 * 1024,
                    null,
                ) catch |err| {
                    if (err == error.Cancelled) return err;
                    if (err != error.NotFound or job.request.policy.database == .required) {
                        last = err;
                        continue;
                    }
                };
            }
            return;
        }
        return last;
    }

    /// Only the owner pumps public callbacks, including when concurrency is
    /// unavailable or a custom fetch implementation owns the transport.
    fn wait(self: *Batch) void {
        self.finished.store(false, .release);
        if (self.owner.configuration.callbacks.fetch != null) {
            for (0..self.jobs.len) |i| {
                self.execute(i) catch {};
                self.dispatch();
            }
        } else {
            var future = self.io.concurrent(Batch.run, .{self}) catch null;
            if (future) |*running| {
                while (!self.finished.load(.acquire)) {
                    self.dispatch();
                    self.io.sleep(.fromMilliseconds(20), .awake) catch self.owner.requestCancellation();
                }
                running.await(self.io);
            } else self.run();
            self.dispatch();
        }
    }

    fn run(self: *Batch) void {
        defer self.finished.store(true, .release);
        transport.Queue.run(
            self.io,
            @intCast(@min(self.owner.configuration.parallel_downloads, 255)),
            self.jobs.len,
            self,
            execute,
        ) catch {};
    }

    fn dispatch(self: *Batch) void {
        for (self.jobs) |*job| {
            if (!job.needs_download or job.reported_done or !job.started.load(.acquire)) continue;
            // Snapshot completion before byte counters. If the worker finishes
            // during this dispatch, leave its terminal event to the next pass
            // so no late progress can reopen a completed child operation.
            const done = job.done.load(.acquire);
            if (!job.reported_start) {
                job.reported_start = true;
                self.owner.downloadEvent(
                    .{ .started = .{ .name = job.request.name, .attempt = job.attempt } },
                );
            }
            const retry_count = job.retries.load(.acquire);
            while (job.reported_retries < retry_count) : (job.reported_retries += 1)
                self.owner.downloadEvent(
                    .{
                        .retry = .{
                            .name = job.request.name,
                            .attempt = job.attempt,
                            .resuming = job.resuming.load(.acquire),
                        },
                    },
                );
            const progress = job.downloaded.load(.acquire);
            if (progress != job.reported) {
                const observed_total = job.total.load(.acquire);
                const expected_total = if (job.request.package) |p| p.compressed_size else null;
                self.owner.downloadEvent(
                    .{
                        .progress = .{
                            .name = job.request.name,
                            .attempt = job.attempt,
                            .downloaded = progress,
                            .total = expected_total orelse
                                (if (observed_total != 0)
                                    observed_total
                                else
                                    null),
                        },
                    },
                );
                job.reported = progress;
            }
            // Acquire pairs all non-atomic result fields with the worker's
            // release, and never read them while its signature request runs.
            if (done) {
                job.reported_done = true;
                self.owner.downloadEvent(
                    .{
                        .transferred = .{
                            .name = job.request.name,
                            .attempt = job.attempt,
                            .downloaded = job.downloaded.load(.acquire),
                            .result = if (job.failure != null)
                                .failed
                            else if (job.unchanged) .unchanged else .updated,
                        },
                    },
                );
            }
        }
    }
};

pub fn acquire(owner: *Owner, io: std.Io, requests: []const Request) ![]File {
    var arena = std.heap.ArenaAllocator.init(owner.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const jobs = try a.alloc(Job, requests.len);
    var initialized: usize = 0;
    defer for (jobs[0..initialized]) |*job| {
        if (job.effective_url) |url| owner.allocator.free(url);
        if (job.event_initialized and !job.event_completed)
            owner.downloadEvent(
                .{
                    .completed = .{
                        .name = job.request.name,
                        .downloaded = job.downloaded.load(.acquire),
                        .result = .failed,
                    },
                },
            );
        if (job.result) |*result| result.deinit();
        if (job.stage_lock) |*lock| {
            if (job.failure == null) std.Io.Dir.cwd().deleteTree(io, job.stage) catch {};
            lock.deinit();
        }
    };
    var directory: ?[]const u8 = null;
    for (requests, jobs) |request, *job| {
        try owner.checkCancelled();
        try filename(request.name);
        for (jobs[0..initialized]) |previous|
            if (std.mem.eql(u8, previous.request.name, request.name))
                return error.DuplicateFilename;
        job.* = .{
            .request = request,
            .stage = "",
            .path = "",
            .destination = "",
        };
        initialized += 1;
        job.result = try cached(owner, io, request);
        job.needs_download = job.result == null;
        if (!job.needs_download) continue;
        if (directory == null) directory = try writableCache(owner, io, a);
        const stage = try stageDirectory(a, io, directory.?, request.name);
        job.stage = stage;
        job.path = try std.fs.path.join(a, &.{ stage, request.name });
        job.destination = try std.fs.path.join(a, &.{ directory.?, request.name });
        job.stage_lock = try Publication.DirectoryLock.acquire(stage, true, true);
        try Publication.recover(io, owner.allocator, job.destination);
        job.event_initialized = true;
        owner.downloadEvent(.{ .init = .{ .name = request.name, .optional = false } });
    }
    var thread_safe: transport.LockedAllocator = .{ .child_allocator = owner.allocator, .io = io };
    var session = transport.DownloadSession.init(
        thread_safe.allocator(),
        io,
        if (owner.configuration.disable_download_timeout)
            0
        else
            30,
        owner.configuration.address_family_policy,
    );
    defer session.deinit();
    const servers = &owner.download_servers;
    for (requests) |request| {
        for ([_][]const []const u8{
            request.servers,
            request.cache_servers,
            if (request.url) |url| &.{url} else &.{},
        }) |sources|
            for (sources) |source| {
                const uri = std.Uri.parse(source) catch continue;
                const host = uri.host orelse continue;
                const name = switch (host) {
                    .raw => |v| v,
                    .percent_encoded => |v| v,
                };
                var found = false;
                for (servers.items) |entry|
                    if (std.ascii.eqlIgnoreCase(entry.host, name)) {
                        found = true;
                        break;
                    };
                if (!found) {
                    const owned = try owner.allocator.dupe(u8, name);
                    errdefer owner.allocator.free(owned);
                    try servers.append(owner.allocator, .{ .host = owned });
                }
            };
    }
    var batch: Batch = .{
        .owner = owner,
        .allocator = thread_safe.allocator(),
        .io = io,
        .jobs = jobs,
        .session = &session,
        .servers = servers.items,
    };
    batch.wait();
    var failure: ?anyerror = null;
    for (jobs, 0..) |*job, index| {
        if (!job.needs_download) continue;
        if (!job.done.load(.acquire))
            job.failure = if (owner.cancelled.load(.acquire))
                error.Cancelled
            else
                error.DownloadFailed;
        if (job.failure == null) owner.checkCancelled() catch |err| {
            job.failure = err;
        };
        if (job.failure == null) {
            processing(owner, job, .verification, .start, index + 1, jobs.len);
            job.result = check(owner, io, job.path, job.request) catch |err| blk: {
                job.failure = err;
                break :blk null;
            };
            processing(
                owner,
                job,
                .verification,
                if (job.failure == null) .done else .failed,
                index + 1,
                jobs.len,
            );
            if (job.failure == null) owner.checkCancelled() catch |err| {
                job.failure = err;
            };
            if (job.result) |*result|
                if (job.failure == null) {
                    processing(owner, job, .publication, .start, index + 1, jobs.len);
                    // A progress callback may cancel before the durable write.
                    owner.checkCancelled() catch |err| {
                        job.failure = err;
                    };
                    if (job.failure == null) publishCache(owner, io, result, job.path, job.destination) catch |err| {
                        job.failure = err;
                    };
                    processing(
                        owner,
                        job,
                        .publication,
                        if (job.failure == null) .done else .failed,
                        index + 1,
                        jobs.len,
                    );
                    result.cached = false;
                    result.transferred = job.downloaded.load(.acquire);
                };
        }
        job.event_completed = true;
        owner.downloadEvent(
            .{
                .completed = .{
                    .name = job.request.name,
                    .downloaded = job.downloaded.load(.acquire),
                    .result = if (job.failure != null)
                        .failed
                    else if (job.unchanged) .unchanged else .updated,
                },
            },
        );
        if (job.failure) |err| {
            if (failure == null or err == error.Cancelled) failure = err;
        }
    }
    if (failure) |err| return err;
    try owner.checkCancelled();
    const results = try owner.allocator.alloc(File, jobs.len);
    for (jobs, results) |*job, *result| {
        result.* = job.result.?;
        job.result = null;
    }
    return results;
}

fn processing(
    owner: *Owner,
    job: *const Job,
    stage: @FieldType(@FieldType(Callbacks.Download, "processing"), "stage"),
    boundary: Callbacks.Boundary,
    position: usize,
    total: usize,
) void {
    owner.downloadEvent(
        .{
            .processing = .{
                .name = job.request.name,
                .stage = stage,
                .boundary = boundary,
                .position = position,
                .total = total,
            },
        },
    );
}

fn publishCache(
    owner: *Owner,
    io: std.Io,
    result: *File,
    _: []const u8,
    destination: []const u8,
) !void {
    // Publish from the sealed copy; replacing staging during verification cannot
    // change the bytes subsequently consumed by preflight or copied to cache.
    const new_path = try owner.allocator.dupe(u8, destination);
    errdefer owner.allocator.free(new_path);
    try Publication.publish(
        io,
        owner.allocator,
        result.snapshot.path(),
        if (result.signature) |*sig|
            sig.path()
        else
            null,
        destination,
    );
    owner.allocator.free(result.path);
    result.path = new_path;
}

pub fn joinUrl(a: std.mem.Allocator, server: []const u8, name: []const u8) ![]const u8 {
    try filename(name);
    var writer: std.Io.Writer.Allocating = .init(a);
    defer writer.deinit();
    // Repository filenames are literal path segments. Escape reserved bytes
    // too: S3-backed mirrors interpret an unescaped '+' as a space.
    try (std.Uri.Component{ .raw = name }).formatEscaped(&writer.writer);
    const encoded = writer.written();
    return std.fmt.allocPrint(a, "{s}/{s}", .{ std.mem.trimEnd(u8, server, "/"), encoded });
}

pub fn signatureUrl(a: std.mem.Allocator, url: []const u8) ![]const u8 {
    const end = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    return std.fmt.allocPrint(a, "{s}.sig{s}", .{ url[0..end], url[end..] });
}

pub fn signatureSource(original: []const u8, effective: ?[]const u8, extension: []const u8) []const u8 {
    const url = effective orelse return original;
    const uri = std.Uri.parse(url) catch return original;
    const path = switch (uri.path) {
        .raw => |value| value,
        .percent_encoded => |value| value,
    };
    const name = std.fs.path.basename(path);
    return if (std.mem.indexOf(u8, name, extension) != null or std.mem.indexOf(u8, name, ".pkg") != null)
        url
    else
        original;
}

fn writableCache(owner: *Owner, io: std.Io, a: std.mem.Allocator) ![]const u8 {
    for (owner.configuration.cache_directories) |directory| {
        std.Io.Dir.cwd().createDirPath(io, directory) catch continue;
        const probe = try uniquePath(a, io, directory, ".rlpm-write");
        const file = std.Io.Dir.cwd().createFile(io, probe, .{ .exclusive = true }) catch continue;
        file.close(io);
        try std.Io.Dir.cwd().deleteFile(io, probe);
        return std.Io.Dir.cwd().realPathFileAlloc(io, directory, a);
    }
    const fallback = try std.fmt.allocPrint(a, "/tmp/rlpm-cache-{d}", .{std.c.getuid()});
    try Publication.privateDirectory(fallback);
    if (owner.fallback_cache == null) owner.fallback_cache = try owner.allocator.dupe(u8, fallback);
    return fallback;
}

pub fn stageDirectory(
    a: std.mem.Allocator,
    _: std.Io,
    directory: []const u8,
    name: []const u8,
) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(name, &digest, .{});
    const path = try std.fmt.allocPrint(
        a,
        "{s}/.rlpm-{s}",
        .{ directory, std.fmt.bytesToHex(digest, .lower) },
    );
    try Publication.privateDirectory(path);
    return path;
}

pub fn uniquePath(
    a: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    name: []const u8,
) ![]const u8 {
    var random: [8]u8 = undefined;
    io.random(&random);
    return std.fmt.allocPrint(a, "{s}/{s}-{s}", .{ directory, name, std.fmt.bytesToHex(random, .lower) });
}

pub const Refresh = struct {
    reference: DatabaseRef,
    outcome: enum { updated, unchanged, skipped, failed },
    cause: ?anyerror = null,
};

pub const RefreshResult = struct {
    allocator: std.mem.Allocator,
    databases: []Refresh,

    pub fn deinit(self: *RefreshResult) void {
        self.allocator.free(self.databases);
        self.* = undefined;
    }

    pub fn check(self: RefreshResult) !void {
        for (self.databases) |db|
            if (db.cause) |err| return err;
    }
};

pub fn refresh(owner: *Owner, io: std.Io, force: bool) !RefreshResult {
    try owner.checkCancelled();
    var lock = try DatabaseLock.acquire(owner.allocator, owner.lock_file);
    var lock_live = true;
    defer if (lock_live) lock.release(owner.allocator) catch {};
    const entries = try owner.allocator.alloc(Refresh, owner.sync_databases.items.len);
    errdefer owner.allocator.free(entries);
    var arena = std.heap.ArenaAllocator.init(owner.allocator);
    defer arena.deinit();
    const jobs = try arena.allocator().alloc(Job, entries.len);
    // All jobs are initialized before cleanup, including skipped repositories.
    for (owner.sync_databases.items, entries, jobs) |*db, *entry, *job| {
        entry.* = .{ .reference = db.identity.?, .outcome = .skipped };
        job.* = .{
            .database = true,
            .request = .{
                .name = std.fs.path.basename(db.path),
                .servers = db.servers.items,
                .policy = db.signature_policy,
            },
            .stage = "",
            .path = "",
            .destination = db.path,
            .force = force,
            .needs_download = false,
        };
    }
    defer for (jobs) |*job| {
        if (job.effective_url) |url| owner.allocator.free(url);
        if (job.event_initialized and !job.event_completed)
            owner.downloadEvent(
                .{
                    .completed = .{
                        .name = job.request.name,
                        .downloaded = job.downloaded.load(.acquire),
                        .result = .failed,
                    },
                },
            );
        if (job.stage_lock) |*guard| {
            std.Io.Dir.cwd().deleteTree(io, job.stage) catch {};
            guard.deinit();
        }
    };
    var thread_safe: transport.LockedAllocator = .{ .child_allocator = owner.allocator, .io = io };
    var session = transport.DownloadSession.init(
        thread_safe.allocator(),
        io,
        if (owner.configuration.disable_download_timeout)
            0
        else
            30,
        owner.configuration.address_family_policy,
    );
    defer session.deinit();
    var batch: Batch = .{
        .owner = owner,
        .allocator = thread_safe.allocator(),
        .io = io,
        .jobs = jobs,
        .session = &session,
    };
    owner.transactionEvent(.{ .phase = .{ .phase = .database_retrieve, .boundary = .start } });
    for (owner.sync_databases.items, jobs, entries) |*db, *job, *entry| {
        if (!db.usage.sync) continue;
        prepareDatabase(owner, io, arena.allocator(), job) catch |err| {
            entry.outcome = .failed;
            entry.cause = err;
            continue;
        };
        job.needs_download = true;
        job.event_initialized = true;
        owner.downloadEvent(.{ .init = .{ .name = job.request.name, .optional = false } });
    }
    while (true) {
        batch.wait();
        var retry = false;
        for (owner.sync_databases.items, jobs, entries, 0..) |*db, *job, *entry, index| {
            if (!job.needs_download) continue;
            if (!job.done.load(.acquire))
                job.failure = if (owner.cancelled.load(.acquire))
                    error.Cancelled
                else
                    error.DownloadFailed;
            if (job.failure == null) {
                const accepted = acceptDatabase(owner, io, db, job, &lock, index + 1, jobs.len) catch |err| blk: {
                    job.failure = err;
                    break :blk true; // Fatal errors must not try another mirror.
                };
                if (!accepted and job.next_server < job.request.servers.len and
                    !owner.cancelled.load(.acquire))
                {
                    // The rejected candidate's transfer already finished. A new
                    // round gets a fresh visible attempt, with no stale counters.
                    job.attempt += 1;
                    job.failure = null;
                    job.started.store(false, .release);
                    job.done.store(false, .release);
                    job.downloaded.store(0, .release);
                    job.total.store(0, .release);
                    job.reported = 0;
                    job.reported_start = false;
                    job.reported_done = false;
                    retry = true;
                    continue;
                }
            }
            job.needs_download = false;
            job.event_completed = true;
            entry.outcome = if (job.failure != null)
                .failed
            else if (db.last_refresh_updated)
                .updated
            else
                .unchanged;
            entry.cause = job.failure;
            owner.downloadEvent(
                .{
                    .completed = .{
                        .name = job.request.name,
                        .downloaded = job.downloaded.load(.acquire),
                        .result = if (job.failure != null)
                            .failed
                        else if (db.last_refresh_updated)
                            .updated
                        else
                            .unchanged,
                    },
                },
            );
        }
        if (!retry) break;
    }
    var failed = false;
    for (entries) |entry|
        if (entry.cause) |err| {
            failed = true;
            if (owner.last_diagnostic == null)
                owner.last_diagnostic = Diagnostic.init(
                    .refresh,
                    err,
                    entry.reference,
                );
        };
    lock_live = false;
    try lock.release(owner.allocator);
    owner.transactionEvent(
        .{
            .phase = .{
                .phase = .database_retrieve,
                .boundary = if (failed) .failed else .done,
            },
        },
    );
    return .{ .allocator = owner.allocator, .databases = entries };
}

fn prepareDatabase(owner: *Owner, io: std.Io, a: std.mem.Allocator, job: *Job) !void {
    try owner.checkCancelled();
    const parent = std.fs.path.dirname(job.destination).?;
    try std.Io.Dir.cwd().createDirPath(io, parent);
    try Publication.recover(io, owner.allocator, job.destination);
    job.stage = try stageDirectory(a, io, parent, job.request.name);
    job.path = try std.fs.path.join(a, &.{ job.stage, job.request.name });
    job.stage_lock = try Publication.DirectoryLock.acquire(job.stage, true, true);
    if (!job.force) {
        const st = std.Io.Dir.cwd().statFile(io, job.destination, .{}) catch return;
        job.mtime = st.mtime.nanoseconds;
    }
}

/// False means candidate validation rejected this mirror; all mutations and
/// trust questions stay on the owner thread after acquisition workers join.
fn acceptDatabase(
    owner: *Owner,
    io: std.Io,
    db: *Database,
    job: *Job,
    lock: *const DatabaseLock,
    position: usize,
    total: usize,
) !bool {
    try owner.checkCancelled();
    processing(owner, job, .verification, .start, position, total);
    var verified = false;
    errdefer if (!verified) processing(owner, job, .verification, .failed, position, total);
    try owner.checkCancelled();
    var snapshot = try Immutable.copy(io, job.path);
    defer snapshot.deinit();
    const signature_bytes = if (db.signature_policy.database != .disabled)
        try OpenPgp.readDetached(
            owner.allocator,
            io,
            job.path,
        )
    else
        null;
    defer if (signature_bytes) |bytes| owner.allocator.free(bytes);
    var signature: ?Immutable = if (signature_bytes) |bytes| try Immutable.fromBytes(bytes) else null;
    defer if (signature) |*file| file.deinit();
    var candidate = try db.copyRegistration(db.path, db.signature_policy);
    defer candidate.deinit();
    candidate.populateSealed(io, owner.verificationContext(), &snapshot, .{ .bytes = signature_bytes }) catch |err| {
        Verification.clearReport(&db.last_verification);
        db.last_verification = candidate.last_verification;
        candidate.last_verification = null;
        db.last_load_error = err;
        job.failure = err;
        processing(owner, job, .verification, .failed, position, total);
        return false;
    };
    verified = true;
    processing(owner, job, .verification, .done, position, total);
    try owner.checkCancelled();
    try lock.validate();
    // Verify and parse exactly the sealed bytes subsequently published.
    var old_signature_invalid = false;
    const old_signature = if (db.signature_policy.database != .disabled) OpenPgp.readDetached(
        owner.allocator,
        io,
        db.path,
    ) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        old_signature_invalid = true;
        break :blk null;
    } else null;
    defer if (old_signature) |bytes| owner.allocator.free(bytes);
    const same_signature = !old_signature_invalid and
        if (signature_bytes) |bytes|
            old_signature != null and
                std.mem.eql(u8, bytes, old_signature.?)
        else
            old_signature == null;
    if (!job.unchanged or !same_signature) {
        processing(owner, job, .publication, .start, position, total);
        try owner.checkCancelled();
        try lock.validate();
        errdefer processing(owner, job, .publication, .failed, position, total);
        try Publication.publish(
            io,
            owner.allocator,
            snapshot.path(),
            if (signature) |*file| file.path() else null,
            db.path,
        );
        if (!job.unchanged) db.takeCache(&candidate);
        processing(owner, job, .publication, .done, position, total);
    }
    if (job.unchanged) {
        Verification.clearReport(&db.last_verification);
        db.last_verification = candidate.last_verification;
        candidate.last_verification = null;
        db.last_load_error = null;
    }
    db.last_refresh_updated = !job.unchanged;
    return true;
}

/// Effective bytes remaining, after policy-aware cache checks. Partial lengths
/// are estimates only; completed bytes always undergo integrity verification.
pub fn sizes(owner: *Owner, io: std.Io, requests: []const Request) !Sizes {
    var result: Sizes = .{};
    var arena = std.heap.ArenaAllocator.init(owner.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (requests) |request| {
        if (try cached(owner, io, request)) |value| {
            var file = value;
            file.deinit();
            result.cached += 1;
            continue;
        }
        const size = if (request.package) |pkg| pkg.compressed_size else null;
        if (size) |total| {
            var partial_size: u64 = 0;
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(request.name, &digest, .{});
            for (owner.configuration.cache_directories) |directory| {
                const path = try std.fmt.allocPrint(
                    a,
                    "{s}/.rlpm-{s}/{s}.part",
                    .{
                        directory,
                        std.fmt.bytesToHex(digest, .lower),
                        request.name,
                    },
                );
                const st = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch continue;
                if (st.kind == .file and st.size < total) {
                    partial_size = st.size;
                    break;
                }
            }
            result.bytes = try std.math.add(u64, result.bytes, total - partial_size);
        } else result.unknown += 1;
    }
    return result;
}
