//! Callbacks run synchronously on the Owner's thread. Payloads are borrowed for
//! the call. They may request cancellation, but may not reenter Owner operations.
const DatabaseRef = @import("DatabaseRef.zig");
const PackageRef = @import("PackageRef.zig");
const PackageRelation = @import("PackageRelation.zig");
const Diagnostic = @import("Diagnostic.zig");
const Transaction = @import("Transaction.zig");
const Package = @import("Package.zig");

const Callbacks = @This();

pub const LogLevel = enum { err, warning, debug, function };

pub const Log = struct {
    level: LogLevel,
    message: []const u8,
};

pub const Phase = enum {
    dependencies,
    conflicts,
    resolve_dependencies,
    inter_conflicts,
    file_conflicts,
    transaction,
    integrity,
    load_packages,
    disk_space,
    keyring,
    key_download,
    database_retrieve,
    package_retrieve,
};

pub const Boundary = enum { start, done, failed };

pub const PackageOperation = enum { install, upgrade, reinstall, downgrade, remove };

pub const HookWhen = enum { pre_transaction, post_transaction };

pub const Event = union(enum) {
    /// Shelly lifecycle extension, independent of native work-phase events.
    lifecycle: Transaction.Result,
    phase: struct {
        phase: Phase,
        boundary: Boundary,
        total_packages: ?usize = null,
        total_bytes: ?u64 = null,
    },
    package_operation: struct {
        operation: PackageOperation,
        boundary: Boundary,
        old: ?PackageRef,
        new: ?PackageRef,
        views: []const PackageView = &.{},
    },
    database_missing: DatabaseRef,
    optional_dependency_removed: struct {
        package: PackageRef,
        dependency: PackageRelation,
    },
    scriptlet_output: []const u8,
    pacnew_created: struct {
        path: []const u8,
        old: ?PackageRef,
        new: PackageRef,
        from_no_upgrade: bool,
    },
    pacsave_created: struct {
        path: []const u8,
        old: PackageRef,
    },
    hook: struct {
        when: HookWhen,
        boundary: Boundary,
    },
    hook_run: struct {
        name: []const u8,
        description: ?[]const u8,
        position: usize,
        total: usize,
        boundary: Boundary,
    },
    diagnostic: Diagnostic,
};

pub const Progress = struct {
    phase: Phase,
    package: ?PackageRef,
    percent: u8,
    position: usize,
    total: usize,
};

pub const Download = union(enum) {
    /// Queued acquisition; no network slot has been occupied yet.
    init: struct {
        name: []const u8,
        optional: bool,
    },
    started: struct {
        name: []const u8,
        attempt: u32,
    },
    progress: struct {
        name: []const u8,
        attempt: u32 = 1,
        downloaded: u64,
        total: ?u64,
    },
    retry: struct {
        name: []const u8,
        attempt: u32 = 1,
        resuming: bool,
    },
    /// Payload and applicable signature requests ended, before acceptance.
    /// A verification retry starts a new attempt for the same acquisition.
    transferred: struct {
        name: []const u8,
        attempt: u32,
        downloaded: u64,
        result: enum { updated, unchanged, failed },
    },
    processing: struct {
        name: []const u8,
        stage: enum { verification, publication },
        boundary: Boundary,
        position: usize,
        total: usize,
    },
    /// Terminal acquisition result, after verification and durable publication.
    completed: struct {
        name: []const u8,
        downloaded: u64,
        result: enum { updated, unchanged, failed },
    },
};

pub const Key = struct {
    fingerprint: []const u8,
    user_id: ?[]const u8 = null,
};

/// Borrowed metadata for resolution callbacks, which cannot reenter Owner.
/// Archive references resolve through the returned plan, not Owner.package.
pub const PackageView = struct {
    reference: PackageRef,
    package: *const Package,
};

/// Answers start with libalpm's conservative defaults. A provider answer is an
/// index into candidates. The callback must retain the question's union tag.
pub const Question = union(enum) {
    install_ignored: struct {
        package: PackageRef,
        install: bool = false,
        views: []const PackageView = &.{},
    },
    replace: struct {
        old: PackageRef,
        new: PackageRef,
        database: DatabaseRef,
        replace: bool = false,
        views: []const PackageView = &.{},
    },
    conflict: struct {
        first: PackageRef,
        second: PackageRef,
        reason: PackageRelation,
        remove: bool = false,
        views: []const PackageView = &.{},
    },
    corrupted: struct {
        path: []const u8,
        reason: anyerror,
        remove: bool = false,
    },
    remove_packages: struct {
        packages: []const PackageRef,
        skip: bool = false,
        views: []const PackageView = &.{},
    },
    select_provider: struct {
        dependency: PackageRelation,
        candidates: []const PackageRef,
        selected: usize = 0,
        views: []const PackageView = &.{},
    },
    import_key: struct {
        key: Key,
        import: bool = false,
    },
};

pub const Fetch = struct {
    url: []const u8,
    destination_directory: []const u8,
    force: bool,
};

pub const FetchResult = enum { updated, unchanged };
pub const FetchError = error{ DownloadFailed, Cancelled, OutOfMemory };

log: ?*const fn (?*anyopaque, Log) void = null,
log_context: ?*anyopaque = null,
event: ?*const fn (?*anyopaque, Event) void = null,
event_context: ?*anyopaque = null,
question: ?*const fn (?*anyopaque, *Question) void = null,
/// Fallible adapter variant, preferred when set. Uses question_context.
question_with_error: ?*const fn (?*anyopaque, *Question) anyerror!void = null,
question_context: ?*anyopaque = null,
progress: ?*const fn (?*anyopaque, Progress) void = null,
progress_context: ?*anyopaque = null,
download: ?*const fn (?*anyopaque, Download) void = null,
download_context: ?*anyopaque = null,
fetch: ?*const fn (?*anyopaque, Fetch) FetchError!FetchResult = null,
fetch_context: ?*anyopaque = null,
