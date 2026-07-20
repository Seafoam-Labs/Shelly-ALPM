const std = @import("std");
const HttpClient = @import("../shared/http_client.zig");
const bindings = @import("bindings.zig");
const cache_manager = @import("cache_manager.zig");
const alpm_manager = @import("manager.zig");
const shared_downloader = @import("../shared/downloader.zig");
const operation_api = @import("operation_context");

pub const arch_linux_archive = "https://archive.archlinux.org/packages";
pub const cachyos_archive = "https://archive.cachyos.org/archive/cachyos";
pub const cachyos_v3_archive = "https://archive.cachyos.org/archive/cachyos-v3";
pub const cachyos_v4_archive = "https://archive.cachyos.org/archive/cachyos-v4";

const max_default_listing_size = 16 * 1024 * 1024;
var temporary_file_counter: std.atomic.Value(u64) = .init(0);

pub const Error = error{
    OutOfMemory,
    InvalidPackageName,
    DirectoryReadFailed,
    RemoteListingFailed,
    TargetNotFound,
    InvalidCandidate,
    LocalPackageMissing,
    TempFileFailed,
    DownloadFailed,
    Cancelled,
};

pub const DiscoveryError = Error || alpm_manager.QueryError;
pub const InstallError = Error || alpm_manager.TransactionError;

pub const Source = enum {
    local_cache,
    arch_linux,
    cachyos,
    cachyos_v3,
    cachyos_v4,

    pub fn is_remote(self: Source) bool {
        return self != .local_cache;
    }
};

/// An owned package version available for downgrade. `location` is a local
/// path for `.local_cache` candidates and an HTTP(S) URL for archive sources.
pub const DowngradeCandidate = struct {
    name: [:0]u8,
    version: [:0]u8,
    release: [:0]u8,
    version_release: [:0]u8,
    architecture: [:0]u8,
    filename: []u8,
    location: []u8,
    source: Source,
    is_installed: bool,
    size: ?u64,

    pub fn deinit(self: *DowngradeCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.release);
        allocator.free(self.version_release);
        allocator.free(self.architecture);
        allocator.free(self.filename);
        allocator.free(self.location);
        self.* = undefined;
    }

    pub fn deinitSlice(allocator: std.mem.Allocator, candidates: []DowngradeCandidate) void {
        for (candidates) |*candidate| candidate.deinit(allocator);
        allocator.free(candidates);
    }
};

pub const ArchiveEndpoint = struct {
    source: Source,
    url: []u8,

    pub fn deinit(self: *ArchiveEndpoint, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        self.* = undefined;
    }

    pub fn deinitSlice(allocator: std.mem.Allocator, endpoints: []ArchiveEndpoint) void {
        for (endpoints) |*endpoint| endpoint.deinit(allocator);
        allocator.free(endpoints);
    }
};

/// A local package path prepared for ALPM installation. Remote packages are
/// deleted when this value is deinitialized; local cache packages are retained.
pub const PreparedPackage = struct {
    path: []u8,
    temporary: bool,

    pub fn deinit(self: *PreparedPackage, allocator: std.mem.Allocator, io: std.Io) void {
        if (self.temporary) std.Io.Dir.cwd().deleteFile(io, self.path) catch {};
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const Options = struct {
    cache_directory_fallback: []const u8 = "/var/cache/pacman/pkg",
    temporary_directory: []const u8 = "/tmp",
    arch_linux_base_url: []const u8 = arch_linux_archive,
    cachyos_base_url: []const u8 = cachyos_archive,
    cachyos_v3_base_url: []const u8 = cachyos_v3_archive,
    cachyos_v4_base_url: []const u8 = cachyos_v4_archive,
    max_listing_size: usize = max_default_listing_size,
    download_configuration: shared_downloader.DownloadConfiguration = .default(),
};

pub const ArchiveManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    http_client: HttpClient,
    download_event_callback: ?shared_downloader.DownloadEventCallback = null,
    download_event_context: ?*anyopaque = null,
    operation_context: ?*operation_api.OperationContext = null,
    parent_operation: ?*const operation_api.Operation = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) ArchiveManager {
        return .{
            .allocator = allocator,
            .io = io,
            .options = options,
            .http_client = .{ .allocator = allocator, .io = io },
        };
    }

    pub fn deinit(self: *ArchiveManager) void {
        self.http_client.deinit();
    }

    /// Borrows a context for archive HTTP and package downloads.
    pub fn setOperationContext(self: *ArchiveManager, context: ?*operation_api.OperationContext) void {
        self.operation_context = context;
    }

    pub fn setParentOperation(self: *ArchiveManager, parent: ?*const operation_api.Operation) void {
        self.parent_operation = parent;
        if (parent) |operation| self.operation_context = operation.context;
    }

    pub fn set_download_event_callback(
        self: *ArchiveManager,
        callback: shared_downloader.DownloadEventCallback,
        context: ?*anyopaque,
    ) void {
        self.download_event_callback = callback;
        self.download_event_context = context;
    }

    /// Builds the exact archive endpoints used for a package lookup.
    pub fn get_archive_endpoints(
        self: *ArchiveManager,
        package_name: []const u8,
        include_cachyos: bool,
        include_v3: bool,
        include_v4: bool,
    ) Error![]ArchiveEndpoint {
        try self.checkCancelled();
        if (!isValidPackageName(package_name)) return Error.InvalidPackageName;

        var endpoints: std.ArrayList(ArchiveEndpoint) = .empty;
        errdefer deinitEndpointList(self.allocator, &endpoints);

        const encoded_name = percentEncodePathSegment(self.allocator, package_name) catch
            return Error.OutOfMemory;
        defer self.allocator.free(encoded_name);
        const arch_url = std.fmt.allocPrint(
            self.allocator,
            "{s}/{c}/{s}/",
            .{ std.mem.trimEnd(u8, self.options.arch_linux_base_url, "/"), package_name[0], encoded_name },
        ) catch return Error.OutOfMemory;
        try appendEndpoint(self.allocator, &endpoints, .arch_linux, arch_url);

        if (include_cachyos) {
            try appendBaseEndpoint(self.allocator, &endpoints, .cachyos, self.options.cachyos_base_url);
            if (include_v4) try appendBaseEndpoint(self.allocator, &endpoints, .cachyos_v4, self.options.cachyos_v4_base_url);
            if (include_v3) try appendBaseEndpoint(self.allocator, &endpoints, .cachyos_v3, self.options.cachyos_v3_base_url);
        }

        return endpoints.toOwnedSlice(self.allocator) catch return Error.OutOfMemory;
    }

    /// Scans configured pacman cache directories for matching package files.
    pub fn list_local_cache(
        self: *ArchiveManager,
        package_name: []const u8,
        installed_version: ?[]const u8,
        cache_directories: []const []const u8,
    ) Error![]DowngradeCandidate {
        try self.checkCancelled();
        if (!isValidPackageName(package_name)) return Error.InvalidPackageName;

        var candidates: std.ArrayList(DowngradeCandidate) = .empty;
        errdefer deinitCandidateList(self.allocator, &candidates);

        for (cache_directories) |cache_directory| {
            var directory = std.Io.Dir.cwd().openDir(self.io, cache_directory, .{ .iterate = true }) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => continue,
                else => return Error.DirectoryReadFailed,
            };
            defer directory.close(self.io);

            var iterator = directory.iterate();
            while (iterator.next(self.io) catch return Error.DirectoryReadFailed) |directory_entry| {
                try self.checkCancelled();
                if (directory_entry.kind == .directory) continue;
                const full_path = std.fs.path.join(self.allocator, &.{ cache_directory, directory_entry.name }) catch
                    return Error.OutOfMemory;
                defer self.allocator.free(full_path);
                const stat = directory.statFile(self.io, directory_entry.name, .{}) catch continue;
                var entry = (cache_manager.parsePackageFilename(self.allocator, full_path, stat.size) catch
                    return Error.OutOfMemory) orelse continue;
                defer entry.deinit(self.allocator);
                if (!std.mem.eql(u8, entry.name, package_name)) continue;

                var candidate = createCandidate(
                    self.allocator,
                    entry,
                    .local_cache,
                    full_path,
                    installed_version,
                    stat.size,
                ) catch return Error.OutOfMemory;
                candidates.append(self.allocator, candidate) catch {
                    candidate.deinit(self.allocator);
                    return Error.OutOfMemory;
                };
            }
        }

        sortCandidates(candidates.items);
        return candidates.toOwnedSlice(self.allocator) catch return Error.OutOfMemory;
    }

    /// Fetches and parses one remote archive directory listing.
    pub fn list_remote_archive(
        self: *ArchiveManager,
        package_name: []const u8,
        installed_version: ?[]const u8,
        endpoint: ArchiveEndpoint,
    ) Error![]DowngradeCandidate {
        try self.checkCancelled();
        const listing = try self.fetchListing(endpoint.url);
        defer self.allocator.free(listing);
        return parseArchiveListing(
            self.allocator,
            listing,
            package_name,
            installed_version,
            endpoint.source,
            endpoint.url,
        );
    }

    /// Gathers local and remote options using the state already configured on
    /// the ALPM manager. Individual unavailable archives are treated as
    /// best-effort sources; allocation and local-cache failures remain fatal.
    pub fn find_candidates(
        self: *ArchiveManager,
        manager: *alpm_manager.Manager,
        package_name: []const u8,
        installed_version: ?[]const u8,
    ) DiscoveryError![]DowngradeCandidate {
        try self.checkCancelled();
        var cache_directories = try manager.get_cache_directories();
        defer cache_directories.deinit(manager.allocator);

        var cache_directory_view: std.ArrayList([]const u8) = .empty;
        defer cache_directory_view.deinit(self.allocator);
        for (cache_directories.items) |directory| {
            cache_directory_view.append(self.allocator, directory) catch return Error.OutOfMemory;
        }
        if (cache_directory_view.items.len == 0) {
            cache_directory_view.append(self.allocator, self.options.cache_directory_fallback) catch
                return Error.OutOfMemory;
        }

        var candidates: std.ArrayList(DowngradeCandidate) = .empty;
        errdefer deinitCandidateList(self.allocator, &candidates);
        const local = try self.list_local_cache(package_name, installed_version, cache_directory_view.items);
        try moveCandidates(self.allocator, &candidates, local);

        var include_v3 = false;
        var include_v4 = false;
        if (manager.is_cachyos()) {
            const architectures = try manager.get_allowed_architecture();
            defer {
                for (architectures) |architecture| manager.allocator.free(architecture);
                manager.allocator.free(architectures);
            }
            for (architectures) |architecture| {
                include_v3 = include_v3 or std.mem.endsWith(u8, architecture, "v3");
                include_v4 = include_v4 or std.mem.endsWith(u8, architecture, "v4");
            }
        }

        const endpoints = try self.get_archive_endpoints(
            package_name,
            manager.is_cachyos(),
            include_v3,
            include_v4,
        );
        defer ArchiveEndpoint.deinitSlice(self.allocator, endpoints);
        for (endpoints) |endpoint| {
            try self.checkCancelled();
            const remote = self.list_remote_archive(package_name, installed_version, endpoint) catch |err| switch (err) {
                Error.OutOfMemory => return Error.OutOfMemory,
                Error.Cancelled => return Error.Cancelled,
                else => continue,
            };
            try moveCandidates(self.allocator, &candidates, remote);
        }

        sortCandidates(candidates.items);
        return candidates.toOwnedSlice(self.allocator) catch return Error.OutOfMemory;
    }

    /// Resolves an exact package filename or exact `version-release` target.
    /// The returned pointer is borrowed from `candidates`.
    pub fn resolve_target(
        self: *const ArchiveManager,
        candidates: []const DowngradeCandidate,
        target: []const u8,
    ) Error!*const DowngradeCandidate {
        try self.checkCancelled();
        if (target.len == 0) return Error.TargetNotFound;
        const filename_target = std.mem.indexOf(u8, target, ".pkg.tar.") != null;
        for (candidates) |*candidate| {
            const value = if (filename_target) candidate.filename else candidate.version_release;
            if (std.mem.eql(u8, value, target)) return candidate;
        }
        return Error.TargetNotFound;
    }

    /// Returns a local path for a selected candidate, downloading remote
    /// candidates to a uniquely named temporary file.
    pub fn prepare_candidate(
        self: *ArchiveManager,
        candidate: *const DowngradeCandidate,
    ) Error!PreparedPackage {
        try self.checkCancelled();
        if (!isSafeFilename(candidate.filename)) return Error.InvalidCandidate;
        if (!candidate.source.is_remote()) {
            _ = std.Io.Dir.cwd().statFile(self.io, candidate.location, .{}) catch
                return Error.LocalPackageMissing;
            return .{
                .path = self.allocator.dupe(u8, candidate.location) catch return Error.OutOfMemory,
                .temporary = false,
            };
        }
        return self.download_candidate(candidate);
    }

    pub fn download_candidate(
        self: *ArchiveManager,
        candidate: *const DowngradeCandidate,
    ) Error!PreparedPackage {
        try self.checkCancelled();
        if (!candidate.source.is_remote() or !isSafeFilename(candidate.filename))
            return Error.InvalidCandidate;
        std.Io.Dir.cwd().createDirPath(self.io, self.options.temporary_directory) catch
            return Error.TempFileFailed;

        const nonce = temporary_file_counter.fetchAdd(1, .monotonic);
        const timestamp = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
        const destination_path = std.fmt.allocPrint(
            self.allocator,
            "{s}/shelly-downgrade-{d}-{x}-{s}",
            .{ std.mem.trimEnd(u8, self.options.temporary_directory, "/"), timestamp, nonce, candidate.filename },
        ) catch return Error.OutOfMemory;
        errdefer self.allocator.free(destination_path);

        var core = shared_downloader.CoreDownloader.init(
            self.allocator,
            self.io,
            self.options.download_configuration,
        );
        defer core.deinit();
        if (self.download_event_callback) |callback| {
            core.setEventCallback(callback, self.download_event_context);
        }
        if (self.parent_operation) |operation| core.setParentOperation(operation) else core.setOperationContext(self.operation_context);

        switch (core.downloadToFile(candidate.location, destination_path, true)) {
            .succes, .skipped => {},
            .failure => |err| {
                std.Io.Dir.cwd().deleteFile(self.io, destination_path) catch {};
                if (err == shared_downloader.DownloadError.Cancelled) return Error.Cancelled;
                return Error.DownloadFailed;
            },
        }
        return .{ .path = destination_path, .temporary = true };
    }

    /// Prepares the selected candidate and delegates the actual transaction to
    /// `alpm.Manager.install_local_packages`.
    pub fn install_candidate(
        self: *ArchiveManager,
        manager: *alpm_manager.Manager,
        candidate: *const DowngradeCandidate,
        flags: bindings.libalpm.TransFlag,
    ) InstallError!void {
        try self.checkCancelled();
        var prepared = try self.prepare_candidate(candidate);
        defer prepared.deinit(self.allocator, self.io);
        var paths = [_][]const u8{prepared.path};
        try manager.install_local_packages(paths[0..], flags);
    }

    fn checkCancelled(self: *const ArchiveManager) error{Cancelled}!void {
        if (self.operation_context) |context| {
            if (context.isCancelled()) return error.Cancelled;
        }
        if (self.parent_operation) |operation| try operation.checkCancelled();
    }

    fn fetchListing(self: *ArchiveManager, url: []const u8) Error![]u8 {
        var operation_storage: operation_api.Operation = undefined;
        const has_operation = if (self.parent_operation) |parent| blk: {
            operation_storage = parent.child(.{ .backend = .download, .kind = .download, .subject = url });
            break :blk true;
        } else if (self.operation_context) |context| blk: {
            operation_storage = context.begin(.{ .backend = .download, .kind = .download, .subject = url });
            break :blk true;
        } else false;
        var successful = false;
        defer if (has_operation) {
            if (!successful) operation_storage.reportError(
                if (operation_storage.isCancelled()) error.Cancelled else error.ArchiveListingDownloadFailed,
                if (operation_storage.isCancelled()) "Archive listing download cancelled" else "Archive listing download failed",
                "download",
                null,
                false,
            );
            operation_storage.finish(if (successful) .success else if (operation_storage.isCancelled()) .cancelled else .failed);
        };
        if (has_operation and operation_storage.isCancelled()) return Error.Cancelled;
        const uri = std.Uri.parse(url) catch return Error.RemoteListingFailed;
        var request = self.http_client.request(.GET, uri, .{
            .headers = .{
                .user_agent = .{ .override = "Shelly-ALPM/3" },
                .accept_encoding = .{ .override = "identity" },
            },
            .redirect_behavior = .init(10),
        }) catch return Error.RemoteListingFailed;
        defer request.deinit();
        request.accept_encoding[@intFromEnum(std.http.ContentEncoding.gzip)] = false;
        request.accept_encoding[@intFromEnum(std.http.ContentEncoding.deflate)] = false;
        request.sendBodiless() catch return Error.RemoteListingFailed;
        var redirect_buffer: [8 * 1024]u8 = undefined;
        var response = request.receiveHead(&redirect_buffer) catch return Error.RemoteListingFailed;
        if (response.head.status.class() != .success) return Error.RemoteListingFailed;
        var transfer_buffer: [8 * 1024]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        var listing: std.ArrayList(u8) = .empty;
        errdefer listing.deinit(self.allocator);
        var read_buffer: [16 * 1024]u8 = undefined;
        while (true) {
            if (has_operation and operation_storage.isCancelled()) return Error.Cancelled;
            const amount = reader.readSliceShort(&read_buffer) catch return Error.RemoteListingFailed;
            if (amount == 0) break;
            if (listing.items.len + amount > self.options.max_listing_size) return Error.RemoteListingFailed;
            listing.appendSlice(self.allocator, read_buffer[0..amount]) catch return Error.OutOfMemory;
            if (has_operation) operation_storage.progress(.{
                .stage = "archive-listing",
                .completed = @intCast(listing.items.len),
                .total = response.head.content_length,
                .percentage = if (response.head.content_length) |total| if (total == 0) 100 else @as(f64, @floatFromInt(listing.items.len)) * 100.0 / @as(f64, @floatFromInt(total)) else null,
                .bytes_completed = @intCast(listing.items.len),
                .bytes_total = response.head.content_length,
            });
        }
        const owned = listing.toOwnedSlice(self.allocator) catch return Error.OutOfMemory;
        successful = true;
        return owned;
    }
};

pub const Manager = ArchiveManager;

/// Parses package links from an archive directory listing into owned values.
pub fn parseArchiveListing(
    allocator: std.mem.Allocator,
    html: []const u8,
    package_name: []const u8,
    installed_version: ?[]const u8,
    source: Source,
    base_url: []const u8,
) Error![]DowngradeCandidate {
    if (!isValidPackageName(package_name) or !source.is_remote()) return Error.InvalidPackageName;

    var candidates: std.ArrayList(DowngradeCandidate) = .empty;
    errdefer deinitCandidateList(allocator, &candidates);
    var cursor: usize = 0;
    while (nextHref(html, &cursor)) |href| {
        const encoded_filename = hrefFilename(href) orelse continue;
        if (std.mem.endsWith(u8, encoded_filename, ".sig")) continue;
        const decoded = percentDecode(allocator, encoded_filename) catch continue;
        defer allocator.free(decoded);
        if (!isSafeFilename(decoded)) continue;

        var entry = (cache_manager.parsePackageFilename(allocator, decoded, 0) catch
            return Error.OutOfMemory) orelse continue;
        defer entry.deinit(allocator);
        if (!std.mem.eql(u8, entry.name, package_name)) continue;

        const resolved_url = resolveHref(allocator, base_url, href) catch return Error.OutOfMemory;
        defer allocator.free(resolved_url);
        var candidate = createCandidate(
            allocator,
            entry,
            source,
            resolved_url,
            installed_version,
            null,
        ) catch return Error.OutOfMemory;
        candidates.append(allocator, candidate) catch {
            candidate.deinit(allocator);
            return Error.OutOfMemory;
        };
    }
    sortCandidates(candidates.items);
    return candidates.toOwnedSlice(allocator) catch return Error.OutOfMemory;
}

fn createCandidate(
    allocator: std.mem.Allocator,
    entry: cache_manager.Entry,
    source: Source,
    location: []const u8,
    installed_version: ?[]const u8,
    size: ?u64,
) std.mem.Allocator.Error!DowngradeCandidate {
    const name = try allocator.dupeZ(u8, entry.name);
    errdefer allocator.free(name);
    const version = try allocator.dupeZ(u8, entry.version);
    errdefer allocator.free(version);
    const release = try allocator.dupeZ(u8, entry.release);
    errdefer allocator.free(release);
    const version_release = try allocator.dupeZ(u8, entry.version_release);
    errdefer allocator.free(version_release);
    const architecture = try allocator.dupeZ(u8, entry.arch);
    errdefer allocator.free(architecture);
    const filename = try allocator.dupe(u8, std.fs.path.basename(entry.full_path));
    errdefer allocator.free(filename);
    return .{
        .name = name,
        .version = version,
        .release = release,
        .version_release = version_release,
        .architecture = architecture,
        .filename = filename,
        .location = try allocator.dupe(u8, location),
        .source = source,
        .is_installed = if (installed_version) |current|
            std.mem.eql(u8, current, entry.version_release)
        else
            false,
        .size = size,
    };
}

fn appendEndpoint(
    allocator: std.mem.Allocator,
    endpoints: *std.ArrayList(ArchiveEndpoint),
    source: Source,
    owned_url: []u8,
) Error!void {
    var endpoint: ArchiveEndpoint = .{ .source = source, .url = owned_url };
    endpoints.append(allocator, endpoint) catch {
        endpoint.deinit(allocator);
        return Error.OutOfMemory;
    };
}

fn appendBaseEndpoint(
    allocator: std.mem.Allocator,
    endpoints: *std.ArrayList(ArchiveEndpoint),
    source: Source,
    base_url: []const u8,
) Error!void {
    const url = std.fmt.allocPrint(allocator, "{s}/", .{std.mem.trimEnd(u8, base_url, "/")}) catch
        return Error.OutOfMemory;
    try appendEndpoint(allocator, endpoints, source, url);
}

fn moveCandidates(
    allocator: std.mem.Allocator,
    destination: *std.ArrayList(DowngradeCandidate),
    source: []DowngradeCandidate,
) Error!void {
    destination.ensureUnusedCapacity(allocator, source.len) catch {
        DowngradeCandidate.deinitSlice(allocator, source);
        return Error.OutOfMemory;
    };
    for (source) |candidate| destination.appendAssumeCapacity(candidate);
    allocator.free(source);
}

fn deinitCandidateList(allocator: std.mem.Allocator, candidates: *std.ArrayList(DowngradeCandidate)) void {
    for (candidates.items) |*candidate| candidate.deinit(allocator);
    candidates.deinit(allocator);
}

fn deinitEndpointList(allocator: std.mem.Allocator, endpoints: *std.ArrayList(ArchiveEndpoint)) void {
    for (endpoints.items) |*endpoint| endpoint.deinit(allocator);
    endpoints.deinit(allocator);
}

fn sortCandidates(candidates: []DowngradeCandidate) void {
    std.mem.sort(DowngradeCandidate, candidates, {}, candidateBefore);
}

fn candidateBefore(_: void, a: DowngradeCandidate, b: DowngradeCandidate) bool {
    const version_order = alpm_manager.Manager.compare_package_versions(a.version_release, b.version_release);
    if (version_order != 0) return version_order > 0;
    if (a.is_installed != b.is_installed) return a.is_installed;
    if (a.source == .local_cache and b.source != .local_cache) return true;
    if (a.source != .local_cache and b.source == .local_cache) return false;
    const filename_order = std.mem.order(u8, a.filename, b.filename);
    if (filename_order != .eq) return filename_order == .gt;
    return @intFromEnum(a.source) < @intFromEnum(b.source);
}

fn isValidPackageName(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isAlphanumeric(name[0])) return false;
    for (name) |character| {
        if (!std.ascii.isAlphanumeric(character) and
            character != '@' and character != '.' and character != '_' and
            character != '+' and character != '-') return false;
    }
    return true;
}

fn isSafeFilename(filename: []const u8) bool {
    return filename.len != 0 and
        !std.mem.eql(u8, filename, ".") and
        !std.mem.eql(u8, filename, "..") and
        std.mem.eql(u8, filename, std.fs.path.basename(filename)) and
        std.mem.indexOfScalar(u8, filename, '\\') == null;
}

fn nextHref(html: []const u8, cursor: *usize) ?[]const u8 {
    while (findIgnoreCase(html, cursor.*, "href")) |position| {
        var index = position + "href".len;
        cursor.* = index;
        while (index < html.len and std.ascii.isWhitespace(html[index])) : (index += 1) {}
        if (index >= html.len or html[index] != '=') continue;
        index += 1;
        while (index < html.len and std.ascii.isWhitespace(html[index])) : (index += 1) {}
        if (index >= html.len or (html[index] != '\'' and html[index] != '"')) continue;
        const quote = html[index];
        const start = index + 1;
        const end = std.mem.indexOfScalarPos(u8, html, start, quote) orelse {
            cursor.* = html.len;
            return null;
        };
        cursor.* = end + 1;
        return html[start..end];
    }
    cursor.* = html.len;
    return null;
}

fn hrefFilename(href: []const u8) ?[]const u8 {
    const query = std.mem.indexOfAny(u8, href, "?#") orelse href.len;
    const path = href[0..query];
    if (path.len == 0 or std.mem.endsWith(u8, path, "/")) return null;
    const separator = std.mem.lastIndexOfScalar(u8, path, '/');
    return if (separator) |index| path[index + 1 ..] else path;
}

fn findIgnoreCase(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len == 0) return @min(start, haystack.len);
    if (start >= haystack.len or needle.len > haystack.len - start) return null;
    var index = start;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return index;
    }
    return null;
}

fn percentEncodePathSegment(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const hex = "0123456789ABCDEF";
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    for (input) |character| {
        if (std.ascii.isAlphanumeric(character) or character == '-' or character == '_' or character == '.' or character == '~') {
            try output.writer.writeByte(character);
        } else {
            try output.writer.writeAll(&.{ '%', hex[character >> 4], hex[character & 0x0f] });
        }
    }
    return output.toOwnedSlice();
}

fn percentDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output = try allocator.alloc(u8, input.len);
    errdefer allocator.free(output);
    var read_index: usize = 0;
    var write_index: usize = 0;
    while (read_index < input.len) {
        if (input[read_index] == '%') {
            if (read_index + 2 >= input.len) return error.InvalidPercentEncoding;
            const high = std.fmt.charToDigit(input[read_index + 1], 16) catch return error.InvalidPercentEncoding;
            const low = std.fmt.charToDigit(input[read_index + 2], 16) catch return error.InvalidPercentEncoding;
            output[write_index] = high * 16 + low;
            read_index += 3;
        } else {
            output[write_index] = input[read_index];
            read_index += 1;
        }
        write_index += 1;
    }
    return allocator.realloc(output, write_index);
}

fn resolveHref(allocator: std.mem.Allocator, base_url: []const u8, href: []const u8) std.mem.Allocator.Error![]u8 {
    if (std.mem.startsWith(u8, href, "https://") or std.mem.startsWith(u8, href, "http://"))
        return allocator.dupe(u8, href);
    if (std.mem.startsWith(u8, href, "/")) {
        const scheme_end = std.mem.indexOf(u8, base_url, "://") orelse
            return std.fmt.allocPrint(allocator, "{s}{s}", .{ std.mem.trimEnd(u8, base_url, "/"), href });
        const host_start = scheme_end + 3;
        const host_end = std.mem.indexOfScalarPos(u8, base_url, host_start, '/') orelse base_url.len;
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ base_url[0..host_end], href });
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ std.mem.trimEnd(u8, base_url, "/"), href });
}

const testing = std.testing;

test "archive endpoints include Arch and selected CachyOS variants" {
    var manager = ArchiveManager.init(testing.allocator, testing.io, .{});
    defer manager.deinit();

    const arch_only = try manager.get_archive_endpoints("linux", false, false, false);
    defer ArchiveEndpoint.deinitSlice(testing.allocator, arch_only);
    try testing.expectEqual(@as(usize, 1), arch_only.len);
    try testing.expectEqual(Source.arch_linux, arch_only[0].source);
    try testing.expectEqualStrings("https://archive.archlinux.org/packages/l/linux/", arch_only[0].url);

    const all = try manager.get_archive_endpoints("demo+tools", true, true, true);
    defer ArchiveEndpoint.deinitSlice(testing.allocator, all);
    try testing.expectEqual(@as(usize, 4), all.len);
    try testing.expectEqualStrings("https://archive.archlinux.org/packages/d/demo%2Btools/", all[0].url);
    try testing.expectEqual(Source.cachyos, all[1].source);
    try testing.expectEqual(Source.cachyos_v4, all[2].source);
    try testing.expectEqual(Source.cachyos_v3, all[3].source);
}

test "archive listing parses package filenames and ignores signatures and other packages" {
    const html =
        "<html><a href=\"demo-2.0-1-x86_64.pkg.tar.zst\">new</a>\n" ++
        "<A HREF='demo-1.5%2Bgit-2-x86_64.pkg.tar.zst'>encoded</A>\n" ++
        "<a href=\"https://cdn.example/demo-1.0-1-x86_64.pkg.tar.zst\">absolute</a>\n" ++
        "<a href=\"demo-2.0-1-x86_64.pkg.tar.zst.sig\">sig</a>\n" ++
        "<a href=\"other-1.0-1-x86_64.pkg.tar.zst\">other</a></html>";
    const candidates = try parseArchiveListing(
        testing.allocator,
        html,
        "demo",
        "2.0-1",
        .arch_linux,
        "https://archive.example/packages/d/demo/",
    );
    defer DowngradeCandidate.deinitSlice(testing.allocator, candidates);

    try testing.expectEqual(@as(usize, 3), candidates.len);
    try testing.expectEqualStrings("demo-2.0-1-x86_64.pkg.tar.zst", candidates[0].filename);
    try testing.expectEqualStrings("2.0-1", candidates[0].version_release);
    try testing.expect(candidates[0].is_installed);
    try testing.expectEqualStrings(
        "https://archive.example/packages/d/demo/demo-2.0-1-x86_64.pkg.tar.zst",
        candidates[0].location,
    );
    try testing.expectEqualStrings("1.5+git-2", candidates[1].version_release);
    try testing.expect(!candidates[1].is_installed);
    try testing.expectEqualStrings("https://cdn.example/demo-1.0-1-x86_64.pkg.tar.zst", candidates[2].location);
}

test "local cache lookup returns owned matching candidates" {
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const cache_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer testing.allocator.free(cache_path);

    const files = [_][]const u8{
        "demo-3.0-1-x86_64.pkg.tar.zst",
        "demo-2.0-1-x86_64.pkg.tar.xz",
        "demo-2.0-1-x86_64.pkg.tar.xz.sig",
        "other-4.0-1-x86_64.pkg.tar.zst",
    };
    for (files) |filename| {
        var file = try temporary.dir.createFile(testing.io, filename, .{});
        try file.writeStreamingAll(testing.io, "package");
        file.close(testing.io);
    }

    var manager = ArchiveManager.init(testing.allocator, testing.io, .{});
    defer manager.deinit();
    const candidates = try manager.list_local_cache("demo", "3.0-1", &.{cache_path});
    defer DowngradeCandidate.deinitSlice(testing.allocator, candidates);

    try testing.expectEqual(@as(usize, 2), candidates.len);
    try testing.expectEqualStrings("3.0-1", candidates[0].version_release);
    try testing.expect(candidates[0].is_installed);
    try testing.expectEqual(Source.local_cache, candidates[0].source);
    try testing.expectEqual(@as(?u64, 7), candidates[0].size);
}

test "target resolution accepts exact version-release or filename" {
    const html =
        "<a href=\"demo-2.0-1-x86_64.pkg.tar.zst\">new</a>" ++
        "<a href=\"demo-1.0-2-x86_64.pkg.tar.zst\">old</a>";
    const candidates = try parseArchiveListing(
        testing.allocator,
        html,
        "demo",
        null,
        .arch_linux,
        "https://archive.example/",
    );
    defer DowngradeCandidate.deinitSlice(testing.allocator, candidates);

    var manager = ArchiveManager.init(testing.allocator, testing.io, .{});
    defer manager.deinit();
    const by_version = try manager.resolve_target(candidates, "1.0-2");
    try testing.expectEqualStrings("demo-1.0-2-x86_64.pkg.tar.zst", by_version.filename);
    const by_filename = try manager.resolve_target(candidates, "demo-2.0-1-x86_64.pkg.tar.zst");
    try testing.expectEqualStrings("2.0-1", by_filename.version_release);
    try testing.expectError(Error.TargetNotFound, manager.resolve_target(candidates, "9.0-1"));
}

test "prepare_candidate retains local cache files" {
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const cache_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer testing.allocator.free(cache_path);
    var file = try temporary.dir.createFile(testing.io, "demo-1.0-1-x86_64.pkg.tar.zst", .{});
    file.close(testing.io);

    var manager = ArchiveManager.init(testing.allocator, testing.io, .{});
    defer manager.deinit();
    const candidates = try manager.list_local_cache("demo", null, &.{cache_path});
    defer DowngradeCandidate.deinitSlice(testing.allocator, candidates);
    var prepared = try manager.prepare_candidate(&candidates[0]);
    try testing.expect(!prepared.temporary);
    prepared.deinit(testing.allocator, testing.io);
    _ = try std.Io.Dir.cwd().statFile(testing.io, candidates[0].location, .{});

    var transaction_manager: alpm_manager.Manager = undefined;
    transaction_manager.handle = null;
    try testing.expectError(
        error.NoHandle,
        manager.install_candidate(&transaction_manager, &candidates[0], .{}),
    );
}

test "archive installation API delegates through the ALPM manager" {
    var archive = ArchiveManager.init(testing.allocator, testing.io, .{});
    defer archive.deinit();
    var manager: alpm_manager.Manager = undefined;
    manager.handle = null;
    manager.allocator = testing.allocator;
    try testing.expectError(error.NoHandle, archive.find_candidates(&manager, "demo", null));
    _ = ArchiveManager.download_candidate;
    _ = DowngradeCandidate;
    _ = PreparedPackage;
}

test "archive downloads honor shared cancellation" {
    var context = operation_api.OperationContext.init(testing.allocator, testing.io);
    defer context.deinit();
    var archive = ArchiveManager.init(testing.allocator, testing.io, .{});
    defer archive.deinit();
    archive.setOperationContext(&context);

    context.cancel();
    try testing.expectError(error.Cancelled, archive.list_remote_archive("demo", null, .{
        .source = .arch_linux,
        .url = @constCast("https://example.invalid/"),
    }));
}
