//! Source acquisition and integrity pipeline: local copy, HTTP download,
//! git cloning, checksum and PGP signature verification, and safe archive
//! extraction into the staging tree.

const std = @import("std");
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
        switch (source.kind) {
            .local => try copyLocalSource(self, source.location, destination),
            .http => try acquireHttpSource(self, operation, source, destination, false),
            .git => try cloneGitSource(self, operation, source, destination),
        }
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
    // existing direct local sources are already visible in $startdir.
    if (self.options.run_verify and !self.options.skip_source_pgp_verification) {
        const execution = package_build.execution orelse return error.MissingExecutionSteps;
        if (execution.verify_step) |step| {
            const links = try exposeSourcesForVerify(self, prepared);
            defer {
                for (links) |path| {
                    std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
                    self.allocator.free(path);
                }
                self.allocator.free(links);
            }
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
        }
    }

    std.Io.Dir.cwd().createDirPath(self.io, extraction_staging) catch {
        steps.reportUnwritableBuildDirectory(self, extraction_staging);
        return error.BuildDirectoryNotWritable;
    };
    for (prepared) |*source| {
        try operation.checkCancelled();
        const materialized = try std.fs.path.join(
            self.allocator,
            &.{ extraction_staging, source.source.name },
        );
        defer self.allocator.free(materialized);
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
            _ = std.Io.Dir.cwd().statFile(self.io, materialized, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => {
                    const extracted = try extractSourceArchiveIfRecognized(
                        self,
                        operation,
                        source.destination,
                        extraction_staging,
                    );
                    if (!extracted) try decompressStandaloneSource(self, operation, source, prepared, extraction_staging);
                    if (!extracted or !pathExistsNoFollow(self.io, materialized))
                        try std.Io.Dir.copyFile(.cwd(), source.destination, .cwd(), materialized, self.io, .{});
                    continue;
                },
                else => return err,
            };
            return error.UnsafeSourceArchivePath;
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

    var random_suffix: [8]u8 = undefined;
    self.io.random(&random_suffix);
    const suffix = std.fmt.bytesToHex(random_suffix, .lower);
    const archive_path = try std.fmt.allocPrint(
        self.allocator,
        "{s}.shelly-archive-{s}.tmp",
        .{ prepared.destination, suffix },
    );
    defer self.allocator.free(archive_path);
    defer std.Io.Dir.cwd().deleteFile(self.io, archive_path) catch {};

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
    try verifySourceChecksums(self, package_build, prepared.index, archive_path);
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

fn exposeSourcesForVerify(self: *PackageBuilder, prepared: []const source_spec.PreparedSource) ![][]u8 {
    var links: std.ArrayList([]u8) = .empty;
    errdefer {
        for (links.items) |path| {
            std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
            self.allocator.free(path);
        }
        links.deinit(self.allocator);
    }
    for (prepared) |*source| {
        const visible_path = try std.fs.path.join(
            self.allocator,
            &.{ self.options.start_directory, source.source.name },
        );
        errdefer self.allocator.free(visible_path);
        const exists = if (std.Io.Dir.cwd().statFile(
            self.io,
            visible_path,
            .{ .follow_symlinks = false },
        )) |_| true else |err| switch (err) {
            error.FileNotFound => false,
            else => return err,
        };
        if (exists) {
            // A direct local source already occupies its makepkg-visible
            // path. Never replace an unrelated user path for a renamed,
            // downloaded, or VCS source.
            if (source.source.kind == .local and
                std.mem.eql(u8, source.source.location, source.source.name))
            {
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
        try links.append(self.allocator, visible_path);
    }
    return links.toOwnedSlice(self.allocator);
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

fn cloneGitSource(
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
        try runSourceCommand(self, operation, &.{ "-C", cache_path, "remote", "set-url", "origin", source.location });
        try runSourceCommand(self, operation, &.{ "-C", cache_path, "remote", "update", "--prune" });
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
        errdefer std.Io.Dir.cwd().deleteTree(self.io, temporary_path) catch {};
        try runSourceCommand(self, operation, &.{ "clone", "--mirror", "--", source.location, temporary_path });
        std.Io.Dir.cwd().renamePreserve(temporary_path, std.Io.Dir.cwd(), cache_path, self.io) catch |err| switch (err) {
            error.PathAlreadyExists => std.Io.Dir.cwd().deleteTree(self.io, temporary_path) catch {},
            else => return err,
        };
    }
    try materializeGitSource(self, operation, source, cache_path, destination);
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
    var child = try std.process.spawn(self.io, .{
        .argv = argv,
        .environ_map = null,
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
    prepared: []const source_spec.PreparedSource,
    destination_root: []const u8,
) !void {
    const compression = (try archive.StandaloneCompression.fromFile(self.io, source.destination)) orelse return;
    const output_name = compression.outputName(source.source.name) orelse return;
    const relative = try archive.normalizeEntryPath(self.allocator, output_name);
    defer self.allocator.free(relative);
    // Reserve source aliases even when they occur later or are in noextract.
    for (prepared) |other| {
        if (std.mem.eql(u8, relative, other.source.name)) return error.UnsafeSourceArchivePath;
    }
    const destination = try std.fs.path.join(self.allocator, &.{ destination_root, relative });
    defer self.allocator.free(destination);
    try ensureSafeArchivePath(self, destination_root, relative, false);
    try rejectExistingDestination(self.io, destination);

    decompressStandalonePayload(self, operation, source.destination, destination, compression) catch |err| {
        if (err == error.SourceDecompressionFailed or err == error.SourcePayloadTooLarge) {
            const reason: []const u8 = if (err == error.SourcePayloadTooLarge)
                "The decompressed file exceeds the 4 GiB source size limit."
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
) !bool {
    const DirectoryTimestamp = struct {
        path: []u8,
        mtime: std.Io.Timestamp,
    };

    var reader = (try archive.Reader.initAllIfRecognized(self.allocator, archive_path)) orelse return false;
    defer reader.deinit();
    const first_entry = switch (try reader.probe()) {
        .not_archive => return false,
        .archive => |entry| entry,
    };
    if (reader.isCompressedPlainFile()) return false;
    var directory_timestamps: std.ArrayList(DirectoryTimestamp) = .empty;
    defer {
        for (directory_timestamps.items) |timestamp| self.allocator.free(timestamp.path);
        directory_timestamps.deinit(self.allocator);
    }
    var buffer: [64 * 1024]u8 = undefined;
    var entry_count: usize = 0;
    var total_size: u64 = 0;
    var next_entry = first_entry;
    while (next_entry) |entry| {
        try operation.checkCancelled();
        entry_count += 1;
        if (entry_count > 1_000_000 or entry.size > 4 * 1024 * 1024 * 1024)
            return error.SourceArchiveTooLarge;
        if (isArchiveRootDirectoryEntry(entry.kind, entry.path)) {
            try reader.skip();
            next_entry = try reader.next();
            continue;
        }
        const relative = try archive.normalizeEntryPath(self.allocator, entry.path);
        defer self.allocator.free(relative);
        const destination = try std.fs.path.join(self.allocator, &.{ destination_root, relative });
        defer self.allocator.free(destination);
        switch (entry.kind) {
            .directory => {
                try ensureSafeArchivePath(self, destination_root, relative, true);
                if (entry.mtime) |mtime| {
                    const owned_path = try self.allocator.dupe(u8, destination);
                    errdefer self.allocator.free(owned_path);
                    try directory_timestamps.append(self.allocator, .{
                        .path = owned_path,
                        .mtime = mtime,
                    });
                }
            },
            .regular_file => {
                try ensureSafeArchivePath(self, destination_root, relative, false);
                try rejectExistingDestination(self.io, destination);
                var output = try std.Io.Dir.cwd().createFile(self.io, destination, .{
                    .truncate = true,
                    .permissions = std.Io.File.Permissions.fromMode(entry.permissions & 0o777),
                });
                defer output.close(self.io);
                var writer = output.writer(self.io, &.{});
                var entry_size: u64 = 0;
                while (true) {
                    const amount = try reader.read(&buffer);
                    if (amount == 0) break;
                    entry_size += amount;
                    total_size += amount;
                    if (entry_size > 4 * 1024 * 1024 * 1024 or total_size > 16 * 1024 * 1024 * 1024)
                        return error.SourceArchiveTooLarge;
                    try writer.interface.writeAll(buffer[0..amount]);
                }
                try writer.interface.flush();
                if (entry.mtime) |mtime| try output.setTimestamps(self.io, .{
                    .modify_timestamp = .{ .new = mtime },
                });
            },
            .symbolic_link => {
                const target = entry.link_target orelse return error.UnsafeSourceArchiveLink;
                const safe_target = try source_spec.archiveLinkTarget(self.allocator, relative, target);
                defer self.allocator.free(safe_target);
                try ensureSafeArchivePath(self, destination_root, relative, false);
                try rejectExistingDestination(self.io, destination);
                try std.Io.Dir.cwd().symLink(self.io, safe_target, destination, .{});
                if (entry.mtime) |mtime| try std.Io.Dir.cwd().setTimestamps(
                    self.io,
                    destination,
                    .{
                        .follow_symlinks = false,
                        .modify_timestamp = .{ .new = mtime },
                    },
                );
            },
            .other => return error.UnsupportedSourceArchiveEntry,
        }
        next_entry = try reader.next();
    }

    // Creating children changes directory mtimes. Restore recorded directory
    // timestamps only after the complete tree exists. Archive order is retained
    // so a repeated directory entry keeps the metadata from its last occurrence.
    for (directory_timestamps.items) |timestamp| {
        try std.Io.Dir.cwd().setTimestamps(self.io, timestamp.path, .{
            .follow_symlinks = false,
            .modify_timestamp = .{ .new = timestamp.mtime },
        });
    }
    return true;
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
    operation.status(.information, message, "aur_build_output", @intFromEnum(events.EventType.aur_build_output));
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
