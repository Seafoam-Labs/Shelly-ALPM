//! Stored diagnostics contain values only; they never retain caller-owned strings.

const std = @import("std");
const DatabaseRef = @import("DatabaseRef.zig");

const Diagnostic = @This();

pub const Operation = enum {
    download,
    refresh,
    configure,
    register_database,
    unregister_database,
    load_database,
    load_package,
    invalidate_database,
    query,
    resolve,
    transaction,
    callback,
};

pub const Category = enum {
    memory,
    invalid_argument,
    database,
    integrity,
    resolution,
    file_conflict,
    stale_reference,
    busy,
    cancelled,
    unsupported,
    io,
};

operation: Operation,
category: Category,
cause: anyerror,
database: ?DatabaseRef = null,

pub fn init(operation: Operation, cause: anyerror, database: ?DatabaseRef) Diagnostic {
    return .{
        .operation = operation,
        .cause = cause,
        .database = database,
        .category = switch (cause) {
            error.FileConflicts, error.MigrationOwnershipConflict, error.MigrationTargetConflict, error.MigrationNoExtractConflict => .file_conflict,
            error.StaleFilesystemState => .stale_reference,
            error.InvalidMigrationMetadata,
            error.PackageMetadataMismatch,
            error.UnsafeArchivePath,
            error.UnsafeHardlink,
            error.UnsafeSymlink,
            error.ArchiveInventoryMismatch,
            error.DuplicateArchivePath,
            => .integrity,
            error.OutOfMemory => .memory,
            error.DependencyPlanMismatch,
            error.TargetNotFound,
            error.PackageIgnored,
            error.DuplicateTarget,
            error.InvalidArchitecture,
            error.UnsatisfiedDependencies,
            error.ConflictingDependencies,
            error.DuplicateFilename,
            => .resolution,
            error.InvalidMigrationFlags, error.InvalidMigrationPath, error.InvalidMigrationTarget, error.InvalidMigrationSource, error.DuplicateMigration, error.MigrationPathMissing, error.InvalidTransactionFlags, error.InvalidSnapshot => .invalid_argument,
            error.DatabaseNotFound, error.InvalidDatabase, error.IncompleteMetadata => .database,
            error.UnsupportedMigrationVersion, error.UnsupportedMigrationType, error.UnsupportedMigrationBackup, error.UnsupportedPackageOrigin => .unsupported,
            error.ChecksumMismatch,
            error.ChecksumMissing,
            error.SignatureMissing,
            error.InvalidSignature,
            error.SignatureTooLarge,
            error.KeyImportDeclined,
            error.KeyImportFailed,
            error.KeyAcquisitionUnavailable,
            error.GpgFailed,
            error.InvalidKeySource,
            error.PackageIdentityMismatch,
            => .integrity,
            error.ConfigParseFailed,
            error.InvalidParallelDownloads,
            error.InvalidHookDirMode,
            error.InvalidMigrationPolicy,
            error.InvalidPath,
            error.InvalidOption,
            error.InvalidVersion,
            error.InvalidCharacter,
            error.InvalidPackageRelation,
            error.InvalidDatabaseName,
            error.ReservedDatabaseName,
            error.ImmutablePath,
            error.InvalidAnswer,
            error.InvalidRegex,
            => .invalid_argument,
            error.DuplicateDatabase,
            error.DatabaseNotLoaded,
            error.DatabaseAlreadyLoaded,
            error.UnsupportedDatabaseVersion,
            error.InvalidDatabaseEntry,
            error.InvalidSqliteDatabase,
            error.DuplicatePackage,
            error.InvalidPackageFilename,
            error.ArchiveFailed,
            => .database,
            error.ForeignOwner, error.StaleDatabaseReference, error.StalePackageReference => .stale_reference,
            error.CallbackReentry, error.OwnerBusy, error.TransactionActive, error.DatabaseLocked => .busy,
            error.InvalidTransactionState,
            error.TransactionNotInitialized,
            error.InvalidPackageOwnership,
            error.TransactionNotLocked,
            => .invalid_argument,
            error.StaleDatabaseState, error.LockOwnershipLost, error.LockNotHeld => .stale_reference,
            error.CommitUnavailable, error.PreviewRootReadOnly, error.ReadOnlyDatabase => .unsupported,
            error.Cancelled => .cancelled,
            error.UnsupportedDatabaseBackend => .unsupported,
            else => .io,
        },
    };
}

pub fn format(self: Diagnostic, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("{t}: {s}", .{ self.operation, @errorName(self.cause) });

    if (self.database) |reference| try writer.print(" (database {d})", .{@backingInt(reference.id)});
}

/// Context is borrowed only while rendering, like the callback diagnostic itself.
pub const Context = @import("diagnostics").Context;
pub const explanation = @import("DiagnosticMessages.zig").cause;

pub fn userMessage(self: Diagnostic, allocator: std.mem.Allocator, context: Context) ![]u8 {
    const diagnostics = @import("diagnostics");
    if (diagnostics.isCancellation(self.cause)) return diagnostics.format(allocator, self.cause, context);
    var full = context;
    full.domain = "rlpm";
    full.stage = context.stage orelse @tagName(self.operation);
    var owned_detail: ?[]u8 = null;
    defer if (owned_detail) |value| allocator.free(value);
    if (full.detail == null) {
        if (explanation(self.cause)) |reason| {
            owned_detail = try std.fmt.allocPrint(allocator, "RLPM could not complete {s}. {s}", .{ context.operation, reason });
            full.detail = owned_detail;
        } else {
            owned_detail = try std.fmt.allocPrint(allocator, "RLPM could not complete {s}. The backend returned {s}; no further explanation is available for this error.", .{ context.operation, @errorName(self.cause) });
            full.detail = owned_detail;
        }
    }
    const message = try diagnostics.format(allocator, self.cause, full);
    defer allocator.free(message);
    if (self.database) |reference| return std.fmt.allocPrint(allocator, "{s}\nDiagnostic category: {t}\nDatabase ID: {d}", .{ message, self.category, @backingInt(reference.id) });
    return std.fmt.allocPrint(allocator, "{s}\nDiagnostic category: {t}", .{ message, self.category });
}

/// No heap allocation or untrusted strings: even memory failures keep the cause.
pub fn fallback(buffer: *[512]u8, err: anyerror) []const u8 {
    return std.fmt.bufPrint(buffer, "RLPM failed. Detailed error formatting was unavailable.\n\nTechnical details: {s}\nBackend: rlpm", .{@errorName(err)}) catch "RLPM failed; detailed error formatting was unavailable.";
}

test "RLPM failures explain each diagnostic family and retain context and original codes" {
    const cases = .{
        .{ error.InvalidSignature, "signature" },
        .{ error.ChecksumMismatch, "checksum" },
        .{ error.DownloadWorkerFailed, "worker" },
        .{ error.InvalidDatabaseEntry, "metadata" },
        .{ error.InvalidArchitecture, "architecture" },
        .{ error.InvalidTransactionFlags, "options" },
        .{ error.UnsafeArchivePath, "unsafe" },
        .{ error.MigrationOwnershipConflict, "ownership" },
        .{ error.DiskSpaceInsufficient, "free space" },
        .{ error.PreTransactionHookFailed, "hook" },
        .{ error.PreviewRootReadOnly, "update-check root" },
        .{ error.InvalidParallelDownloads, "greater than zero" },
    };
    inline for (cases) |case| {
        const message = try Diagnostic.init(.transaction, case[0], null).userMessage(std.testing.allocator, .{ .subject = "demo", .path = "/tmp/demo", .stage = "preflight" });
        defer std.testing.allocator.free(message);
        for ([_][]const u8{ case[1], @errorName(case[0]), "demo", "/tmp/demo", "preflight", "Backend: rlpm" }) |part|
            try std.testing.expect(std.mem.indexOf(u8, message, part) != null);
        try std.testing.expect(std.mem.indexOf(u8, message, "more specific reason") == null);
    }
}

test "RLPM unknown failures and allocation failure preserve original error safely" {
    const d = Diagnostic.init(.refresh, error.FutureRlpmFailure, null);
    const message = try d.userMessage(std.testing.allocator, .{ .operation = "repository refresh", .path = "https://user:secret@example.test/private?token=hidden" });
    defer std.testing.allocator.free(message);
    try std.testing.expect(std.mem.indexOf(u8, message, "repository refresh") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "FutureRlpmFailure") != null);
    for ([_][]const u8{ "secret", "hidden", "private" }) |part| try std.testing.expect(std.mem.indexOf(u8, message, part) == null);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var buffer: [512]u8 = undefined;
    const emergency = d.userMessage(failing.allocator(), .{}) catch fallback(&buffer, d.cause);
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(std.mem.indexOf(u8, emergency, "FutureRlpmFailure") != null);
}
