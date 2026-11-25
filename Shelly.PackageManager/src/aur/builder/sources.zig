//! Source acquisition and integrity pipeline: local copy, HTTP download,
//! git cloning, checksum and PGP signature verification, and safe archive
//! extraction into the staging tree.

const std = @import("std");
const trackReturnError = @import("diagnostics").captureError;
const events = @import("../events.zig");
const op_context = @import("operation_context");
const archive = @import("archive");
const process_runner = @import("../builder.zig");
const downloader = @import("../../shared/downloader.zig");
const source_pgp_verifier = @import("../../shared/source_pgp_verifier.zig");
const steps = @import("steps.zig");
const checksums = @import("checksums.zig");
const source_spec = @import("source_spec.zig");
const metadata = @import("metadata.zig");
const PackageBuilder = @import("builder.zig").PackageBuilder;
const PackageBuild = @import("../../pkgbuild/pkgbuild_parser.zig").Pkgbuild;

pub fn prepareSources(self: *PackageBuilder, operation: *op_context.Operation) !void {
    try steps.logPhase(self, "sources");
    try operation.checkCancelled();
    const package_build = &self.package_builds[0];
    self.failure_location = .{
        .package_name = package_build.pkg_name,
        .step_name = "sources",
    };
    const sources = package_build.source orelse &.{};
    const valid_pgp_keys = package_build.valid_pgp_keys orelse &.{};
    try source_pgp_verifier.validatePinnedKeys(valid_pgp_keys);

    for (checksums.checksumSets(package_build)) |set|
        try checksums.validateChecksumCount(sources.len, set.sums);
    if (sources.len > 0 and !checksums.hasSourceChecksums(package_build))
        return error.MissingSourceChecksums;

    const srcdir = try std.fs.path.join(self.allocator, &.{ self.options.work_directory, "src" });
    defer self.allocator.free(srcdir);
    const source_staging = try std.fs.path.join(self.allocator, &.{ self.options.work_directory, ".sources.shelly-staging" });
    defer self.allocator.free(source_staging);
    const extraction_staging = try std.fs.path.join(self.allocator, &.{ self.options.work_directory, ".src.shelly-staging" });
    defer self.allocator.free(extraction_staging);

    std.Io.Dir.cwd().deleteTree(self.io, source_staging) catch {
        steps.reportUnwritableBuildDirectory(self, source_staging);
        return error.BuildDirectoryNotWritable;
    };
    std.Io.Dir.cwd().deleteTree(self.io, extraction_staging) catch {
        steps.reportUnwritableBuildDirectory(self, extraction_staging);
        return error.BuildDirectoryNotWritable;
    };
    std.Io.Dir.cwd().createDirPath(self.io, source_staging) catch {
        steps.reportUnwritableBuildDirectory(self, source_staging);
        return error.BuildDirectoryNotWritable;
    };
    defer std.Io.Dir.cwd().deleteTree(self.io, source_staging) catch {};
    errdefer std.Io.Dir.cwd().deleteTree(self.io, extraction_staging) catch {};

    raiseSourceMessage(self, package_build, "Preparing package sources");
    const prepared = try self.allocator.alloc(source_spec.PreparedSource, sources.len);
    var prepared_count: usize = 0;
    defer {
        for (prepared[0..prepared_count]) |*source| source.deinit(self.allocator);
        self.allocator.free(prepared);
    }
    for (sources, 0..) |raw_source, index| {
        try operation.checkCancelled();
        var source = try source_spec.ParsedSource.parse(self.allocator, raw_source);
        const destination = std.fs.path.join(self.allocator, &.{ source_staging, source.name }) catch |err| {
            source.deinit(self.allocator);
            return err;
        };
        prepared[prepared_count] = .{
            .source = source,
            .destination = destination,
            .index = index,
        };
        prepared_count += 1;

        raiseSourceMessage(self, package_build, source.name);
        try acquireSource(self, operation, source, destination);
    }

    // Match makepkg's integrity ordering: acquire every source, then check
    // hashes and signatures, and only then extract anything. makepkg hashes a
    // deterministic `git archive` for pinned tags and commits. Moving Git
    // references cannot be checksummed and must retain their SKIP entries.
    for (prepared) |*source| {
        try operation.checkCancelled();
        if (source.source.kind == .git) {
            try verifyGitSourceChecksums(self, operation, package_build, source);
            continue;
        }
        verifySourceChecksums(self, package_build, source.index, source.destination) catch |err| {
            if (err != error.SourceChecksumMismatch or source.source.kind != .http) return err;
            try acquireHttpSource(self, operation, source.source, source.destination, true);
            try verifySourceChecksums(self, package_build, source.index, source.destination);
        };
    }

    if (!self.options.skip_source_pgp_verification)
        try verifyPreparedSourceSignatures(self, operation, package_build, prepared, source_staging);

    // makepkg runs the optional verify() function in $startdir after
    // built-in integrity checks and before extracting any source. Expose
    // staged remote/renamed sources there through temporary symlinks;
    // existing direct local sources and the default HTTP cache are already
    // visible in $startdir.
    if (self.options.run_verify and !self.options.skip_source_pgp_verification) {
        if (package_build.execution) |execution| if (execution.verify_step) |step| {
            var view = try exposeSourcesForVerify(self, prepared);
            defer view.deinit(self);
            try steps.runStep(
                self,
                operation,
                self.requested_names[0],
                step.name,
                execution.shared_prelude,
                execution.shared_helpers,
                step.body,
                self.options.start_directory,
            );
            // Direct local sources are the real files in $startdir rather
            // than temporary links. Carry any intentional verify()
            // mutation forward into extraction, as makepkg does.
            for (prepared) |*source| if (source.source.kind == .local and
                std.mem.eql(u8, source.source.location, source.source.name))
            {
                try copyLocalSource(self, source.source.location, source.destination);
            };
            for (view.cached_sources.items) |index| {
                const source = &prepared[index];
                if (source.source.kind == .git) {
                    const cache_path = try std.fs.path.join(self.allocator, &.{ self.options.source_destination, source.source.name });
                    defer self.allocator.free(cache_path);
                    try std.Io.Dir.cwd().deleteTree(self.io, source.destination);
                    try materializeGitSource(self, operation, source.source, cache_path, source.destination);
                } else try copyLocalSource(self, source.source.name, source.destination);
            }
        };
    }

    std.Io.Dir.cwd().createDirPath(self.io, extraction_staging) catch {
        steps.reportUnwritableBuildDirectory(self, extraction_staging);
        return error.BuildDirectoryNotWritable;
    };
    var extracted_files: ExtractedSourceFiles = .{ .sources = prepared };
    defer extracted_files.deinit(self.allocator);
    for (prepared) |*source| {
        try operation.checkCancelled();
        const materialized = try std.fs.path.join(
            self.allocator,
            &.{ extraction_staging, source.source.name },
        );
        defer self.allocator.free(materialized);
        try rejectExistingDestination(self.io, materialized);
        if (source.source.kind == .git) {
            try materializeGitSource(self, operation, source.source, source.destination, materialized);
        } else {
            const no_extract = source_spec.containsString(
                package_build.no_extract orelse &.{},
                source.source.name,
            );
            if (no_extract) {
                try std.Io.Dir.copyFile(.cwd(), source.destination, .cwd(), materialized, self.io, .{});
                continue;
            }

            // Extract before materializing the raw payload. An extensionless
            // renamed source may have the same name as the archive's root
            // directory; in that case the extracted entry owns the path and
            // the raw archive must not overwrite it.
            const extracted = try extractSourceArchiveIfRecognized(
                self,
                operation,
                source.destination,
                extraction_staging,
                source.index,
                &extracted_files,
            );
            if (!extracted) try decompressStandaloneSource(self, operation, source, &extracted_files, extraction_staging);
            if (!extracted or !pathExistsNoFollow(self.io, materialized))
                try std.Io.Dir.copyFile(.cwd(), source.destination, .cwd(), materialized, self.io, .{});
        }
    }
    // Only a fully prepared staging tree is committed. Sources are
    // reproducible, so retaining a second backup tree adds state without
    // improving recovery.
    std.Io.Dir.cwd().deleteTree(self.io, srcdir) catch {
        steps.reportUnwritableBuildDirectory(self, srcdir);
        return error.BuildDirectoryNotWritable;
    };
    std.Io.Dir.rename(.cwd(), extraction_staging, .cwd(), srcdir, self.io) catch {
        steps.reportUnwritableBuildDirectory(self, srcdir);
        return error.BuildDirectoryNotWritable;
    };
}

fn verifyGitSourceChecksums(
    self: *PackageBuilder,
    operation: *op_context.Operation,
    package_build: *const PackageBuild,
    prepared: *const source_spec.PreparedSource,
) !void {
    const reference = prepared.source.reference orelse {
        return checksums.requireSkippedVcsChecksums(package_build, prepared.index);
    };
    if (reference.kind == .branch)
        return checksums.requireSkippedVcsChecksums(package_build, prepared.index);
    if (!checksums.hasVerifiableChecksum(package_build, prepared.index)) return;

    const archive_path = try gitChecksumArchive(self, operation, prepared);
    defer self.allocator.free(archive_path);
    defer std.Io.Dir.cwd().deleteFile(self.io, archive_path) catch {};
    try verifySourceChecksums(self, package_build, prepared.index, archive_path);
}

/// Deterministic archive used by both verification and checksum updating.
pub fn gitChecksumArchive(self: *PackageBuilder, operation: *op_context.Operation, prepared: *const source_spec.PreparedSource) ![]u8 {
    const reference = prepared.source.reference orelse return error.UnsupportedVcsChecksum;
    if (reference.kind == .branch) return error.UnsupportedVcsChecksum;
    var random_suffix: [8]u8 = undefined;
    self.io.random(&random_suffix);
    const suffix = std.fmt.bytesToHex(random_suffix, .lower);
    const archive_path = try std.fmt.allocPrint(
        self.allocator,
        "{s}.shelly-archive-{s}.tmp",
        .{ prepared.destination, suffix },
    );
    errdefer self.allocator.free(archive_path);
    errdefer std.Io.Dir.cwd().deleteFile(self.io, archive_path) catch {};

    // makepkg neutralizes export-subst/export-ignore when it archives the
    // acquisition mirror. Apply the same highest-precedence Git attributes
    // to this fresh working clone only for the checksum operation.
    const info_path = try std.fs.path.join(self.allocator, &.{ prepared.destination, ".git/info" });
    defer self.allocator.free(info_path);
    try std.Io.Dir.cwd().createDirPath(self.io, info_path);
    const attributes_path = try std.fs.path.join(self.allocator, &.{ info_path, "attributes" });
    defer self.allocator.free(attributes_path);
    const previous_attributes: ?[]u8 = std.Io.Dir.cwd().readFileAlloc(
        self.io,
        attributes_path,
        self.allocator,
        .limited(1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer {
        if (previous_attributes) |contents| {
            std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = attributes_path, .data = contents }) catch {};
            self.allocator.free(contents);
        } else {
            std.Io.Dir.cwd().deleteFile(self.io, attributes_path) catch {};
        }
    }
    try std.Io.Dir.cwd().writeFile(self.io, .{
        .sub_path = attributes_path,
        .data = "* -export-subst -export-ignore\n",
    });

    try runSourceCommand(self, operation, &.{
        "-C",
        prepared.destination,
        "archive",
        "--format=tar",
        "--output",
        archive_path,
        "--",
        reference.value,
    });
    return archive_path;
}

fn copyLocalSource(self: *PackageBuilder, source_name: []const u8, destination: []const u8) !void {
    const normalized = try archive.normalizeEntryPath(self.allocator, source_name);
    defer self.allocator.free(normalized);
    const source_path = try std.fs.path.join(self.allocator, &.{ self.options.start_directory, normalized });
    defer self.allocator.free(source_path);
    const stat = try std.Io.Dir.cwd().statFile(self.io, source_path, .{ .follow_symlinks = false });
    if (stat.kind != .file) return error.InvalidLocalSource;
    try std.Io.Dir.copyFile(.cwd(), source_path, .cwd(), destination, self.io, .{});
}

const SourceVerificationView = struct {
    links: std.ArrayList([]u8) = .empty,
    cached_sources: std.ArrayList(usize) = .empty,

    fn deinit(view: *SourceVerificationView, self: *PackageBuilder) void {
        for (view.links.items) |path| {
            std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
            self.allocator.free(path);
        }
        view.links.deinit(self.allocator);
        view.cached_sources.deinit(self.allocator);
    }
};

fn exposeSourcesForVerify(self: *PackageBuilder, prepared: []const source_spec.PreparedSource) !SourceVerificationView {
    var view: SourceVerificationView = .{};
    errdefer view.deinit(self);
    const start_directory = try std.Io.Dir.cwd().realPathFileAlloc(self.io, self.options.start_directory, self.allocator);
    defer self.allocator.free(start_directory);
    const source_directory = try std.Io.Dir.cwd().realPathFileAlloc(self.io, self.options.source_destination, self.allocator);
    defer self.allocator.free(source_directory);
    const cache_in_startdir = std.mem.eql(u8, start_directory, source_directory);

    for (prepared, 0..) |*source, index| {
        const visible_path = try std.fs.path.join(
            self.allocator,
            &.{ self.options.start_directory, source.source.name },
        );
        errdefer self.allocator.free(visible_path);
        const existing = std.Io.Dir.cwd().statFile(
            self.io,
            visible_path,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (existing) |stat| {
            // A direct local source already occupies its makepkg-visible
            // path. Never replace an unrelated user path for a renamed,
            // downloaded, or VCS source.
            if (source.source.kind == .local and
                std.mem.eql(u8, source.source.location, source.source.name))
            {
                self.allocator.free(visible_path);
                continue;
            }
            if (source.source.kind == .git and cache_in_startdir and stat.kind == .directory) {
                // Acquisition validated this mirror. Keep it visible to verify()
                // and materialize its selected ref again after verification.
                try view.cached_sources.append(self.allocator, index);
                self.allocator.free(visible_path);
                continue;
            }
            if (source.source.kind == .http and cache_in_startdir and stat.kind == .file) {
                // Acquisition created or validated this exact cache entry.
                // Expose the bytes that passed integrity checks, then copy
                // any successful verify() changes back into staging. Keep
                // cached files out of the temporary-link cleanup list.
                try std.Io.Dir.copyFile(.cwd(), source.destination, .cwd(), visible_path, self.io, .{});
                try view.cached_sources.append(self.allocator, index);
                self.allocator.free(visible_path);
                continue;
            }
            return error.SourceVerificationViewConflict;
        }
        try std.Io.Dir.cwd().symLink(
            self.io,
            source.destination,
            visible_path,
            .{ .is_directory = source.source.kind == .git },
        );
        errdefer std.Io.Dir.cwd().deleteFile(self.io, visible_path) catch {};
        try view.links.append(self.allocator, visible_path);
    }
    return view;
}

fn downloadSource(
    self: *PackageBuilder,
    operation: *op_context.Operation,
    url: []const u8,
    destination: []const u8,
) !void {
    var core = downloader.CoreDownloader.init(self.allocator, self.io, .default());
    defer core.deinit();
    core.setParentOperation(operation);
    switch (core.downloadToFile(url, destination, true)) {
        .succes, .skipped => {},
        .failure => |err| return if (err == downloader.DownloadError.Cancelled)
            error.Cancelled
        else
            error.SourceDownloadFailed,
    }
}

fn acquireHttpSource(
    self: *PackageBuilder,
    operation: *op_context.Operation,
    source: source_spec.ParsedSource,
    destination: []const u8,
    force_refresh: bool,
) !void {
    const cache_path = try std.fs.path.join(
        self.allocator,
        &.{ self.options.source_destination, source.name },
    );
    defer self.allocator.free(cache_path);
    if (force_refresh) std.Io.Dir.cwd().deleteFile(self.io, cache_path) catch {};
    const cached = std.Io.Dir.cwd().statFile(
        self.io,
        cache_path,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (cached) |stat| {
        if (stat.kind != .file) return error.InvalidSourceCacheEntry;
    } else {
        var random_suffix: [8]u8 = undefined;
        self.io.random(&random_suffix);
        const suffix = std.fmt.bytesToHex(random_suffix, .lower);
        const temporary_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}.shelly-{s}.tmp",
            .{ cache_path, suffix },
        );
        defer self.allocator.free(temporary_path);
        errdefer std.Io.Dir.cwd().deleteFile(self.io, temporary_path) catch {};
        try downloadSource(self, operation, source.location, temporary_path);
        std.Io.Dir.cwd().renamePreserve(temporary_path, std.Io.Dir.cwd(), cache_path, self.io) catch |err| switch (err) {
            error.PathAlreadyExists => std.Io.Dir.cwd().deleteFile(self.io, temporary_path) catch {},
            else => return err,
        };
    }
    std.Io.Dir.cwd().deleteFile(self.io, destination) catch {};
    try std.Io.Dir.copyFile(.cwd(), cache_path, .cwd(), destination, self.io, .{});
}

/// Git sources whose emitted checksums are all SKIP (or moving) are validated
/// without transferring objects. Commit pins cannot be probed: ls-remote does
/// not expose raw commits and a dry-run fetch still transfers objects, so an
/// all-SKIP commit pin is deliberately not existence-checked.
pub fn probeSkippedGitRef(
    self: *PackageBuilder,
    operation: *op_context.Operation,
    source: source_spec.ParsedSource,
) !void {
    if (source.kind != .git) return;
    const reference = source.reference orelse {
        try runSourceCommand(self, operation, &.{ "ls-remote", "--exit-code", "--heads", "--", source.location });
        return;
    };
    switch (reference.kind) {
        .commit => {},
        .branch, .tag => {
            const prefix = if (reference.kind == .branch) "refs/heads/" else "refs/tags/";
            const full_ref = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, reference.value });
            defer self.allocator.free(full_ref);
            // Validate before using the name as an ls-remote pattern so an
            // invalid ref fails instead of matching a glob.
            try runSourceCommand(self, operation, &.{ "check-ref-format", full_ref });
            const heads_or_tags = if (reference.kind == .branch) "--heads" else "--tags";
            try runSourceCommand(self, operation, &.{ "ls-remote", "--exit-code", heads_or_tags, "--", source.location, full_ref });
        },
    }
}

const git_cache_lock_name = ".shelly-lock";
/// Force-updated tags append shallow boundaries; past this many the entry is
/// replaced with a fresh single-boundary shallow mirror.
const git_shallow_boundary_limit = 64;

fn acquireGitSource(
    self: *PackageBuilder,
    operation: *op_context.Operation,
    source: source_spec.ParsedSource,
    destination: []const u8,
) !void {
    const cache_path = try std.fs.path.join(
        self.allocator,
        &.{ self.options.source_destination, source.name },
    );
    defer self.allocator.free(cache_path);
    const shallow_allowed = try shallowAcquisitionAllowed(self, operation, source);
    try ensureGitCacheEntry(self, operation, source, cache_path, shallow_allowed);
    materializeGitSource(self, operation, source, cache_path, destination) catch |err| {
        if (err == error.Cancelled) return err;
        const shallow = gitCacheIsShallow(self, operation, cache_path) catch false;
        if (!shallow) return err;
        // A shallow entry can fail materialization (for example a tag that
        // does not peel to a commit). Recreate once with full history.
        try replaceGitCacheEntry(self, operation, source, cache_path, false);
        try materializeGitSource(self, operation, source, cache_path, destination);
    };
}

/// Shallow acquisition requires an enabled setting, a pinned tag with a safe
/// ref name or a full 40-hex commit, and no lifecycle body that could read
/// repository history. Everything else takes the full mirror path.
fn shallowAcquisitionAllowed(
    self: *PackageBuilder,
    operation: *op_context.Operation,
    source: source_spec.ParsedSource,
) !bool {
    if (!self.shellybuild_config.build.shallow_git) return false;
    const reference = source.reference orelse return false;
    if (reference.kind == .branch) return false;
    if (requiresFullGitHistory(self)) return false;
    if (reference.kind == .commit) return source_spec.isFullCommitSha(reference.value);
    const full_ref = try std.fmt.allocPrint(self.allocator, "refs/tags/{s}", .{reference.value});
    defer self.allocator.free(full_ref);
    runSourceCommand(self, operation, &.{ "check-ref-format", full_ref }) catch |err| {
        if (err == error.Cancelled) return err;
        return false;
    };
    return true;
}

/// The scan covers every lifecycle body even when a metadata-only command
/// will not run it, because the same cache entry may later serve a real
/// build. It is intentionally coarse: git apply, submodule updates, and
/// secondary clones also force full history. Static scanning cannot see git
/// invoked by an external script or Makefile; the fallback stays conservative.
fn requiresFullGitHistory(self: *const PackageBuilder) bool {
    const execution = self.package_builds[0].execution orelse return false;
    if (preludeMentionsGitOrSrcdest(execution.shared_prelude)) return true;
    if (bodyMentionsGitOrSrcdest(execution.shared_helpers)) return true;
    if (bodyMentionsGitOrSrcdest(execution.package_helpers)) return true;
    if (execution.verify_step) |step| {
        if (bodyMentionsGitOrSrcdest(step.body) or bodyMentionsGitOrSrcdest(step.expanded_body)) return true;
    }
    for (execution.steps) |step| {
        if (bodyMentionsGitOrSrcdest(step.body) or bodyMentionsGitOrSrcdest(step.expanded_body)) return true;
    }
    return false;
}

/// The prelude redeclares top-level shell state: `declare -a` data arrays
/// (source, depends, makedepends, options, ...) and `declare --` scalars. A
/// `makedepends=('git')` entry is data, not an invocation, so array lines are
/// skipped; scalars can hold a command name or fragment and are still scanned.
fn preludeMentionsGitOrSrcdest(prelude: []const u8) bool {
    var lines = std.mem.splitScalar(u8, prelude, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "declare -a ")) continue;
        if (bodyMentionsGitOrSrcdest(line)) return true;
    }
    return false;
}

fn bodyMentionsGitOrSrcdest(body: []const u8) bool {
    if (std.mem.indexOf(u8, body, "SRCDEST") != null) return true;
    var cursor: usize = 0;
    var quote: u8 = 0;
    while (cursor < body.len) {
        const character = body[cursor];
        if (quote == 0 and character == '\\') {
            cursor += 2;
            continue;
        }
        if (quote == 0 and (character == '\'' or character == '"')) {
            quote = character;
            cursor += 1;
            continue;
        }
        if (quote != 0) {
            if (character == quote) {
                quote = 0;
                cursor += 1;
                continue;
            }
            // Quoted text can still run commands (`sh -c "git describe"`), so
            // keep scanning it; only comment handling depends on the state.
            if (std.mem.startsWith(u8, body[cursor..], "git")) {
                const after = cursor + "git".len;
                const before_ok = cursor == 0 or isGitCommandBoundary(body[cursor - 1], true);
                const after_ok = after == body.len or isGitCommandBoundary(body[after], false);
                if (before_ok and after_ok) return true;
            }
            cursor += 1;
            continue;
        }
        // A metadata array literal (depends=('git'), source=('git+...')) is
        // data even inside a package function. Skip the whole literal so a
        // quoted dependency name cannot force full history.
        if (isLineStart(body, cursor)) {
            if (metadataArrayLiteralEnd(body, cursor)) |end| {
                cursor = end;
                continue;
            }
        }
        // Comments are never executed, including the ones that merely mention
        // git. Skip to the end of the line.
        if (character == '#' and isCommentStart(body, cursor)) {
            cursor = std.mem.indexOfScalarPos(u8, body, cursor, '\n') orelse body.len;
            continue;
        }
        if (std.mem.startsWith(u8, body[cursor..], "git")) {
            // Command-position boundaries only: identifier characters, URL and
            // path punctuation (git+ prefixes, git:// URLs, .git suffixes, and
            // foo-git names) are not git invocations. /usr/bin/git still counts.
            const before_ok = cursor == 0 or isGitCommandBoundary(body[cursor - 1], true);
            const after = cursor + "git".len;
            const after_ok = after == body.len or isGitCommandBoundary(body[after], false);
            if (before_ok and after_ok) return true;
        }
        cursor += 1;
    }
    return false;
}

fn isCommentStart(body: []const u8, position: usize) bool {
    if (position == 0) return true;
    const before = body[position - 1];
    return std.ascii.isWhitespace(before) or std.mem.indexOfScalar(u8, ";&|()", before) != null;
}

fn isLineStart(body: []const u8, position: usize) bool {
    if (position == 0) return true;
    const line_start = if (std.mem.lastIndexOfScalar(u8, body[0..position], '\n')) |index| index + 1 else 0;
    for (body[line_start..position]) |character| {
        if (character != ' ' and character != '\t') return false;
    }
    return true;
}

const checksum_algorithms = std.meta.tags(checksums.ChecksumAlgorithm);
/// Names whose array literals carry makepkg metadata rather than commands.
const metadata_arrays: []const []const u8 = &.{
    "pkgbase",    "pkgname",     "source",         "depends", "makedepends", "checkdepends",
    "optdepends", "provides",    "conflicts",      "replaces", "groups",     "license",
    "arch",       "backup",      "options",        "noextract", "validpgpkeys", "install",
    "changelog",
};

fn metadataArrayName(name: []const u8) bool {
    for (metadata_arrays) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    if (std.mem.eql(u8, name, "cksums")) return true;
    inline for (checksum_algorithms) |algorithm| {
        const base: []const u8 = @tagName(algorithm) ++ "sums";
        if (name.len >= base.len and std.mem.eql(u8, name[0..base.len], base)) {
            if (name.len == base.len or name[base.len] == '_') return true;
        }
    }
    return false;
}

/// Returns the index just past a `<metadata array>=()` literal starting at
/// `start`, or null when the text is not one or its end cannot be determined.
/// Failing to skip only keeps the conservative full-history path.
fn metadataArrayLiteralEnd(body: []const u8, start: usize) ?usize {
    var cursor = start;
    while (cursor < body.len and (body[cursor] == ' ' or body[cursor] == '\t')) cursor += 1;
    const name_start = cursor;
    while (cursor < body.len and (std.ascii.isAlphanumeric(body[cursor]) or body[cursor] == '_')) cursor += 1;
    if (!metadataArrayName(body[name_start..cursor])) return null;
    if (cursor < body.len and body[cursor] == '+') cursor += 1;
    if (cursor >= body.len or body[cursor] != '=') return null;
    cursor += 1;
    if (cursor >= body.len or body[cursor] != '(') return null;
    return shellArrayEnd(body, cursor + 1);
}

fn shellArrayEnd(body: []const u8, start: usize) ?usize {
    var depth: usize = 1;
    var i = start;
    while (i < body.len) {
        switch (body[i]) {
            '\'' => {
                i += 1;
                while (i < body.len and body[i] != '\'') i += 1;
                if (i >= body.len) return null;
                i += 1;
            },
            '"' => {
                i = shellDoubleQuotedEnd(body, i + 1) orelse return null;
            },
            '\\' => i += 2,
            '#' => if (i == start or std.ascii.isWhitespace(body[i - 1])) {
                i = std.mem.indexOfScalarPos(u8, body, i, '\n') orelse return null;
            } else {
                i += 1;
            },
            '(' => {
                depth += 1;
                i += 1;
            },
            ')' => {
                depth -= 1;
                if (depth == 0) return i + 1;
                i += 1;
            },
            '<' => if (std.mem.startsWith(u8, body[i..], "<<")) return null else {
                i += 1;
            },
            else => i += 1,
        }
    }
    return null;
}

fn shellDoubleQuotedEnd(body: []const u8, start: usize) ?usize {
    var i = start;
    while (i < body.len) {
        switch (body[i]) {
            '\\' => i += 2,
            '"' => return i + 1,
            '$' => if (i + 1 < body.len and body[i + 1] == '(') {
                var depth: usize = 1;
                i += 2;
                while (i < body.len and depth > 0) : (i += 1) {
                    switch (body[i]) {
                        '\\' => i += 1,
                        '\'' => {
                            i += 1;
                            while (i < body.len and body[i] != '\'') i += 1;
                            if (i >= body.len) return null;
                        },
                        '(' => depth += 1,
                        ')' => depth -= 1,
                        else => {},
                    }
                }
                if (depth != 0) return null;
            } else {
                i += 1;
            },
            else => i += 1,
        }
    }
    return null;
}

fn isGitCommandBoundary(character: u8, leading: bool) bool {
    return switch (character) {
        ' ', '\t', '\r', '\n', ';', '|', '&', '(', ')', '{', '}', '\'', '"', '`', '!', '=' => true,
        '/' => leading,
        else => false,
    };
}

fn ensureGitCacheEntry(
    self: *PackageBuilder,
    operation: *op_context.Operation,
    source: source_spec.ParsedSource,
    cache_path: []const u8,
    shallow_allowed: bool,
) !void {
    while (true) {
        try operation.checkCancelled();
        const cached = std.Io.Dir.cwd().statFile(
            self.io,
            cache_path,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (cached) |stat| {
            if (stat.kind != .directory) return error.InvalidSourceCacheEntry;
            var lock = try lockGitCacheEntry(self, operation, cache_path);
            defer lock.deinit(self);
            const origin = gitCacheOriginUrl(self, operation, cache_path) catch null;
            defer if (origin) |url| self.allocator.free(url);
            if (origin == null or !std.mem.eql(u8, origin.?, source.location)) {
                // Never silently repoint another package's cache entry.
                try replaceGitCacheEntryLocked(self, operation, source, cache_path, shallow_allowed);
                return;
            }
            const shallow = try gitCacheIsShallow(self, operation, cache_path);
            if (!shallow) {
                // A full mirror is never downgraded to shallow.
                try refreshFullGitMirror(self, operation, source, cache_path);
                return;
            }
            if (shallow_allowed) {
                if (try gitShallowBoundaryExceeded(self, cache_path)) {
                    try replaceGitCacheEntryLocked(self, operation, source, cache_path, true);
                    return;
                }
                // Ref-targeted fetch only: the mirror refspec would delete the
                // synthetic commit pin and pull unrelated refs.
                fetchShallowPinnedRef(self, operation, source, cache_path) catch |err| {
                    if (err == error.Cancelled) return err;
                    try repairShallowCache(self, operation, source, cache_path);
                };
                return;
            }
            try repairShallowCache(self, operation, source, cache_path);
            return;
        }
        if (try createGitCacheEntry(self, operation, source, cache_path, shallow_allowed)) return;
        // Lost the creation race; loop and continue under the winner's lock.
    }
}

fn refreshFullGitMirror(
    self: *PackageBuilder,
    operation: *op_context.Operation,
    source: source_spec.ParsedSource,
    cache_path: []const u8,
) !void {
    try runSourceCommand(self, operation, &.{ "-C", cache_path, "remote", "set-url", "origin", source.location });
    // A detached repack can delete packs while the clone below copies them.
    try runSourceCommand(self, operation, &.{
        "-C",
        cache_path,
        "-c",
        "maintenance.autoDetach=false",
        "-c",
        "gc.autoDetach=false",
        "remote",
        "update",
        "--prune",
    });
}

/// Upgrade a shallow entry to full history in place; recreate a full mirror
/// when the server or repository cannot unshallow.
fn repairShallowCache(
    self: *PackageBuilder,
    operation: *op_context.Operation,
    source: source_spec.ParsedSource,
    cache_path: []const u8,
) !void {
    runSourceCommand(self, operation, &.{
        "-C",
        cache_path,
        "-c",
        "maintenance.autoDetach=false",
        "-c",
        "gc.autoDetach=false",
        "fetch",
        "--unshallow",
        "--prune",
    }) catch |err| {
        if (err == error.Cancelled) return err;
        try replaceGitCacheEntryLocked(self, operation, source, cache_path, false);
        return;
    };
    runSourceCommand(self, operation, &.{ "-C", cache_path, "config", "shelly.acquisitionMode", "full" }) catch {};
}

fn createGitCacheEntry(
    self: *PackageBuilder,
    operation: *op_context.Operation,
    source: source_spec.ParsedSource,
    cache_path: []const u8,
    shallow_allowed: bool,
) !bool {
    const temporary_path = try randomCacheSiblingPath(self, cache_path);
    defer self.allocator.free(temporary_path);
    errdefer std.Io.Dir.cwd().deleteTree(self.io, temporary_path) catch {};
    try std.Io.Dir.cwd().createDirPath(self.io, temporary_path);
    if (shallow_allowed) {
        buildShallowGitEntry(self, operation, source, temporary_path) catch |err| {
            if (err == error.Cancelled) return err;
            // Unsupported sha want, invalid ref, or server/client mismatch:
            // fall back to the full mirror path.
            std.Io.Dir.cwd().deleteTree(self.io, temporary_path) catch {};
            try std.Io.Dir.cwd().createDirPath(self.io, temporary_path);
            try buildFullGitMirror(self, operation, source, temporary_path);
        };
    } else {
        try buildFullGitMirror(self, operation, source, temporary_path);
    }
    std.Io.Dir.cwd().renamePreserve(temporary_path, std.Io.Dir.cwd(), cache_path, self.io) catch |err| switch (err) {
        error.PathAlreadyExists => {
            std.Io.Dir.cwd().deleteTree(self.io, temporary_path) catch {};
            return false;
        },
        else => return err,
    };
    return true;
}

fn buildFullGitMirror(
    self: *PackageBuilder,
    operation: *op_context.Operation,
    source: source_spec.ParsedSource,
    repository_path: []const u8,
) !void {
    try runSourceCommand(self, operation, &.{ "clone", "--mirror", "--", source.location, repository_path });
    try runSourceCommand(self, operation, &.{ "-C", repository_path, "config", "shelly.acquisitionMode", "full" });
}

fn buildShallowGitEntry(
    self: *PackageBuilder,
    operation: *op_context.Operation,
    source: source_spec.ParsedSource,
    repository_path: []const u8,
) !void {
    try runSourceCommand(self, operation, &.{ "init", "--bare", repository_path });
    try runSourceCommand(self, operation, &.{ "-C", repository_path, "config", "remote.origin.url", source.location });
    try runSourceCommand(self, operation, &.{ "-C", repository_path, "config", "remote.origin.fetch", "+refs/*:refs/*" });
    try runSourceCommand(self, operation, &.{ "-C", repository_path, "config", "remote.origin.mirror", "true" });
    try fetchShallowPinnedRef(self, operation, source, repository_path);
    try runSourceCommand(self, operation, &.{ "-C", repository_path, "config", "shelly.acquisitionMode", "shallow" });
}

fn fetchShallowPinnedRef(
    self: *PackageBuilder,
    operation: *op_context.Operation,
    source: source_spec.ParsedSource,
    repository_path: []const u8,
) !void {
    const reference = source.reference orelse return error.UnsupportedVcsChecksum;
    switch (reference.kind) {
        .branch => return error.UnsupportedVcsChecksum,
        .tag => {
            const refspec = try std.fmt.allocPrint(
                self.allocator,
                "+refs/tags/{s}:refs/tags/{s}",
                .{ reference.value, reference.value },
            );
            defer self.allocator.free(refspec);
            try runSourceCommand(self, operation, &.{ "-C", repository_path, "fetch", "--depth", "1", "--no-tags", "--", source.location, refspec });
            const peel = try std.fmt.allocPrint(self.allocator, "refs/tags/{s}^{{commit}}", .{reference.value});
            defer self.allocator.free(peel);
            const peeled = try runGitCapture(self, operation, &.{ "-C", repository_path, "rev-parse", "--verify", peel });
            defer self.allocator.free(peeled.stdout);
            if (peeled.exit_code != 0) return error.SourceVcsFailed;
            const commit = std.mem.trim(u8, peeled.stdout, " \t\r\n");
            try runSourceCommand(self, operation, &.{ "-C", repository_path, "update-ref", "--no-deref", "HEAD", commit });
        },
        .commit => {
            // Store the pin under refs/heads/* so materializeGitSource's clone
            // includes it as a remote-tracking ref.
            const refspec = try std.fmt.allocPrint(self.allocator, "+{s}:refs/heads/shelly-pin", .{reference.value});
            defer self.allocator.free(refspec);
            try runSourceCommand(self, operation, &.{ "-C", repository_path, "fetch", "--depth", "1", "--no-tags", "--", source.location, refspec });
            try runSourceCommand(self, operation, &.{ "-C", repository_path, "symbolic-ref", "HEAD", "refs/heads/shelly-pin" });
        },
    }
}

fn replaceGitCacheEntry(
    self: *PackageBuilder,
    operation: *op_context.Operation,
    source: source_spec.ParsedSource,
    cache_path: []const u8,
    shallow: bool,
) !void {
    var lock = try lockGitCacheEntry(self, operation, cache_path);
    defer lock.deinit(self);
    try replaceGitCacheEntryLocked(self, operation, source, cache_path, shallow);
}

/// The caller holds the entry lock. Waiters re-check lock identity after the
/// swap and re-lock the new entry; a concurrent creator that wins the rename
/// race keeps its complete entry.
fn replaceGitCacheEntryLocked(
    self: *PackageBuilder,
    operation: *op_context.Operation,
    source: source_spec.ParsedSource,
    cache_path: []const u8,
    shallow: bool,
) !void {
    const temporary_path = try randomCacheSiblingPath(self, cache_path);
    defer self.allocator.free(temporary_path);
    errdefer std.Io.Dir.cwd().deleteTree(self.io, temporary_path) catch {};
    try std.Io.Dir.cwd().createDirPath(self.io, temporary_path);
    if (shallow) {
        buildShallowGitEntry(self, operation, source, temporary_path) catch |err| {
            if (err == error.Cancelled) return err;
            std.Io.Dir.cwd().deleteTree(self.io, temporary_path) catch {};
            try std.Io.Dir.cwd().createDirPath(self.io, temporary_path);
            try buildFullGitMirror(self, operation, source, temporary_path);
        };
    } else {
        try buildFullGitMirror(self, operation, source, temporary_path);
    }
    std.Io.Dir.cwd().deleteTree(self.io, cache_path) catch |err| {
        if (err != error.FileNotFound) return err;
    };
    std.Io.Dir.cwd().renamePreserve(temporary_path, std.Io.Dir.cwd(), cache_path, self.io) catch |err| switch (err) {
        error.PathAlreadyExists => std.Io.Dir.cwd().deleteTree(self.io, temporary_path) catch {},
        else => return err,
    };
}

test "history gate ignores metadata arrays and finds git invocations" {
    const full = [_][]const u8{
        "depends=('git' 'curl')\n",
        "makedepends=('git')\n",
        "depends=(\n    'curl'\n    'git'\n)\n",
        "package_x() {\n  depends=(\n    'git'\n  )\n}\n",
        "source=('repo::git+https://example.invalid/demo.git#tag=v1')\n",
        "sha256sums_x86_64=('SKIP')\nurl='https://github.com/example/demo'\n",
        "_srcdir=demo-git\n",
        "# git clone https://example.invalid/demo.git\n",
        "  sed -i 's/x/y/' file  # see https://gitlab.example/merge_requests/4\n",
        "echo done # not git status\n",
        "prepare() {\n  # only gitlab links in comments\n  patch -Np1 < fix.patch\n}\n",
    };
    for (full) |body| try std.testing.expect(!bodyMentionsGitOrSrcdest(body));
    const partial = [_][]const u8{
        "git describe --tags\n",
        "  git rev-list --count HEAD\n",
        "/usr/bin/git apply fix.patch\n",
        "local cmd=git\n$cmd describe\n",
        "depends=('git') && git status\n",
        "echo $SRCDEST\n",
        "cat " ++ "<<'EOF'\ngit log\nEOF\n",
        "depends=('git' 'curl')\n  git status\n",
        "sh -c \"git describe --tags\"\n",
        "echo '# git'\n",
    };
    for (partial) |body| try std.testing.expect(bodyMentionsGitOrSrcdest(body));
    // Generated preludes declare data arrays on one line; raw `name=(...)`
    // text is a normal body and still scans.
    try std.testing.expect(!preludeMentionsGitOrSrcdest("declare -a depends=('git' 'curl')\n"));
    try std.testing.expect(!preludeMentionsGitOrSrcdest("declare -a source=('git+https://example.invalid/demo.git#tag=v1')\n"));
    try std.testing.expect(preludeMentionsGitOrSrcdest("declare -- cmd='git'\n"));
    try std.testing.expect(preludeMentionsGitOrSrcdest("declare -- srcdest=$SRCDEST\n"));
}

fn randomCacheSiblingPath(self: *PackageBuilder, cache_path: []const u8) ![]u8 {
    var random_suffix: [8]u8 = undefined;
    self.io.random(&random_suffix);
    const suffix = std.fmt.bytesToHex(random_suffix, .lower);
    return std.fmt.allocPrint(self.allocator, "{s}.shelly-{s}.tmp", .{ cache_path, suffix });
}

const GitCacheLock = struct {
    file: std.Io.File,

    fn deinit(lock: *GitCacheLock, self: *PackageBuilder) void {
        lock.file.unlock(self.io);
        lock.file.close(self.io);
    }
};

/// Exclusive advisory lock on <cache_path>/.shelly-lock (a sibling
/// <cache_path>.lock could collide with a source named <name>.lock). The
/// tryLock retry loop stays cancellable, and the identity re-check follows
/// entry replacements made while waiting.
fn lockGitCacheEntry(
    self: *PackageBuilder,
    operation: *op_context.Operation,
    cache_path: []const u8,
) !GitCacheLock {
    const lock_path = try std.fs.path.join(self.allocator, &.{ cache_path, git_cache_lock_name });
    defer self.allocator.free(lock_path);
    while (true) {
        try operation.checkCancelled();
        const file = std.Io.Dir.cwd().createFile(self.io, lock_path, .{ .read = true, .truncate = false }) catch |err| switch (err) {
            error.FileNotFound => return error.InvalidSourceCacheEntry,
            else => return err,
        };
        while (true) {
            operation.checkCancelled() catch |err| {
                file.close(self.io);
                return err;
            };
            const acquired = file.tryLock(self.io, .exclusive) catch |err| {
                file.close(self.io);
                return err;
            };
            if (acquired) break;
            self.io.sleep(.fromMilliseconds(50), .awake) catch |err| {
                file.close(self.io);
                return err;
            };
        }
        const current = std.Io.Dir.cwd().statFile(self.io, lock_path, .{ .follow_symlinks = false }) catch null;
        const file_stat = file.stat(self.io) catch {
            file.unlock(self.io);
            file.close(self.io);
            return error.InvalidSourceCacheEntry;
        };
        if (current == null or current.?.inode != file_stat.inode) {
            file.unlock(self.io);
            file.close(self.io);
            continue;
        }
        return .{ .file = file };
    }
}

fn gitCacheOriginUrl(
    self: *PackageBuilder,
    operation: *op_context.Operation,
    cache_path: []const u8,
) !?[]u8 {
    const result = try runGitCapture(self, operation, &.{ "-C", cache_path, "config", "--get", "remote.origin.url" });
    defer self.allocator.free(result.stdout);
    if (result.exit_code != 0) return null;
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try self.allocator.dupe(u8, trimmed);
}

fn gitCacheIsShallow(
    self: *PackageBuilder,
    operation: *op_context.Operation,
    cache_path: []const u8,
) !bool {
    // A bare cache keeps its shallow boundary file at the repository root.
    const result = try runGitCapture(self, operation, &.{ "-C", cache_path, "rev-parse", "--is-shallow-repository" });
    defer self.allocator.free(result.stdout);
    if (result.exit_code != 0) return error.InvalidSourceCacheEntry;
    return std.mem.eql(u8, std.mem.trim(u8, result.stdout, " \t\r\n"), "true");
}

fn gitShallowBoundaryExceeded(self: *PackageBuilder, cache_path: []const u8) !bool {
    const shallow_path = try std.fs.path.join(self.allocator, &.{ cache_path, "shallow" });
    defer self.allocator.free(shallow_path);
    const contents = std.Io.Dir.cwd().readFileAlloc(self.io, shallow_path, self.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.StreamTooLong => return true,
        else => return err,
    };
    defer self.allocator.free(contents);
    var lines: usize = 0;
    for (contents) |character| {
        if (character == '\n') lines += 1;
    }
    return lines > git_shallow_boundary_limit;
}

const GitCapture = struct {
    allocator: std.mem.Allocator,
    stdout: std.ArrayList(u8) = .empty,
    failed: bool = false,

    fn onLine(data: ?*anyopaque, stream: process_runner.StreamKind, line: []const u8) void {
        const capture: *GitCapture = @ptrCast(@alignCast(data.?));
        if (stream != .stdout) return;
        capture.stdout.appendSlice(capture.allocator, line) catch {
            capture.failed = true;
        };
        capture.stdout.append(capture.allocator, '\n') catch {
            capture.failed = true;
        };
    }
};

/// Like runSourceCommand but captures stdout for state queries instead of
/// forwarding it to the build log.
fn runGitCapture(
    self: *PackageBuilder,
    operation: *op_context.Operation,
    args: []const []const u8,
) !struct { exit_code: u8, stdout: []u8 } {
    try operation.checkCancelled();
    var command: std.ArrayList([]const u8) = .empty;
    defer command.deinit(self.allocator);
    try command.append(self.allocator, "git");
    try command.appendSlice(self.allocator, args);
    var capture = GitCapture{ .allocator = self.allocator };
    defer capture.stdout.deinit(self.allocator);
    const effective_options = try metadata.effectivePackageOptions(
        self.allocator,
        self.shellybuild_config.package.options,
        self.package_builds[0].options orelse &.{},
    );
    defer metadata.freeOwnedStrings(self.allocator, effective_options);
    const exit_code = try process_runner.runStreamingWithBuildEnvironmentOperation(
        self.allocator,
        self.io,
        self.environ,
        steps.buildEnvironment(self, effective_options),
        command.items,
        self.options.source_destination,
        null,
        .{ .function = GitCapture.onLine, .data = &capture },
        operation,
    );
    if (self.active_log) |log| try log.ensureHealthy();
    if (capture.failed) return error.OutOfMemory;
    return .{ .exit_code = exit_code, .stdout = try capture.stdout.toOwnedSlice(self.allocator) };
}

fn materializeGitSource(
    self: *PackageBuilder,
    operation: *op_context.Operation,
    source: source_spec.ParsedSource,
    acquired_repository: []const u8,
    destination: []const u8,
) !void {
    try runSourceCommand(self, operation, &.{
        "clone",
        "--local",
        "--no-hardlinks",
        "--",
        acquired_repository,
        destination,
    });
    // Relative submodule URLs must resolve against upstream, not the
    // acquisition directory that is removed before PKGBUILD steps run.
    try runSourceCommand(self, operation, &.{
        "-C", destination, "remote", "set-url", "origin", source.location,
    });
    if (source.reference) |reference| switch (reference.kind) {
        .branch => try runSourceCommand(self, operation, &.{
            "-C",
            destination,
            "checkout",
            "--force",
            reference.value,
        }),
        .tag, .commit => try runSourceCommand(self, operation, &.{
            "-C",
            destination,
            "checkout",
            "--detach",
            reference.value,
        }),
    };
}

fn runSourceCommand(
    self: *PackageBuilder,
    operation: *op_context.Operation,
    args: []const []const u8,
) !void {
    try operation.checkCancelled();
    var command: std.ArrayList([]const u8) = .empty;
    defer command.deinit(self.allocator);
    try command.append(self.allocator, "git");
    try command.appendSlice(self.allocator, args);
    var stream_context: steps.StepStreamContext = .{
        .operation = operation,
        .package_name = self.requested_names[0],
        .log = self.active_log,
    };
    const effective_options = try metadata.effectivePackageOptions(
        self.allocator,
        self.shellybuild_config.package.options,
        self.package_builds[0].options orelse &.{},
    );
    defer metadata.freeOwnedStrings(self.allocator, effective_options);
    const exit_code = try process_runner.runStreamingWithBuildEnvironmentOperation(
        self.allocator,
        self.io,
        self.environ,
        steps.buildEnvironment(self, effective_options),
        command.items,
        self.options.source_destination,
        null,
        .{ .function = steps.forwardStepLine, .data = &stream_context },
        operation,
    );
    if (self.active_log) |log| try log.ensureHealthy();
    if (exit_code != 0) return error.SourceVcsFailed;
}

fn verifySourceChecksums(
    self: *PackageBuilder,
    package_build: *const PackageBuild,
    index: usize,
    path: []const u8,
) !void {
    for (checksums.checksumSets(package_build)) |set| {
        const sums = set.sums orelse continue;
        if (sums.len == 0) continue;
        switch (set.algorithm) {
            .sha512 => try checksums.verifyFileHash(std.crypto.hash.sha2.Sha512, self.io, path, sums[index]),
            .sha384 => try checksums.verifyFileHash(std.crypto.hash.sha2.Sha384, self.io, path, sums[index]),
            .sha256 => try checksums.verifyFileHash(std.crypto.hash.sha2.Sha256, self.io, path, sums[index]),
            .sha224 => try checksums.verifyFileHash(std.crypto.hash.sha2.Sha224, self.io, path, sums[index]),
            .sha1 => try checksums.verifyFileHash(std.crypto.hash.Sha1, self.io, path, sums[index]),
            .md5 => try checksums.verifyFileHash(std.crypto.hash.Md5, self.io, path, sums[index]),
            .b2 => try checksums.verifyFileHash(std.crypto.hash.blake2.Blake2b512, self.io, path, sums[index]),
        }
    }
}

fn verifyPreparedSourceSignatures(
    self: *PackageBuilder,
    operation: *op_context.Operation,
    package_build: *const PackageBuild,
    prepared: []const source_spec.PreparedSource,
    staging: []const u8,
) !void {
    const valid_pgp_keys = package_build.valid_pgp_keys orelse &.{};
    const verifier = source_pgp_verifier.Verifier{
        .allocator = self.allocator,
        .io = self.io,
        .environ = self.environ,
        .gnupg_home = self.options.source_pgp_gnupg_home,
    };

    for (prepared) |*signature| {
        try operation.checkCancelled();
        if (!source_spec.isDetachedSignatureName(signature.source.name)) continue;
        const pairing = try source_spec.findDetachedPayload(prepared, signature);
        var temporary_payload: ?[]u8 = null;
        defer if (temporary_payload) |path| {
            std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
            self.allocator.free(path);
        };
        const payload_path = if (pairing.compression) |compression| blk: {
            const path = try std.fmt.allocPrint(
                self.allocator,
                "{s}/.shelly-pgp-payload-{d}",
                .{ staging, signature.index },
            );
            errdefer self.allocator.free(path);
            try decompressSignedPayload(self, operation, pairing.source.destination, compression, path);
            temporary_payload = path;
            break :blk path;
        } else pairing.source.destination;

        const message = try std.fmt.allocPrint(
            self.allocator,
            "Verifying source signature: {s}",
            .{pairing.source.source.name},
        );
        defer self.allocator.free(message);
        raiseSourceMessage(self, package_build, message);
        var verification = try verifier.verifyDetached(
            signature.destination,
            payload_path,
            valid_pgp_keys,
        );
        defer verification.deinit(self.allocator);
        if (verification.warning != .none) raisePgpWarning(
            self,
            package_build,
            pairing.source.source.name,
            verification.warning,
        );
    }

    for (prepared) |*source| {
        try operation.checkCancelled();
        if (source.source.kind != .git or !source.source.signed) continue;
        const object: source_pgp_verifier.GitObject = if (source.source.reference) |reference|
            if (reference.kind == .tag) .tag else .commit
        else
            .commit;
        const reference = if (source.source.reference) |value| value.value else "HEAD";
        const message = try std.fmt.allocPrint(
            self.allocator,
            "Verifying Git signature: {s}",
            .{source.source.name},
        );
        defer self.allocator.free(message);
        raiseSourceMessage(self, package_build, message);
        var verification = try verifier.verifyGit(
            source.destination,
            object,
            reference,
            valid_pgp_keys,
        );
        defer verification.deinit(self.allocator);
        if (verification.warning != .none) raisePgpWarning(
            self,
            package_build,
            source.source.name,
            verification.warning,
        );
    }
}

fn raisePgpWarning(
    self: *PackageBuilder,
    package_build: *const PackageBuild,
    source_name: []const u8,
    warning: source_pgp_verifier.Warning,
) void {
    var buffer: [512]u8 = undefined;
    const message = std.fmt.bufPrint(
        &buffer,
        "PGP warning for {s}: {s}",
        .{ source_name, @tagName(warning) },
    ) catch return;
    raiseSourceMessage(self, package_build, message);
}

fn decompressSignedPayload(
    self: *PackageBuilder,
    operation: *op_context.Operation,
    source_path: []const u8,
    compression: source_spec.SignatureCompression,
    destination: []const u8,
) !void {
    const argv: []const []const u8 = switch (compression) {
        .gz, .compress => &.{ "/usr/bin/gzip", "-cdf", "--", source_path },
        .bz2 => &.{ "/usr/bin/bzip2", "-cdf", "--", source_path },
        .xz => &.{ "/usr/bin/xz", "-cdf", "--", source_path },
        .zst => &.{ "/usr/bin/zstd", "-d", "-q", "-c", "--", source_path },
        .lzo => &.{ "/usr/bin/lzop", "-d", "-q", "-c", "--", source_path },
        .lrz => &.{ "/usr/bin/lrzip", "-q", "-d", "-o", "-", source_path },
    };
    var environment = try self.environ.createMap(self.allocator);
    defer environment.deinit();
    var child = try std.process.spawn(self.io, .{
        .argv = argv,
        .environ_map = &environment,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(self.io);
    var output = try std.Io.Dir.cwd().createFile(self.io, destination, .{
        .truncate = true,
        .permissions = .fromMode(0o600),
    });
    defer output.close(self.io);
    var reader_buffer: [64 * 1024]u8 = undefined;
    var chunk: [64 * 1024]u8 = undefined;
    var output_buffer: [64 * 1024]u8 = undefined;
    var reader = child.stdout.?.reader(self.io, &reader_buffer);
    var writer = output.writer(self.io, &output_buffer);
    var total: u64 = 0;
    while (true) {
        try operation.checkCancelled();
        const amount = try reader.interface.readSliceShort(&chunk);
        if (amount == 0) break;
        total += amount;
        if (total > 4 * 1024 * 1024 * 1024) return error.SourcePayloadTooLarge;
        try writer.interface.writeAll(chunk[0..amount]);
    }
    try writer.interface.flush();
    try output.sync(self.io);
    const term = try child.wait(self.io);
    if (term != .exited or term.exited != 0) return error.SourceDecompressionFailed;
}

fn decompressStandaloneSource(
    self: *PackageBuilder,
    operation: *op_context.Operation,
    source: *const source_spec.PreparedSource,
    extracted_files: *const ExtractedSourceFiles,
    destination_root: []const u8,
) !void {
    const compression = (try archive.StandaloneCompression.fromFile(self.io, source.destination)) orelse return;
    const output_name = compression.outputName(source.source.name) orelse return;
    const relative = try archive.normalizeEntryPath(self.allocator, output_name);
    defer self.allocator.free(relative);
    try extracted_files.checkReservedPath(relative, .regular_file, null);
    const destination = try std.fs.path.join(self.allocator, &.{ destination_root, relative });
    defer self.allocator.free(destination);
    try ensureSafeArchivePath(self, destination_root, relative, false);
    try rejectExistingDestination(self.io, destination);

    decompressStandalonePayload(self, operation, source.destination, destination, compression) catch |err| {
        if (err == error.SourceDecompressionFailed or err == error.SourcePayloadTooLarge) {
            const reason: []const u8 = if (err == error.SourcePayloadTooLarge)
                "Could not extract the source because its decompressed size exceeds the 4 GiB limit. Check that the selected source archive is correct."
            else
                "The compressed file is damaged or incomplete. Download it again and retry the build.";
            const message = try std.fmt.allocPrint(self.allocator, "Could not decompress source \"{s}\". {s}", .{ source.source.name, reason });
            defer self.allocator.free(message);
            operation.reportError(err, message, "sources", null, false);
        }
        return err;
    };
}

fn decompressStandalonePayload(
    self: *PackageBuilder,
    operation: *op_context.Operation,
    source_path: []const u8,
    destination: []const u8,
    compression: archive.StandaloneCompression,
) !void {
    try operation.checkCancelled();
    var reader = try archive.CompressedReader.init(self.allocator, self.io, source_path, compression);
    defer reader.deinit();
    var output = try std.Io.Dir.cwd().createFile(self.io, destination, .{ .exclusive = true });
    defer output.close(self.io);
    errdefer std.Io.Dir.cwd().deleteFile(self.io, destination) catch {};
    var writer = output.writer(self.io, &.{});
    try reader.copyTo(&writer.interface, 4 * 1024 * 1024 * 1024, operation);
}

fn extractSourceArchiveIfRecognized(
    self: *PackageBuilder,
    operation: *op_context.Operation,
    archive_path: []const u8,
    destination_root: []const u8,
    source_index: usize,
    extracted_files: *ExtractedSourceFiles,
) !bool {
    var returned_error: ?anyerror = null;
    const DirectoryTimestamp = struct {
        path: []u8,
        mtime: std.Io.Timestamp,
    };

    var reader = (try trackReturnError(archive.Reader.initAllIfRecognized(self.allocator, archive_path), &returned_error)) orelse return trackReturnError(false, &returned_error);
    defer reader.deinit();
    const first_entry = switch (try trackReturnError(reader.probe(), &returned_error)) {
        .not_archive => return trackReturnError(false, &returned_error),
        .archive => |entry| entry,
    };
    if (reader.isPlainSourceFile()) return trackReturnError(false, &returned_error);
    var directory_timestamps: std.ArrayList(DirectoryTimestamp) = .empty;
    var members: SourceArchiveMembers = .{};
    defer members.deinit(self.allocator);
    defer {
        for (directory_timestamps.items) |timestamp| self.allocator.free(timestamp.path);
        directory_timestamps.deinit(self.allocator);
    }
    var buffer: [64 * 1024]u8 = undefined;
    var entry_count: usize = 0;
    var total_size: u64 = 0;
    var next_entry = first_entry;
    while (next_entry) |entry| {
        try trackReturnError(operation.checkCancelled(), &returned_error);
        entry_block: {
            errdefer {
                const err = returned_error.?;
                reportArchiveEntryFailure(self, operation, archive_path, entry.path, entry.link_target, err);
            }
            entry_count += 1;
            if (entry_count > 1_000_000 or entry.size > 4 * 1024 * 1024 * 1024)
                return trackReturnError(error.SourceArchiveTooLarge, &returned_error);
            if (isArchiveRootDirectoryEntry(entry.kind, entry.path)) {
                try trackReturnError(reader.skip(), &returned_error);
                break :entry_block;
            }
            const relative = try trackReturnError(archive.normalizePosixEntryPath(self.allocator, entry.path), &returned_error);
            defer self.allocator.free(relative);
            try trackReturnError(extracted_files.checkReservedPath(relative, entry.kind, source_index), &returned_error);
            const destination = try trackReturnError(std.fs.path.join(self.allocator, &.{ destination_root, relative }), &returned_error);
            defer self.allocator.free(destination);
            try trackReturnError(members.add(self.allocator, relative, entry.kind, entry.link_target), &returned_error);
            switch (entry.kind) {
                .directory => {
                    try trackReturnError(ensureSafeArchivePath(self, destination_root, relative, true), &returned_error);
                    if (entry.mtime) |mtime| {
                        const owned_path = try trackReturnError(self.allocator.dupe(u8, destination), &returned_error);
                        errdefer self.allocator.free(owned_path);
                        try trackReturnError(directory_timestamps.append(self.allocator, .{
                            .path = owned_path,
                            .mtime = mtime,
                        }), &returned_error);
                    }
                },
                .regular_file => {
                    try trackReturnError(ensureSafeArchivePath(self, destination_root, relative, false), &returned_error);
                    if (extracted_files.regular_files.contains(relative)) {
                        const stat = try trackReturnError(std.Io.Dir.cwd().statFile(self.io, destination, .{ .follow_symlinks = false }), &returned_error);
                        if (stat.kind != .file) return trackReturnError(error.UnsafeSourceArchivePath, &returned_error);
                        // Later archive entries replace earlier regular files,
                        // including read-only originals. Recreate the inode so
                        // existing hard links retain their original contents.
                        try trackReturnError(std.Io.Dir.cwd().deleteFile(self.io, destination), &returned_error);
                    } else {
                        try trackReturnError(rejectExistingDestination(self.io, destination), &returned_error);
                    }
                    var output = try trackReturnError(std.Io.Dir.cwd().createFile(self.io, destination, .{
                        .exclusive = true,
                        .permissions = std.Io.File.Permissions.fromMode(entry.permissions & 0o777),
                    }), &returned_error);
                    defer output.close(self.io);
                    var writer = output.writer(self.io, &.{});
                    var entry_size: u64 = 0;
                    while (true) {
                        const amount = try trackReturnError(reader.read(&buffer), &returned_error);
                        if (amount == 0) break;
                        entry_size += amount;
                        total_size += amount;
                        if (entry_size > 4 * 1024 * 1024 * 1024 or total_size > 16 * 1024 * 1024 * 1024)
                            return trackReturnError(error.SourceArchiveTooLarge, &returned_error);
                        try trackReturnError(writer.interface.writeAll(buffer[0..amount]), &returned_error);
                    }
                    try trackReturnError(writer.interface.flush(), &returned_error);
                    if (entry.mtime) |mtime| try trackReturnError(output.setTimestamps(self.io, .{
                        .modify_timestamp = .{ .new = mtime },
                    }), &returned_error);
                    try trackReturnError(extracted_files.recordRegularFile(self.allocator, relative, source_index), &returned_error);
                },
                .symbolic_link => {
                    const target = entry.link_target orelse return trackReturnError(error.UnsafeSourceArchiveLink, &returned_error);
                    const safe_target = try trackReturnError(source_spec.archiveLinkTarget(self.allocator, relative, target), &returned_error);
                    defer self.allocator.free(safe_target);
                    try trackReturnError(ensureSafeArchivePath(self, destination_root, relative, false), &returned_error);
                    try trackReturnError(rejectExistingDestination(self.io, destination), &returned_error);
                    try trackReturnError(std.Io.Dir.cwd().symLink(self.io, safe_target, destination, .{}), &returned_error);
                    if (entry.mtime) |mtime| try trackReturnError(std.Io.Dir.cwd().setTimestamps(
                        self.io,
                        destination,
                        .{
                            .follow_symlinks = false,
                            .modify_timestamp = .{ .new = mtime },
                        },
                    ), &returned_error);
                },
                .hard_link => {
                    // Reserve the destination now; resolve targets only after all
                    // archive members have been recorded (including forward links).
                    try trackReturnError(ensureSafeArchivePath(self, destination_root, relative, false), &returned_error);
                    try trackReturnError(rejectExistingDestination(self.io, destination), &returned_error);
                    try trackReturnError(reader.skip(), &returned_error);
                },
                .other => return trackReturnError(error.UnsupportedSourceArchiveEntry, &returned_error),
            }
        }
        next_entry = try trackReturnError(reader.next(), &returned_error);
    }
    try trackReturnError(members.resolve(self, operation, archive_path, destination_root), &returned_error);

    // Creating children changes directory mtimes. Restore recorded directory
    // timestamps only after the complete tree exists. Archive order is retained
    // so a repeated directory entry keeps the metadata from its last occurrence.
    for (directory_timestamps.items) |timestamp| {
        try trackReturnError(std.Io.Dir.cwd().setTimestamps(self.io, timestamp.path, .{
            .follow_symlinks = false,
            .modify_timestamp = .{ .new = timestamp.mtime },
        }), &returned_error);
    }
    return trackReturnError(true, &returned_error);
}

/// Only completed regular archive entries are eligible for replacement. Raw
/// sources, standalone outputs, Git files, and hard-link destinations never
/// enter this registry, even when stat() describes them as regular files.
const ExtractedSourceFiles = struct {
    sources: []const source_spec.PreparedSource,
    regular_files: std.StringHashMapUnmanaged(usize) = .empty,

    fn deinit(self: *ExtractedSourceFiles, allocator: std.mem.Allocator) void {
        var keys = self.regular_files.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        self.regular_files.deinit(allocator);
    }

    fn recordRegularFile(self: *ExtractedSourceFiles, allocator: std.mem.Allocator, path: []const u8, source_index: usize) !void {
        if (self.regular_files.getPtr(path)) |origin| {
            origin.* = source_index;
            return;
        }
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        try self.regular_files.putNoClobber(allocator, owned_path, source_index);
    }

    fn checkReservedPath(self: *const ExtractedSourceFiles, path: []const u8, kind: archive.EntryKind, source_index: ?usize) !void {
        // Source aliases are single path components. Reserve their entire
        // subtree before processing any archive, independent of source order.
        for (self.sources) |source| {
            const name = source.source.name;
            const exact = std.mem.eql(u8, path, name);
            const descendant = path.len > name.len and std.mem.startsWith(u8, path, name) and path[name.len] == '/';
            if (!exact and !descendant) continue;
            // An extensionless archive may own its matching root directory;
            // its raw payload is then kept only in the acquisition staging tree.
            if (source_index != null and source.index == source_index.? and
                source.source.kind != .git and (descendant or kind == .directory)) continue;
            return error.UnsafeSourceArchivePath;
        }
    }
};

const SourceArchiveMembers = struct {
    const Member = struct {
        kind: archive.EntryKind,
        target: ?[]u8,
        state: enum { pending, visiting, resolved } = .pending,
    };

    entries: std.StringArrayHashMapUnmanaged(Member) = .empty,

    fn deinit(self: *SourceArchiveMembers, allocator: std.mem.Allocator) void {
        for (self.entries.keys(), self.entries.values()) |path, member| {
            allocator.free(path);
            if (member.target) |target| allocator.free(target);
        }
        self.entries.deinit(allocator);
    }

    fn add(self: *SourceArchiveMembers, allocator: std.mem.Allocator, path: []const u8, kind: archive.EntryKind, link_target: ?[]const u8) !void {
        if (self.entries.getIndex(path)) |index| {
            const previous_kind = self.entries.values()[index].kind;
            if (kind == .directory and previous_kind == .directory) return;
            if (kind == .regular_file and previous_kind == .regular_file) return;
            return error.UnsafeSourceArchivePath;
        }
        var parent = std.fs.path.dirname(path);
        while (parent) |directory| : (parent = std.fs.path.dirname(directory)) {
            if (self.entries.getIndex(directory)) |index| {
                if (self.entries.values()[index].kind != .directory) return error.UnsafeSourceArchivePath;
            }
        }
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        // Unlike symlink targets, hard-link targets are archive-root-relative.
        const target = if (kind == .hard_link)
            try archive.normalizePosixEntryPath(allocator, link_target orelse return error.UnsafeSourceArchiveLink)
        else
            null;
        errdefer if (target) |value| allocator.free(value);
        try self.entries.putNoClobber(allocator, owned_path, .{ .kind = kind, .target = target });
    }

    fn resolve(self: *SourceArchiveMembers, builder: *PackageBuilder, operation: *op_context.Operation, archive_path: []const u8, root: []const u8) !void {
        var returned_error: ?anyerror = null;
        // Iterative DFS visits each link once. No recursive stack growth or
        // repeated full scans for long chains supplied by an untrusted archive.
        var chain: std.ArrayList(usize) = .empty;
        defer chain.deinit(builder.allocator);
        const paths = self.entries.keys();
        const members = self.entries.values();
        for (members, 0..) |member, start| {
            try trackReturnError(operation.checkCancelled(), &returned_error);
            if (member.kind != .hard_link or member.state == .resolved) continue;
            var index = start;
            errdefer {
                const err = returned_error.?;
                reportArchiveEntryFailure(builder, operation, archive_path, paths[index], members[index].target, err);
            }
            while (members[index].kind == .hard_link and members[index].state != .resolved) {
                try trackReturnError(operation.checkCancelled(), &returned_error);
                if (members[index].state == .visiting) return trackReturnError(error.CyclicSourceArchiveHardLink, &returned_error);
                members[index].state = .visiting;
                try trackReturnError(chain.append(builder.allocator, index), &returned_error);
                const target_index = self.entries.getIndex(members[index].target.?) orelse
                    return trackReturnError(error.MissingSourceArchiveHardLinkTarget, &returned_error);
                switch (members[target_index].kind) {
                    .regular_file, .hard_link => index = target_index,
                    else => return trackReturnError(error.UnsafeSourceArchiveLink, &returned_error),
                }
            }
            while (chain.pop()) |link_index| {
                index = link_index;
                try trackReturnError(operation.checkCancelled(), &returned_error);
                const target = members[index].target.?;
                // Inspect every component without following symlinks, even
                // though the target is also required to belong to this archive.
                try trackReturnError(ensureSafeArchivePath(builder, root, target, false), &returned_error);
                try trackReturnError(ensureSafeArchivePath(builder, root, paths[index], false), &returned_error);
                const source = try trackReturnError(std.fs.path.join(builder.allocator, &.{ root, target }), &returned_error);
                defer builder.allocator.free(source);
                const destination = try trackReturnError(std.fs.path.join(builder.allocator, &.{ root, paths[index] }), &returned_error);
                defer builder.allocator.free(destination);
                const stat = try trackReturnError(std.Io.Dir.cwd().statFile(builder.io, source, .{ .follow_symlinks = false }), &returned_error);
                if (stat.kind != .file) return trackReturnError(error.UnsafeSourceArchiveLink, &returned_error);
                try trackReturnError(rejectExistingDestination(builder.io, destination), &returned_error);
                try trackReturnError(std.Io.Dir.hardLink(.cwd(), source, .cwd(), destination, builder.io, .{ .follow_symlinks = false }), &returned_error);
                // Mode and timestamps belong to the shared inode. Applying
                // the link header's metadata would change the original file.
                members[index].state = .resolved;
            }
        }
    }
};

fn reportArchiveEntryFailure(self: *PackageBuilder, operation: *op_context.Operation, archive_path: []const u8, path: []const u8, target: ?[]const u8, err: anyerror) void {
    if (err == error.Cancelled) return;
    const safe = @import("diagnostics").safe;
    const message = if (target) |value|
        std.fmt.allocPrint(self.allocator, "Could not extract source archive {f}, entry {f}, link target {f}. Technical details: {s}", .{ safe(std.fs.path.basename(archive_path)), safe(path), safe(value), @errorName(err) }) catch return
    else
        std.fmt.allocPrint(self.allocator, "Could not extract source archive {f}, entry {f}. Technical details: {s}", .{ safe(std.fs.path.basename(archive_path)), safe(path), @errorName(err) }) catch return;
    defer self.allocator.free(message);
    operation.reportError(err, message, "sources", null, false);
}

fn pathExistsNoFollow(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

fn isArchiveRootDirectoryEntry(kind: archive.EntryKind, path: []const u8) bool {
    if (kind != .directory or path.len == 0 or std.fs.path.isAbsolute(path) or
        std.mem.indexOfScalar(u8, path, '\\') != null)
        return false;

    var saw_current_directory = false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0) continue;
        if (!std.mem.eql(u8, component, ".")) return false;
        saw_current_directory = true;
    }
    return saw_current_directory;
}

test "PackageBuilder skips only source archive root directory markers" {
    const root_markers = [_][]const u8{
        ".",
        "./",
        ".//",
        "././",
    };
    for (root_markers) |path| {
        try std.testing.expect(isArchiveRootDirectoryEntry(.directory, path));
        try std.testing.expect(!isArchiveRootDirectoryEntry(.regular_file, path));
        try std.testing.expect(!isArchiveRootDirectoryEntry(.symbolic_link, path));
        try std.testing.expect(!isArchiveRootDirectoryEntry(.hard_link, path));
        try std.testing.expect(!isArchiveRootDirectoryEntry(.other, path));
    }

    const invalid_root_markers = [_][]const u8{
        "",
        "/",
        "//.",
        "dir",
        "./dir",
        "../",
        "./../",
        "dir/..",
        "\\",
        ".\\",
    };
    for (invalid_root_markers) |path|
        try std.testing.expect(!isArchiveRootDirectoryEntry(.directory, path));
}

fn ensureSafeArchivePath(
    self: *PackageBuilder,
    destination_root: []const u8,
    relative: []const u8,
    include_last: bool,
) !void {
    var current = try self.allocator.dupe(u8, destination_root);
    defer self.allocator.free(current);
    var components = std.mem.splitScalar(u8, relative, '/');
    while (components.next()) |component| {
        if (!include_last and components.peek() == null) break;
        const next = try std.fs.path.join(self.allocator, &.{ current, component });
        self.allocator.free(current);
        current = next;
        const stat = std.Io.Dir.cwd().statFile(self.io, current, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => {
                try std.Io.Dir.cwd().createDir(self.io, current, .default_dir);
                continue;
            },
            else => return err,
        };
        if (stat.kind != .directory) return error.UnsafeSourceArchivePath;
    }
}

fn raiseSourceMessage(self: *PackageBuilder, package_build: *const PackageBuild, message: []const u8) void {
    const operation = self.active_operation orelse return;
    operation.status(.information, message, "aur_build_output", @backingInt(events.EventType.aur_build_output));
    operation.progress(.{
        .stage = "sources",
        .message = package_build.pkg_name orelse message,
    });
}

fn rejectExistingDestination(io: std.Io, path: []const u8) !void {
    _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.UnsafeSourceArchivePath;
}

/// Acquisition only: callers choose whether to verify, hash, or extract.
pub fn acquireSource(self: *PackageBuilder, operation: *op_context.Operation, source: source_spec.ParsedSource, destination: []const u8) !void {
    try operation.checkCancelled();
    switch (source.kind) {
        .local => try copyLocalSource(self, source.location, destination),
        .http => try acquireHttpSource(self, operation, source, destination, false),
        .git => try acquireGitSource(self, operation, source, destination),
    }
}
