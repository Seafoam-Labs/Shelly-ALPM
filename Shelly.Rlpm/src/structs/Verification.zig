//! Integrity checks over immutable bytes. Neither checking nor listing keys
//! acquires keys; acquisition is a separate operation after an import question.
const std = @import("std");
const Gpg = @import("Shelly_Key").gpg.Gpg;
const Policy = @import("SignaturePolicy.zig");
const Report = @import("SignatureResult.zig");
const Snapshot = @import("ImmutableFile.zig");
const OpenPgp = @import("OpenPgp.zig");
const Checksum = @import("Checksum.zig");
const Package = @import("Package.zig");
const Callbacks = @import("Callbacks.zig");

pub const KeyAcquisition = struct {
    /// Ordered local sources, each containing one public primary key and its
    /// subkeys. Bundles/secret keys are rejected before changing the keyring.
    key_files: []const []const u8 = &.{},
    /// Reference order after local sources: WKD when a UID supplies an email,
    /// then the configured GPG keyserver. Every route requires explicit consent.
    allow_wkd: bool = true,
    allow_keyserver: bool = true,
    keyserver: ?[]const u8 = null,
};

pub const Context = struct {
    gpg_directory: ?[]const u8 = null,
    acquisition: KeyAcquisition = .{},
    question_context: ?*anyopaque = null,
    question: ?*const fn (?*anyopaque, *Callbacks.Question) anyerror!void = null,
    check_cancelled: ?*const fn (?*anyopaque) anyerror!void = null,
    /// Optional process adapter; returns owned stdout/stderr even on nonzero exit.
    runner: ?*const fn (std.mem.Allocator, std.Io, []const u8, []const []const u8) anyerror!std.process.RunResult = null,

    pub fn checkCancelled(self: Context) !void {
        if (self.check_cancelled) |check_cancelled| try check_cancelled(self.question_context);
    }

    fn capture(
        self: Context,
        allocator: std.mem.Allocator,
        io: std.Io,
        args: []const []const u8,
    ) !std.process.RunResult {
        try self.checkCancelled();
        const home = self.gpg_directory orelse "/etc/pacman.d/gnupg";
        if (home.len == 0 or std.mem.indexOfScalar(u8, home, 0) != null) return error.InvalidPath;
        if (self.runner) |run| return run(allocator, io, home, args);
        return (Gpg{ .io = io, .homedir = home }).runCaptureResult(allocator, args);
    }
};
const verify_options = [_][]const u8{
    "--no-options",
    "--batch",
    "--no-tty",
    "--no-auto-key-retrieve",
    "--no-auto-key-import",
    "--auto-key-locate",
    "clear",
    "--no-auto-check-trustdb",
    "--no-autostart",
    "--proc-all-sigs",
};

pub const Options = struct {
    requirement: Policy.Verification,
    trust: Policy.Trust = .{},
    md5: ?[]const u8 = null,
    sha256: ?[]const u8 = null,
    base64_signature: ?[]const u8 = null,
    detached_signature: union(enum) { read_from_path, bytes: ?[]const u8 } = .read_from_path,
    /// alpm_pkg_load refreshes expired keys before detached file validation;
    /// database/repository verification instead applies the KEY_EXPIRED policy.
    refresh_expired_keys: bool = false,
};

pub fn clearReport(report: *?Report) void {
    if (report.*) |*old| old.deinit();
    report.* = null;
}

/// The output report survives policy rejection. I/O/spawn errors propagate;
/// completed processes retain termination, raw statuses and stderr in the report.
pub fn check(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: Context,
    snapshot: *const Snapshot,
    source: []const u8,
    options: Options,
    report: *?Report,
) !Package.Validation {
    clearReport(report);
    const signature = if (options.requirement == .disabled)
        null
    else if (options.base64_signature) |encoded|
        try OpenPgp.decode(allocator, encoded)
    else switch (options.detached_signature) {
        .read_from_path => try OpenPgp.readDetached(allocator, io, source),
        .bytes => |value| if (value) |bytes| blk: {
            if (bytes.len > OpenPgp.max_signature_size) return error.SignatureTooLarge;
            break :blk try allocator.dupe(u8, bytes);
        } else null,
    };
    defer if (signature) |bytes| allocator.free(bytes);
    var performed: Package.Validation = .{};
    // libalpm prefers SHA256 to MD5, and skips repository digests only when
    // verifying an embedded signature. Detached signatures still check digests.
    if (signature == null or options.base64_signature == null) {
        if (options.sha256) |expected| {
            try Checksum.check(.sha256, io, snapshot.path(), expected);
            performed.sha256 = true;
        } else if (options.md5) |expected| {
            try Checksum.check(.md5, io, snapshot.path(), expected);
            performed.md5 = true;
        }
    }
    if (options.requirement != .disabled) {
        if (signature) |bytes| {
            var detached = try Snapshot.fromBytes(bytes);
            defer detached.deinit();
            report.* = try verify(allocator, io, context, snapshot.path(), detached.path());
            if (!report.*.?.process_failure and !report.*.?.malformed_status) {
                var attempted: std.StringHashMapUnmanaged(void) = .empty;
                defer attempted.deinit(allocator);
                var imported = false;
                for (report.*.?.signatures) |key| {
                    if (key.status != .key_unknown and
                        !(key.status == .key_expired and
                            options.refresh_expired_keys))
                        continue;
                    const id = key.fingerprint orelse key.key_id orelse return error.InvalidSignature;
                    const entry = try attempted.getOrPut(allocator, id);
                    if (entry.found_existing) continue;
                    var question: Callbacks.Question = .{
                        .import_key = .{
                            .key = .{
                                .fingerprint = id,
                                .user_id = key.user_id,
                            },
                        },
                    };
                    if (context.question) |ask| try ask(context.question_context, &question);
                    try context.checkCancelled();
                    if (question != .import_key) return error.InvalidAnswer;
                    if (!question.import_key.import) return error.KeyImportDeclined;
                    try importKey(allocator, io, context, id, key.user_id, &report.*.?);
                    imported = true;
                }
                if (imported) {
                    var rechecked = try verify(allocator, io, context, snapshot.path(), detached.path());
                    errdefer rechecked.deinit();
                    for (report.*.?.key_operations.items) |operation|
                        try rechecked.recordKeyOperation(operation);
                    clearReport(report);
                    report.* = rechecked;
                }
            }
            try report.*.?.check(options.trust);
            performed.pgp = true;
        } else if (options.requirement == .required) return error.SignatureMissing;
    }
    performed.none = !performed.md5 and !performed.sha256 and !performed.pgp;
    try context.checkCancelled();
    return performed;
}

/// Low-level checking preserves all signature outcomes without applying trust.
/// Inputs should be pinned by the caller; check() supplies sealed snapshots.
pub fn verify(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: Context,
    data: []const u8,
    signature: []const u8,
) !Report {
    const result = try context.capture(
        allocator,
        io,
        &(verify_options ++ .{
            "--status-fd",
            "1",
            "--verify",
            "--",
            signature,
            data,
        }),
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    var report = try Report.parse(allocator, result.stdout, result.stderr, result.term);
    errdefer report.deinit();
    if (report.process_failure or report.malformed_status) return report;
    // GPG verification statuses omit locally disabled key state. The reference
    // checks it explicitly via its key object; query the same configured keyring.
    for (report.signatures) |*key| {
        const fingerprint = key.primary_fingerprint orelse continue;
        const listing = try context.capture(
            allocator,
            io,
            &(verify_options ++ .{
                "--with-colons",
                "--fixed-list-mode",
                "--list-keys",
                "--",
                fingerprint,
            }),
        );
        defer allocator.free(listing.stdout);
        defer allocator.free(listing.stderr);
        try report.recordKeyOperation(
            .{
                .termination = listing.term,
                .status_output = listing.stdout,
                .diagnostics = listing.stderr,
            },
        );
        if (!succeeded(listing.term)) {
            report.process_failure = true;
            report.diagnostics = try std.fmt.allocPrint(
                report.arena.allocator(),
                "{s}\n{s}",
                .{ report.diagnostics, listing.stderr },
            );
            continue;
        }
        var lines = std.mem.splitScalar(u8, listing.stdout, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "pub:")) continue;
            var fields = std.mem.splitScalar(u8, line, ':');
            var index: usize = 0;
            while (fields.next()) |value| : (index += 1) {
                if (index == 1) key.key_revoked = std.mem.indexOfScalar(u8, value, 'r') != null;
                if (index == 2) key.key_length = std.fmt.parseInt(u32, value, 10) catch null;
                if (index == 5) key.key_created = std.fmt.parseInt(u64, value, 10) catch null;
                if (index == 6) key.key_expires = std.fmt.parseInt(u64, value, 10) catch null;
                if (index == 11 and std.mem.indexOfScalar(u8, value, 'D') != null) key.status = .key_disabled;
            }
        }
    }
    return report;
}

fn succeeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn runImport(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: Context,
    args: []const []const u8,
    report: *Report,
) !bool {
    const result = try context.capture(allocator, io, args);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try report.recordKeyOperation(
        .{
            .termination = result.term,
            .status_output = result.stdout,
            .diagnostics = result.stderr,
        },
    );
    return succeeded(result.term);
}

fn matches(fingerprint: []const u8, requested: []const u8) bool {
    return Report.validIdentifier(fingerprint) and std.ascii.endsWithIgnoreCase(fingerprint, requested);
}

/// Returns the primary fingerprint owning a requested primary/subkey fingerprint
/// (or long key ID). Never imports unrelated primary keys from a supplied file.
fn findPrimary(listing: []const u8, requested: []const u8) ?[]const u8 {
    var primary: ?[]const u8 = null;
    var next_primary = false;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "pub:")) {
            primary = null;
            next_primary = true;
        }
        if (!std.mem.startsWith(u8, line, "fpr:")) continue;
        var fields = std.mem.splitScalar(u8, line, ':');
        var index: usize = 0;
        while (fields.next()) |field| : (index += 1) {
            if (index != 9) continue;
            if (next_primary) {
                primary = field;
                next_primary = false;
            }
            if (matches(field, requested)) return primary;
        }
    }
    return null;
}

fn importKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: Context,
    id: []const u8,
    uid: ?[]const u8,
    report: *Report,
) !void {
    if (!Report.validIdentifier(id)) return error.InvalidSignature;
    for (context.acquisition.key_files) |path| {
        var key = try Snapshot.copy(io, path);
        defer key.deinit();
        const listing = try context.capture(
            allocator,
            io,
            &(verify_options ++ .{
                "--with-colons",
                "--show-keys",
                "--",
                key.path(),
            }),
        );
        defer allocator.free(listing.stdout);
        defer allocator.free(listing.stderr);
        try report.recordKeyOperation(
            .{
                .termination = listing.term,
                .status_output = listing.stdout,
                .diagnostics = listing.stderr,
            },
        );
        if (!succeeded(listing.term)) return error.KeyImportFailed;
        _ = findPrimary(listing.stdout, id) orelse continue;
        var primary_count: usize = 0;
        var lines = std.mem.splitScalar(u8, listing.stdout, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "pub:")) primary_count += 1;
            if (std.mem.startsWith(u8, line, "sec:") or std.mem.startsWith(u8, line, "ssb:"))
                return error.InvalidKeySource;
        }
        if (primary_count != 1) return error.InvalidKeySource;
        if (!try runImport(
            allocator,
            io,
            context,
            &(verify_options ++ .{ "--import", "--", key.path() }),
            report,
        ))
            return error.KeyImportFailed;
        return;
    }
    // Acquisition may use this keyring's gpg.conf/keyserver settings, like the
    // reference. It is never invoked by verify(), only after the question above.
    const acquire_options = [_][]const u8{
        "--batch",
        "--no-tty",
        "--no-auto-key-retrieve",
        "--no-auto-key-import",
        "--keyserver-options",
        "only-pubkeys",
    };
    if (context.acquisition.allow_wkd) {
        if (uid) |user_id| {
            if (std.mem.indexOfScalar(u8, user_id, '<')) |start| {
                if (std.mem.indexOfScalarPos(u8, user_id, start + 1, '>')) |end| {
                    const email = user_id[start + 1 .. end];
                    if (std.mem.indexOfScalar(u8, email, '@') != null and
                        std.mem.indexOfAny(u8, email, "\x00\r\n") == null)
                    {
                        if (try runImport(
                            allocator,
                            io,
                            context,
                            &(acquire_options ++ .{
                                "--auto-key-locate",
                                "clear,wkd",
                                "--locate-external-key",
                                "--",
                                email,
                            }),
                            report,
                        )) {
                            const listing = try context.capture(
                                allocator,
                                io,
                                &(verify_options ++ .{ "--with-colons", "--list-keys", "--", id }),
                            );
                            defer allocator.free(listing.stdout);
                            defer allocator.free(listing.stderr);
                            try report.recordKeyOperation(
                                .{
                                    .termination = listing.term,
                                    .status_output = listing.stdout,
                                    .diagnostics = listing.stderr,
                                },
                            );
                            if (succeeded(listing.term) and findPrimary(listing.stdout, id) != null) return;
                        }
                    }
                }
            }
        }
    }
    if (context.acquisition.allow_keyserver) {
        const ok = if (context.acquisition.keyserver) |server|
            try runImport(
                allocator,
                io,
                context,
                &(acquire_options ++ .{
                    "--keyserver",
                    server,
                    "--recv-keys",
                    "--",
                    id,
                }),
                report,
            )
        else
            try runImport(allocator, io, context, &(acquire_options ++ .{ "--recv-keys", "--", id }), report);
        if (!ok) return error.KeyImportFailed;
        return;
    }
    return error.KeyAcquisitionUnavailable;
}
