//! Maintenance of a repository database pair: staging, entry creation,
//! publication, and rotation of `<name>.db.tar.*` with `<name>.files.tar.*`.

const std = @import("std");
const archive = @import("archive");
const pkginfo = @import("pkginfo.zig");
const alpm_manager = @import("../alpm/manager.zig");
const package_signer = @import("../shared/package_signer.zig");
const source_pgp_verifier = @import("../shared/source_pgp_verifier.zig");

const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error || archive.Error || std.Io.Cancelable || std.Io.UnexpectedError || error{
    /// The database basename is not one of the writable `.db.tar.*` forms.
    UnsupportedExtension,
    /// No database file exists where an operation requires one.
    DatabaseNotFound,
    /// An existing database cannot be read as a package database.
    InvalidDatabase,
    /// The database directory is missing or is not a directory.
    DirectoryMissing,
    /// Another process holds the lock and waiting was not requested.
    LockHeld,
    NoSpaceLeft,
    PermissionDenied,
    /// No package paths or names were given.
    NoArguments,
};

pub const AddOptions = struct {
    new_only: bool = false,
    prevent_downgrade: bool = false,
    remove_old_files: bool = false,
    include_sigs: bool = false,
    wait_for_lock: bool = false,
    /// Set to sign both published archives with a detached binary signature.
    signer: ?package_signer.Signer = null,
    /// Passed to the signer as `--local-user`; null lets GnuPG pick the default key.
    sign_key: ?[]const u8 = null,
};

pub const RemoveOptions = struct {
    remove_old_files: bool = false,
    wait_for_lock: bool = false,
    signer: ?package_signer.Signer = null,
    sign_key: ?[]const u8 = null,
};

pub const AddedEntry = struct { name: []const u8, version: []const u8, filename: []const u8 };

pub const FailureKind = enum {
    missing_file,
    not_a_package,
    invalid_package,
    armored_signature,
    oversized_signature,
};

pub const Failure = struct { package_path: []const u8, kind: FailureKind };

pub const AddSummary = struct {
    added: []const AddedEntry = &.{},
    /// Entry dir names (`<name>-<ver>`) whose identical entry already existed.
    skipped_existing: []const []const u8 = &.{},
    /// Package names whose existing entry compares strictly newer.
    skipped_newer: []const []const u8 = &.{},
    failures: []const Failure = &.{},
    /// False when nothing was published, including a fully skipped run.
    published: bool = false,
    /// True when the published database carries no entries.
    published_empty: bool = false,
    /// Basenames of removed old package files, in removal order.
    removed_files: []const []const u8 = &.{},

    pub fn deinit(self: *AddSummary, allocator: Allocator) void {
        for (self.added) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.version);
            allocator.free(entry.filename);
        }
        allocator.free(self.added);
        freeStringSlice(allocator, self.skipped_existing);
        freeStringSlice(allocator, self.skipped_newer);
        for (self.failures) |failure| allocator.free(failure.package_path);
        allocator.free(self.failures);
        freeStringSlice(allocator, self.removed_files);
        self.* = undefined;
    }
};

pub const RemoveSummary = struct {
    /// Entry dir names that were removed, in removal order.
    removed_entries: []const []const u8 = &.{},
    /// Requested names that matched no entry.
    not_found: []const []const u8 = &.{},
    published: bool = false,
    published_empty: bool = false,
    removed_files: []const []const u8 = &.{},

    pub fn deinit(self: *RemoveSummary, allocator: Allocator) void {
        freeStringSlice(allocator, self.removed_entries);
        freeStringSlice(allocator, self.not_found);
        freeStringSlice(allocator, self.removed_files);
        self.* = undefined;
    }
};

pub const EntryInfo = struct { name: []const u8, version: []const u8, filename: []const u8 };

pub const VerifyTarget = enum { database, files };

pub const VerifyResult = struct {
    target: VerifyTarget,
    /// False when the archive is absent, leaving nothing to check.
    archive_present: bool,
    /// False when `<archive>.sig` is absent: upstream warns and skips the check.
    signature_present: bool,
    /// True only when a present signature verified.
    verified: bool,
    warning: source_pgp_verifier.Warning,
    /// Primary signing key fingerprint, empty unless `verified`.
    fingerprint: []const u8,
};

pub const VerifySummary = struct {
    /// One result per archive, stopping before the second when the first
    /// signature is present but unusable.
    results: []const VerifyResult = &.{},

    pub fn deinit(self: *VerifySummary, allocator: Allocator) void {
        for (self.results) |result| allocator.free(result.fingerprint);
        allocator.free(self.results);
        self.* = undefined;
    }
};

pub fn freeEntries(allocator: Allocator, entries: []EntryInfo) void {
    for (entries) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.version);
        allocator.free(entry.filename);
    }
    allocator.free(entries);
}

/// Upstream rejects signatures above this size; the read is bounded by it too.
const max_signature_size = 16384;
const read_chunk_size = 8 * 1024;
const digest_chunk_size = 64 * 1024;

const file_permissions = std.Io.File.Permissions.fromMode(0o644);
const staging_directory_permissions = std.Io.File.Permissions.fromMode(0o700);

/// Makes staging directory names unique without consulting the filesystem.
var staging_counter: std.atomic.Value(u64) = .init(0);

pub const Database = struct {
    allocator: Allocator,
    io: std.Io,
    /// The path as given by the caller.
    db_path: []const u8,
    /// Directory part, `"."` when the path has none.
    db_dir: []const u8,
    db_filename: []const u8,
    files_path: []const u8,
    files_filename: []const u8,
    /// Extension-less names, to be joined with `db_dir`.
    db_link: []const u8,
    files_link: []const u8,
    lock_path: []const u8,

    /// Validates and derives the name pair. Touches no filesystem entry.
    pub fn open(allocator: Allocator, io: std.Io, db_path: []const u8) Error!Database {
        const db_filename = std.fs.path.basename(db_path);
        const suffix = databaseSuffix(db_filename) orelse return error.UnsupportedExtension;
        const stem_len = db_filename.len - ".db.".len - suffix.len;
        if (stem_len == 0) return error.UnsupportedExtension;
        const prefix = db_filename[0..stem_len];
        const db_dir = std.fs.path.dirname(db_path) orelse ".";

        const owned_path = try allocator.dupe(u8, db_path);
        errdefer allocator.free(owned_path);
        const owned_dir = try allocator.dupe(u8, db_dir);
        errdefer allocator.free(owned_dir);
        const owned_filename = try allocator.dupe(u8, db_filename);
        errdefer allocator.free(owned_filename);
        const files_filename = try std.fmt.allocPrint(allocator, "{s}.files.{s}", .{ prefix, suffix });
        errdefer allocator.free(files_filename);
        const files_path = try joinDir(allocator, db_dir, files_filename);
        errdefer allocator.free(files_path);
        const db_link = try std.fmt.allocPrint(allocator, "{s}.db", .{prefix});
        errdefer allocator.free(db_link);
        const files_link = try std.fmt.allocPrint(allocator, "{s}.files", .{prefix});
        errdefer allocator.free(files_link);
        const lock_path = try std.fmt.allocPrint(allocator, "{s}.lock", .{db_path});
        errdefer allocator.free(lock_path);

        return .{
            .allocator = allocator,
            .io = io,
            .db_path = owned_path,
            .db_dir = owned_dir,
            .db_filename = owned_filename,
            .files_path = files_path,
            .files_filename = files_filename,
            .db_link = db_link,
            .files_link = files_link,
            .lock_path = lock_path,
        };
    }

    pub fn deinit(self: *Database) void {
        const allocator = self.allocator;
        allocator.free(self.db_path);
        allocator.free(self.db_dir);
        allocator.free(self.db_filename);
        allocator.free(self.files_path);
        allocator.free(self.files_filename);
        allocator.free(self.db_link);
        allocator.free(self.files_link);
        allocator.free(self.lock_path);
        self.* = undefined;
    }

    pub fn addPackages(
        self: *Database,
        package_paths: []const []const u8,
        options: AddOptions,
    ) Error!AddSummary {
        if (package_paths.len == 0) return error.NoArguments;
        try self.requireDatabaseDirectory();
        var lock = try self.acquireLock(options.wait_for_lock);
        defer lock.release();

        var staging = try Staging.create(self.allocator, self.io, self.db_dir);
        defer staging.deinit();
        try self.extractIfPresent(self.db_path, staging.db_root);
        try self.extractIfPresent(self.files_path, staging.files_root);

        var added: std.ArrayList(AddedEntry) = .empty;
        defer freeAdded(self.allocator, &added);
        var skipped_existing: std.ArrayList([]const u8) = .empty;
        defer freeStringList(self.allocator, &skipped_existing);
        var skipped_newer: std.ArrayList([]const u8) = .empty;
        defer freeStringList(self.allocator, &skipped_newer);
        var failures: std.ArrayList(Failure) = .empty;
        defer freeFailureList(self.allocator, &failures);
        var old_files: std.ArrayList([]const u8) = .empty;
        defer freeStringList(self.allocator, &old_files);
        var removed_files: std.ArrayList([]const u8) = .empty;
        defer freeStringList(self.allocator, &removed_files);

        var modified = false;
        for (package_paths) |package_path| {
            const package_stat = std.Io.Dir.cwd().statFile(self.io, package_path, .{}) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => {
                    try appendFailureCopy(self.allocator, &failures, package_path, .missing_file);
                    continue;
                },
                else => return mapIoError(err),
            };
            if (package_stat.kind != .file) {
                try appendFailureCopy(self.allocator, &failures, package_path, .missing_file);
                continue;
            }

            var info = pkginfo.readFromPackage(self.allocator, package_path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.MissingPkginfo => {
                    try appendFailureCopy(self.allocator, &failures, package_path, .invalid_package);
                    continue;
                },
                else => {
                    try appendFailureCopy(self.allocator, &failures, package_path, .not_a_package);
                    continue;
                },
            };
            defer info.deinit(self.allocator);

            const file_paths = pkginfo.listFilePaths(self.allocator, package_path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    try appendFailureCopy(self.allocator, &failures, package_path, .not_a_package);
                    continue;
                },
            };
            defer pkginfo.freeFilePaths(self.allocator, file_paths);

            const entry_dir = try std.fmt.allocPrint(self.allocator, "{s}-{s}", .{ info.pkgname, info.pkgver });
            defer self.allocator.free(entry_dir);
            // The entry name comes from package metadata, so it must not be
            // able to place staging writes outside the staging tree.
            if (std.mem.indexOfScalar(u8, entry_dir, '/') != null) {
                try appendFailureCopy(self.allocator, &failures, package_path, .invalid_package);
                continue;
            }

            const staging_entries = try stageEntryDirs(self.allocator, self.io, staging.db);
            defer freeStringSlice(self.allocator, staging_entries);

            if (hasEntryDir(staging_entries, entry_dir)) {
                try appendStringCopy(self.allocator, &skipped_existing, entry_dir);
                if (options.new_only) continue;
            } else if (findPackageEntry(staging_entries, info.pkgname)) |existing_entry| {
                const existing_desc = try self.readStagingDesc(staging.db, existing_entry);
                defer self.allocator.free(existing_desc);
                if (try compareVersions(self.allocator, descField(existing_desc, "VERSION"), info.pkgver) > 0) {
                    try appendStringCopy(self.allocator, &skipped_newer, info.pkgname);
                    if (options.prevent_downgrade) continue;
                }
                if (options.remove_old_files) {
                    const old_filename = descField(existing_desc, "FILENAME");
                    const incoming_filename = std.fs.path.basename(package_path);
                    if (deletableOldFilename(old_filename) and
                        !std.mem.eql(u8, old_filename, incoming_filename))
                        try appendStringCopy(self.allocator, &old_files, old_filename);
                }
            }

            var pgpsig: ?[]const u8 = null;
            defer if (pgpsig) |sig| self.allocator.free(sig);
            if (options.include_sigs) {
                pgpsig = self.signatureFor(package_path) catch |err| switch (err) {
                    error.ArmoredSignature => {
                        try appendFailureCopy(self.allocator, &failures, package_path, .armored_signature);
                        continue;
                    },
                    error.OversizedSignature => {
                        try appendFailureCopy(self.allocator, &failures, package_path, .oversized_signature);
                        continue;
                    },
                    else => |other| return mapIoError(other),
                };
            }

            const sha256_hex = try self.sha256Hex(package_path);
            const desc = try buildDesc(
                self.allocator,
                &info,
                std.fs.path.basename(package_path),
                package_stat.size,
                &sha256_hex,
                pgpsig,
            );
            defer self.allocator.free(desc);
            const files = try buildFiles(self.allocator, file_paths);
            defer self.allocator.free(files);

            for (staging_entries) |staging_entry| {
                const name = entryPackage(staging_entry) orelse continue;
                if (!std.mem.eql(u8, name, info.pkgname)) continue;
                try deleteStagingEntry(self.io, &staging, staging_entry);
            }
            try writeEntryFile(self.allocator, self.io, staging.db, entry_dir, "desc", desc);
            try writeEntryFile(self.allocator, self.io, staging.files, entry_dir, "desc", desc);
            try writeEntryFile(self.allocator, self.io, staging.files, entry_dir, "files", files);

            try appendAdded(self.allocator, &added, info.pkgname, info.pkgver, std.fs.path.basename(package_path));
            modified = true;
        }

        var summary: AddSummary = .{};
        errdefer summary.deinit(self.allocator);

        const should_publish = failures.items.len == 0 and modified;
        var published_empty = false;
        if (should_publish) {
            published_empty = try self.publish(&staging, options.signer, options.sign_key);
            if (options.remove_old_files)
                try self.removeOldFiles(old_files.items, &removed_files);
        }

        summary.added = try added.toOwnedSlice(self.allocator);
        summary.skipped_existing = try skipped_existing.toOwnedSlice(self.allocator);
        summary.skipped_newer = try skipped_newer.toOwnedSlice(self.allocator);
        summary.failures = try failures.toOwnedSlice(self.allocator);
        summary.removed_files = try removed_files.toOwnedSlice(self.allocator);
        summary.published = should_publish;
        summary.published_empty = published_empty;
        return summary;
    }

    pub fn removePackages(
        self: *Database,
        names: []const []const u8,
        options: RemoveOptions,
    ) Error!RemoveSummary {
        if (names.len == 0) return error.NoArguments;
        try self.requireDatabaseFile();
        var lock = try self.acquireLock(options.wait_for_lock);
        defer lock.release();

        var staging = try Staging.create(self.allocator, self.io, self.db_dir);
        defer staging.deinit();
        try self.extractIfPresent(self.db_path, staging.db_root);
        try self.extractIfPresent(self.files_path, staging.files_root);

        var removed_entries: std.ArrayList([]const u8) = .empty;
        defer freeStringList(self.allocator, &removed_entries);
        var not_found: std.ArrayList([]const u8) = .empty;
        defer freeStringList(self.allocator, &not_found);
        var old_files: std.ArrayList([]const u8) = .empty;
        defer freeStringList(self.allocator, &old_files);
        var removed_files: std.ArrayList([]const u8) = .empty;
        defer freeStringList(self.allocator, &removed_files);

        var modified = false;
        for (names) |name| {
            const staging_entries = try stageEntryDirs(self.allocator, self.io, staging.db);
            defer freeStringSlice(self.allocator, staging_entries);
            var matched = false;
            for (staging_entries) |staging_entry| {
                const derived = entryPackage(staging_entry) orelse continue;
                if (!std.mem.eql(u8, derived, name)) continue;
                matched = true;
                if (options.remove_old_files) {
                    const desc = try self.readStagingDesc(staging.db, staging_entry);
                    defer self.allocator.free(desc);
                    const old_filename = descField(desc, "FILENAME");
                    if (deletableOldFilename(old_filename))
                        try appendStringCopy(self.allocator, &old_files, old_filename);
                }
                try appendStringCopy(self.allocator, &removed_entries, staging_entry);
                try deleteStagingEntry(self.io, &staging, staging_entry);
                modified = true;
            }
            if (!matched) try appendStringCopy(self.allocator, &not_found, name);
        }

        var summary: RemoveSummary = .{};
        errdefer summary.deinit(self.allocator);

        const should_publish = not_found.items.len == 0 and modified;
        var published_empty = false;
        if (should_publish) {
            published_empty = try self.publish(&staging, options.signer, options.sign_key);
            if (options.remove_old_files)
                try self.removeOldFiles(old_files.items, &removed_files);
        }

        summary.removed_entries = try removed_entries.toOwnedSlice(self.allocator);
        summary.not_found = try not_found.toOwnedSlice(self.allocator);
        summary.removed_files = try removed_files.toOwnedSlice(self.allocator);
        summary.published = should_publish;
        summary.published_empty = published_empty;
        return summary;
    }

    /// Lists the entries of the database archive in archive order.
    pub fn listEntries(self: *Database) Error![]EntryInfo {
        try self.requireDatabaseFile();
        var reader = archive.Reader.initAll(self.allocator, self.db_path) catch |err| switch (err) {
            error.ArchiveOpenFailed => return error.InvalidDatabase,
            else => return mapIoError(err),
        };
        defer reader.deinit();

        var entries: std.ArrayList(EntryInfo) = .empty;
        errdefer freeEntryList(self.allocator, &entries);
        var contents: std.ArrayList(u8) = .empty;
        defer contents.deinit(self.allocator);
        var buffer: [read_chunk_size]u8 = undefined;

        while (true) {
            const maybe_entry = reader.next() catch |err| switch (err) {
                error.InvalidEntryPath => return error.InvalidDatabase,
                else => return mapIoError(err),
            };
            const entry = maybe_entry orelse break;
            if (entry.kind != .regular_file) continue;
            const path = archive.normalizeEntryPath(self.allocator, entry.path) catch |err| switch (err) {
                error.InvalidEntryPath => return error.InvalidDatabase,
                else => return mapIoError(err),
            };
            defer self.allocator.free(path);
            if (!isEntryDesc(path)) continue;

            contents.clearRetainingCapacity();
            while (true) {
                const amount = reader.read(&buffer) catch |err| return mapIoError(err);
                if (amount == 0) break;
                if (contents.items.len + amount > pkginfo.max_pkginfo_size) return error.InvalidDatabase;
                try contents.appendSlice(self.allocator, buffer[0..amount]);
            }

            const name = try self.allocator.dupe(u8, descField(contents.items, "NAME"));
            errdefer self.allocator.free(name);
            const version = try self.allocator.dupe(u8, descField(contents.items, "VERSION"));
            errdefer self.allocator.free(version);
            const filename = try self.allocator.dupe(u8, descField(contents.items, "FILENAME"));
            errdefer self.allocator.free(filename);
            try entries.append(self.allocator, .{
                .name = name,
                .version = version,
                .filename = filename,
            });
        }
        return entries.toOwnedSlice(self.allocator);
    }

    /// Checks the detached signature of each present archive. Nothing is pinned,
    /// so a signature counts only when GnuPG also reports the signing key as
    /// trusted. Read-only: no lock, no staging, like `listEntries`.
    pub fn verifySignatures(self: *Database, verifier: source_pgp_verifier.Verifier) Error!VerifySummary {
        try self.requireDatabaseFile();

        const archives = [_]struct { target: VerifyTarget, path: []const u8 }{
            .{ .target = .database, .path = self.db_path },
            .{ .target = .files, .path = self.files_path },
        };
        var results: std.ArrayList(VerifyResult) = .empty;
        errdefer freeVerifyResults(self.allocator, &results);
        try results.ensureTotalCapacity(self.allocator, archives.len);
        for (archives) |item| {
            const result = try self.verifyOne(verifier, item.target, item.path);
            results.appendAssumeCapacity(result);
            if (result.signature_present and !result.verified) break;
        }
        return .{ .results = try results.toOwnedSlice(self.allocator) };
    }

    /// An unusable signature is a result, not an operation error; only a check
    /// that never got to GnuPG's verdict propagates.
    fn verifyOne(
        self: *Database,
        verifier: source_pgp_verifier.Verifier,
        target: VerifyTarget,
        archive_path: []const u8,
    ) Error!VerifyResult {
        var result: VerifyResult = .{
            .target = target,
            .archive_present = try isRegularFile(self.io, archive_path),
            .signature_present = false,
            .verified = false,
            .warning = .none,
            .fingerprint = try self.allocator.dupe(u8, ""),
        };
        errdefer self.allocator.free(result.fingerprint);
        if (!result.archive_present) return result;

        const signature_path = try signaturePath(self.allocator, archive_path);
        defer self.allocator.free(signature_path);
        result.signature_present = try isRegularFile(self.io, signature_path);
        if (!result.signature_present) return result;

        var verification = verifier.verifyDetached(signature_path, archive_path, &.{}) catch |err| {
            switch (err) {
                error.MissingPgpSignature,
                error.PgpVerificationFailed,
                error.RevokedPgpKey,
                error.BadPgpSignature,
                error.MissingPgpKey,
                error.InvalidPgpStatus,
                error.InvalidPgpKey,
                error.InvalidPgpFingerprint,
                error.UntrustedPgpKey,
                => return result,
                else => return mapIoError(err),
            }
        };
        defer verification.deinit(self.allocator);
        const fingerprint = try self.allocator.dupe(u8, verification.primary_fingerprint);
        const absent = result.fingerprint;
        result.fingerprint = fingerprint;
        self.allocator.free(absent);
        result.verified = true;
        result.warning = verification.warning;
        return result;
    }

    fn requireDatabaseDirectory(self: *Database) Error!void {
        const stat = std.Io.Dir.cwd().statFile(self.io, self.db_dir, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return error.DirectoryMissing,
            else => return mapIoError(err),
        };
        if (stat.kind != .directory) return error.DirectoryMissing;
    }

    fn requireDatabaseFile(self: *Database) Error!void {
        const stat = std.Io.Dir.cwd().statFile(self.io, self.db_path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return error.DatabaseNotFound,
            else => return mapIoError(err),
        };
        if (stat.kind != .file) return error.DatabaseNotFound;
    }

    fn acquireLock(self: *Database, wait: bool) Error!LockGuard {
        const file = std.Io.Dir.cwd().createFile(self.io, self.lock_path, .{
            .read = true,
            .truncate = false,
        }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return error.DirectoryMissing,
            else => return mapIoError(err),
        };
        errdefer file.close(self.io);

        if (wait) {
            file.lock(self.io, .exclusive) catch |err| return mapIoError(err);
        } else {
            const acquired = file.tryLock(self.io, .exclusive) catch |err| return mapIoError(err);
            if (!acquired) return error.LockHeld;
        }
        return .{ .file = file, .io = self.io };
    }

    fn extractIfPresent(self: *Database, archive_path: []const u8, dest_root: []const u8) Error!void {
        const stat = std.Io.Dir.cwd().statFile(self.io, archive_path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return,
            else => return mapIoError(err),
        };
        if (stat.kind != .file) return;
        const extracted = try extractTo(self.allocator, self.io, archive_path, dest_root);
        if (extracted.members > 0 and !extracted.saw_desc) return error.InvalidDatabase;
    }

    fn readStagingDesc(self: *Database, tree: std.Io.Dir, entry_dir: []const u8) Error![]u8 {
        const desc_rel = try std.fmt.allocPrint(self.allocator, "{s}/desc", .{entry_dir});
        defer self.allocator.free(desc_rel);
        return tree.readFileAlloc(self.io, desc_rel, self.allocator, .limited(pkginfo.max_pkginfo_size)) catch |err| switch (err) {
            error.FileNotFound => try self.allocator.alloc(u8, 0),
            error.StreamTooLong => return error.InvalidDatabase,
            else => return mapIoError(err),
        };
    }

    fn signatureFor(self: *Database, package_path: []const u8) (Error || SignatureError)!?[]const u8 {
        const signature_path = try std.fmt.allocPrint(self.allocator, "{s}.sig", .{package_path});
        defer self.allocator.free(signature_path);

        const stat = std.Io.Dir.cwd().statFile(self.io, signature_path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return null,
            else => return mapIoError(err),
        };
        if (stat.kind != .file) return null;
        if (stat.size > max_signature_size) return error.OversizedSignature;

        const contents = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            signature_path,
            self.allocator,
            .limited(max_signature_size),
        ) catch |err| switch (err) {
            error.StreamTooLong => return error.OversizedSignature,
            else => return mapIoError(err),
        };
        defer self.allocator.free(contents);
        if (std.mem.indexOf(u8, contents, "BEGIN PGP SIGNATURE") != null)
            return error.ArmoredSignature;

        const encoded_len = std.base64.standard.Encoder.calcSize(contents.len);
        const encoded = try self.allocator.alloc(u8, encoded_len);
        _ = std.base64.standard.Encoder.encode(encoded, contents);
        return encoded;
    }

    fn sha256Hex(self: *Database, path: []const u8) Error![std.crypto.hash.sha2.Sha256.digest_length * 2]u8 {
        var file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch |err| return mapIoError(err);
        defer file.close(self.io);
        const stat = file.stat(self.io) catch |err| return mapIoError(err);

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var buffer: [digest_chunk_size]u8 = undefined;
        var offset: u64 = 0;
        while (offset < stat.size) {
            const remaining: usize = @intCast(@min(stat.size - offset, buffer.len));
            const amount = file.readPositionalAll(self.io, buffer[0..remaining], offset) catch |err|
                return mapIoError(err);
            if (amount == 0) return error.Unexpected;
            hasher.update(buffer[0..amount]);
            offset += amount;
        }
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        hasher.final(&digest);
        return std.fmt.bytesToHex(digest, .lower);
    }

    /// Writes, optionally signs, and rotates both archives; returns whether the
    /// db tree was empty.
    fn publish(
        self: *Database,
        staging: *const Staging,
        signer: ?package_signer.Signer,
        sign_key: ?[]const u8,
    ) Error!bool {
        const empty = !try dirHasEntries(self.io, staging.db_root);

        try self.writeTmpArchive(staging.db_root, self.db_filename);
        try self.writeTmpArchive(staging.files_root, self.files_filename);
        errdefer {
            self.deleteTmpArchive(self.db_filename);
            self.deleteTmpArchive(self.files_filename);
        }

        if (signer) |selected| {
            try self.signTmpArchive(selected, sign_key, self.db_filename);
            try self.signTmpArchive(selected, sign_key, self.files_filename);
        }

        try self.rotateOne(self.db_filename);
        try self.rotateOne(self.files_filename);
        try self.refreshLink(self.db_filename, self.db_link);
        try self.refreshLink(self.files_filename, self.files_link);
        return empty;
    }

    fn writeTmpArchive(self: *Database, source_root: []const u8, filename: []const u8) Error!void {
        const tmp_path = try self.tmpPath(filename);
        defer self.allocator.free(tmp_path);
        errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
        const staged_signature = try signaturePath(self.allocator, tmp_path);
        defer self.allocator.free(staged_signature);
        // A signature staged by an aborted run must not survive beside this archive.
        try deleteFileIgnoringMissing(self.io, staged_signature);

        var writer = try archive.Writer.init(self.allocator, self.io, tmp_path);
        defer writer.deinit();
        writer.addDirectory(source_root) catch |err| return mapIoError(err);
        try writer.finish();

        // The writer never fsyncs; reopen so the rename below is durable.
        var file = std.Io.Dir.cwd().openFile(self.io, tmp_path, .{}) catch |err| return mapIoError(err);
        defer file.close(self.io);
        file.sync(self.io) catch |err| return mapIoError(err);
    }

    /// A signing failure leaves the archive publishable and unsigned, so it is
    /// reported through the log instead of aborting the operation.
    fn signTmpArchive(
        self: *Database,
        signer: package_signer.Signer,
        key: ?[]const u8,
        filename: []const u8,
    ) Error!void {
        const tmp_path = try self.tmpPath(filename);
        defer self.allocator.free(tmp_path);
        const staged_signature = try signaturePath(self.allocator, tmp_path);
        defer self.allocator.free(staged_signature);

        signer.signDetached(tmp_path, staged_signature, key) catch |err| {
            std.log.warn(
                "Could not sign repository database {0f}. {1s} Review the signing key and signer output.\n\nTechnical details: {2s}",
                .{ @import("diagnostics").safe(filename), @import("diagnostics").cause(err), @errorName(err) },
            );
            // A signer that died mid-write can leave a partial file behind.
            deleteFileIgnoringMissing(self.io, staged_signature) catch {};
        };
    }

    fn deleteTmpArchive(self: *Database, filename: []const u8) void {
        const tmp_path = self.tmpPath(filename) catch return;
        defer self.allocator.free(tmp_path);
        deleteFileIgnoringMissing(self.io, tmp_path) catch {};
        const staged_signature = signaturePath(self.allocator, tmp_path) catch return;
        defer self.allocator.free(staged_signature);
        deleteFileIgnoringMissing(self.io, staged_signature) catch {};
    }

    fn rotateOne(self: *Database, filename: []const u8) Error!void {
        const target = try self.dirPath(filename);
        defer self.allocator.free(target);
        const signature = try std.fmt.allocPrint(self.allocator, "{s}.sig", .{target});
        defer self.allocator.free(signature);

        const existing = std.Io.Dir.cwd().statFile(self.io, target, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return mapIoError(err),
        };
        if (existing != null and existing.?.kind == .file) {
            const backup = try std.fmt.allocPrint(self.allocator, "{s}.old", .{target});
            defer self.allocator.free(backup);
            try deleteFileIgnoringMissing(self.io, backup);
            try linkOrMove(self.io, target, backup);

            const backup_signature = try std.fmt.allocPrint(self.allocator, "{s}.old.sig", .{target});
            defer self.allocator.free(backup_signature);
            const signature_stat = std.Io.Dir.cwd().statFile(self.io, signature, .{}) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return mapIoError(err),
            };
            if (signature_stat != null and signature_stat.?.kind == .file)
                try linkOrMove(self.io, signature, backup_signature)
            else
                try deleteFileIgnoringMissing(self.io, backup_signature);
        }

        const tmp = try self.tmpPath(filename);
        defer self.allocator.free(tmp);
        std.Io.Dir.rename(.cwd(), tmp, .cwd(), target, self.io) catch |err| return mapIoError(err);

        const staged_signature = try signaturePath(self.allocator, tmp);
        defer self.allocator.free(staged_signature);
        if (try isRegularFile(self.io, staged_signature))
            std.Io.Dir.rename(.cwd(), staged_signature, .cwd(), signature, self.io) catch |err|
                return mapIoError(err);
    }

    fn refreshLink(self: *Database, filename: []const u8, link: []const u8) Error!void {
        const link_path = try self.dirPath(link);
        defer self.allocator.free(link_path);
        const link_signature = try std.fmt.allocPrint(self.allocator, "{s}.sig", .{link_path});
        defer self.allocator.free(link_signature);

        try deleteFileIgnoringMissing(self.io, link_path);
        try deleteFileIgnoringMissing(self.io, link_signature);
        try self.createLink(filename, link_path);

        const signature = try std.fmt.allocPrint(self.allocator, "{s}.sig", .{filename});
        defer self.allocator.free(signature);
        const signature_path = try self.dirPath(signature);
        defer self.allocator.free(signature_path);
        const signature_stat = std.Io.Dir.cwd().statFile(self.io, signature_path, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return mapIoError(err),
        };
        if (signature_stat != null and signature_stat.?.kind == .file)
            try self.createLink(signature, link_signature);
    }

    /// Points `link_path` at the relative `filename`, falling back to a
    /// hardlink and then to a byte copy when symlinks are unavailable.
    fn createLink(self: *Database, filename: []const u8, link_path: []const u8) Error!void {
        const target = try self.dirPath(filename);
        defer self.allocator.free(target);
        std.Io.Dir.cwd().symLink(self.io, filename, link_path, .{}) catch {
            std.Io.Dir.cwd().hardLink(target, .cwd(), link_path, self.io, .{}) catch {
                try copyFile(self.allocator, self.io, target, link_path);
            };
        };
    }

    fn removeOldFiles(
        self: *Database,
        filenames: []const []const u8,
        removed: *std.ArrayList([]const u8),
    ) Error!void {
        for (filenames) |filename| {
            const target = try self.dirPath(filename);
            defer self.allocator.free(target);
            try deleteFileIgnoringMissing(self.io, target);
            const signature = try std.fmt.allocPrint(self.allocator, "{s}.sig", .{target});
            defer self.allocator.free(signature);
            try deleteFileIgnoringMissing(self.io, signature);
            try appendStringCopy(self.allocator, removed, filename);
        }
    }

    fn tmpPath(self: *Database, filename: []const u8) Allocator.Error![]u8 {
        const name = try std.fmt.allocPrint(self.allocator, ".tmp.{s}", .{filename});
        defer self.allocator.free(name);
        return self.dirPath(name);
    }

    fn dirPath(self: *const Database, name: []const u8) Allocator.Error![]u8 {
        return joinDir(self.allocator, self.db_dir, name);
    }
};

const SignatureError = error{ ArmoredSignature, OversizedSignature };

/// Exclusive `flock` on a sidecar file, held for the length of an operation.
/// Rotation replaces the database inode, so a lock on the database itself would
/// stop excluding later lockers; a leftover sidecar file never blocks anyone.
const LockGuard = struct {
    file: std.Io.File,
    io: std.Io,

    fn release(self: *LockGuard) void {
        self.file.unlock(self.io);
        self.file.close(self.io);
        self.* = undefined;
    }
};

/// Extraction target for both database trees of one operation.
const Staging = struct {
    allocator: Allocator,
    io: std.Io,
    root: []const u8,
    db_root: []const u8,
    files_root: []const u8,
    db: std.Io.Dir,
    files: std.Io.Dir,

    fn create(allocator: Allocator, io: std.Io, db_dir: []const u8) Error!Staging {
        var attempt: u8 = 0;
        while (true) : (attempt += 1) {
            if (try createStaging(allocator, io, db_dir)) |staging| return staging;
            if (attempt >= 1) return error.Unexpected;
        }
    }

    fn deinit(self: *Staging) void {
        self.db.close(self.io);
        self.files.close(self.io);
        std.Io.Dir.cwd().deleteTree(self.io, self.root) catch {};
        const allocator = self.allocator;
        allocator.free(self.root);
        allocator.free(self.db_root);
        allocator.free(self.files_root);
        self.* = undefined;
    }
};

fn createStaging(allocator: Allocator, io: std.Io, db_dir: []const u8) Error!?Staging {
    const counter = staging_counter.fetchAdd(1, .monotonic);
    const timestamp = std.Io.Timestamp.now(io, .awake).nanoseconds;
    const root = try std.fmt.allocPrint(
        allocator,
        "{s}/.shelly-repo-db-{d}-{x}",
        .{ std.mem.trimEnd(u8, db_dir, "/"), timestamp, counter },
    );
    errdefer allocator.free(root);
    std.Io.Dir.cwd().createDir(io, root, staging_directory_permissions) catch |err| switch (err) {
        error.PathAlreadyExists => {
            allocator.free(root);
            return null;
        },
        else => return mapIoError(err),
    };
    errdefer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const db_root = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    errdefer allocator.free(db_root);
    const files_root = try std.fmt.allocPrint(allocator, "{s}/files", .{root});
    errdefer allocator.free(files_root);
    std.Io.Dir.cwd().createDir(io, db_root, staging_directory_permissions) catch |err| return mapIoError(err);
    std.Io.Dir.cwd().createDir(io, files_root, staging_directory_permissions) catch |err| return mapIoError(err);
    const db = std.Io.Dir.cwd().openDir(io, db_root, .{ .iterate = true }) catch |err| return mapIoError(err);
    errdefer db.close(io);
    const files = std.Io.Dir.cwd().openDir(io, files_root, .{ .iterate = true }) catch |err| return mapIoError(err);

    return .{
        .allocator = allocator,
        .io = io,
        .root = root,
        .db_root = db_root,
        .files_root = files_root,
        .db = db,
        .files = files,
    };
}

const Extraction = struct { members: usize = 0, saw_desc: bool = false };

fn extractTo(
    allocator: Allocator,
    io: std.Io,
    archive_path: []const u8,
    dest_root: []const u8,
) Error!Extraction {
    var reader = archive.Reader.initAll(allocator, archive_path) catch |err| switch (err) {
        error.ArchiveOpenFailed => return error.InvalidDatabase,
        else => return mapIoError(err),
    };
    defer reader.deinit();
    var dest = std.Io.Dir.cwd().openDir(io, dest_root, .{}) catch |err| return mapIoError(err);
    defer dest.close(io);

    var extracted: Extraction = .{};
    var buffer: [read_chunk_size]u8 = undefined;
    while (true) {
        const maybe_entry = reader.next() catch |err| switch (err) {
            error.InvalidEntryPath => return error.InvalidDatabase,
            else => return mapIoError(err),
        };
        const entry = maybe_entry orelse break;
        extracted.members += 1;
        // Hostile member paths (absolute, `..`) must not reach the staging tree.
        const path = archive.normalizeEntryPath(allocator, entry.path) catch |err| switch (err) {
            error.InvalidEntryPath => return error.InvalidDatabase,
            else => return mapIoError(err),
        };
        defer allocator.free(path);

        switch (entry.kind) {
            .directory => dest.createDirPath(io, path) catch |err| return mapIoError(err),
            .regular_file => {
                if (std.fs.path.dirname(path)) |parent|
                    dest.createDirPath(io, parent) catch |err| return mapIoError(err);
                if (isEntryDesc(path)) extracted.saw_desc = true;
                var file = dest.createFile(io, path, .{ .permissions = file_permissions }) catch |err|
                    return mapIoError(err);
                defer file.close(io);
                while (true) {
                    const amount = reader.read(&buffer) catch |err| return mapIoError(err);
                    if (amount == 0) break;
                    file.writeStreamingAll(io, buffer[0..amount]) catch |err| return mapIoError(err);
                }
            },
            // A symlink member plus a later write through it would escape
            // staging; real databases contain neither it nor other kinds.
            .symbolic_link, .hard_link, .other => {},
        }
    }
    return extracted;
}

fn writeEntryFile(
    allocator: Allocator,
    io: std.Io,
    tree: std.Io.Dir,
    entry_dir: []const u8,
    name: []const u8,
    contents: []const u8,
) Error!void {
    const entry_rel = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ entry_dir, name });
    defer allocator.free(entry_rel);
    tree.createDirPath(io, entry_dir) catch |err| return mapIoError(err);
    tree.writeFile(io, .{
        .sub_path = entry_rel,
        .data = contents,
        .flags = .{ .permissions = file_permissions },
    }) catch |err| return mapIoError(err);
}

fn deleteStagingEntry(io: std.Io, staging: *const Staging, entry_dir: []const u8) Error!void {
    staging.db.deleteTree(io, entry_dir) catch |err| return mapIoError(err);
    staging.files.deleteTree(io, entry_dir) catch |err| return mapIoError(err);
}

fn stageEntryDirs(allocator: Allocator, io: std.Io, tree: std.Io.Dir) Error![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer freeStringList(allocator, &names);
    var iterator = tree.iterate();
    while (iterator.next(io) catch |err| return mapIoError(err)) |entry| {
        if (entry.kind != .directory) continue;
        const owned = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(owned);
        try names.append(allocator, owned);
    }
    std.mem.sort([]const u8, names.items, {}, lessThanString);
    return names.toOwnedSlice(allocator);
}

fn dirHasEntries(io: std.Io, path: []const u8) Error!bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| return mapIoError(err);
    defer dir.close(io);
    var iterator = dir.iterate();
    return (iterator.next(io) catch |err| return mapIoError(err)) != null;
}

fn buildDesc(
    allocator: Allocator,
    info: *const pkginfo.PkgInfo,
    filename: []const u8,
    csize: u64,
    sha256_hex: []const u8,
    pgpsig: ?[]const u8,
) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try appendSection(&out, allocator, "FILENAME", &.{filename});
    try appendSection(&out, allocator, "NAME", &.{info.pkgname});
    try appendSection(&out, allocator, "BASE", &.{info.pkgbase});
    try appendSection(&out, allocator, "VERSION", &.{info.pkgver});
    try appendSection(&out, allocator, "DESC", &.{info.pkgdesc});
    try appendSection(&out, allocator, "GROUPS", info.groups);
    var csize_buffer: [24]u8 = undefined;
    const csize_text = std.fmt.bufPrint(&csize_buffer, "{d}", .{csize}) catch unreachable;
    try appendSection(&out, allocator, "CSIZE", &.{csize_text});
    try appendSection(&out, allocator, "ISIZE", &.{info.size});
    try appendSection(&out, allocator, "SHA256SUM", &.{sha256_hex});
    if (pgpsig) |signature| try appendSection(&out, allocator, "PGPSIG", &.{signature});
    try appendSection(&out, allocator, "URL", &.{info.url});
    try appendSection(&out, allocator, "LICENSE", info.licenses);
    try appendSection(&out, allocator, "ARCH", &.{info.arch});
    try appendSection(&out, allocator, "BUILDDATE", &.{info.builddate});
    try appendSection(&out, allocator, "PACKAGER", &.{info.packager});
    try appendSection(&out, allocator, "REPLACES", info.replaces);
    try appendSection(&out, allocator, "CONFLICTS", info.conflicts);
    try appendSection(&out, allocator, "PROVIDES", info.provides);
    try appendSection(&out, allocator, "DEPENDS", info.depends);
    try appendSection(&out, allocator, "OPTDEPENDS", info.optdepends);
    try appendSection(&out, allocator, "MAKEDEPENDS", info.makedepends);
    try appendSection(&out, allocator, "CHECKDEPENDS", info.checkdepends);
    return out.toOwnedSlice(allocator);
}

fn buildFiles(allocator: Allocator, paths: []const []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "%FILES%\n");
    for (paths) |path| {
        try out.appendSlice(allocator, path);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

fn appendSection(
    out: *std.ArrayList(u8),
    allocator: Allocator,
    key: []const u8,
    values: []const []const u8,
) Allocator.Error!void {
    if (values.len == 0 or values[0].len == 0) return;
    try out.append(allocator, '%');
    try out.appendSlice(allocator, key);
    try out.appendSlice(allocator, "%\n");
    for (values) |value| {
        try out.appendSlice(allocator, value);
        try out.append(allocator, '\n');
    }
    try out.append(allocator, '\n');
}

/// First line after a line that is exactly `%KEY%`, empty when absent.
fn descField(contents: []const u8, key: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    var next_is_value = false;
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (next_is_value) return line;
        if (line.len == key.len + 2 and line[0] == '%' and line[line.len - 1] == '%' and
            std.mem.eql(u8, line[1 .. line.len - 1], key)) next_is_value = true;
    }
    return "";
}

/// `<entry>/desc` exactly one component deep, matching the `*/desc` pattern.
fn isEntryDesc(path: []const u8) bool {
    if (!std.mem.endsWith(u8, path, "/desc")) return false;
    const prefix = path[0 .. path.len - "/desc".len];
    return prefix.len != 0 and std.mem.indexOfScalar(u8, prefix, '/') == null;
}

/// The `<name>` of a `<name>-<version>` dir: everything before the last two
/// dash-separated fields. A name with fewer than two dashes never matches.
fn entryPackage(dir_name: []const u8) ?[]const u8 {
    const last = std.mem.lastIndexOfScalar(u8, dir_name, '-') orelse return null;
    const previous = std.mem.lastIndexOfScalar(u8, dir_name[0..last], '-') orelse return null;
    return dir_name[0..previous];
}

fn hasEntryDir(entries: []const []const u8, entry_dir: []const u8) bool {
    for (entries) |name| if (std.mem.eql(u8, name, entry_dir)) return true;
    return false;
}

fn findPackageEntry(entries: []const []const u8, pkgname: []const u8) ?[]const u8 {
    for (entries) |entry_dir| {
        const name = entryPackage(entry_dir) orelse continue;
        if (std.mem.eql(u8, name, pkgname)) return entry_dir;
    }
    return null;
}

/// A captured `%FILENAME%` names a file to delete, so it must be a plain
/// basename: a directory component could reach outside the database directory.
fn deletableOldFilename(filename: []const u8) bool {
    if (filename.len == 0 or std.mem.eql(u8, filename, ".") or std.mem.eql(u8, filename, ".."))
        return false;
    return std.mem.eql(u8, std.fs.path.basename(filename), filename);
}

fn compareVersions(allocator: Allocator, a: []const u8, b: []const u8) Allocator.Error!c_int {
    const a_z = try allocator.dupeZ(u8, a);
    defer allocator.free(a_z);
    const b_z = try allocator.dupeZ(u8, b);
    defer allocator.free(b_z);
    return alpm_manager.Manager.compare_package_versions(a_z, b_z);
}

fn databaseSuffix(filename: []const u8) ?[]const u8 {
    inline for (.{ "tar", "tar.gz", "tar.bz2", "tar.xz", "tar.zst" }) |suffix| {
        if (std.mem.endsWith(u8, filename, ".db." ++ suffix)) return suffix;
    }
    return null;
}

/// Joins a directory with a name, treating the no-directory case as bare.
fn joinDir(allocator: Allocator, dir: []const u8, name: []const u8) Allocator.Error![]u8 {
    if (std.mem.eql(u8, dir, ".")) return allocator.dupe(u8, name);
    return std.fs.path.join(allocator, &.{ dir, name });
}

/// The sibling path where a detached signature for `path` lives.
fn signaturePath(allocator: Allocator, path: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.sig", .{path});
}

fn isRegularFile(io: std.Io, path: []const u8) Error!bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return mapIoError(err),
    };
    return stat.kind == .file;
}

fn linkOrMove(io: std.Io, source: []const u8, destination: []const u8) Error!void {
    std.Io.Dir.cwd().hardLink(source, .cwd(), destination, io, .{}) catch {
        std.Io.Dir.rename(.cwd(), source, .cwd(), destination, io) catch |err| return mapIoError(err);
    };
}

fn copyFile(allocator: Allocator, io: std.Io, source: []const u8, destination: []const u8) Error!void {
    const contents = std.Io.Dir.cwd().readFileAlloc(io, source, allocator, .unlimited) catch |err|
        return mapIoError(err);
    defer allocator.free(contents);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = destination, .data = contents }) catch |err|
        return mapIoError(err);
}

fn deleteFileIgnoringMissing(io: std.Io, path: []const u8) Error!void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return mapIoError(err),
    };
}

/// Maps raw filesystem and lock errors into the public set: close misses turn
/// into their typed counterparts, everything exotic becomes `Unexpected`.
fn mapIoError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        error.Unexpected => error.Unexpected,
        error.NoSpaceLeft => error.NoSpaceLeft,
        error.DiskQuota => error.NoSpaceLeft,
        error.PermissionDenied => error.PermissionDenied,
        error.AccessDenied => error.PermissionDenied,
        error.ReadOnlyFileSystem => error.PermissionDenied,
        error.ArchiveCreateFailed => error.ArchiveCreateFailed,
        error.ArchiveOpenFailed => error.ArchiveOpenFailed,
        error.ArchiveReadFailed => error.ArchiveReadFailed,
        error.ArchiveEntryCreateFailed => error.ArchiveEntryCreateFailed,
        error.ArchiveWriteFailed => error.ArchiveWriteFailed,
        error.ArchiveCloseFailed => error.ArchiveCloseFailed,
        error.InvalidEntryPath => error.InvalidEntryPath,
        error.InvalidEntryTimestamp => error.InvalidEntryTimestamp,
        error.EntryTooLarge => error.EntryTooLarge,
        error.UnsupportedCompression => error.UnsupportedCompression,
        error.UnsupportedFileType => error.UnsupportedFileType,
        error.UnsupportedExtension => error.UnsupportedExtension,
        error.DatabaseNotFound => error.DatabaseNotFound,
        error.InvalidDatabase => error.InvalidDatabase,
        error.DirectoryMissing => error.DirectoryMissing,
        error.LockHeld => error.LockHeld,
        error.NoArguments => error.NoArguments,
        else => error.Unexpected,
    };
}

fn appendStringCopy(
    allocator: Allocator,
    list: *std.ArrayList([]const u8),
    value: []const u8,
) Allocator.Error!void {
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try list.append(allocator, owned);
}

fn appendFailureCopy(
    allocator: Allocator,
    list: *std.ArrayList(Failure),
    package_path: []const u8,
    kind: FailureKind,
) Allocator.Error!void {
    const owned = try allocator.dupe(u8, package_path);
    errdefer allocator.free(owned);
    try list.append(allocator, .{ .package_path = owned, .kind = kind });
}

fn appendAdded(
    allocator: Allocator,
    list: *std.ArrayList(AddedEntry),
    name: []const u8,
    version: []const u8,
    filename: []const u8,
) Allocator.Error!void {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_version = try allocator.dupe(u8, version);
    errdefer allocator.free(owned_version);
    const owned_filename = try allocator.dupe(u8, filename);
    errdefer allocator.free(owned_filename);
    try list.append(allocator, .{
        .name = owned_name,
        .version = owned_version,
        .filename = owned_filename,
    });
}

fn freeStringSlice(allocator: Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn freeStringList(allocator: Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |value| allocator.free(value);
    list.deinit(allocator);
}

fn freeFailureList(allocator: Allocator, list: *std.ArrayList(Failure)) void {
    for (list.items) |failure| allocator.free(failure.package_path);
    list.deinit(allocator);
}

fn freeVerifyResults(allocator: Allocator, list: *std.ArrayList(VerifyResult)) void {
    for (list.items) |result| allocator.free(result.fingerprint);
    list.deinit(allocator);
}

fn freeAdded(allocator: Allocator, list: *std.ArrayList(AddedEntry)) void {
    for (list.items) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.version);
        allocator.free(entry.filename);
    }
    list.deinit(allocator);
}

fn freeEntryList(allocator: Allocator, list: *std.ArrayList(EntryInfo)) void {
    for (list.items) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.version);
        allocator.free(entry.filename);
    }
    list.deinit(allocator);
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

const testing = std.testing;

const full_pkginfo =
    \\pkgbase = demo
    \\pkgname = demo
    \\pkgver = 2:1.0-1
    \\pkgdesc = Demo package
    \\url = https://example.com/demo
    \\builddate = 1700000000
    \\packager = Jane Doe <jane@example.com>
    \\size = 4096
    \\arch = x86_64
    \\group = tools
    \\group = extra
    \\license = MIT
    \\license = Apache-2.0
    \\replaces = old-demo
    \\conflict = other-demo
    \\provides = demo-provider=1.0
    \\depend = glibc
    \\depend = sh>=1.0
    \\optdepend = python: for scripting
    \\makedepend = cmake
    \\checkdepend = bats
;

const seeded_desc =
    \\%FILENAME%
    \\demo-1.0-1-any.pkg.tar.zst
    \\%NAME%
    \\demo
    \\%VERSION%
    \\1.0-1
    \\
;

const newer_entry_desc =
    \\%NAME%
    \\demo
    \\%VERSION%
    \\2.0-1
    \\
;

fn fixturePath(sub_path: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ sub_path, name });
}

fn writePackage(package_path: []const u8, name: []const u8, version: []const u8) !void {
    const contents = try std.fmt.allocPrint(
        testing.allocator,
        "pkgname = {s}\npkgver = {s}\npkgdesc = Demo package\narch = x86_64\nsize = 4096\n" ++
            "url = https://example.com/demo\ngroup = tools\nlicense = MIT\ndepend = glibc\n",
        .{ name, version },
    );
    defer testing.allocator.free(contents);
    try archive.writeFixture(testing.allocator, package_path, .zstd, &.{
        .{ .path = ".PKGINFO", .contents = contents },
        .{ .path = "usr/", .kind = .directory },
        .{ .path = "usr/bin/", .kind = .directory },
        .{ .path = "usr/bin/demo", .contents = "payload" },
    });
}

fn readMember(allocator: Allocator, archive_path: []const u8, member: []const u8) ![]u8 {
    var reader = try archive.Reader.initAll(allocator, archive_path);
    defer reader.deinit();
    var buffer: [4 * 1024]u8 = undefined;
    while (true) {
        const maybe_entry = try reader.next();
        const entry = maybe_entry orelse return error.MemberNotFound;
        if (!std.mem.eql(u8, entry.path, member)) continue;
        var contents: std.ArrayList(u8) = .empty;
        errdefer contents.deinit(allocator);
        while (true) {
            const amount = try reader.read(&buffer);
            if (amount == 0) break;
            try contents.appendSlice(allocator, buffer[0..amount]);
        }
        return contents.toOwnedSlice(allocator);
    }
}

fn listMembers(allocator: Allocator, archive_path: []const u8) ![]const []const u8 {
    var reader = try archive.Reader.initAll(allocator, archive_path);
    defer reader.deinit();
    var names: std.ArrayList([]const u8) = .empty;
    errdefer freeStringList(allocator, &names);
    while (true) {
        const maybe_entry = try reader.next();
        const entry = maybe_entry orelse break;
        const owned = try allocator.dupe(u8, entry.path);
        errdefer allocator.free(owned);
        try names.append(allocator, owned);
    }
    std.mem.sort([]const u8, names.items, {}, lessThanString);
    return names.toOwnedSlice(allocator);
}

fn expectMembers(expected_sorted: []const []const u8, archive_path: []const u8) !void {
    const members = try listMembers(testing.allocator, archive_path);
    defer freeStringSlice(testing.allocator, members);
    try testing.expectEqual(expected_sorted.len, members.len);
    for (expected_sorted, members) |want, got| try testing.expectEqualStrings(want, got);
}

fn readLinkText(dir: std.Io.Dir, name: []const u8, buffer: []u8) ![]const u8 {
    const length = try dir.readLink(testing.io, name, buffer);
    return buffer[0..length];
}

fn expectMissing(dir: std.Io.Dir, name: []const u8) !void {
    try testing.expectError(error.FileNotFound, dir.statFile(testing.io, name, .{}));
}

fn expectPresent(dir: std.Io.Dir, name: []const u8) !void {
    _ = try dir.statFile(testing.io, name, .{});
}

/// Signature bytes written by `signing_script`.
const fake_signature = "fake detached signature";
const signing_primary_fingerprint = "0123456789abcdef0123456789abcdef01234567";

const signing_script =
    \\while [ "$#" -gt 0 ]; do
    \\    if [ "$1" = "--output" ]; then
    \\        printf 'fake detached signature' > "$2"
    \\        exit 0
    \\    fi
    \\    shift
    \\done
    \\exit 9
;

const failing_script = "exit 9";

const accepting_verifier_script =
    \\echo "[GNUPG:] NEWSIG"
    \\echo "[GNUPG:] GOODSIG 0123456789abcdef01234567 Test User"
    \\echo "[GNUPG:] VALIDSIG 0123456789abcdef0123456789abcdef01234567 2026-01-01 0 0 4 0 1 10 00 0123456789abcdef0123456789abcdef01234567"
    \\echo "[GNUPG:] TRUST_ULTIMATE 0 pgp"
;

const rejecting_verifier_script =
    \\echo "[GNUPG:] NEWSIG"
    \\echo "[GNUPG:] BADSIG 0123456789abcdef01234567 Test User"
    \\exit 1
;

/// Installs an executable stand-in for GnuPG, so signing and verification are
/// exercised without a keyring.
fn writeScript(dir: std.Io.Dir, name: []const u8, body: []const u8) !void {
    const contents = try std.fmt.allocPrint(testing.allocator, "#!/bin/sh\n{s}\n", .{body});
    defer testing.allocator.free(contents);
    try dir.writeFile(testing.io, .{
        .sub_path = name,
        .data = contents,
        .flags = .{ .permissions = std.Io.File.Permissions.fromMode(0o755) },
    });
}

fn testEnviron() !std.process.Environ {
    var map = std.process.Environ.Map.init(testing.allocator);
    defer map.deinit();
    try map.put("PATH", "/usr/bin:/bin");
    return .{ .block = try map.createPosixBlock(testing.allocator, .{}) };
}

test "desc writes repo-add section order and omits empty sections" {
    const sha = "a" ** 64;
    var info = try pkginfo.parse(testing.allocator, full_pkginfo);
    defer info.deinit(testing.allocator);
    const desc = try buildDesc(
        testing.allocator,
        &info,
        "demo-2:1.0-1-x86_64.pkg.tar.zst",
        4242,
        sha,
        null,
    );
    defer testing.allocator.free(desc);
    try testing.expectEqualStrings(
        \\%FILENAME%
        \\demo-2:1.0-1-x86_64.pkg.tar.zst
        \\
        \\%NAME%
        \\demo
        \\
        \\%BASE%
        \\demo
        \\
        \\%VERSION%
        \\2:1.0-1
        \\
        \\%DESC%
        \\Demo package
        \\
        \\%GROUPS%
        \\tools
        \\extra
        \\
        \\%CSIZE%
        \\4242
        \\
        \\%ISIZE%
        \\4096
        \\
        \\%SHA256SUM%
        \\aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        \\
        \\%URL%
        \\https://example.com/demo
        \\
        \\%LICENSE%
        \\MIT
        \\Apache-2.0
        \\
        \\%ARCH%
        \\x86_64
        \\
        \\%BUILDDATE%
        \\1700000000
        \\
        \\%PACKAGER%
        \\Jane Doe <jane@example.com>
        \\
        \\%REPLACES%
        \\old-demo
        \\
        \\%CONFLICTS%
        \\other-demo
        \\
        \\%PROVIDES%
        \\demo-provider=1.0
        \\
        \\%DEPENDS%
        \\glibc
        \\sh>=1.0
        \\
        \\%OPTDEPENDS%
        \\python: for scripting
        \\
        \\%MAKEDEPENDS%
        \\cmake
        \\
        \\%CHECKDEPENDS%
        \\bats
        \\
        \\
    , desc);

    var minimal = try pkginfo.parse(testing.allocator, "pkgname = mini\npkgver = 1-1\narch = x86_64\n");
    defer minimal.deinit(testing.allocator);
    const minimal_desc = try buildDesc(testing.allocator, &minimal, "mini-1-1-any.pkg.tar.zst", 17, sha, null);
    defer testing.allocator.free(minimal_desc);
    try testing.expectEqualStrings(
        \\%FILENAME%
        \\mini-1-1-any.pkg.tar.zst
        \\
        \\%NAME%
        \\mini
        \\
        \\%VERSION%
        \\1-1
        \\
        \\%CSIZE%
        \\17
        \\
        \\%SHA256SUM%
        \\aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        \\
        \\%ARCH%
        \\x86_64
        \\
        \\
    , minimal_desc);
}

test "desc includes stat size streamed sha256 and PKGINFO isize" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try fixturePath(&tmp.sub_path, "demo.db.tar.zst");
    defer testing.allocator.free(db_path);
    const package_path = try fixturePath(&tmp.sub_path, "demo-1.0-1-any.pkg.tar.zst");
    defer testing.allocator.free(package_path);
    try writePackage(package_path, "demo", "1.0-1");

    var db = try Database.open(testing.allocator, testing.io, db_path);
    defer db.deinit();
    var summary = try db.addPackages(&.{package_path}, .{});
    defer summary.deinit(testing.allocator);
    try testing.expect(summary.published);

    const desc = try readMember(testing.allocator, db_path, "demo-1.0-1/desc");
    defer testing.allocator.free(desc);
    try testing.expectEqualStrings("demo-1.0-1-any.pkg.tar.zst", descField(desc, "FILENAME"));
    try testing.expectEqualStrings("4096", descField(desc, "ISIZE"));

    const package_bytes = try tmp.dir.readFileAlloc(
        testing.io,
        "demo-1.0-1-any.pkg.tar.zst",
        testing.allocator,
        .unlimited,
    );
    defer testing.allocator.free(package_bytes);
    var size_buffer: [24]u8 = undefined;
    const expected_csize = std.fmt.bufPrint(&size_buffer, "{d}", .{package_bytes.len}) catch unreachable;
    try testing.expectEqualStrings(expected_csize, descField(desc, "CSIZE"));

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(package_bytes, &digest, .{});
    const expected_sha = std.fmt.bytesToHex(digest, .lower);
    try testing.expectEqualStrings(&expected_sha, descField(desc, "SHA256SUM"));
}

test "pgpsig is embedded only when requested" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const package_path = try fixturePath(&tmp.sub_path, "demo-1.0-1-any.pkg.tar.zst");
    defer testing.allocator.free(package_path);
    try writePackage(package_path, "demo", "1.0-1");

    const plain_db_path = try fixturePath(&tmp.sub_path, "plain.db.tar.zst");
    defer testing.allocator.free(plain_db_path);
    var plain_db = try Database.open(testing.allocator, testing.io, plain_db_path);
    defer plain_db.deinit();
    var plain_summary = try plain_db.addPackages(&.{package_path}, .{});
    defer plain_summary.deinit(testing.allocator);
    try testing.expect(plain_summary.published);
    const plain_desc = try readMember(testing.allocator, plain_db_path, "demo-1.0-1/desc");
    defer testing.allocator.free(plain_desc);
    try testing.expect(std.mem.indexOf(u8, plain_desc, "%PGPSIG%") == null);

    const signature_bytes = "raw signature bytes";
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "demo-1.0-1-any.pkg.tar.zst.sig",
        .data = signature_bytes,
    });
    const signed_db_path = try fixturePath(&tmp.sub_path, "signed.db.tar.zst");
    defer testing.allocator.free(signed_db_path);
    var signed_db = try Database.open(testing.allocator, testing.io, signed_db_path);
    defer signed_db.deinit();
    var signed_summary = try signed_db.addPackages(&.{package_path}, .{ .include_sigs = true });
    defer signed_summary.deinit(testing.allocator);
    try testing.expect(signed_summary.published);
    const signed_desc = try readMember(testing.allocator, signed_db_path, "demo-1.0-1/desc");
    defer testing.allocator.free(signed_desc);

    var encoded_buffer: [std.base64.standard.Encoder.calcSize(signature_bytes.len)]u8 = undefined;
    const expected_signature = std.base64.standard.Encoder.encode(&encoded_buffer, signature_bytes);
    try testing.expectEqualStrings(expected_signature, descField(signed_desc, "PGPSIG"));
}

test "pgpsig rejects armored and oversized signatures" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try fixturePath(&tmp.sub_path, "demo.db.tar.zst");
    defer testing.allocator.free(db_path);
    const package_path = try fixturePath(&tmp.sub_path, "demo-1.0-1-any.pkg.tar.zst");
    defer testing.allocator.free(package_path);
    try writePackage(package_path, "demo", "1.0-1");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "demo-1.0-1-any.pkg.tar.zst.sig",
        .data = "-----BEGIN PGP SIGNATURE-----\narmored\n",
    });

    var db = try Database.open(testing.allocator, testing.io, db_path);
    defer db.deinit();
    var armored = try db.addPackages(&.{package_path}, .{ .include_sigs = true });
    defer armored.deinit(testing.allocator);
    try testing.expect(!armored.published);
    try testing.expectEqual(@as(usize, 1), armored.failures.len);
    try testing.expectEqual(FailureKind.armored_signature, armored.failures[0].kind);
    try testing.expectEqualStrings(package_path, armored.failures[0].package_path);
    try expectMissing(tmp.dir, "demo.db.tar.zst");

    const oversized = try testing.allocator.alloc(u8, 16385);
    defer testing.allocator.free(oversized);
    @memset(oversized, 0x42);
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "demo-1.0-1-any.pkg.tar.zst.sig",
        .data = oversized,
    });
    var large = try db.addPackages(&.{package_path}, .{ .include_sigs = true });
    defer large.deinit(testing.allocator);
    try testing.expect(!large.published);
    try testing.expectEqual(@as(usize, 1), large.failures.len);
    try testing.expectEqual(FailureKind.oversized_signature, large.failures[0].kind);
    try expectMissing(tmp.dir, "demo.db.tar.zst");
}

test "add creates db and files archives with a matching entry" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try fixturePath(&tmp.sub_path, "demo.db.tar.zst");
    defer testing.allocator.free(db_path);
    const files_path = try fixturePath(&tmp.sub_path, "demo.files.tar.zst");
    defer testing.allocator.free(files_path);
    const package_path = try fixturePath(&tmp.sub_path, "demo-1.0-1-any.pkg.tar.zst");
    defer testing.allocator.free(package_path);
    try writePackage(package_path, "demo", "1.0-1");

    var db = try Database.open(testing.allocator, testing.io, db_path);
    defer db.deinit();
    var summary = try db.addPackages(&.{package_path}, .{});
    defer summary.deinit(testing.allocator);
    try testing.expect(summary.published);
    try testing.expect(!summary.published_empty);
    try testing.expectEqual(@as(usize, 1), summary.added.len);
    try testing.expectEqualStrings("demo", summary.added[0].name);
    try testing.expectEqualStrings("1.0-1", summary.added[0].version);
    try testing.expectEqualStrings("demo-1.0-1-any.pkg.tar.zst", summary.added[0].filename);

    try expectMembers(&.{ "demo-1.0-1/", "demo-1.0-1/desc" }, db_path);
    try expectMembers(&.{ "demo-1.0-1/", "demo-1.0-1/desc", "demo-1.0-1/files" }, files_path);
    const files = try readMember(testing.allocator, files_path, "demo-1.0-1/files");
    defer testing.allocator.free(files);
    try testing.expectEqualStrings("%FILES%\nusr/\nusr/bin/\nusr/bin/demo\n", files);

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("demo.db.tar.zst", try readLinkText(tmp.dir, "demo.db", &buffer));
    try testing.expectEqualStrings("demo.files.tar.zst", try readLinkText(tmp.dir, "demo.files", &buffer));
}

test "add replacement keeps both databases in lockstep" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try fixturePath(&tmp.sub_path, "demo.db.tar.zst");
    defer testing.allocator.free(db_path);
    const files_path = try fixturePath(&tmp.sub_path, "demo.files.tar.zst");
    defer testing.allocator.free(files_path);
    const first_path = try fixturePath(&tmp.sub_path, "demo-1.0-1-any.pkg.tar.zst");
    defer testing.allocator.free(first_path);
    const second_path = try fixturePath(&tmp.sub_path, "demo-2.0-1-any.pkg.tar.zst");
    defer testing.allocator.free(second_path);
    try writePackage(first_path, "demo", "1.0-1");
    try writePackage(second_path, "demo", "2.0-1");

    var db = try Database.open(testing.allocator, testing.io, db_path);
    defer db.deinit();
    var first = try db.addPackages(&.{first_path}, .{});
    defer first.deinit(testing.allocator);
    try testing.expect(first.published);
    var second = try db.addPackages(&.{second_path}, .{});
    defer second.deinit(testing.allocator);
    try testing.expect(second.published);

    try expectMembers(&.{ "demo-2.0-1/", "demo-2.0-1/desc" }, db_path);
    try expectMembers(&.{ "demo-2.0-1/", "demo-2.0-1/desc", "demo-2.0-1/files" }, files_path);
    const db_desc = try readMember(testing.allocator, db_path, "demo-2.0-1/desc");
    defer testing.allocator.free(db_desc);
    const files_desc = try readMember(testing.allocator, files_path, "demo-2.0-1/desc");
    defer testing.allocator.free(files_desc);
    try testing.expectEqualStrings(db_desc, files_desc);
    try testing.expectEqualStrings("2.0-1", descField(db_desc, "VERSION"));
}

test "add with new skips an existing identical entry without rewriting" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try fixturePath(&tmp.sub_path, "demo.db.tar.zst");
    defer testing.allocator.free(db_path);
    const package_path = try fixturePath(&tmp.sub_path, "demo-1.0-1-any.pkg.tar.zst");
    defer testing.allocator.free(package_path);
    try writePackage(package_path, "demo", "1.0-1");

    var db = try Database.open(testing.allocator, testing.io, db_path);
    defer db.deinit();
    var seed = try db.addPackages(&.{package_path}, .{});
    defer seed.deinit(testing.allocator);
    try testing.expect(seed.published);
    const before_db = try tmp.dir.readFileAlloc(testing.io, "demo.db.tar.zst", testing.allocator, .unlimited);
    defer testing.allocator.free(before_db);
    const before_files = try tmp.dir.readFileAlloc(testing.io, "demo.files.tar.zst", testing.allocator, .unlimited);
    defer testing.allocator.free(before_files);
    const before_stat = try tmp.dir.statFile(testing.io, "demo.db.tar.zst", .{});

    var again = try db.addPackages(&.{package_path}, .{ .new_only = true });
    defer again.deinit(testing.allocator);
    try testing.expect(!again.published);
    try testing.expectEqual(@as(usize, 0), again.added.len);
    try testing.expectEqual(@as(usize, 1), again.skipped_existing.len);
    try testing.expectEqualStrings("demo-1.0-1", again.skipped_existing[0]);

    const after_db = try tmp.dir.readFileAlloc(testing.io, "demo.db.tar.zst", testing.allocator, .unlimited);
    defer testing.allocator.free(after_db);
    const after_files = try tmp.dir.readFileAlloc(testing.io, "demo.files.tar.zst", testing.allocator, .unlimited);
    defer testing.allocator.free(after_files);
    try testing.expectEqualSlices(u8, before_db, after_db);
    try testing.expectEqualSlices(u8, before_files, after_files);
    const after_stat = try tmp.dir.statFile(testing.io, "demo.db.tar.zst", .{});
    try testing.expectEqual(before_stat.mtime.nanoseconds, after_stat.mtime.nanoseconds);
    try expectMissing(tmp.dir, "demo.db.tar.zst.old");
}

test "add with prevent_downgrade skips only strictly newer existing versions" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try fixturePath(&tmp.sub_path, "demo.db.tar.zst");
    defer testing.allocator.free(db_path);
    try archive.writeFixture(testing.allocator, db_path, .zstd, &.{
        .{ .path = "demo-2.0-1/desc", .contents = newer_entry_desc },
    });

    const older_path = try fixturePath(&tmp.sub_path, "demo-1.0-1-any.pkg.tar.zst");
    defer testing.allocator.free(older_path);
    const same_path = try fixturePath(&tmp.sub_path, "demo-2.0-1-any.pkg.tar.zst");
    defer testing.allocator.free(same_path);
    const newer_path = try fixturePath(&tmp.sub_path, "demo-3.0-1-any.pkg.tar.zst");
    defer testing.allocator.free(newer_path);
    try writePackage(older_path, "demo", "1.0-1");
    try writePackage(same_path, "demo", "2.0-1");
    try writePackage(newer_path, "demo", "3.0-1");

    var db = try Database.open(testing.allocator, testing.io, db_path);
    defer db.deinit();

    var skipped = try db.addPackages(&.{older_path}, .{ .prevent_downgrade = true });
    defer skipped.deinit(testing.allocator);
    try testing.expect(!skipped.published);
    try testing.expectEqual(@as(usize, 0), skipped.failures.len);
    try testing.expectEqual(@as(usize, 1), skipped.skipped_newer.len);
    try testing.expectEqualStrings("demo", skipped.skipped_newer[0]);

    var identical = try db.addPackages(&.{same_path}, .{});
    defer identical.deinit(testing.allocator);
    try testing.expect(identical.published);
    try testing.expectEqual(@as(usize, 0), identical.skipped_newer.len);
    try testing.expectEqual(@as(usize, 1), identical.skipped_existing.len);
    try testing.expectEqualStrings("demo-2.0-1", identical.skipped_existing[0]);

    var replaced = try db.addPackages(&.{newer_path}, .{});
    defer replaced.deinit(testing.allocator);
    try testing.expect(replaced.published);
    try expectMembers(&.{ "demo-3.0-1/", "demo-3.0-1/desc" }, db_path);
}

test "failed add leaves the database files unchanged" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try fixturePath(&tmp.sub_path, "demo.db.tar.zst");
    defer testing.allocator.free(db_path);
    const files_path = try fixturePath(&tmp.sub_path, "demo.files.tar.zst");
    defer testing.allocator.free(files_path);
    const seed_path = try fixturePath(&tmp.sub_path, "demo-1.0-1-any.pkg.tar.zst");
    defer testing.allocator.free(seed_path);
    const good_path = try fixturePath(&tmp.sub_path, "demo-2.0-1-any.pkg.tar.zst");
    defer testing.allocator.free(good_path);
    const garbage_path = try fixturePath(&tmp.sub_path, "garbage.txt");
    defer testing.allocator.free(garbage_path);
    try writePackage(seed_path, "demo", "1.0-1");
    try writePackage(good_path, "demo", "2.0-1");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "garbage.txt", .data = "not an archive\n" });

    var db = try Database.open(testing.allocator, testing.io, db_path);
    defer db.deinit();
    var seed = try db.addPackages(&.{seed_path}, .{});
    defer seed.deinit(testing.allocator);
    try testing.expect(seed.published);
    const before_db = try tmp.dir.readFileAlloc(testing.io, "demo.db.tar.zst", testing.allocator, .unlimited);
    defer testing.allocator.free(before_db);
    const before_files = try tmp.dir.readFileAlloc(testing.io, "demo.files.tar.zst", testing.allocator, .unlimited);
    defer testing.allocator.free(before_files);

    var failed = try db.addPackages(&.{ good_path, garbage_path }, .{});
    defer failed.deinit(testing.allocator);
    try testing.expect(!failed.published);
    try testing.expectEqual(@as(usize, 1), failed.failures.len);
    try testing.expectEqual(FailureKind.not_a_package, failed.failures[0].kind);
    try testing.expectEqualStrings(garbage_path, failed.failures[0].package_path);

    const after_db = try tmp.dir.readFileAlloc(testing.io, "demo.db.tar.zst", testing.allocator, .unlimited);
    defer testing.allocator.free(after_db);
    const after_files = try tmp.dir.readFileAlloc(testing.io, "demo.files.tar.zst", testing.allocator, .unlimited);
    defer testing.allocator.free(after_files);
    try testing.expectEqualSlices(u8, before_db, after_db);
    try testing.expectEqualSlices(u8, before_files, after_files);
    try expectMissing(tmp.dir, ".tmp.demo.db.tar.zst");
    try expectMissing(tmp.dir, ".tmp.demo.files.tar.zst");
    try expectMissing(tmp.dir, "demo.db.tar.zst.old");
}

test "remove deletes entries by package name from both databases" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try fixturePath(&tmp.sub_path, "demo.db.tar.zst");
    defer testing.allocator.free(db_path);
    const files_path = try fixturePath(&tmp.sub_path, "demo.files.tar.zst");
    defer testing.allocator.free(files_path);
    const demo_path = try fixturePath(&tmp.sub_path, "demo-1.0-1-any.pkg.tar.zst");
    defer testing.allocator.free(demo_path);
    const extra_path = try fixturePath(&tmp.sub_path, "extra-1.0-1-any.pkg.tar.zst");
    defer testing.allocator.free(extra_path);
    try writePackage(demo_path, "demo", "1.0-1");
    try writePackage(extra_path, "extra", "1.0-1");

    var db = try Database.open(testing.allocator, testing.io, db_path);
    defer db.deinit();
    var added = try db.addPackages(&.{ demo_path, extra_path }, .{});
    defer added.deinit(testing.allocator);
    try testing.expect(added.published);

    var removed = try db.removePackages(&.{"demo"}, .{});
    defer removed.deinit(testing.allocator);
    try testing.expect(removed.published);
    try testing.expect(!removed.published_empty);
    try testing.expectEqual(@as(usize, 1), removed.removed_entries.len);
    try testing.expectEqualStrings("demo-1.0-1", removed.removed_entries[0]);
    try testing.expectEqual(@as(usize, 0), removed.not_found.len);

    try expectMembers(&.{ "extra-1.0-1/", "extra-1.0-1/desc" }, db_path);
    try expectMembers(&.{ "extra-1.0-1/", "extra-1.0-1/desc", "extra-1.0-1/files" }, files_path);

    const entries = try db.listEntries();
    defer freeEntries(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("extra", entries[0].name);
    try testing.expectEqualStrings("1.0-1", entries[0].version);
    try testing.expectEqualStrings("extra-1.0-1-any.pkg.tar.zst", entries[0].filename);
}

test "remove of an unknown name fails without publishing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try fixturePath(&tmp.sub_path, "demo.db.tar.zst");
    defer testing.allocator.free(db_path);
    const package_path = try fixturePath(&tmp.sub_path, "demo-1.0-1-any.pkg.tar.zst");
    defer testing.allocator.free(package_path);
    try writePackage(package_path, "demo", "1.0-1");

    var db = try Database.open(testing.allocator, testing.io, db_path);
    defer db.deinit();
    var seed = try db.addPackages(&.{package_path}, .{});
    defer seed.deinit(testing.allocator);
    try testing.expect(seed.published);
    const before_db = try tmp.dir.readFileAlloc(testing.io, "demo.db.tar.zst", testing.allocator, .unlimited);
    defer testing.allocator.free(before_db);
    const before_files = try tmp.dir.readFileAlloc(testing.io, "demo.files.tar.zst", testing.allocator, .unlimited);
    defer testing.allocator.free(before_files);

    var removed = try db.removePackages(&.{ "demo", "ghost" }, .{});
    defer removed.deinit(testing.allocator);
    try testing.expect(!removed.published);
    try testing.expectEqual(@as(usize, 1), removed.removed_entries.len);
    try testing.expectEqualStrings("demo-1.0-1", removed.removed_entries[0]);
    try testing.expectEqual(@as(usize, 1), removed.not_found.len);
    try testing.expectEqualStrings("ghost", removed.not_found[0]);

    const after_db = try tmp.dir.readFileAlloc(testing.io, "demo.db.tar.zst", testing.allocator, .unlimited);
    defer testing.allocator.free(after_db);
    const after_files = try tmp.dir.readFileAlloc(testing.io, "demo.files.tar.zst", testing.allocator, .unlimited);
    defer testing.allocator.free(after_files);
    try testing.expectEqualSlices(u8, before_db, after_db);
    try testing.expectEqualSlices(u8, before_files, after_files);
}

test "removing the last entry produces valid empty databases" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try fixturePath(&tmp.sub_path, "demo.db.tar.zst");
    defer testing.allocator.free(db_path);
    const files_path = try fixturePath(&tmp.sub_path, "demo.files.tar.zst");
    defer testing.allocator.free(files_path);
    const package_path = try fixturePath(&tmp.sub_path, "demo-1.0-1-any.pkg.tar.zst");
    defer testing.allocator.free(package_path);
    try writePackage(package_path, "demo", "1.0-1");

    var db = try Database.open(testing.allocator, testing.io, db_path);
    defer db.deinit();
    var seed = try db.addPackages(&.{package_path}, .{});
    defer seed.deinit(testing.allocator);
    try testing.expect(seed.published);

    var removed = try db.removePackages(&.{"demo"}, .{});
    defer removed.deinit(testing.allocator);
    try testing.expect(removed.published);
    try testing.expect(removed.published_empty);

    for ([_][]const u8{ db_path, files_path }) |path| {
        var reader = try archive.Reader.initAll(testing.allocator, path);
        defer reader.deinit();
        try testing.expect((try reader.next()) == null);
    }
    const entries = try db.listEntries();
    defer freeEntries(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "publication keeps one old generation and refreshes the extension-less symlink" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try fixturePath(&tmp.sub_path, "demo.db.tar.zst");
    defer testing.allocator.free(db_path);
    const package_path = try fixturePath(&tmp.sub_path, "demo-2.0-1-any.pkg.tar.zst");
    defer testing.allocator.free(package_path);
    try writePackage(package_path, "demo", "2.0-1");

    try archive.writeFixture(testing.allocator, db_path, .zstd, &.{
        .{ .path = "demo-1.0-1/desc", .contents = seeded_desc },
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "demo.db.tar.zst.sig", .data = "stale signature" });
    try tmp.dir.symLink(testing.io, "demo.db.tar.zst", "demo.db", .{});
    const before_db = try tmp.dir.readFileAlloc(testing.io, "demo.db.tar.zst", testing.allocator, .unlimited);
    defer testing.allocator.free(before_db);

    var db = try Database.open(testing.allocator, testing.io, db_path);
    defer db.deinit();
    var summary = try db.addPackages(&.{package_path}, .{});
    defer summary.deinit(testing.allocator);
    try testing.expect(summary.published);

    const old_db = try tmp.dir.readFileAlloc(testing.io, "demo.db.tar.zst.old", testing.allocator, .unlimited);
    defer testing.allocator.free(old_db);
    try testing.expectEqualSlices(u8, before_db, old_db);
    const old_sig = try tmp.dir.readFileAlloc(testing.io, "demo.db.tar.zst.old.sig", testing.allocator, .unlimited);
    defer testing.allocator.free(old_sig);
    try testing.expectEqualStrings("stale signature", old_sig);

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("demo.db.tar.zst", try readLinkText(tmp.dir, "demo.db", &buffer));
    try testing.expectEqualStrings("demo.db.tar.zst.sig", try readLinkText(tmp.dir, "demo.db.sig", &buffer));

    // A stale `.old.sig` is dropped when no current signature survives.
    var second = testing.tmpDir(.{});
    defer second.cleanup();
    const second_db_path = try fixturePath(&second.sub_path, "demo.db.tar.zst");
    defer testing.allocator.free(second_db_path);
    const second_package = try fixturePath(&second.sub_path, "demo-2.0-1-any.pkg.tar.zst");
    defer testing.allocator.free(second_package);
    try writePackage(second_package, "demo", "2.0-1");
    try archive.writeFixture(testing.allocator, second_db_path, .zstd, &.{
        .{ .path = "demo-1.0-1/desc", .contents = seeded_desc },
    });
    try second.dir.writeFile(testing.io, .{ .sub_path = "demo.db.tar.zst.old.sig", .data = "stale" });

    var second_db = try Database.open(testing.allocator, testing.io, second_db_path);
    defer second_db.deinit();
    var second_summary = try second_db.addPackages(&.{second_package}, .{});
    defer second_summary.deinit(testing.allocator);
    try testing.expect(second_summary.published);
    try expectMissing(second.dir, "demo.db.tar.zst.old.sig");
    try expectMissing(second.dir, "demo.db.sig");
}

test "remove old files deletes package and signature only after publication" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try fixturePath(&tmp.sub_path, "demo.db.tar.zst");
    defer testing.allocator.free(db_path);
    const package_path = try fixturePath(&tmp.sub_path, "demo-2.0-1-any.pkg.tar.zst");
    defer testing.allocator.free(package_path);
    try writePackage(package_path, "demo", "2.0-1");

    try archive.writeFixture(testing.allocator, db_path, .zstd, &.{
        .{ .path = "demo-1.0-1/desc", .contents = seeded_desc },
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "demo-1.0-1-any.pkg.tar.zst", .data = "old package" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "demo-1.0-1-any.pkg.tar.zst.sig", .data = "old signature" });

    var db = try Database.open(testing.allocator, testing.io, db_path);
    defer db.deinit();
    var summary = try db.addPackages(&.{package_path}, .{ .remove_old_files = true });
    defer summary.deinit(testing.allocator);
    try testing.expect(summary.published);
    try testing.expectEqual(@as(usize, 1), summary.removed_files.len);
    try testing.expectEqualStrings("demo-1.0-1-any.pkg.tar.zst", summary.removed_files[0]);
    try expectMissing(tmp.dir, "demo-1.0-1-any.pkg.tar.zst");
    try expectMissing(tmp.dir, "demo-1.0-1-any.pkg.tar.zst.sig");

    // A failed argument withholds publication, so the old files stay.
    var second = testing.tmpDir(.{});
    defer second.cleanup();
    const second_db_path = try fixturePath(&second.sub_path, "demo.db.tar.zst");
    defer testing.allocator.free(second_db_path);
    const second_package = try fixturePath(&second.sub_path, "demo-2.0-1-any.pkg.tar.zst");
    defer testing.allocator.free(second_package);
    const garbage_path = try fixturePath(&second.sub_path, "garbage.txt");
    defer testing.allocator.free(garbage_path);
    try writePackage(second_package, "demo", "2.0-1");
    try second.dir.writeFile(testing.io, .{ .sub_path = "garbage.txt", .data = "not an archive\n" });
    try archive.writeFixture(testing.allocator, second_db_path, .zstd, &.{
        .{ .path = "demo-1.0-1/desc", .contents = seeded_desc },
    });
    try second.dir.writeFile(testing.io, .{ .sub_path = "demo-1.0-1-any.pkg.tar.zst", .data = "old package" });
    try second.dir.writeFile(testing.io, .{ .sub_path = "demo-1.0-1-any.pkg.tar.zst.sig", .data = "old signature" });

    var second_db = try Database.open(testing.allocator, testing.io, second_db_path);
    defer second_db.deinit();
    var failing = try second_db.addPackages(&.{ second_package, garbage_path }, .{ .remove_old_files = true });
    defer failing.deinit(testing.allocator);
    try testing.expect(!failing.published);
    try testing.expectEqual(@as(usize, 0), failing.removed_files.len);
    try expectPresent(second.dir, "demo-1.0-1-any.pkg.tar.zst");
    try expectPresent(second.dir, "demo-1.0-1-any.pkg.tar.zst.sig");
}

test "remove with remove old files deletes each matched package after publication" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try fixturePath(&tmp.sub_path, "demo.db.tar.zst");
    defer testing.allocator.free(db_path);
    const demo_path = try fixturePath(&tmp.sub_path, "demo-1.0-1-any.pkg.tar.zst");
    defer testing.allocator.free(demo_path);
    const extra_path = try fixturePath(&tmp.sub_path, "extra-1.0-1-any.pkg.tar.zst");
    defer testing.allocator.free(extra_path);
    try writePackage(demo_path, "demo", "1.0-1");
    try writePackage(extra_path, "extra", "1.0-1");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "demo-1.0-1-any.pkg.tar.zst.sig", .data = "old signature" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "extra-1.0-1-any.pkg.tar.zst.sig", .data = "old signature" });

    var db = try Database.open(testing.allocator, testing.io, db_path);
    defer db.deinit();
    var seed = try db.addPackages(&.{ demo_path, extra_path }, .{});
    defer seed.deinit(testing.allocator);
    try testing.expect(seed.published);

    var removed = try db.removePackages(&.{ "demo", "extra" }, .{ .remove_old_files = true });
    defer removed.deinit(testing.allocator);
    try testing.expect(removed.published);
    try testing.expect(removed.published_empty);
    try testing.expectEqual(@as(usize, 2), removed.removed_entries.len);
    try testing.expectEqual(@as(usize, 2), removed.removed_files.len);
    try testing.expectEqualStrings("demo-1.0-1-any.pkg.tar.zst", removed.removed_files[0]);
    try testing.expectEqualStrings("extra-1.0-1-any.pkg.tar.zst", removed.removed_files[1]);
    try expectMissing(tmp.dir, "demo-1.0-1-any.pkg.tar.zst");
    try expectMissing(tmp.dir, "demo-1.0-1-any.pkg.tar.zst.sig");
    try expectMissing(tmp.dir, "extra-1.0-1-any.pkg.tar.zst");
    try expectMissing(tmp.dir, "extra-1.0-1-any.pkg.tar.zst.sig");

    // An unmatched name withholds publication, so no matched file is deleted.
    var second = testing.tmpDir(.{});
    defer second.cleanup();
    const second_db_path = try fixturePath(&second.sub_path, "demo.db.tar.zst");
    defer testing.allocator.free(second_db_path);
    const second_package = try fixturePath(&second.sub_path, "demo-1.0-1-any.pkg.tar.zst");
    defer testing.allocator.free(second_package);
    try writePackage(second_package, "demo", "1.0-1");
    try second.dir.writeFile(testing.io, .{ .sub_path = "demo-1.0-1-any.pkg.tar.zst.sig", .data = "old signature" });

    var second_db = try Database.open(testing.allocator, testing.io, second_db_path);
    defer second_db.deinit();
    var second_seed = try second_db.addPackages(&.{second_package}, .{});
    defer second_seed.deinit(testing.allocator);
    try testing.expect(second_seed.published);

    var failing = try second_db.removePackages(&.{ "demo", "ghost" }, .{ .remove_old_files = true });
    defer failing.deinit(testing.allocator);
    try testing.expect(!failing.published);
    try testing.expectEqual(@as(usize, 1), failing.removed_entries.len);
    try testing.expectEqual(@as(usize, 0), failing.removed_files.len);
    try expectPresent(second.dir, "demo-1.0-1-any.pkg.tar.zst");
    try expectPresent(second.dir, "demo-1.0-1-any.pkg.tar.zst.sig");
}

test "lock contention fails without modifying the database" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try fixturePath(&tmp.sub_path, "demo.db.tar.zst");
    defer testing.allocator.free(db_path);
    const package_path = try fixturePath(&tmp.sub_path, "demo-1.0-1-any.pkg.tar.zst");
    defer testing.allocator.free(package_path);
    try writePackage(package_path, "demo", "1.0-1");

    var db = try Database.open(testing.allocator, testing.io, db_path);
    defer db.deinit();

    {
        const lock_file = try tmp.dir.createFile(testing.io, "demo.db.tar.zst.lock", .{ .read = true });
        defer lock_file.close(testing.io);
        try testing.expect(try lock_file.tryLock(testing.io, .exclusive));
        try testing.expectError(error.LockHeld, db.addPackages(&.{package_path}, .{}));
        try expectMissing(tmp.dir, "demo.db.tar.zst");
        lock_file.unlock(testing.io);
    }

    var summary = try db.addPackages(&.{package_path}, .{});
    defer summary.deinit(testing.allocator);
    try testing.expect(summary.published);
}

test "database derives the files path and rejects unsupported extensions" {
    var db = try Database.open(testing.allocator, testing.io, "demo.db.tar.zst");
    defer db.deinit();
    try testing.expectEqualStrings("demo.db.tar.zst", db.db_path);
    try testing.expectEqualStrings(".", db.db_dir);
    try testing.expectEqualStrings("demo.db.tar.zst", db.db_filename);
    try testing.expectEqualStrings("demo.files.tar.zst", db.files_path);
    try testing.expectEqualStrings("demo.files.tar.zst", db.files_filename);
    try testing.expectEqualStrings("demo.db", db.db_link);
    try testing.expectEqualStrings("demo.files", db.files_link);
    try testing.expectEqualStrings("demo.db.tar.zst.lock", db.lock_path);

    var nested = try Database.open(testing.allocator, testing.io, "/srv/repo/demo.db.tar.xz");
    defer nested.deinit();
    try testing.expectEqualStrings("/srv/repo", nested.db_dir);
    try testing.expectEqualStrings("/srv/repo/demo.files.tar.xz", nested.files_path);
    try testing.expectEqualStrings("/srv/repo/demo.db.tar.xz.lock", nested.lock_path);

    try testing.expectError(error.UnsupportedExtension, Database.open(testing.allocator, testing.io, "demo.db"));
    try testing.expectError(error.UnsupportedExtension, Database.open(testing.allocator, testing.io, "demo.db.tar.lz4"));
    try testing.expectError(error.UnsupportedExtension, Database.open(testing.allocator, testing.io, ".db.tar.zst"));

    var plain = try Database.open(testing.allocator, testing.io, "demo.db.tar");
    defer plain.deinit();
    try testing.expectEqualStrings("demo.files.tar", plain.files_filename);
    try testing.expectEqualStrings("demo.files", plain.files_link);
}

test "publication signs each database archive and rotates the signature into place" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try fixturePath(&tmp.sub_path, "demo.db.tar.zst");
    defer testing.allocator.free(db_path);
    const package_path = try fixturePath(&tmp.sub_path, "demo-1.0-1-any.pkg.tar.zst");
    defer testing.allocator.free(package_path);
    const gpg_path = try fixturePath(&tmp.sub_path, "fake-gpg");
    defer testing.allocator.free(gpg_path);
    try writePackage(package_path, "demo", "1.0-1");
    try writeScript(tmp.dir, "fake-gpg", signing_script);

    const environ = try testEnviron();
    defer environ.block.deinit(testing.allocator);
    const signer = package_signer.Signer{
        .allocator = testing.allocator,
        .io = testing.io,
        .environ = environ,
        .gpg_path = gpg_path,
    };

    var db = try Database.open(testing.allocator, testing.io, db_path);
    defer db.deinit();
    var first = try db.addPackages(&.{package_path}, .{ .signer = signer, .sign_key = "TEST-KEY" });
    defer first.deinit(testing.allocator);
    try testing.expect(first.published);

    const db_signature = try tmp.dir.readFileAlloc(
        testing.io,
        "demo.db.tar.zst.sig",
        testing.allocator,
        .unlimited,
    );
    defer testing.allocator.free(db_signature);
    try testing.expectEqualStrings(fake_signature, db_signature);
    try expectPresent(tmp.dir, "demo.files.tar.zst.sig");
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("demo.db.tar.zst.sig", try readLinkText(tmp.dir, "demo.db.sig", &buffer));
    try testing.expectEqualStrings(
        "demo.files.tar.zst.sig",
        try readLinkText(tmp.dir, "demo.files.sig", &buffer),
    );
    try expectMissing(tmp.dir, ".tmp.demo.db.tar.zst");
    try expectMissing(tmp.dir, ".tmp.demo.db.tar.zst.sig");

    // Rotation keeps the previous signature as one backup generation.
    const second_package = try fixturePath(&tmp.sub_path, "demo-2.0-1-any.pkg.tar.zst");
    defer testing.allocator.free(second_package);
    try writePackage(second_package, "demo", "2.0-1");
    var second = try db.addPackages(&.{second_package}, .{ .signer = signer });
    defer second.deinit(testing.allocator);
    try testing.expect(second.published);
    const old_signature = try tmp.dir.readFileAlloc(
        testing.io,
        "demo.db.tar.zst.old.sig",
        testing.allocator,
        .unlimited,
    );
    defer testing.allocator.free(old_signature);
    try testing.expectEqualStrings(fake_signature, old_signature);
}

test "a failed signature still publishes the database unsigned" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try fixturePath(&tmp.sub_path, "demo.db.tar.zst");
    defer testing.allocator.free(db_path);
    const package_path = try fixturePath(&tmp.sub_path, "demo-1.0-1-any.pkg.tar.zst");
    defer testing.allocator.free(package_path);
    const gpg_path = try fixturePath(&tmp.sub_path, "fake-gpg");
    defer testing.allocator.free(gpg_path);
    try writePackage(package_path, "demo", "1.0-1");
    try writeScript(tmp.dir, "fake-gpg", failing_script);

    const environ = try testEnviron();
    defer environ.block.deinit(testing.allocator);

    var db = try Database.open(testing.allocator, testing.io, db_path);
    defer db.deinit();
    var summary = try db.addPackages(&.{package_path}, .{ .signer = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .environ = environ,
        .gpg_path = gpg_path,
    } });
    defer summary.deinit(testing.allocator);
    try testing.expect(summary.published);
    try expectMembers(&.{ "demo-1.0-1/", "demo-1.0-1/desc" }, db_path);
    try expectMissing(tmp.dir, "demo.db.tar.zst.sig");
    try expectMissing(tmp.dir, "demo.files.tar.zst.sig");
    try expectMissing(tmp.dir, "demo.db.sig");
    try expectMissing(tmp.dir, ".tmp.demo.db.tar.zst.sig");
}

test "a staged signature from an aborted run is not published" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try fixturePath(&tmp.sub_path, "demo.db.tar.zst");
    defer testing.allocator.free(db_path);
    const package_path = try fixturePath(&tmp.sub_path, "demo-1.0-1-any.pkg.tar.zst");
    defer testing.allocator.free(package_path);
    try writePackage(package_path, "demo", "1.0-1");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = ".tmp.demo.db.tar.zst.sig",
        .data = "signature of an archive that no longer exists",
    });

    var db = try Database.open(testing.allocator, testing.io, db_path);
    defer db.deinit();
    var summary = try db.addPackages(&.{package_path}, .{});
    defer summary.deinit(testing.allocator);
    try testing.expect(summary.published);
    try expectPresent(tmp.dir, "demo.db.tar.zst");
    try expectMissing(tmp.dir, "demo.db.tar.zst.sig");
    try expectMissing(tmp.dir, ".tmp.demo.db.tar.zst.sig");
    try expectMissing(tmp.dir, "demo.db.sig");
}

test "verify checks the signature of both database archives" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try fixturePath(&tmp.sub_path, "demo.db.tar.zst");
    defer testing.allocator.free(db_path);
    const package_path = try fixturePath(&tmp.sub_path, "demo-1.0-1-any.pkg.tar.zst");
    defer testing.allocator.free(package_path);
    const gpg_path = try fixturePath(&tmp.sub_path, "fake-gpg");
    defer testing.allocator.free(gpg_path);
    try writePackage(package_path, "demo", "1.0-1");
    try writeScript(tmp.dir, "fake-gpg", accepting_verifier_script);

    var db = try Database.open(testing.allocator, testing.io, db_path);
    defer db.deinit();
    var added = try db.addPackages(&.{package_path}, .{});
    defer added.deinit(testing.allocator);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "demo.db.tar.zst.sig", .data = fake_signature });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "demo.files.tar.zst.sig", .data = fake_signature });

    const environ = try testEnviron();
    defer environ.block.deinit(testing.allocator);
    var summary = try db.verifySignatures(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .environ = environ,
        .gpg_path = gpg_path,
    });
    defer summary.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), summary.results.len);
    try testing.expectEqual(VerifyTarget.database, summary.results[0].target);
    try testing.expectEqual(VerifyTarget.files, summary.results[1].target);
    for (summary.results) |result| {
        try testing.expect(result.archive_present);
        try testing.expect(result.signature_present);
        try testing.expect(result.verified);
        try testing.expectEqual(source_pgp_verifier.Warning.none, result.warning);
        try testing.expectEqualStrings(signing_primary_fingerprint, result.fingerprint);
    }
}

test "verify reports a missing signature as skipped" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try fixturePath(&tmp.sub_path, "demo.db.tar.zst");
    defer testing.allocator.free(db_path);
    const package_path = try fixturePath(&tmp.sub_path, "demo-1.0-1-any.pkg.tar.zst");
    defer testing.allocator.free(package_path);
    const gpg_path = try fixturePath(&tmp.sub_path, "fake-gpg");
    defer testing.allocator.free(gpg_path);
    try writePackage(package_path, "demo", "1.0-1");
    try writeScript(tmp.dir, "fake-gpg", accepting_verifier_script);

    var db = try Database.open(testing.allocator, testing.io, db_path);
    defer db.deinit();
    var added = try db.addPackages(&.{package_path}, .{});
    defer added.deinit(testing.allocator);

    const environ = try testEnviron();
    defer environ.block.deinit(testing.allocator);
    const verifier = source_pgp_verifier.Verifier{
        .allocator = testing.allocator,
        .io = testing.io,
        .environ = environ,
        .gpg_path = gpg_path,
    };

    var unsigned = try db.verifySignatures(verifier);
    defer unsigned.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), unsigned.results.len);
    for (unsigned.results) |result| {
        try testing.expect(result.archive_present);
        try testing.expect(!result.signature_present);
        try testing.expect(!result.verified);
        try testing.expectEqual(@as(usize, 0), result.fingerprint.len);
    }

    // An absent archive is reported and never blocks the other target.
    try tmp.dir.deleteFile(testing.io, "demo.files.tar.zst");
    var partial = try db.verifySignatures(verifier);
    defer partial.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), partial.results.len);
    try testing.expect(partial.results[0].archive_present);
    try testing.expect(!partial.results[1].archive_present);
    try testing.expect(!partial.results[1].signature_present);
}

test "verify stops at an unusable signature" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try fixturePath(&tmp.sub_path, "demo.db.tar.zst");
    defer testing.allocator.free(db_path);
    const package_path = try fixturePath(&tmp.sub_path, "demo-1.0-1-any.pkg.tar.zst");
    defer testing.allocator.free(package_path);
    const gpg_path = try fixturePath(&tmp.sub_path, "fake-gpg");
    defer testing.allocator.free(gpg_path);
    try writePackage(package_path, "demo", "1.0-1");
    try writeScript(tmp.dir, "fake-gpg", rejecting_verifier_script);

    var db = try Database.open(testing.allocator, testing.io, db_path);
    defer db.deinit();
    var added = try db.addPackages(&.{package_path}, .{});
    defer added.deinit(testing.allocator);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "demo.db.tar.zst.sig", .data = fake_signature });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "demo.files.tar.zst.sig", .data = fake_signature });

    const environ = try testEnviron();
    defer environ.block.deinit(testing.allocator);
    var summary = try db.verifySignatures(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .environ = environ,
        .gpg_path = gpg_path,
    });
    defer summary.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), summary.results.len);
    try testing.expect(summary.results[0].signature_present);
    try testing.expect(!summary.results[0].verified);
    try testing.expectEqual(@as(usize, 0), summary.results[0].fingerprint.len);
}
