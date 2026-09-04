//! Tests for the AUR PackageBuilder (builder.zig).
//!
//! These tests describe the intended behavior of `PackageBuilder`. They are
//! wired into the module test block in src/root.zig and the aur-test filter
//! list in build.zig.
//!
//! `PackageBuilder.deinit` releases only the builder container. Its parsed
//! PKGBUILDs, requested names, and operation context are borrowed from the
//! caller and remain fixture-owned.

const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");
const package_options = @import("package_options");

const builder_mod = @import("builder.zig");
const PackageBuilder = builder_mod.PackageBuilder;
const process_runner = @import("../builder.zig");
const pkgbuild_mod = @import("../../pkgbuild/pkgbuild_parser.zig");
const install_script = @import("../../pkgbuild/install_script.zig");
const op_context = @import("operation_context");
const ShellyBuildConfiguration = @import("../shellybuild.zig").ShellyBuildConfiguration;
const archive = @import("archive");
const raw_alpm = @import("../../alpm/bindings.zig").libalpm.alpm;
const source_pgp_verifier = @import("../../shared/source_pgp_verifier.zig");
const source_spec = @import("source_spec.zig");

const source_pgp_fingerprint = "2E37DFCC9287C8A2F84B2519241A5B24548FAC70";
const source_pgp_public_key_base64 = "LS0tLS1CRUdJTiBQR1AgUFVCTElDIEtFWSBCTE9DSy0tLS0tCgptRE1FYW9OTXZ4WUpLd1lCQkFIYVJ3OEJBUWRBM0RFdFI5MXZLRU4zcXVsTmJBWVh2Z2EvRWl5K1VoQTMxeVBKCjcwZGlvbzIwTUZOb1pXeHNlU0JUYjNWeVkyVWdWR1Z6ZENBOGMyOTFjbU5sTFhSbGMzUkFaWGhoYlhCc1pTNXAKYm5aaGJHbGtQb2lRQkJNV0NnQTRGaUVFTGpmZnpKS0h5S0w0U3lVWkpCcGJKRlNQckhBRkFtcURUTDhDR3dNRgpDd2tJQndJR0ZRb0pDQXNDQkJZQ0F3RUNIZ0VDRjRBQUNna1FKQnBiSkZTUHJIQnJnUUVBbVFEdkNMNHZoc01CClgya3Y2V3ZFN1pMVzgyaUZQbkJaR2U1SXpDYWVvdUlCQVBMRC80M2RmbGlxZkVFTzFFZktJQVQ5SjV3cXdldmUKdFRBdXFvVGFRUXNLCj1jbzViCi0tLS0tRU5EIFBHUCBQVUJMSUMgS0VZIEJMT0NLLS0tLS0K";
const source_pgp_signature_base64 = "iHUEABYKAB0WIQQuN9/MkofIovhLJRkkGlskVI+scAUCaoNNkwAKCRAkGlskVI+scBdcAP91A7dSPdze1V9Nmg8WM8/fQ1ok2OdwBK5tSxyvKX4OeQEA16pbB6X6y/DarBoa3OaU5Up21xdPZL1g+3o2i1xztgM=";
const source_pgp_payload_gzip_base64 = "H4sIAAAAAAAAA0ssLclIzSvJTE4sSU1RKEiszMlPTOECACsbVvAWAAAA";
const signed_git_bundle_base64 = "IyB2MiBnaXQgYnVuZGxlCjljYWUwYTE2NWExZGQ2NjdjZWMxN2Y2ODQ4NjAxYWU5Y2EwZGQyMzIgcmVmcy9oZWFkcy9tYWluCgpQQUNLAAAAAgAAAAOdG3icrY/NboJAGEX38xTf3ljHgjAktekoE6RYKr+mSxgHpIAoDIo+fVObdNVl7+6exUmObIWAx0wnhCs8ybJUJSlXVEF2mGt4ync6T2ealvJEUwhKerlvWgj2oqquEDR9ywWEopPw1N3PWIpOvoghqY+VeCgO56Qqds8w1YlmGBgrBMZYxRjxpq4LKcV/uPJj3hU5jL+3YJbtwsbaQGBbLg0jn905AgTFKmJ08eHQBd7ante7xuStbDK7Oe/Xr35ZWlVXxvao4zRaJo3rTnPqLH36yxFw59ZSz1RHhuFvsa2YVlwPnIomji5X3XGWnwrzWX7AOulXtxV/z02D9b13wmtcTeIYQXY5qs4p3AaKFrYzm1nDlRheUF+iiS8onyOYY/+Wo58a5pp/taCsGGTfCvQFaluI2KMCeJwzNDAwMzFRKEiszMlPTGEoCGu5+pP98hNt39nJAtc8/aclPLsLAN9wDr22AXicSywtyUjNK8lMTixJTVEoSKzMyU9M4QIAZowIeN5X7vtMSMeGSu5llThgA/cTIihw";
const signing_pgp_fingerprint = "CE4814F7337B98A2527A32F8FCEBF9274CA93649";
const signing_pgp_secret_key_base64 = "LS0tLS1CRUdJTiBQR1AgUFJJVkFURSBLRVkgQkxPQ0stLS0tLQoKbEZnRWFvUGN4eFlKS3dZQkJBSGFSdzhCQVFkQUpqQVAyRXhlWFBrVDduZTM5R3dCSkhINlpXVkhnRzV0NGNRcApnWlYySENJQUFRRGtVbGVMZXp2U1JTdkdqVHRDclRjcFIxdUhrejVveWFSYWQyeGFRNzE1WkE0eHRFWlRhR1ZzCmJIa2dWR1Z6ZENCVGFXZHVhVzVuSUV0bGVTQW9kR1Z6ZEMxdmJteDVLU0E4YzJobGJHeDVMWE5wWjI0dGRHVnoKZEVCbGVHRnRjR3hsTG1sdWRtRnNhV1EraUpBRUV4WUtBRGdXSVFUT1NCVDNNM3VZb2xKNk12ajg2L2tuVEtrMgpTUVVDYW9QY3h3SWJBd1VMQ1FnSEFnWVZDZ2tJQ3dJRUZnSURBUUllQVFJWGdBQUtDUkQ4Ni9rblRLazJTVGhMCkFQNGhoblkrMW5zUUxRblpkN0Fqb3NlNkwrOHgzbFVJS3NOV2ZlNTVtT2dHZ1FFQWhWckorU2lvVnBLYVduVWwKTkNVU3NTUjVPeEwxV21xZE9QUVNzQ0lYQVFzPQo9WUZ2MgotLS0tLUVORCBQR1AgUFJJVkFURSBLRVkgQkxPQ0stLS0tLQo=";

const ErrorCapture = struct {
    count: usize = 0,

    fn handle(data: ?*anyopaque, event: op_context.Event) void {
        const self: *@This() = @ptrCast(@alignCast(data.?));
        switch (event) {
            .failure => self.count += 1,
            else => {},
        }
    }
};

const CompletionCapture = struct {
    completion: ?op_context.CompletionStatus = null,

    fn handle(data: ?*anyopaque, event: op_context.Event) void {
        const self: *@This() = @ptrCast(@alignCast(data.?));
        switch (event) {
            .completed => |completed| self.completion = completed.status,
            else => {},
        }
    }
};

const StreamCapture = struct {
    stdout_seen: std.atomic.Value(bool) = .init(false),
    stderr_seen: std.atomic.Value(bool) = .init(false),

    fn handle(data: ?*anyopaque, event: op_context.Event) void {
        const self: *@This() = @ptrCast(@alignCast(data.?));
        switch (event) {
            .status => |status| {
                if (std.mem.eql(u8, status.message, "log stdout marker"))
                    self.stdout_seen.store(true, .release);
                if (std.mem.eql(u8, status.message, "log stderr marker"))
                    self.stderr_seen.store(true, .release);
            },
            else => {},
        }
    }
};

const AcceptQuestions = struct {
    fn answer(_: ?*anyopaque, _: op_context.Question) op_context.QuestionResponse {
        return .accepted;
    }
};

const Fixture = struct {
    builder: *PackageBuilder,
    package_builds: []pkgbuild_mod.Pkgbuild,
    requested_names: [][]const u8,
    operation_context: *op_context.OperationContext,
    config: *ShellyBuildConfiguration,
    // Sentinel-terminated: realPathFileAlloc allocates len+1 for the 0 byte,
    // and free() only releases the full allocation when the slice type still
    // carries the sentinel.
    build_dir: [:0]const u8,
    allocator: std.mem.Allocator,
    temporary: std.testing.TmpDir,
    short_gnupg_home: ?[:0]u8 = null,

    /// Parses `pkgbuild_content`, creates a per-test build directory, and
    /// constructs a PackageBuilder around them. The builder borrows parsed
    /// PKGBUILD data and requested names; the fixture owns and releases them.
    ///
    /// The build directory doubles as the parser's base directory so the
    /// makepkg built-ins ($startdir/$srcdir/$pkgdir) expand into it.
    /// `event_handler`, when provided, is subscribed to the operation context
    /// *before* the context is copied into the builder so the builder's copy
    /// (which dispatches during BuildPackage) sees the subscription.
    /// `selected_package_name` selects the split-package member whose
    /// package_<name>() step is extracted; pass null for single packages.
    fn create(
        allocator: std.mem.Allocator,
        pkgbuild_content: []const u8,
        event_handler: ?op_context.EventHandler,
        selected_package_name: ?[]const u8,
    ) !Fixture {
        const io = testing.io;

        var temporary = std.testing.tmpDir(.{});
        errdefer temporary.cleanup();
        const build_dir = try temporary.dir.realPathFileAlloc(io, ".", allocator);
        errdefer allocator.free(build_dir);
        // sources_prepared means the caller supplies makepkg's $srcdir.
        try temporary.dir.createDirPath(io, "src");

        var parser = pkgbuild_mod.PkgbuildParser{
            .allocator = allocator,
            .io = io,
            .selected_package_name = selected_package_name,
        };
        var info = try parser.parser_content(pkgbuild_content, build_dir);
        errdefer info.deinit(allocator);

        const operation_context = try allocator.create(op_context.OperationContext);
        errdefer allocator.destroy(operation_context);
        operation_context.* = op_context.OperationContext.init(allocator, io);
        errdefer operation_context.deinit();

        if (event_handler) |handler| {
            _ = try operation_context.subscribe(handler);
        }

        const config = try ShellyBuildConfiguration.initFromBuffers(allocator, null, null);
        errdefer config.deinit();

        const package_builds = try allocator.alloc(pkgbuild_mod.Pkgbuild, 1);
        errdefer allocator.free(package_builds);
        package_builds[0] = info;
        const requested_names = try allocator.alloc([]const u8, 1);
        errdefer allocator.free(requested_names);
        requested_names[0] = try allocator.dupe(u8, info.pkg_name orelse "");
        var pkgbuild_digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(pkgbuild_content, &pkgbuild_digest, .{});
        const builder = try PackageBuilder.init(
            allocator,
            package_builds,
            operation_context,
            config.*,
            requested_names,
            .{
                .run_check = true,
                .overwrite = true,
                .clean_after_success = false,
                .skip_source_pgp_verification = true,
                .start_directory = build_dir,
                .work_directory = build_dir,
                .package_destination = build_dir,
                .source_destination = build_dir,
                .log_destination = build_dir,
                .sources_prepared = true,
                .reviewed_pkgbuild_digest = [_]u8{0} ** std.crypto.hash.sha2.Sha256.digest_length,
                .pkgbuild_sha256sum = pkgbuild_digest,
                .installed_packages = &.{"base-1-1-any"},
            },
            testing.environ,
            io,
        );

        return .{
            .builder = builder,
            .package_builds = package_builds,
            .requested_names = requested_names,
            .operation_context = operation_context,
            .config = config,
            .build_dir = build_dir,
            .allocator = allocator,
            .temporary = temporary,
        };
    }

    fn createMany(
        allocator: std.mem.Allocator,
        pkgbuild_content: []const u8,
        requested: []const []const u8,
        event_handler: ?op_context.EventHandler,
    ) !Fixture {
        const io = testing.io;
        var temporary = std.testing.tmpDir(.{});
        errdefer temporary.cleanup();
        const build_dir = try temporary.dir.realPathFileAlloc(io, ".", allocator);
        errdefer allocator.free(build_dir);
        // sources_prepared means the caller supplies makepkg's $srcdir.
        try temporary.dir.createDirPath(io, "src");

        const package_builds = try allocator.alloc(pkgbuild_mod.Pkgbuild, requested.len);
        var parsed_count: usize = 0;
        errdefer {
            for (package_builds[0..parsed_count]) |*package_build| package_build.deinit(allocator);
            allocator.free(package_builds);
        }
        for (requested, package_builds) |requested_name, *package_build| {
            package_build.* = try (pkgbuild_mod.PkgbuildParser{
                .allocator = allocator,
                .io = io,
                .selected_package_name = requested_name,
            }).parser_content(pkgbuild_content, build_dir);
            parsed_count += 1;
        }

        const operation_context = try allocator.create(op_context.OperationContext);
        errdefer allocator.destroy(operation_context);
        operation_context.* = op_context.OperationContext.init(allocator, io);
        errdefer operation_context.deinit();
        if (event_handler) |handler| _ = try operation_context.subscribe(handler);
        const config = try ShellyBuildConfiguration.initFromBuffers(allocator, null, null);
        errdefer config.deinit();
        const requested_names = try allocator.alloc([]const u8, requested.len);
        var duped_names: usize = 0;
        errdefer {
            for (requested_names[0..duped_names]) |name| allocator.free(name);
            allocator.free(requested_names);
        }
        for (requested, requested_names) |name, *slot| {
            slot.* = try allocator.dupe(u8, name);
            duped_names += 1;
        }
        var pkgbuild_digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(pkgbuild_content, &pkgbuild_digest, .{});
        const builder = try PackageBuilder.init(
            allocator,
            package_builds,
            operation_context,
            config.*,
            requested_names,
            .{
                .run_check = true,
                .overwrite = true,
                .clean_after_success = false,
                .skip_source_pgp_verification = true,
                .start_directory = build_dir,
                .work_directory = build_dir,
                .package_destination = build_dir,
                .source_destination = build_dir,
                .log_destination = build_dir,
                .sources_prepared = true,
                .reviewed_pkgbuild_digest = [_]u8{0} ** std.crypto.hash.sha2.Sha256.digest_length,
                .pkgbuild_sha256sum = pkgbuild_digest,
                .installed_packages = &.{"base-1-1-any"},
            },
            testing.environ,
            io,
        );

        return .{
            .builder = builder,
            .package_builds = package_builds,
            .requested_names = requested_names,
            .operation_context = operation_context,
            .config = config,
            .build_dir = build_dir,
            .allocator = allocator,
            .temporary = temporary,
        };
    }

    fn destroy(self: *Fixture) void {
        // Release borrowed inputs before destroying the builder container.
        // The testing allocator catches omissions.
        for (self.package_builds) |*package_build| package_build.deinit(self.allocator);
        self.allocator.free(self.package_builds);
        for (self.requested_names) |name| self.allocator.free(name);
        self.allocator.free(self.requested_names);
        self.builder.deinit();
        self.config.deinit();
        self.operation_context.deinit();
        self.allocator.destroy(self.operation_context);
        if (self.short_gnupg_home) |path| {
            std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};
            self.allocator.free(path);
        }
        self.allocator.free(self.build_dir);
        self.temporary.cleanup();
    }
};

fn printPackageTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    package_directory: []const u8,
) !void {
    var directory = try std.Io.Dir.cwd().openDir(io, package_directory, .{ .iterate = true });
    defer directory.close(io);

    var walker = try directory.walk(allocator);
    defer walker.deinit();

    std.debug.print("[builder-test] staged package tree: {s}\n", .{package_directory});
    while (try walker.next(io)) |entry| {
        const stat = try entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false });
        const mode = stat.permissions.toMode() & 0o7777;
        std.debug.print(
            "[builder-test]   {s: <13} {o:0>4} {s}\n",
            .{ @tagName(entry.kind), mode, entry.path },
        );
    }
}

fn readPackageEntry(
    allocator: std.mem.Allocator,
    package_path: []const u8,
    entry_name: []const u8,
) ![]u8 {
    var reader = try archive.Reader.init(allocator, package_path);
    defer reader.deinit();
    while (try reader.next()) |entry| {
        if (!std.mem.eql(u8, entry.path, entry_name)) continue;
        var buffer: [256 * 1024]u8 = undefined;
        const amount = try reader.readPrefix(&buffer);
        return allocator.dupe(u8, buffer[0..amount]);
    }
    return error.MissingPackageEntry;
}

fn readOnlyBuildLog(allocator: std.mem.Allocator, io: std.Io, directory_path: []const u8) ![]u8 {
    var directory = try std.Io.Dir.cwd().openDir(io, directory_path, .{ .iterate = true });
    defer directory.close(io);
    var iterator = directory.iterate();
    var found: ?[]u8 = null;
    defer if (found) |path| allocator.free(path);
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".log")) continue;
        if (found != null) return error.MultipleBuildLogs;
        found = try std.fs.path.join(allocator, &.{ directory_path, entry.name });
    }
    const path = found orelse return error.MissingBuildLog;
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
}

fn readPkgInfo(allocator: std.mem.Allocator, package_path: []const u8) ![]u8 {
    return readPackageEntry(allocator, package_path, ".PKGINFO");
}

fn runTestCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    working_directory: ?[]const u8,
) !void {
    var result = try process_runner.run(allocator, io, argv, working_directory, null);
    defer result.deinit(allocator);
    if (result.exit_code != 0) {
        std.debug.print("builder fixture command failed ({d}): {s}\n", .{ result.exit_code, result.stderr });
        return error.FixtureCommandFailed;
    }
}

fn writeBase64Fixture(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    sub_path: []const u8,
    encoded: []const u8,
) !void {
    const decoded_size = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const decoded = try allocator.alloc(u8, decoded_size);
    defer allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, encoded);
    try directory.writeFile(io, .{ .sub_path = sub_path, .data = decoded });
}

/// Creates the small ar-plus-tar structure used by Debian binary packages.
/// Keeping it local makes source-extraction tests independent of upstream
/// downloads while exercising the same nested data.tar.xz flow as binary AUR
/// recipes such as visual-studio-code-bin.
fn writeDebFixture(fixture: *Fixture, sub_path: []const u8) !void {
    const allocator = fixture.allocator;
    const io = testing.io;
    try fixture.temporary.dir.createDirPath(io, "deb-fixture");
    try fixture.temporary.dir.writeFile(io, .{
        .sub_path = "deb-fixture/debian-binary",
        .data = "2.0\n",
    });

    const fixture_directory = try std.fs.path.join(
        allocator,
        &.{ fixture.build_dir, "deb-fixture" },
    );
    defer allocator.free(fixture_directory);
    const control_archive = try std.fs.path.join(
        allocator,
        &.{ fixture_directory, "control.tar.xz" },
    );
    defer allocator.free(control_archive);
    const data_archive = try std.fs.path.join(
        allocator,
        &.{ fixture_directory, "data.tar.xz" },
    );
    defer allocator.free(data_archive);
    const deb_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, sub_path });
    defer allocator.free(deb_path);

    try archive.writeFixture(allocator, control_archive, .xz, &.{});
    try archive.writeFixture(allocator, data_archive, .xz, &.{
        .{ .path = "usr/share/deb-source-demo/payload", .contents = "from deb\n" },
    });
    try runTestCommand(
        allocator,
        io,
        &.{ "/usr/bin/ar", "rc", deb_path, "debian-binary", "control.tar.xz", "data.tar.xz" },
        fixture_directory,
    );
}

fn prepareSourcePgpHome(fixture: *Fixture) ![:0]u8 {
    const allocator = fixture.allocator;
    const io = testing.io;
    try fixture.temporary.dir.createDir(io, "gnupg", .fromMode(0o700));
    try writeBase64Fixture(
        allocator,
        io,
        fixture.temporary.dir,
        "source-test-public.asc",
        source_pgp_public_key_base64,
    );
    const actual_home = try fixture.temporary.dir.realPathFileAlloc(io, "gnupg", allocator);
    defer allocator.free(actual_home);
    const short_home_text = try std.fmt.allocPrint(
        allocator,
        "/tmp/sg-{s}",
        .{std.fs.path.basename(fixture.build_dir)},
    );
    defer allocator.free(short_home_text);
    const short_home = try allocator.dupeZ(u8, short_home_text);
    errdefer allocator.free(short_home);
    try std.Io.Dir.cwd().symLink(io, actual_home, short_home, .{});
    fixture.short_gnupg_home = short_home;
    const home = try allocator.dupeZ(u8, short_home);
    errdefer allocator.free(home);
    const public_key = try fixture.temporary.dir.realPathFileAlloc(io, "source-test-public.asc", allocator);
    defer allocator.free(public_key);
    try runTestCommand(allocator, io, &.{
        "/usr/bin/gpg",
        "--homedir",
        home,
        "--batch",
        "--no-autostart",
        "--import",
        public_key,
    }, null);
    return home;
}

/// Prepares an isolated GNUPGHOME that holds the test signing key pair so
/// PackageBuilder can create detached package signatures. The returned home
/// is a short path because GnuPG agent sockets have a length limit.
fn prepareSigningPgpHome(fixture: *Fixture) ![:0]u8 {
    const allocator = fixture.allocator;
    const io = testing.io;
    try fixture.temporary.dir.createDir(io, "gnupg", .fromMode(0o700));
    try writeBase64Fixture(
        allocator,
        io,
        fixture.temporary.dir,
        "signing-test-secret.asc",
        signing_pgp_secret_key_base64,
    );
    const actual_home = try fixture.temporary.dir.realPathFileAlloc(io, "gnupg", allocator);
    defer allocator.free(actual_home);
    const short_home_text = try std.fmt.allocPrint(
        allocator,
        "/tmp/sk-{s}",
        .{std.fs.path.basename(fixture.build_dir)},
    );
    defer allocator.free(short_home_text);
    const short_home = try allocator.dupeZ(u8, short_home_text);
    errdefer allocator.free(short_home);
    try std.Io.Dir.cwd().symLink(io, actual_home, short_home, .{});
    const home = try allocator.dupeZ(u8, short_home);
    errdefer allocator.free(home);
    const secret_key = try fixture.temporary.dir.realPathFileAlloc(io, "signing-test-secret.asc", allocator);
    defer allocator.free(secret_key);
    try runTestCommand(allocator, io, &.{
        "/usr/bin/gpg",
        "--homedir",
        home,
        "--batch",
        "--import",
        secret_key,
    }, null);
    fixture.short_gnupg_home = short_home;
    return home;
}

test "PackageBuilder signs published packages with the configured signing key" {
    const allocator = testing.allocator;
    const io = testing.io;
    const pkgbuild_content =
        \\pkgname=signing-demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\package() {
        \\  mkdir -p "$pkgdir/usr/share/signing-demo"
        \\  printf 'signed payload\n' > "$pkgdir/usr/share/signing-demo/data"
        \\}
    ;
    var fixture = try Fixture.create(allocator, pkgbuild_content, null, null);
    defer fixture.destroy();
    const gnupg_home = try prepareSigningPgpHome(&fixture);
    defer allocator.free(gnupg_home);
    fixture.builder.options.sign = true;
    fixture.builder.options.sign_key = signing_pgp_fingerprint;
    fixture.builder.options.sign_gnupg_home = gnupg_home;

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);

    const signature_path = try std.fmt.allocPrint(allocator, "{s}.sig", .{artifacts[0].path});
    defer allocator.free(signature_path);
    try std.Io.Dir.cwd().access(io, signature_path, .{});

    const verifier = source_pgp_verifier.Verifier{
        .allocator = allocator,
        .io = io,
        .environ = testing.environ,
        .gnupg_home = gnupg_home,
    };
    var verification = try verifier.verifyDetached(
        signature_path,
        artifacts[0].path,
        &.{signing_pgp_fingerprint},
    );
    defer verification.deinit(allocator);
    try testing.expectEqualStrings(signing_pgp_fingerprint, verification.primary_fingerprint);
    try testing.expectEqual(source_pgp_verifier.Warning.none, verification.warning);

    const log = try readOnlyBuildLog(allocator, io, fixture.build_dir);
    defer allocator.free(log);
    try testing.expect(std.mem.indexOf(u8, log, "[phase] signing") != null);

    // Terminate the gpg-agent daemon spawned during signing so it does not
    // outlive the fixture and interfere with teardown.
    var kill = try process_runner.run(allocator, io, &.{ "/usr/bin/gpgconf", "--homedir", gnupg_home, "--kill", "gpg-agent" }, null, null);
    defer kill.deinit(allocator);
}

test "PackageBuilder fails atomically when the signing key is unavailable" {
    const allocator = testing.allocator;
    const io = testing.io;
    const pkgbuild_content =
        \\pkgname=signing-failure-demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\package() {
        \\  mkdir -p "$pkgdir/usr/share/signing-failure-demo"
        \\}
    ;
    var fixture = try Fixture.create(allocator, pkgbuild_content, null, null);
    defer fixture.destroy();
    try fixture.temporary.dir.createDir(io, "gnupg", .fromMode(0o700));
    const actual_home = try fixture.temporary.dir.realPathFileAlloc(io, "gnupg", allocator);
    defer allocator.free(actual_home);
    const short_home_text = try std.fmt.allocPrint(
        allocator,
        "/tmp/sk-{s}",
        .{std.fs.path.basename(fixture.build_dir)},
    );
    defer allocator.free(short_home_text);
    const short_home = try allocator.dupeZ(u8, short_home_text);
    try std.Io.Dir.cwd().symLink(io, actual_home, short_home, .{});
    fixture.short_gnupg_home = short_home;
    fixture.builder.options.sign = true;
    fixture.builder.options.sign_key = signing_pgp_fingerprint;
    fixture.builder.options.sign_gnupg_home = short_home;

    try testing.expectError(error.BuildFailed, fixture.builder.BuildPackage());

    // Signing failures must not leave a published unsigned artifact behind.
    var directory = try std.Io.Dir.cwd().openDir(io, fixture.build_dir, .{ .iterate = true });
    defer directory.close(io);
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind == .file and process_runner.isPackageArchiveArtifact(entry.name))
            return error.UnexpectedPublishedArtifact;
    }
}

test "PackageBuilder leaves packages unsigned when signing is disabled" {
    const allocator = testing.allocator;
    const io = testing.io;
    const pkgbuild_content =
        \\pkgname=unsigned-demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\package() {
        \\  mkdir -p "$pkgdir/usr/share/unsigned-demo"
        \\}
    ;
    var fixture = try Fixture.create(allocator, pkgbuild_content, null, null);
    defer fixture.destroy();

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    const signature_path = try std.fmt.allocPrint(allocator, "{s}.sig", .{artifacts[0].path});
    defer allocator.free(signature_path);
    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(io, signature_path, .{}),
    );
}

test "PackageBuilder init keeps the provided collaborators" {
    const allocator = testing.allocator;

    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\arch=('any')
        \\
        \\build() {
        \\  true
        \\}
    , null, null);
    defer fixture.destroy();

    try testing.expectEqual(fixture.allocator, fixture.builder.allocator);
    try testing.expectEqualStrings("demo", fixture.builder.package_builds[0].pkg_name.?);
}

test "non-root builder guard rejects root effective uid" {
    try testing.expectError(
        error.BuilderMustNotRunAsRoot,
        builder_mod.requireNonRootEffectiveUid(0),
    );
    try builder_mod.requireNonRootEffectiveUid(1000);
}

test "PackageBuilder rejects a PKGBUILD changed after review" {
    const allocator = testing.allocator;
    const io = testing.io;
    const pkgbuild_content =
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\package() {
        \\  mkdir -p "$pkgdir/usr/share/demo"
        \\}
    ;
    var fixture = try Fixture.create(allocator, pkgbuild_content, null, null);
    defer fixture.destroy();
    try fixture.temporary.dir.writeFile(io, .{
        .sub_path = "PKGBUILD",
        .data = pkgbuild_content,
    });
    const pkgbuild_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "PKGBUILD" });
    defer allocator.free(pkgbuild_path);
    var review = try builder_mod.preparePkgbuildReview(
        allocator,
        io,
        fixture.build_dir,
        pkgbuild_content,
        fixture.package_builds,
    );
    defer review.deinit();
    fixture.builder.options.pkgbuild_path = pkgbuild_path;
    fixture.builder.options.reviewed_pkgbuild_digest = review.digest;

    try fixture.temporary.dir.writeFile(io, .{
        .sub_path = "PKGBUILD",
        .data = "pkgname=changed\npkgver=1\npkgrel=1\narch=('any')\n",
    });
    try testing.expectError(
        error.ReviewedPkgbuildChanged,
        fixture.builder.BuildPackage(),
    );
}

test "PackageBuilder resolves top-level command substitution before building" {
    const allocator = testing.allocator;
    const io = testing.io;
    const pkgbuild_content =
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\_greeting="$(printf 'dynamic-resolved')"
        \\package() {
        \\  mkdir -p "$pkgdir/usr/share/demo"
        \\  printf '%s' "$_greeting" > "$pkgdir/usr/share/demo/value"
        \\}
    ;
    var fixture = try Fixture.create(allocator, pkgbuild_content, null, null);
    defer fixture.destroy();

    // The analysis parse records the assignment without evaluating it.
    try testing.expect(fixture.package_builds[0].hasDynamicAssignments());
    try testing.expect(fixture.package_builds[0].variables.get("_greeting") == null);

    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "PKGBUILD", .data = pkgbuild_content });
    const pkgbuild_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "PKGBUILD" });
    defer allocator.free(pkgbuild_path);
    var review = try builder_mod.preparePkgbuildReview(
        allocator,
        io,
        fixture.build_dir,
        pkgbuild_content,
        fixture.package_builds,
    );
    defer review.deinit();
    fixture.builder.options.pkgbuild_path = pkgbuild_path;
    fixture.builder.options.reviewed_pkgbuild_digest = review.digest;
    fixture.builder.options.reviewed_files = review.reviewed_files;

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 1), artifacts.len);

    // The builder evaluated the assignment and re-parsed with the value seeded,
    // so the resolved value reaches the package step and lands in the archive.
    const value = try readPackageEntry(allocator, artifacts[0].path, "usr/share/demo/value");
    defer allocator.free(value);
    try testing.expectEqualStrings("dynamic-resolved", value);
    try testing.expectEqualStrings("dynamic-resolved", fixture.package_builds[0].variables.get("_greeting").?);
    try testing.expect(!fixture.package_builds[0].hasDynamicAssignments());
}

test "PackageBuilder resolves issue 1750 source command substitution after review" {
    const allocator = testing.allocator;
    const io = testing.io;
    const pkgbuild_content =
        \\pkgname=gpu-screen-recorder-ui-git
        \\pkgver=1
        \\pkgrel=1
        \\arch=('x86_64')
        \\_pkgname="gpu-screen-recorder-ui"
        \\url="https://git.dec05eba.com/gpu-screen-recorder-ui"
        \\_pkgsrc="$_pkgname"
        \\source=("$_pkgsrc"::"git+$(sed 's&//git\.&//repo.&' <<< "$url")")
        \\sha256sums=('SKIP')
        \\package() {
        \\  mkdir -p "$pkgdir/usr/share/gpu-screen-recorder-ui"
        \\  printf resolved > "$pkgdir/usr/share/gpu-screen-recorder-ui/source-test"
        \\}
    ;
    var fixture = try Fixture.create(allocator, pkgbuild_content, null, null);
    defer fixture.destroy();
    try testing.expectEqual(@as(usize, 2), fixture.package_builds[0].dynamic_source_assignments.len);

    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "PKGBUILD", .data = pkgbuild_content });
    const pkgbuild_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "PKGBUILD" });
    defer allocator.free(pkgbuild_path);
    var review = try builder_mod.preparePkgbuildReview(
        allocator,
        io,
        fixture.build_dir,
        pkgbuild_content,
        fixture.package_builds,
    );
    defer review.deinit();
    try testing.expectEqual(@as(usize, 1), review.findings.len);
    try testing.expect(std.mem.indexOf(u8, review.findings[0].message, "by the builder after this review") != null);
    fixture.builder.options.pkgbuild_path = pkgbuild_path;
    fixture.builder.options.reviewed_pkgbuild_digest = review.digest;

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 1), artifacts.len);
    try testing.expectEqual(@as(usize, 0), fixture.package_builds[0].dynamic_source_assignments.len);
    try testing.expectEqualStrings(
        "gpu-screen-recorder-ui::git+https://repo.dec05eba.com/gpu-screen-recorder-ui",
        fixture.package_builds[0].source.?[0],
    );
    var parsed_source = try source_spec.ParsedSource.parse(
        allocator,
        fixture.package_builds[0].source.?[0],
    );
    defer parsed_source.deinit(allocator);
    try testing.expectEqual(source_spec.SourceKind.git, parsed_source.kind);
    try testing.expectEqualStrings(
        "https://repo.dec05eba.com/gpu-screen-recorder-ui",
        parsed_source.location,
    );
}

test "PackageBuilder evaluates conditional source and checksum arrays atomically" {
    const allocator = testing.allocator;
    const io = testing.io;
    const pkgbuild_content =
        \\pkgname=generic-integrity-metadata
        \\pkgver=1
        \\pkgrel=1
        \\arch=('x86_64')
        \\_feature=yes
        \\_disabled=no
        \\_feature_enabled() { [[ "$_feature" = yes ]]; }
        \\source=('base.txt')
        \\b2sums=('SKIP')
        \\if _feature_enabled; then
        \\  source+=('feature.txt')
        \\  b2sums+=('SKIP')
        \\  if [ -e nested.txt ]; then
        \\    source+=('nested.txt')
        \\    b2sums+=('SKIP')
        \\  fi
        \\fi
        \\if [ "$_disabled" = yes ]; then
        \\  source+=('must-not-exist.txt')
        \\  b2sums+=('SKIP')
        \\fi
        \\case "$CARCH" in
        \\  x86_64)
        \\    source+=('architecture.txt')
        \\    b2sums+=('SKIP')
        \\    ;;
        \\esac
        \\[ -n "$pkgver" ] && source+=('version.txt')
        \\[ -n "$pkgver" ] && b2sums+=('SKIP')
        \\package() {
        \\  mkdir -p "$pkgdir/usr/share/generic-integrity-metadata"
        \\  printf resolved > "$pkgdir/usr/share/generic-integrity-metadata/result"
        \\}
    ;
    var fixture = try Fixture.create(allocator, pkgbuild_content, null, null);
    defer fixture.destroy();
    try testing.expectEqual(@as(usize, 12), fixture.package_builds[0].dynamic_source_assignments.len);
    try testing.expectEqual(@as(usize, 1), fixture.package_builds[0].source.?.len);
    try testing.expectEqual(@as(usize, 1), fixture.package_builds[0].b_2_sums.?.len);

    fixture.operation_context.setQuestionHandler(.{ .function = AcceptQuestions.answer });
    fixture.builder.options.sources_prepared = false;
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "PKGBUILD", .data = pkgbuild_content });
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "base.txt", .data = "base\n" });
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "feature.txt", .data = "feature\n" });
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "nested.txt", .data = "nested\n" });
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "architecture.txt", .data = "architecture\n" });
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "version.txt", .data = "version\n" });
    const pkgbuild_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "PKGBUILD" });
    defer allocator.free(pkgbuild_path);
    var review = try builder_mod.preparePkgbuildReview(
        allocator,
        io,
        fixture.build_dir,
        pkgbuild_content,
        fixture.package_builds,
    );
    defer review.deinit();
    fixture.builder.options.pkgbuild_path = pkgbuild_path;
    fixture.builder.options.reviewed_pkgbuild_digest = review.digest;
    fixture.builder.options.reviewed_files = review.reviewed_files;

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 1), artifacts.len);
    try testing.expectEqual(@as(usize, 0), fixture.package_builds[0].dynamic_source_assignments.len);
    try testing.expectEqual(@as(usize, 5), fixture.package_builds[0].source.?.len);
    try testing.expectEqual(@as(usize, 5), fixture.package_builds[0].b_2_sums.?.len);
    try testing.expectEqualStrings(
        "version.txt",
        fixture.package_builds[0].source.?[4],
    );
}

test "PackageBuilder preserves generic shell-created scalar defaults for lifecycle steps" {
    const allocator = testing.allocator;
    const io = testing.io;
    const pkgbuild_content =
        \\pkgname=generic-shell-defaults
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\: "${_scheduler:=portable}"
        \\: "${_lto=enabled}"
        \\: "${_empty:=}"
        \\: "${_message:=$'line one\nline two'}"
        \\_set_ticks() { : "${_ticks:=250}"; }
        \\_set_ticks
        \\if [[ "$_scheduler" = portable ]]; then
        \\  : "${_preempt:=full}"
        \\fi
        \\_removed=static
        \\unset _removed
        \\unset HOME
        \\prepare() {
        \\  [[ "$_scheduler" = portable ]]
        \\  [[ "$_lto" = enabled ]]
        \\  [[ "$_ticks" = 250 ]]
        \\  [[ "$_preempt" = full ]]
        \\  [[ ${_empty+x} = x ]]
        \\  [[ ! ${_removed+x} ]]
        \\  [[ ! ${HOME+x} ]]
        \\}
        \\package() {
        \\  mkdir -p "$pkgdir/usr/share/generic-shell-defaults"
        \\  printf '%s|%s|%s|%s|%s' "$_scheduler" "$_lto" "$_ticks" "$_preempt" "$_message" > "$pkgdir/usr/share/generic-shell-defaults/value"
        \\}
    ;
    var fixture = try Fixture.create(allocator, pkgbuild_content, null, null);
    defer fixture.destroy();
    try testing.expect(fixture.package_builds[0].variables.get("_scheduler") == null);

    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "PKGBUILD", .data = pkgbuild_content });
    const pkgbuild_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "PKGBUILD" });
    defer allocator.free(pkgbuild_path);
    var review = try builder_mod.preparePkgbuildReview(
        allocator,
        io,
        fixture.build_dir,
        pkgbuild_content,
        fixture.package_builds,
    );
    defer review.deinit();
    fixture.builder.options.pkgbuild_path = pkgbuild_path;
    fixture.builder.options.reviewed_pkgbuild_digest = review.digest;
    fixture.builder.options.reviewed_files = review.reviewed_files;

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    const value = try readPackageEntry(
        allocator,
        artifacts[0].path,
        "usr/share/generic-shell-defaults/value",
    );
    defer allocator.free(value);
    try testing.expectEqualStrings(
        "portable|enabled|250|full|line one\nline two",
        value,
    );
    try testing.expectEqualStrings("portable", fixture.package_builds[0].variables.get("_scheduler").?);
    try testing.expectEqualStrings("", fixture.package_builds[0].variables.get("_empty").?);
    try testing.expect(fixture.package_builds[0].variables.get("_removed") == null);
    try testing.expect(fixture.package_builds[0].variables.get("HOME") == null);
    try testing.expect(fixture.package_builds[0].variables.get("PATH") == null);
}

test "PackageBuilder preserves top-level Bash option state for lifecycle steps" {
    const allocator = testing.allocator;
    const io = testing.io;
    const pkgbuild_content =
        \\pkgname=shell-option-state
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\shopt -s extglob
        \\shopt -u checkwinsize
        \\set -o noclobber
        \\set +o braceexpand
        \\prepare() {
        \\  shopt -q extglob
        \\  ! shopt -q checkwinsize
        \\  [[ -o noclobber ]]
        \\  [[ ! -o braceexpand ]]
        \\}
        \\package() {
        \\  shopt -q extglob
        \\  ! shopt -q checkwinsize
        \\  [[ -o noclobber ]]
        \\  [[ ! -o braceexpand ]]
        \\  mkdir -p "$pkgdir/usr/share/shell-option-state"
        \\  printf preserved > "$pkgdir/usr/share/shell-option-state/value"
        \\}
    ;
    var fixture = try Fixture.create(allocator, pkgbuild_content, null, null);
    defer fixture.destroy();

    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "PKGBUILD", .data = pkgbuild_content });
    const pkgbuild_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "PKGBUILD" });
    defer allocator.free(pkgbuild_path);
    var review = try builder_mod.preparePkgbuildReview(
        allocator,
        io,
        fixture.build_dir,
        pkgbuild_content,
        fixture.package_builds,
    );
    defer review.deinit();
    fixture.builder.options.pkgbuild_path = pkgbuild_path;
    fixture.builder.options.reviewed_pkgbuild_digest = review.digest;
    fixture.builder.options.reviewed_files = review.reviewed_files;

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    const value = try readPackageEntry(
        allocator,
        artifacts[0].path,
        "usr/share/shell-option-state/value",
    );
    defer allocator.free(value);
    try testing.expectEqualStrings("preserved", value);
    try testing.expect(fixture.package_builds[0].variables.get("BASHOPTS") == null);
    try testing.expect(fixture.package_builds[0].variables.get("SHELLOPTS") == null);
}

test "PackageBuilder preserves generic conditional indexed arrays for lifecycle steps" {
    const allocator = testing.allocator;
    const io = testing.io;
    const pkgbuild_content =
        \\pkgname=generic-shell-arrays
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\_enabled=yes
        \\BUILD_FLAGS=('CC=gcc')
        \\REMOVED_FLAGS=('stale')
        \\COMMAND_FLAGS=("$(printf command-value)")
        \\if [[ "$_enabled" = yes ]]; then
        \\  BUILD_FLAGS=('CC=clang' 'LD=ld.lld' 'LLVM=1' 'LLVM_IAS=1' '' $'line one\nline two')
        \\  EXTRA_FLAGS=('first value' second)
        \\  EMPTY_FLAGS=()
        \\  unset REMOVED_FLAGS
        \\fi
        \\_never_called() { LEAKED_FLAGS=('not top level'); }
        \\prepare() {
        \\  [[ ${#BUILD_FLAGS[@]} = 6 ]]
        \\  [[ "${BUILD_FLAGS[0]}" = CC=clang ]]
        \\  [[ "${BUILD_FLAGS[4]}" = '' ]]
        \\  [[ "${BUILD_FLAGS[5]}" = $'line one\nline two' ]]
        \\  [[ "${EXTRA_FLAGS[*]}" = 'first value second' ]]
        \\  [[ ${#EMPTY_FLAGS[@]} = 0 ]]
        \\  [[ ! ${REMOVED_FLAGS+x} ]]
        \\  [[ ! ${LEAKED_FLAGS+x} ]]
        \\  [[ "${COMMAND_FLAGS[0]}" = command-value ]]
        \\}
        \\package() {
        \\  mkdir -p "$pkgdir/usr/share/generic-shell-arrays"
        \\  printf '%s\n' "${BUILD_FLAGS[@]}" -- "${EXTRA_FLAGS[@]}" --command "${COMMAND_FLAGS[@]}" > "$pkgdir/usr/share/generic-shell-arrays/value"
        \\}
    ;
    var fixture = try Fixture.create(allocator, pkgbuild_content, null, null);
    defer fixture.destroy();

    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "PKGBUILD", .data = pkgbuild_content });
    const pkgbuild_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "PKGBUILD" });
    defer allocator.free(pkgbuild_path);
    var review = try builder_mod.preparePkgbuildReview(
        allocator,
        io,
        fixture.build_dir,
        pkgbuild_content,
        fixture.package_builds,
    );
    defer review.deinit();
    fixture.builder.options.pkgbuild_path = pkgbuild_path;
    fixture.builder.options.reviewed_pkgbuild_digest = review.digest;
    fixture.builder.options.reviewed_files = review.reviewed_files;

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    const value = try readPackageEntry(
        allocator,
        artifacts[0].path,
        "usr/share/generic-shell-arrays/value",
    );
    defer allocator.free(value);
    try testing.expectEqualStrings(
        "CC=clang\nLD=ld.lld\nLLVM=1\nLLVM_IAS=1\n\nline one\nline two\n--\nfirst value\nsecond\n--command\ncommand-value\n",
        value,
    );
}

test "PackageBuilder remaps shell-resolved split package names by reviewed order" {
    const allocator = testing.allocator;
    const io = testing.io;
    const pkgbuild_content =
        \\: "${_suffix:=stable}"
        \\pkgbase="demo-$_suffix"
        \\pkgname=("$pkgbase" "$pkgbase-docs")
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\prepare() { :; }
        \\package_demo-stable() {
        \\  mkdir -p "$pkgdir/usr/share/demo-stable"
        \\  printf main > "$pkgdir/usr/share/demo-stable/value"
        \\}
        \\package_demo-stable-docs() {
        \\  mkdir -p "$pkgdir/usr/share/doc/demo-stable"
        \\  printf docs > "$pkgdir/usr/share/doc/demo-stable/value"
        \\}
    ;
    const requested = [_][]const u8{ "demo-$_suffix", "demo-$_suffix-docs" };
    var fixture = try Fixture.createMany(allocator, pkgbuild_content, &requested, null);
    defer fixture.destroy();

    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "PKGBUILD", .data = pkgbuild_content });
    const pkgbuild_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "PKGBUILD" });
    defer allocator.free(pkgbuild_path);
    var review = try builder_mod.preparePkgbuildReview(
        allocator,
        io,
        fixture.build_dir,
        pkgbuild_content,
        fixture.package_builds,
    );
    defer review.deinit();
    fixture.builder.options.pkgbuild_path = pkgbuild_path;
    fixture.builder.options.reviewed_pkgbuild_digest = review.digest;
    fixture.builder.options.reviewed_files = review.reviewed_files;

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 2), artifacts.len);
    try testing.expectEqualStrings("demo-stable", artifacts[0].package_name);
    try testing.expectEqualStrings("demo-stable-docs", artifacts[1].package_name);
    try testing.expectEqualStrings("demo-stable", fixture.builder.requested_names[0]);
    try testing.expectEqualStrings("demo-stable-docs", fixture.builder.requested_names[1]);
}

test "PackageBuilder builds members added by sandbox-evaluated pkgname" {
    const allocator = testing.allocator;
    const io = testing.io;
    const pkgbuild_content =
        \\: "${_build_addon:=yes}"
        \\pkgbase=dynamic-split
        \\pkgname=("$pkgbase")
        \\pkgname+=("$pkgbase-headers")
        \\[ "$_build_addon" = yes ] && pkgname+=("$pkgbase-addon")
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\_package() {
        \\  mkdir -p "$pkgdir/usr/share/dynamic-split"
        \\  printf main > "$pkgdir/usr/share/dynamic-split/value"
        \\}
        \\_package-headers() {
        \\  mkdir -p "$pkgdir/usr/share/dynamic-split-headers"
        \\  printf headers > "$pkgdir/usr/share/dynamic-split-headers/value"
        \\}
        \\_package-addon() {
        \\  depends=('dynamic-addon-runtime')
        \\  mkdir -p "$pkgdir/usr/share/dynamic-split-addon"
        \\  printf addon > "$pkgdir/usr/share/dynamic-split-addon/value"
        \\}
        \\for _p in "${pkgname[@]}"; do
        \\  eval "package_$_p() {
        \\    $(declare -f "_package${_p#$pkgbase}")
        \\    _package${_p#$pkgbase}
        \\  }"
        \\done
    ;
    const statically_discovered = [_][]const u8{ "dynamic-split", "dynamic-split-headers" };
    var fixture = try Fixture.createMany(allocator, pkgbuild_content, &statically_discovered, null);
    defer fixture.destroy();
    fixture.builder.options.build_all_members = true;

    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "PKGBUILD", .data = pkgbuild_content });
    const pkgbuild_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "PKGBUILD" });
    defer allocator.free(pkgbuild_path);
    var review = try builder_mod.preparePkgbuildReview(
        allocator,
        io,
        fixture.build_dir,
        pkgbuild_content,
        fixture.package_builds,
    );
    defer review.deinit();
    fixture.builder.options.pkgbuild_path = pkgbuild_path;
    fixture.builder.options.reviewed_pkgbuild_digest = review.digest;
    fixture.builder.options.reviewed_files = review.reviewed_files;

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 3), artifacts.len);
    try testing.expectEqualStrings("dynamic-split", artifacts[0].package_name);
    try testing.expectEqualStrings("dynamic-split-headers", artifacts[1].package_name);
    try testing.expectEqualStrings("dynamic-split-addon", artifacts[2].package_name);
    try testing.expectEqual(@as(usize, 3), fixture.builder.package_builds.len);
    const addon_info = try readPkgInfo(allocator, artifacts[2].path);
    defer allocator.free(addon_info);
    try testing.expect(std.mem.indexOf(u8, addon_info, "depend = dynamic-addon-runtime\n") != null);
}

test "PackageBuilder explicitly selects a member added by evaluated pkgname" {
    const allocator = testing.allocator;
    const io = testing.io;
    const pkgbuild_content =
        \\: "${_build_addon:=yes}"
        \\pkgbase=dynamic-explicit
        \\pkgname=("$pkgbase")
        \\[ "$_build_addon" = yes ] && pkgname+=("$pkgbase-addon")
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\_package() {
        \\  mkdir -p "$pkgdir/usr/share/dynamic-explicit"
        \\}
        \\_package-addon() {
        \\  mkdir -p "$pkgdir/usr/share/dynamic-explicit-addon"
        \\  printf addon > "$pkgdir/usr/share/dynamic-explicit-addon/value"
        \\}
        \\for _p in "${pkgname[@]}"; do
        \\  eval "package_$_p() {
        \\    $(declare -f "_package${_p#$pkgbase}")
        \\    _package${_p#$pkgbase}
        \\  }"
        \\done
    ;
    var fixture = try Fixture.create(allocator, pkgbuild_content, null, "dynamic-explicit");
    defer fixture.destroy();
    allocator.free(fixture.requested_names[0]);
    fixture.requested_names[0] = try allocator.dupe(u8, "dynamic-explicit-addon");

    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "PKGBUILD", .data = pkgbuild_content });
    const pkgbuild_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "PKGBUILD" });
    defer allocator.free(pkgbuild_path);
    var review = try builder_mod.preparePkgbuildReview(
        allocator,
        io,
        fixture.build_dir,
        pkgbuild_content,
        fixture.package_builds,
    );
    defer review.deinit();
    fixture.builder.options.pkgbuild_path = pkgbuild_path;
    fixture.builder.options.reviewed_pkgbuild_digest = review.digest;
    fixture.builder.options.reviewed_files = review.reviewed_files;

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 1), artifacts.len);
    try testing.expectEqualStrings("dynamic-explicit-addon", artifacts[0].package_name);
}

test "PackageBuilder rejects an explicitly selected disabled dynamic member" {
    const allocator = testing.allocator;
    const io = testing.io;
    const pkgbuild_content =
        \\_build_addon=no
        \\pkgbase=dynamic-disabled
        \\pkgname=("$pkgbase")
        \\[ "$_build_addon" = yes ] && pkgname+=("$pkgbase-addon")
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\_package() { mkdir -p "$pkgdir/usr/share/dynamic-disabled"; }
        \\_package-addon() { mkdir -p "$pkgdir/usr/share/dynamic-disabled-addon"; }
        \\for _p in "${pkgname[@]}"; do
        \\  eval "package_$_p() {
        \\    $(declare -f "_package${_p#$pkgbase}")
        \\    _package${_p#$pkgbase}
        \\  }"
        \\done
    ;
    var fixture = try Fixture.create(allocator, pkgbuild_content, null, "dynamic-disabled");
    defer fixture.destroy();
    allocator.free(fixture.requested_names[0]);
    fixture.requested_names[0] = try allocator.dupe(u8, "dynamic-disabled-addon");

    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "PKGBUILD", .data = pkgbuild_content });
    const pkgbuild_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "PKGBUILD" });
    defer allocator.free(pkgbuild_path);
    var review = try builder_mod.preparePkgbuildReview(
        allocator,
        io,
        fixture.build_dir,
        pkgbuild_content,
        fixture.package_builds,
    );
    defer review.deinit();
    fixture.builder.options.pkgbuild_path = pkgbuild_path;
    fixture.builder.options.reviewed_pkgbuild_digest = review.digest;
    fixture.builder.options.reviewed_files = review.reviewed_files;

    try testing.expectError(error.BuildFailed, fixture.builder.BuildPackage());
}

test "PackageBuilder requires supplemental review for a dynamically discovered local source" {
    const allocator = testing.allocator;
    const io = testing.io;
    const pkgbuild_content =
        \\pkgname=dynamic-local-review
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=("$(printf local.patch)")
        \\sha256sums=('SKIP')
        \\package() {
        \\  printf ran > "$startdir/package-ran"
        \\}
    ;
    var fixture = try Fixture.create(allocator, pkgbuild_content, null, null);
    defer fixture.destroy();
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "PKGBUILD", .data = pkgbuild_content });
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "local.patch", .data = "review me\n" });
    const pkgbuild_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "PKGBUILD" });
    defer allocator.free(pkgbuild_path);
    var review = try builder_mod.preparePkgbuildReview(
        allocator,
        io,
        fixture.build_dir,
        pkgbuild_content,
        fixture.package_builds,
    );
    defer review.deinit();
    try testing.expectEqual(@as(usize, 0), review.related_files.len);
    fixture.builder.options.pkgbuild_path = pkgbuild_path;
    fixture.builder.options.reviewed_pkgbuild_digest = review.digest;

    try testing.expectError(error.BuildFailed, fixture.builder.BuildPackage());
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, "package-ran", .{}));
}

test "PackageBuilder rejects a legacy unwritable package tree" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\arch=('any')
        \\package() {
        \\  mkdir -p "$pkgdir/usr"
        \\}
    , null, null);
    defer fixture.destroy();

    try fixture.temporary.dir.createDirPath(io, "pkg/demo");
    try fixture.temporary.dir.setFilePermissions(io, "pkg", .fromMode(0o555), .{});
    defer fixture.temporary.dir.setFilePermissions(io, "pkg", .fromMode(0o755), .{}) catch {};

    try testing.expectError(error.BuildDirectoryNotWritable, fixture.builder.BuildPackage());
}

test "PackageBuilder cannot perform privileged package filesystem operations" {
    const allocator = testing.allocator;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\arch=('any')
        \\package() {
        \\  mkdir -p "$pkgdir/usr/share/demo"
        \\  mknod "$pkgdir/usr/share/demo/device" c 1 3
        \\}
    , null, null);
    defer fixture.destroy();

    try testing.expectError(
        error.BuildFailed,
        fixture.builder.BuildPackage(),
    );
}

test "PackageBuilder simulates root ownership without host chown" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\arch=('any')
        \\package() {
        \\  mkdir -p "$pkgdir/usr/share/demo"
        \\  printf payload > "$pkgdir/usr/share/demo/data"
        \\  chown root:root "$pkgdir/usr/share/demo/data"
        \\  install -o root -g root -m 0644 /dev/null "$pkgdir/usr/share/demo/installed"
        \\}
    , null, null);
    defer fixture.destroy();

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);

    const staged_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "pkg/demo/usr/share/demo/data" });
    defer allocator.free(staged_path);
    var stat_result = try process_runner.run(allocator, io, &.{ "stat", "-c", "%u", staged_path }, null, null);
    defer stat_result.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), stat_result.exit_code);
    var expected_uid_buffer: [32]u8 = undefined;
    const expected_uid = try std.fmt.bufPrint(&expected_uid_buffer, "{d}", .{std.os.linux.geteuid()});
    try testing.expectEqualStrings(expected_uid, std.mem.trim(u8, stat_result.stdout, " \t\r\n"));

    var reader = try archive.Reader.init(allocator, artifacts[0].path);
    defer reader.deinit();
    var saw_data = false;
    var saw_installed = false;
    while (try reader.next()) |entry| {
        if (std.mem.eql(u8, entry.path, "usr/share/demo/data")) saw_data = true;
        if (std.mem.eql(u8, entry.path, "usr/share/demo/installed")) saw_installed = true;
        try testing.expectEqual(@as(i64, 0), entry.uid);
        try testing.expectEqual(@as(i64, 0), entry.gid);
    }
    try testing.expect(saw_data);
    try testing.expect(saw_installed);
}

test "PackageBuilder preserves non-root virtual ownership and special modes" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\arch=('any')
        \\package() {
        \\  mkdir -p "$pkgdir/usr/share/demo"
        \\  touch "$pkgdir/usr/share/demo/data"
        \\  chmod 4755 "$pkgdir/usr/share/demo/data"
        \\  chown 42:84 "$pkgdir/usr/share/demo/data"
        \\  chgrp 50 "$pkgdir/usr/share/demo/data"
        \\  install --mode=2755 --owner=42 -g50 /dev/null "$pkgdir/usr/share/demo/installed"
        \\}
    , null, null);
    defer fixture.destroy();

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);

    var reader = try archive.Reader.init(allocator, artifacts[0].path);
    defer reader.deinit();
    var saw_data = false;
    var saw_installed = false;
    while (try reader.next()) |entry| {
        if (std.mem.eql(u8, entry.path, "usr/share/demo/data")) {
            saw_data = true;
            try testing.expectEqual(@as(i64, 42), entry.uid);
            try testing.expectEqual(@as(i64, 50), entry.gid);
            try testing.expectEqual(@as(u32, 0o4755), entry.permissions);
        } else if (std.mem.eql(u8, entry.path, "usr/share/demo/installed")) {
            saw_installed = true;
            try testing.expectEqual(@as(i64, 42), entry.uid);
            try testing.expectEqual(@as(i64, 50), entry.gid);
            try testing.expectEqual(@as(u32, 0o2755), entry.permissions);
        } else {
            try testing.expectEqual(@as(i64, 0), entry.uid);
            try testing.expectEqual(@as(i64, 0), entry.gid);
        }
    }
    try testing.expect(saw_data);
    try testing.expect(saw_installed);

    const mtree_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "pkg/demo/.MTREE" });
    defer allocator.free(mtree_path);
    var gzip = try process_runner.run(allocator, io, &.{ "gzip", "-dc", mtree_path }, null, null);
    defer gzip.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), gzip.exit_code);
    var lines = std.mem.splitScalar(u8, gzip.stdout, '\n');
    var saw_data_metadata = false;
    var saw_installed_metadata = false;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "usr/share/demo/data") != null) {
            saw_data_metadata = true;
            try testing.expect(std.mem.indexOf(u8, line, "uid=42") != null);
            try testing.expect(std.mem.indexOf(u8, line, "gid=50") != null);
            try testing.expect(std.mem.indexOf(u8, line, "mode=4755") != null);
        }
        if (std.mem.indexOf(u8, line, "usr/share/demo/installed") != null) {
            saw_installed_metadata = true;
            try testing.expect(std.mem.indexOf(u8, line, "uid=42") != null);
            try testing.expect(std.mem.indexOf(u8, line, "gid=50") != null);
            try testing.expect(std.mem.indexOf(u8, line, "mode=2755") != null);
        }
    }
    try testing.expect(saw_data_metadata);
    try testing.expect(saw_installed_metadata);
}

test "PackageBuilder virtual ownership follows identities and recursive snapshots" {
    const allocator = testing.allocator;
    var fixture = try Fixture.create(allocator,
        \\pkgname=identity-demo
        \\pkgver=1
        \\arch=('any')
        \\package() {
        \\  mkdir -p "$pkgdir/usr/share/identity/tree"
        \\  touch "$pkgdir/usr/share/identity/renamed"
        \\  chown 41:81 "$pkgdir/usr/share/identity/renamed"
        \\  mv "$pkgdir/usr/share/identity/renamed" "$pkgdir/usr/share/identity/final"
        \\  touch "$pkgdir/usr/share/identity/replaced"
        \\  chown 42:82 "$pkgdir/usr/share/identity/replaced"
        \\  rm "$pkgdir/usr/share/identity/replaced"
        \\  touch "$pkgdir/usr/share/identity/replaced"
        \\  touch "$pkgdir/usr/share/identity/tree/existing"
        \\  chown -R 43:83 "$pkgdir/usr/share/identity/tree"
        \\  touch "$pkgdir/usr/share/identity/tree/later"
        \\  touch "$pkgdir/usr/share/identity/hard"
        \\  ln "$pkgdir/usr/share/identity/hard" "$pkgdir/usr/share/identity/hard-link"
        \\  chown 45:85 "$pkgdir/usr/share/identity/hard"
        \\  touch "$pkgdir/usr/share/identity/symlink-target"
        \\  ln -s symlink-target "$pkgdir/usr/share/identity/symlink"
        \\  chown -h 46:86 "$pkgdir/usr/share/identity/symlink"
        \\}
    , null, null);
    defer fixture.destroy();

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    var reader = try archive.Reader.init(allocator, artifacts[0].path);
    defer reader.deinit();
    var checked: usize = 0;
    while (try reader.next()) |entry| {
        const entry_path = std.mem.trimEnd(u8, entry.path, "/");
        if (std.mem.eql(u8, entry_path, "usr/share/identity/final")) {
            checked += 1;
            try testing.expectEqual(@as(i64, 41), entry.uid);
            try testing.expectEqual(@as(i64, 81), entry.gid);
        } else if (std.mem.eql(u8, entry_path, "usr/share/identity/replaced") or
            std.mem.eql(u8, entry_path, "usr/share/identity/tree/later"))
        {
            checked += 1;
            try testing.expectEqual(@as(i64, 0), entry.uid);
            try testing.expectEqual(@as(i64, 0), entry.gid);
        } else if (std.mem.eql(u8, entry_path, "usr/share/identity/tree") or
            std.mem.eql(u8, entry_path, "usr/share/identity/tree/existing"))
        {
            checked += 1;
            try testing.expectEqual(@as(i64, 43), entry.uid);
            try testing.expectEqual(@as(i64, 83), entry.gid);
        } else if (std.mem.eql(u8, entry_path, "usr/share/identity/hard") or
            std.mem.eql(u8, entry_path, "usr/share/identity/hard-link"))
        {
            checked += 1;
            try testing.expectEqual(@as(i64, 45), entry.uid);
            try testing.expectEqual(@as(i64, 85), entry.gid);
        } else if (std.mem.eql(u8, entry_path, "usr/share/identity/symlink")) {
            checked += 1;
            try testing.expectEqual(archive.EntryKind.symbolic_link, entry.kind);
            try testing.expectEqual(@as(i64, 46), entry.uid);
            try testing.expectEqual(@as(i64, 86), entry.gid);
        }
    }
    try testing.expectEqual(@as(usize, 8), checked);
}

test "PackageBuilder isolates virtual ownership between split members" {
    const allocator = testing.allocator;
    const content =
        \\pkgbase=ownership-split
        \\pkgname=('ownership-one' 'ownership-two')
        \\pkgver=1
        \\arch=('any')
        \\package_ownership-one() {
        \\  mkdir -p "$pkgdir/usr/share/ownership"
        \\  touch "$pkgdir/usr/share/ownership/data"
        \\  chown 44:84 "$pkgdir/usr/share/ownership/data"
        \\}
        \\package_ownership-two() {
        \\  mkdir -p "$pkgdir/usr/share/ownership"
        \\  touch "$pkgdir/usr/share/ownership/data"
        \\}
    ;
    const requested = [_][]const u8{ "ownership-one", "ownership-two" };
    var fixture = try Fixture.createMany(allocator, content, &requested, null);
    defer fixture.destroy();

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    for (artifacts, 0..) |artifact, index| {
        var reader = try archive.Reader.init(allocator, artifact.path);
        defer reader.deinit();
        var saw_data = false;
        while (try reader.next()) |entry| {
            if (!std.mem.eql(u8, entry.path, "usr/share/ownership/data")) continue;
            saw_data = true;
            try testing.expectEqual(@as(i64, if (index == 0) 44 else 0), entry.uid);
            try testing.expectEqual(@as(i64, if (index == 0) 84 else 0), entry.gid);
        }
        try testing.expect(saw_data);
    }
}

test "PackageBuilder rejects malformed virtual ownership" {
    const allocator = testing.allocator;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\arch=('any')
        \\package() {
        \\  mkdir -p "$pkgdir/usr/share/demo"
        \\  install --owner= /dev/null "$pkgdir/usr/share/demo/installed"
        \\}
    , null, null);
    defer fixture.destroy();

    try testing.expectError(
        error.PrivilegedPackageOperationUnsupported,
        fixture.builder.BuildPackage(),
    );
}

test "PackageBuilder rejects unresolved and out-of-package virtual ownership" {
    const allocator = testing.allocator;
    var unresolved = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\arch=('any')
        \\package() {
        \\  mkdir -p "$pkgdir/usr/share/demo"
        \\  touch "$pkgdir/usr/share/demo/data"
        \\  chown shelly-owner-that-does-not-exist "$pkgdir/usr/share/demo/data"
        \\}
    , null, null);
    defer unresolved.destroy();
    try testing.expectError(
        error.PrivilegedPackageOperationUnsupported,
        unresolved.builder.BuildPackage(),
    );

    var outside = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\arch=('any')
        \\package() {
        \\  touch "$startdir/outside"
        \\  chown 42:84 "$startdir/outside"
        \\}
    , null, null);
    defer outside.destroy();
    try testing.expectError(
        error.PrivilegedPackageOperationUnsupported,
        outside.builder.BuildPackage(),
    );
}

test "PackageBuilder runs source-less execution steps inside srcdir" {
    const allocator = testing.allocator;
    const io = testing.io;

    var capture: CompletionCapture = .{};
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1.0
        \\arch=('any')
        \\
        \\build() {
        \\  echo built > build-marker
        \\}
        \\package() {
        \\  mkdir -p "$pkgdir"
        \\  echo packaged > "$pkgdir/package-marker"
        \\}
    , .{ .function = CompletionCapture.handle, .data = &capture }, null);
    defer fixture.destroy();

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 1), artifacts.len);
    const artifact = artifacts[0];

    // makepkg enters $srcdir even when the PKGBUILD has no sources.
    try fixture.temporary.dir.access(io, "src/build-marker", .{});
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, "build-marker", .{}));
    try fixture.temporary.dir.access(io, "pkg/demo/package-marker", .{});

    // The artifact identifies the built package and owns its storage
    // (deinit above must not free borrowed memory).
    try testing.expectEqualStrings("demo", artifact.package_name);
    try testing.expect(artifact.path.len > 0);
    try testing.expect(std.mem.endsWith(u8, artifact.path, "demo-1.0-any.pkg.tar.zst"));
    try std.Io.Dir.cwd().access(io, artifact.path, .{});

    // The operation completed successfully.
    try testing.expectEqual(op_context.CompletionStatus.success, capture.completion.?);
}

test "PackageBuilder provides makepkg messaging helpers to lifecycle steps" {
    const allocator = testing.allocator;
    const io = testing.io;

    var fixture = try Fixture.create(allocator,
        \\pkgname=messaging-demo
        \\pkgver=1.0
        \\arch=('any')
        \\
        \\build() {
        \\  msg 'building %s' "$pkgname"
        \\  msg2 'compiling'
        \\  plain 'detail line'
        \\  plainerr 'detail on stderr'
        \\  warning 'non-fatal warning'
        \\  error 'non-fatal error message'
        \\  echo built > build-marker
        \\}
        \\package() {
        \\  mkdir -p "$pkgdir"
        \\  echo packaged > "$pkgdir/package-marker"
        \\}
    , null, null);
    defer fixture.destroy();

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 1), artifacts.len);

    // Like makepkg, error() reports without aborting the step.
    try fixture.temporary.dir.access(io, "src/build-marker", .{});
    try fixture.temporary.dir.access(io, "pkg/messaging-demo/package-marker", .{});
}

test "PackageBuilder emits makepkg-compatible BUILDINFO and MTREE metadata" {
    const allocator = testing.allocator;
    const io = testing.io;
    const pkgbuild_content =
        \\pkgname=metadata-demo
        \\pkgver=2
        \\pkgrel=3
        \\arch=('any')
        \\options=('!lto' '!debug')
        \\package() {
        \\  mkdir -p "$pkgdir/usr/share/metadata-demo"
        \\  printf 'artifact payload\n' > "$pkgdir/usr/share/metadata-demo/data"
        \\}
    ;
    var fixture = try Fixture.create(allocator, pkgbuild_content, null, null);
    defer fixture.destroy();

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    const build_info = try readPackageEntry(allocator, artifacts[0].path, ".BUILDINFO");
    defer allocator.free(build_info);
    var pkgbuild_digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pkgbuild_content, &pkgbuild_digest, .{});
    const digest_hex = std.fmt.bytesToHex(pkgbuild_digest, .lower);
    const digest_line = try std.fmt.allocPrint(allocator, "pkgbuild_sha256sum = {s}\n", .{digest_hex});
    defer allocator.free(digest_line);
    const buildtool_line = try std.fmt.allocPrint(allocator, "buildtoolver = {s}\n", .{package_options.version});
    defer allocator.free(buildtool_line);
    try testing.expect(std.mem.indexOf(u8, build_info, digest_line) != null);
    try testing.expect(std.mem.indexOf(u8, build_info, buildtool_line) != null);
    try testing.expect(std.mem.indexOf(u8, build_info, "buildenv = !distcc\n") != null);
    try testing.expect(std.mem.indexOf(u8, build_info, "buildenv = (!distcc") == null);
    try testing.expect(std.mem.indexOf(u8, build_info, "options = strip\n") != null);
    try testing.expect(std.mem.indexOf(u8, build_info, "options = !lto\n") != null);
    try testing.expect(std.mem.indexOf(u8, build_info, "installed = base-1-1-any\n") != null);
    try testing.expect(std.mem.indexOf(u8, build_info, "startdir = ") != null);

    const pkg_info = try readPkgInfo(allocator, artifacts[0].path);
    defer allocator.free(pkg_info);
    try testing.expect(std.mem.indexOf(u8, pkg_info, "packager = Unknown Packager\n") != null);

    const mtree_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "pkg/metadata-demo/.MTREE" });
    defer allocator.free(mtree_path);
    var gzip = try process_runner.run(allocator, io, &.{ "gzip", "-dc", mtree_path }, null, null);
    defer gzip.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), gzip.exit_code);
    var payload_digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("artifact payload\n", &payload_digest, .{});
    const payload_hex = std.fmt.bytesToHex(payload_digest, .lower);
    try testing.expect(std.mem.indexOf(u8, gzip.stdout, &payload_hex) != null);
    try testing.expect(std.mem.indexOf(u8, gzip.stdout, "sha256digest=") != null);
}

test "PackageBuilder exports configured build environment to lifecycle steps" {
    const allocator = testing.allocator;
    const pkgbuild_content =
        \\pkgname=environment-demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\package() {
        \\  mkdir -p "$pkgdir/usr/share/environment-demo"
        \\  printf '%s\n' "$CPPFLAGS|$CFLAGS|$CXXFLAGS|$LDFLAGS|$LTOFLAGS|$MAKEFLAGS|$CHOST|$DISTCC_HOSTS|$PATH" > "$pkgdir/usr/share/environment-demo/environment"
        \\}
    ;
    var fixture = try Fixture.create(allocator, pkgbuild_content, null, null);
    defer fixture.destroy();
    fixture.builder.shellybuild_config.build.cppflags = &.{"-D_FORTIFY_SOURCE=3"};
    fixture.builder.shellybuild_config.build.cflags = &.{ "-O3", "-pipe" };
    fixture.builder.shellybuild_config.build.cxxflags = &.{"-O3"};
    fixture.builder.shellybuild_config.build.ldflags = &.{"-Wl,-z,now"};
    fixture.builder.shellybuild_config.build.ltoflags = &.{"-flto=auto"};
    fixture.builder.shellybuild_config.build.makeflags = &.{"-j8"};
    fixture.builder.shellybuild_config.build.distcc_hosts = &.{"builder/8"};
    fixture.builder.shellybuild_config.build.ccache = true;
    fixture.builder.shellybuild_config.build.distcc = true;

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    const environment = try readPackageEntry(allocator, artifacts[0].path, "usr/share/environment-demo/environment");
    defer allocator.free(environment);
    try testing.expect(std.mem.indexOf(u8, environment, "-D_FORTIFY_SOURCE=3|-O3 -pipe|-O3|-Wl,-z,now|-flto=auto|-j8|x86_64-pc-linux-gnu|builder/8|") != null);
    try testing.expect(std.mem.indexOf(u8, environment, "/usr/lib/ccache/bin:/usr/lib/distcc/bin:") != null);
}

test "PackageBuilder establishes one SOURCE_DATE_EPOCH for PKGBUILD evaluation and metadata" {
    const allocator = testing.allocator;
    const io = testing.io;
    const pkgbuild_content =
        \\pkgname=source-date-epoch-demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\_top_level_epoch="${SOURCE_DATE_EPOCH}"
        \\prepare() {
        \\  test -n "$SOURCE_DATE_EPOCH"
        \\  test "$SOURCE_DATE_EPOCH" = "$_top_level_epoch"
        \\  printf '%s\n' "$SOURCE_DATE_EPOCH" > "$startdir/epochs"
        \\}
        \\pkgver() {
        \\  printf '%s\n' "$SOURCE_DATE_EPOCH" >> "$startdir/epochs"
        \\  printf '1'
        \\}
        \\build() {
        \\  printf '%s\n' "$SOURCE_DATE_EPOCH" >> "$startdir/epochs"
        \\  date -u -d "@${SOURCE_DATE_EPOCH}" '+%Y-%m-%dT%H:%M:%S.000Z' > "$startdir/build-time"
        \\}
        \\check() {
        \\  printf '%s\n' "$SOURCE_DATE_EPOCH" >> "$startdir/epochs"
        \\}
        \\package() {
        \\  printf '%s\n' "$SOURCE_DATE_EPOCH" >> "$startdir/epochs"
        \\  mkdir -p "$pkgdir/usr/share/source-date-epoch-demo"
        \\  cp "$startdir/epochs" "$startdir/build-time" "$pkgdir/usr/share/source-date-epoch-demo/"
        \\}
    ;

    // Use an explicitly empty environment so this exercises Shelly's default
    // instead of inheriting a CI-provided SOURCE_DATE_EPOCH.
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    const environ: std.process.Environ = .{
        .block = try environment.createPosixBlock(allocator, .{}),
    };
    defer environ.block.deinit(allocator);

    var fixture = try Fixture.create(allocator, pkgbuild_content, null, null);
    defer fixture.destroy();
    fixture.builder.environ = environ;
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "PKGBUILD", .data = pkgbuild_content });
    const pkgbuild_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "PKGBUILD" });
    defer allocator.free(pkgbuild_path);
    var review = try builder_mod.preparePkgbuildReview(
        allocator,
        io,
        fixture.build_dir,
        pkgbuild_content,
        fixture.package_builds,
    );
    defer review.deinit();
    fixture.builder.options.pkgbuild_path = pkgbuild_path;
    fixture.builder.options.reviewed_pkgbuild_digest = review.digest;
    fixture.builder.options.reviewed_files = review.reviewed_files;

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);

    const epochs = try readPackageEntry(
        allocator,
        artifacts[0].path,
        "usr/share/source-date-epoch-demo/epochs",
    );
    defer allocator.free(epochs);
    var lines = std.mem.tokenizeScalar(u8, epochs, '\n');
    const epoch = lines.next() orelse return error.MissingSourceDateEpoch;
    _ = try std.fmt.parseInt(i64, epoch, 10);
    var phase_count: usize = 1;
    while (lines.next()) |phase_epoch| : (phase_count += 1)
        try testing.expectEqualStrings(epoch, phase_epoch);
    try testing.expectEqual(@as(usize, 5), phase_count);

    const build_time = try readPackageEntry(
        allocator,
        artifacts[0].path,
        "usr/share/source-date-epoch-demo/build-time",
    );
    defer allocator.free(build_time);
    try testing.expect(build_time.len > 1);

    const expected_builddate = try std.fmt.allocPrint(allocator, "builddate = {s}\n", .{epoch});
    defer allocator.free(expected_builddate);
    const pkg_info = try readPkgInfo(allocator, artifacts[0].path);
    defer allocator.free(pkg_info);
    try testing.expect(std.mem.indexOf(u8, pkg_info, expected_builddate) != null);
    const build_info = try readPackageEntry(allocator, artifacts[0].path, ".BUILDINFO");
    defer allocator.free(build_info);
    try testing.expect(std.mem.indexOf(u8, build_info, expected_builddate) != null);
}

test "PackageBuilder preserves a caller-provided SOURCE_DATE_EPOCH" {
    const allocator = testing.allocator;
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("SOURCE_DATE_EPOCH", "1700000000");
    const environ: std.process.Environ = .{
        .block = try environment.createPosixBlock(allocator, .{}),
    };
    defer environ.block.deinit(allocator);

    var fixture = try Fixture.create(allocator,
        \\pkgname=inherited-source-date-epoch
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\package() {
        \\  mkdir -p "$pkgdir/usr/share/inherited-source-date-epoch"
        \\  printf '%s\n' "$SOURCE_DATE_EPOCH" > "$pkgdir/usr/share/inherited-source-date-epoch/epoch"
        \\}
    , null, null);
    defer fixture.destroy();
    fixture.builder.environ = environ;

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    const epoch = try readPackageEntry(
        allocator,
        artifacts[0].path,
        "usr/share/inherited-source-date-epoch/epoch",
    );
    defer allocator.free(epoch);
    try testing.expectEqualStrings("1700000000\n", epoch);
    const pkg_info = try readPkgInfo(allocator, artifacts[0].path);
    defer allocator.free(pkg_info);
    try testing.expect(std.mem.indexOf(u8, pkg_info, "builddate = 1700000000\n") != null);
}

test "PackageBuilder rejects an invalid SOURCE_DATE_EPOCH before PKGBUILD execution" {
    const allocator = testing.allocator;
    const io = testing.io;
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("SOURCE_DATE_EPOCH", "not-a-timestamp");
    const environ: std.process.Environ = .{
        .block = try environment.createPosixBlock(allocator, .{}),
    };
    defer environ.block.deinit(allocator);

    var fixture = try Fixture.create(allocator,
        \\pkgname=invalid-source-date-epoch
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\package() { touch "$startdir/executed"; }
    , null, null);
    defer fixture.destroy();
    fixture.builder.environ = environ;

    try testing.expectError(error.InvalidSourceDateEpoch, fixture.builder.BuildPackage());
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, "executed", .{}));
}

test "PackageBuilder honors PKGBUILD build flag make flag and LTO negations" {
    const allocator = testing.allocator;
    const pkgbuild_content =
        \\pkgname=environment-negation-demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\options=('!buildflags' '!makeflags' '!lto')
        \\package() {
        \\  mkdir -p "$pkgdir/usr/share/environment-negation-demo"
        \\  printf '%s\n' "${CPPFLAGS-unset}|${CFLAGS-unset}|${CXXFLAGS-unset}|${LDFLAGS-unset}|${LTOFLAGS-unset}|${MAKEFLAGS-unset}|$CHOST|${DISTCC_HOSTS-unset}" > "$pkgdir/usr/share/environment-negation-demo/environment"
        \\}
    ;
    var fixture = try Fixture.create(allocator, pkgbuild_content, null, null);
    defer fixture.destroy();
    fixture.builder.shellybuild_config.build.cppflags = &.{"-D_FORTIFY_SOURCE=3"};
    fixture.builder.shellybuild_config.build.cflags = &.{"-O3"};
    fixture.builder.shellybuild_config.build.cxxflags = &.{"-O3"};
    fixture.builder.shellybuild_config.build.ldflags = &.{"-Wl,-z,now"};
    fixture.builder.shellybuild_config.build.ltoflags = &.{"-flto=auto"};
    fixture.builder.shellybuild_config.build.makeflags = &.{"-j8"};

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    const environment = try readPackageEntry(allocator, artifacts[0].path, "usr/share/environment-negation-demo/environment");
    defer allocator.free(environment);
    try testing.expectEqualStrings("unset|unset|unset|unset|unset|unset|x86_64-pc-linux-gnu|unset\n", environment);
}

test "PackageBuilder packages exact reviewed install and changelog files" {
    const allocator = testing.allocator;
    const io = testing.io;
    const pkgbuild_content =
        \\pkgname=install-demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\install=install-demo.install
        \\changelog=install-demo.changelog
        \\package() {
        \\  mkdir -p "$pkgdir/usr/share/install-demo"
        \\}
    ;
    const script_contents =
        "#!/bin/bash\n" ++
        "banner='preserve me exactly'\n" ++
        "touch \"$startdir/install-script-was-executed\"\n" ++
        "helper() { printf '%s\\n' \"$banner\"; }\n" ++
        "pre_install() { helper \"$1\"; }\n" ++
        "post_install() { true; }\n" ++
        "pre_upgrade() { printf '%s %s\\n' \"$1\" \"$2\"; }\n" ++
        "post_upgrade() { true; }\n" ++
        "pre_remove() { true; }\n" ++
        "post_remove() { true; }\n";
    const changelog_contents = "2026-08-17  Split metadata support\n";

    var fixture = try Fixture.create(allocator, pkgbuild_content, null, null);
    defer fixture.destroy();
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "PKGBUILD", .data = pkgbuild_content });
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "install-demo.install", .data = script_contents });
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "install-demo.changelog", .data = changelog_contents });
    const pkgbuild_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "PKGBUILD" });
    defer allocator.free(pkgbuild_path);
    var review = try builder_mod.preparePkgbuildReview(
        allocator,
        io,
        fixture.build_dir,
        pkgbuild_content,
        fixture.package_builds,
    );
    defer review.deinit();
    try testing.expectEqual(@as(usize, 1), review.install_scripts.len);
    try testing.expectEqual(@as(usize, 2), review.reviewed_files.len);
    inline for (std.meta.tags(install_script.Hook)) |hook|
        try testing.expect(review.install_scripts[0].effectiveHook(hook) != null);

    fixture.builder.options.pkgbuild_path = pkgbuild_path;
    fixture.builder.options.reviewed_pkgbuild_digest = review.digest;
    var substituted_script = try install_script.Script.init(
        allocator,
        "install-demo.install",
        "post_install() { false; }\n",
    );
    defer substituted_script.deinit(allocator);
    const substituted_scripts = [_]install_script.Script{substituted_script};
    fixture.builder.options.install_scripts = &substituted_scripts;
    try testing.expectError(error.ReviewedPkgbuildChanged, fixture.builder.BuildPackage());
    fixture.builder.options.install_scripts = review.install_scripts;
    fixture.builder.options.reviewed_files = review.reviewed_files;
    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectError(
        error.FileNotFound,
        fixture.temporary.dir.access(io, "install-script-was-executed", .{}),
    );

    const packaged_script = try readPackageEntry(allocator, artifacts[0].path, ".INSTALL");
    defer allocator.free(packaged_script);
    try testing.expectEqualStrings(script_contents, packaged_script);
    const packaged_changelog = try readPackageEntry(allocator, artifacts[0].path, ".CHANGELOG");
    defer allocator.free(packaged_changelog);
    try testing.expectEqualStrings(changelog_contents, packaged_changelog);

    var reader = try archive.Reader.init(allocator, artifacts[0].path);
    defer reader.deinit();
    var saw_install = false;
    var saw_changelog = false;
    while (try reader.next()) |entry| {
        if (std.mem.eql(u8, entry.path, ".INSTALL")) {
            saw_install = true;
            try testing.expectEqual(@as(u32, 0o644), entry.permissions);
        }
        if (std.mem.eql(u8, entry.path, ".CHANGELOG")) {
            saw_changelog = true;
            try testing.expectEqual(@as(u32, 0o644), entry.permissions);
        }
    }
    try testing.expect(saw_install);
    try testing.expect(saw_changelog);
}

test "PackageBuilder strips ELF debug sections unless PKGBUILD disables strip" {
    const allocator = testing.allocator;
    const io = testing.io;
    const common =
        \\pkgname=strip-demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('x86_64')
        \\build() {
        \\  printf 'int main(void) { return 0; }\n' > demo.c
        \\  cc -g -o demo demo.c
        \\}
        \\package() {
        \\  install -Dm755 demo "$pkgdir/usr/bin/strip-demo"
        \\}
    ;
    var stripped_fixture = try Fixture.create(allocator, common, null, null);
    defer stripped_fixture.destroy();
    const stripped_artifacts = try stripped_fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, stripped_artifacts);
    const stripped_path = try std.fs.path.join(allocator, &.{ stripped_fixture.build_dir, "pkg/strip-demo/usr/bin/strip-demo" });
    defer allocator.free(stripped_path);
    var stripped_sections = try process_runner.run(allocator, io, &.{ "readelf", "-S", stripped_path }, null, null);
    defer stripped_sections.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), stripped_sections.exit_code);
    try testing.expect(std.mem.indexOf(u8, stripped_sections.stdout, ".debug_info") == null);

    const no_strip =
        \\pkgname=strip-demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('x86_64')
        \\build() {
        \\  printf 'int main(void) { return 0; }\n' > demo.c
        \\  cc -g -o demo demo.c
        \\}
        \\package() {
        \\  options=('!strip')
        \\  install -Dm755 demo "$pkgdir/usr/bin/strip-demo"
        \\}
    ;
    var unstripped_fixture = try Fixture.create(allocator, no_strip, null, null);
    defer unstripped_fixture.destroy();
    const unstripped_artifacts = try unstripped_fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, unstripped_artifacts);
    const unstripped_path = try std.fs.path.join(allocator, &.{ unstripped_fixture.build_dir, "pkg/strip-demo/usr/bin/strip-demo" });
    defer allocator.free(unstripped_path);
    var unstripped_sections = try process_runner.run(allocator, io, &.{ "readelf", "-S", unstripped_path }, null, null);
    defer unstripped_sections.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), unstripped_sections.exit_code);
    try testing.expect(std.mem.indexOf(u8, unstripped_sections.stdout, ".debug_info") != null);
}

test "PackageBuilder runs local declarations and reviewed helper functions inside package steps" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=qwen-code-bin
        \\pkgver=1
        \\pkgrel=1
        \\arch=('x86_64')
        \\_target_name() {
        \\  local suffix=cli
        \\  printf '%s-%s' "$pkgname" "$suffix"
        \\}
        \\package() {
        \\  local appdir="$pkgdir/usr/lib/$pkgname"
        \\  mkdir -p "$appdir"
        \\  _target_name > "$appdir/target"
        \\}
    , null, null);
    defer fixture.destroy();

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    const target = try fixture.temporary.dir.readFileAlloc(
        io,
        "pkg/qwen-code-bin/usr/lib/qwen-code-bin/target",
        allocator,
        .unlimited,
    );
    defer allocator.free(target);
    try testing.expectEqualStrings("qwen-code-bin-cli", target);
}

test "PackageBuilder accepts b2 checksums and honors noextract" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=cline-cli
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('payload.tar.gz')
        \\noextract=('payload.tar.gz')
        \\b2sums=('3571ea965605821dbb49046a8de67321531bcefe1bb1d68282eed4ebdaff4f7feb63f710cede300638d3e44f825e3f3e436059d290f4d2749784bf01020f684e')
        \\package() {
        \\  install -Dm644 "$srcdir/payload.tar.gz" "$pkgdir/usr/share/cline-cli/payload.tar.gz"
        \\}
    , null, null);
    defer fixture.destroy();
    fixture.builder.options.sources_prepared = false;
    try fixture.temporary.dir.deleteTree(io, "src");
    try fixture.temporary.dir.writeFile(io, .{
        .sub_path = "payload.tar.gz",
        .data = "opaque archive payload",
    });

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try fixture.temporary.dir.access(io, "src/payload.tar.gz", .{});
    try fixture.temporary.dir.access(io, "pkg/cline-cli/usr/share/cline-cli/payload.tar.gz", .{});
}

test "PackageBuilder stages and verifies local sources before build steps" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('helper.sh')
        \\sha256sums=('a9f2d25d1f71f8065e2119e538bde8846570fcdad320388236e99d9e225c290d')
        \\build() {
        \\  test "$(cat "$srcdir/helper.sh")" = reviewed
        \\}
        \\package() {
        \\  mkdir -p "$pkgdir/usr/share/demo"
        \\  cp "$srcdir/helper.sh" "$pkgdir/usr/share/demo/helper.sh"
        \\}
    , null, null);
    defer fixture.destroy();
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "helper.sh", .data = "reviewed\n" });
    fixture.builder.options.sources_prepared = false;
    try fixture.temporary.dir.deleteTree(io, "src");

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 1), artifacts.len);
    try fixture.temporary.dir.access(io, "src/helper.sh", .{});
    try fixture.temporary.dir.access(io, "pkg/demo/usr/share/demo/helper.sh", .{});
}

test "PackageBuilder runs verify after integrity checks and before extraction" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=verify-order
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('verified-input.tar.gz::payload.tar.gz')
        \\sha256sums=('SKIP')
        \\_verify_tokens=(alpha beta)
        \\_verify_helper() {
        \\  test "${_verify_tokens[*]}" = "alpha beta"
        \\}
        \\verify() {
        \\  test "$PWD" = "$startdir"
        \\  test -L "$startdir/verified-input.tar.gz"
        \\  test ! -e "$startdir/demo/source.txt"
        \\  test "$pkgver" = 1
        \\  _verify_helper
        \\  printf 'verified\n' > verify-marker
        \\}
        \\prepare() {
        \\  test "$(cat "$startdir/verify-marker")" = verified
        \\  test "$(cat demo/source.txt)" = extracted
        \\  printf 'prepared\n' > prepare-marker
        \\}
        \\pkgver() {
        \\  test "$(cat prepare-marker)" = prepared
        \\  printf '1.1\n'
        \\}
        \\package() {
        \\  install -Dm644 demo/source.txt "$pkgdir/usr/share/verify-order/source.txt"
        \\}
    , null, null);
    defer fixture.destroy();
    const archive_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "payload.tar.gz" });
    defer allocator.free(archive_path);
    try archive.writeFixture(allocator, archive_path, .gzip, &.{
        .{ .path = "demo/source.txt", .contents = "extracted\n" },
    });
    fixture.builder.options.sources_prepared = false;
    fixture.builder.options.skip_source_pgp_verification = false;
    fixture.builder.options.run_verify = true;
    try fixture.temporary.dir.deleteTree(io, "src");

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 1), artifacts.len);
    try testing.expect(std.mem.indexOf(u8, artifacts[0].path, "verify-order-1.1-1-any") != null);
    try fixture.temporary.dir.access(io, "verify-marker", .{});
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, "verified-input.tar.gz", .{}));
    try fixture.temporary.dir.access(io, "src/verified-input.tar.gz", .{});
    try fixture.temporary.dir.access(io, "src/prepare-marker", .{});
    try fixture.temporary.dir.access(io, "pkg/verify-order/usr/share/verify-order/source.txt", .{});
}

test "PackageBuilder verify failure preserves the committed src tree" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=verify-failure
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('payload')
        \\sha256sums=('SKIP')
        \\verify() {
        \\  printf 'ran\n' > verify-ran
        \\  return 23
        \\}
        \\prepare() {
        \\  printf 'bad\n' > prepare-ran
        \\}
        \\package() {
        \\  mkdir -p "$pkgdir"
        \\}
    , null, null);
    defer fixture.destroy();
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "payload", .data = "payload\n" });
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "src/retained", .data = "old tree\n" });
    fixture.builder.options.sources_prepared = false;
    fixture.builder.options.skip_source_pgp_verification = false;
    fixture.builder.options.run_verify = true;

    try testing.expectError(error.BuildFailed, fixture.builder.BuildPackage());
    try fixture.temporary.dir.access(io, "src/retained", .{});
    try fixture.temporary.dir.access(io, "verify-ran", .{});
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, "src/verify-ran", .{}));
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, "src/prepare-ran", .{}));
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, ".sources.shelly-staging", .{}));
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, ".src.shelly-staging", .{}));
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, "pkg/verify-failure", .{}));
}

test "PackageBuilder supports noverify and PGP-skip verify policies" {
    const allocator = testing.allocator;
    const io = testing.io;
    const pkgbuild =
        \\pkgname=verify-policy
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=()
        \\verify() {
        \\  return 1
        \\}
        \\package() {
        \\  install -d "$pkgdir/usr/share/verify-policy"
        \\}
    ;

    var noverify = try Fixture.create(allocator, pkgbuild, null, null);
    defer noverify.destroy();
    noverify.builder.options.sources_prepared = false;
    noverify.builder.options.skip_source_pgp_verification = false;
    noverify.builder.options.run_verify = false;
    try noverify.temporary.dir.deleteTree(io, "src");
    const noverify_artifacts = try noverify.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, noverify_artifacts);

    var pgp_skip = try Fixture.create(allocator, pkgbuild, null, null);
    defer pgp_skip.destroy();
    pgp_skip.builder.options.sources_prepared = false;
    pgp_skip.builder.options.skip_source_pgp_verification = true;
    pgp_skip.builder.options.run_verify = true;
    try pgp_skip.temporary.dir.deleteTree(io, "src");
    const pgp_skip_artifacts = try pgp_skip.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, pgp_skip_artifacts);

    var already_prepared = try Fixture.create(allocator, pkgbuild, null, null);
    defer already_prepared.destroy();
    already_prepared.builder.options.sources_prepared = true;
    already_prepared.builder.options.skip_source_pgp_verification = false;
    already_prepared.builder.options.run_verify = true;
    const prepared_artifacts = try already_prepared.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, prepared_artifacts);
}

test "PackageBuilder runs verify once for all split package members" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.createMany(allocator,
        \\pkgbase=verify-split
        \\pkgname=('verify-one' 'verify-two')
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=()
        \\verify() {
        \\  printf 'verified\n' >> verify-count
        \\}
        \\package_verify-one() {
        \\  install -Dm644 "$startdir/verify-count" "$pkgdir/usr/share/verify-one/count"
        \\}
        \\package_verify-two() {
        \\  install -Dm644 "$startdir/verify-count" "$pkgdir/usr/share/verify-two/count"
        \\}
    , &.{ "verify-one", "verify-two" }, null);
    defer fixture.destroy();
    fixture.builder.options.sources_prepared = false;
    fixture.builder.options.skip_source_pgp_verification = false;
    fixture.builder.options.run_verify = true;
    try fixture.temporary.dir.deleteTree(io, "src");

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 2), artifacts.len);
    const count = try fixture.temporary.dir.readFileAlloc(io, "verify-count", allocator, .unlimited);
    defer allocator.free(count);
    try testing.expectEqualStrings("verified\n", count);
}

test "PackageBuilder verifies pinned detached signatures from the user keyring" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('renamed.txt::payload' 'renamed.txt.sig::payload.sig')
        \\sha256sums=('SKIP' 'SKIP')
        \\validpgpkeys=('2E37DFCC9287C8A2F84B2519241A5B24548FAC70')
        \\package() {
        \\  install -Dm644 "$srcdir/renamed.txt" "$pkgdir/usr/share/demo/payload"
        \\}
    , null, null);
    defer fixture.destroy();
    const gnupg_home = try prepareSourcePgpHome(&fixture);
    defer allocator.free(gnupg_home);
    try fixture.temporary.dir.writeFile(io, .{
        .sub_path = "payload",
        .data = "authenticated payload\n",
    });
    try writeBase64Fixture(
        allocator,
        io,
        fixture.temporary.dir,
        "payload.sig",
        source_pgp_signature_base64,
    );
    fixture.builder.options.sources_prepared = false;
    fixture.builder.options.skip_source_pgp_verification = false;
    fixture.builder.options.source_pgp_gnupg_home = gnupg_home;
    try fixture.temporary.dir.deleteTree(io, "src");

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 1), artifacts.len);
    try fixture.temporary.dir.access(io, "src/renamed.txt", .{});
    try fixture.temporary.dir.access(io, "pkg/demo/usr/share/demo/payload", .{});
}

test "PackageBuilder rejects bad signatures atomically unless explicitly skipped" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('payload' 'payload.sig')
        \\sha256sums=('SKIP' 'SKIP')
        \\validpgpkeys=('2E37DFCC9287C8A2F84B2519241A5B24548FAC70')
        \\package() {
        \\  install -Dm644 "$srcdir/payload" "$pkgdir/usr/share/demo/payload"
        \\}
    , null, null);
    defer fixture.destroy();
    const gnupg_home = try prepareSourcePgpHome(&fixture);
    defer allocator.free(gnupg_home);
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "payload", .data = "tampered payload\n" });
    try writeBase64Fixture(
        allocator,
        io,
        fixture.temporary.dir,
        "payload.sig",
        source_pgp_signature_base64,
    );
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "src/retained", .data = "old tree\n" });
    fixture.builder.options.sources_prepared = false;
    fixture.builder.options.skip_source_pgp_verification = false;
    fixture.builder.options.source_pgp_gnupg_home = gnupg_home;

    try testing.expectError(error.BuildFailed, fixture.builder.BuildPackage());
    try fixture.temporary.dir.access(io, "src/retained", .{});
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, ".src.shelly-staging", .{}));

    fixture.builder.options.skip_source_pgp_verification = true;
    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 1), artifacts.len);
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, "src/retained", .{}));
    try fixture.temporary.dir.access(io, "pkg/demo/usr/share/demo/payload", .{});
}

test "PackageBuilder verifies signatures over compressed payload contents" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('payload.gz' 'payload.sign')
        \\noextract=('payload.gz')
        \\sha256sums=('SKIP' 'SKIP')
        \\validpgpkeys=('2E37DFCC9287C8A2F84B2519241A5B24548FAC70')
        \\package() {
        \\  install -Dm644 "$srcdir/payload.gz" "$pkgdir/usr/share/demo/payload.gz"
        \\}
    , null, null);
    defer fixture.destroy();
    const gnupg_home = try prepareSourcePgpHome(&fixture);
    defer allocator.free(gnupg_home);
    try writeBase64Fixture(
        allocator,
        io,
        fixture.temporary.dir,
        "payload.gz",
        source_pgp_payload_gzip_base64,
    );
    try writeBase64Fixture(
        allocator,
        io,
        fixture.temporary.dir,
        "payload.sign",
        source_pgp_signature_base64,
    );
    fixture.builder.options.sources_prepared = false;
    fixture.builder.options.skip_source_pgp_verification = false;
    fixture.builder.options.source_pgp_gnupg_home = gnupg_home;
    try fixture.temporary.dir.deleteTree(io, "src");

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 1), artifacts.len);
    try fixture.temporary.dir.access(io, "src/payload.gz", .{});
}

test "PackageBuilder verifies signed Git sources requested with signed" {
    const allocator = testing.allocator;
    const io = testing.io;
    var remote = std.testing.tmpDir(.{});
    defer remote.cleanup();
    try writeBase64Fixture(allocator, io, remote.dir, "signed.bundle", signed_git_bundle_base64);
    const bundle_path = try remote.dir.realPathFileAlloc(io, "signed.bundle", allocator);
    defer allocator.free(bundle_path);
    const remote_root = try remote.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(remote_root);
    const repository_path = try std.fs.path.join(allocator, &.{ remote_root, "repository" });
    defer allocator.free(repository_path);
    try runTestCommand(
        allocator,
        io,
        &.{ "/usr/bin/git", "clone", "--branch", "main", "--", bundle_path, repository_path },
        null,
    );
    const pkgbuild = try std.fmt.allocPrint(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('repo::git+file://{s}#branch=main?signed')
        \\sha256sums=('SKIP')
        \\validpgpkeys=('2E37DFCC9287C8A2F84B2519241A5B24548FAC70')
        \\package() {{
        \\  install -Dm644 "$srcdir/repo/payload" "$pkgdir/usr/share/demo/payload"
        \\}}
    , .{repository_path});
    defer allocator.free(pkgbuild);
    var fixture = try Fixture.create(allocator, pkgbuild, null, null);
    defer fixture.destroy();
    const gnupg_home = try prepareSourcePgpHome(&fixture);
    defer allocator.free(gnupg_home);
    fixture.builder.options.sources_prepared = false;
    fixture.builder.options.skip_source_pgp_verification = false;
    fixture.builder.options.source_pgp_gnupg_home = gnupg_home;
    try fixture.temporary.dir.deleteTree(io, "src");

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 1), artifacts.len);
    try fixture.temporary.dir.access(io, "src/repo/.git", .{});
    try fixture.temporary.dir.access(io, "pkg/demo/usr/share/demo/payload", .{});
}

test "PackageBuilder rejects a source checksum mismatch without committing srcdir" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('helper.sh')
        \\sha256sums=('0000000000000000000000000000000000000000000000000000000000000000')
        \\package() {
        \\  mkdir -p "$pkgdir"
        \\}
    , null, null);
    defer fixture.destroy();
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "helper.sh", .data = "reviewed\n" });
    fixture.builder.options.sources_prepared = false;
    try fixture.temporary.dir.deleteTree(io, "src");

    try testing.expectError(error.BuildFailed, fixture.builder.BuildPackage());
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, "src", .{}));
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, ".src.shelly-staging", .{}));
}

test "PackageBuilder extracts source archives into srcdir" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('payload.tar.gz')
        \\sha256sums=('SKIP')
        \\build() {
        \\  test "$(cat "$srcdir/demo/source.txt")" = extracted
        \\  test "$(cat "$srcdir/demo/bin/tool")" = linked
        \\  test "$(cat "$srcdir/demo/current")" = linked
        \\}
        \\package() {
        \\  mkdir -p "$pkgdir/usr/share/demo"
        \\  cp "$srcdir/demo/source.txt" "$pkgdir/usr/share/demo/source.txt"
        \\}
    , null, null);
    defer fixture.destroy();
    const archive_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "payload.tar.gz" });
    defer allocator.free(archive_path);
    try archive.writeFixture(allocator, archive_path, .gzip, &.{
        .{ .path = "demo/source.txt", .contents = "extracted\n" },
        .{ .path = "demo/lib/tool", .contents = "linked\n", .permissions = 0o755 },
        .{ .path = "demo/bin/tool", .link_target = "../lib/tool" },
        .{ .path = "demo/current", .link_target = "bin/tool" },
    });
    fixture.builder.options.sources_prepared = false;
    try fixture.temporary.dir.deleteTree(io, "src");

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 1), artifacts.len);
    try fixture.temporary.dir.access(io, "src/payload.tar.gz", .{});
    try fixture.temporary.dir.access(io, "src/demo/source.txt", .{});
    const nested_link = try fixture.temporary.dir.statFile(io, "src/demo/bin/tool", .{ .follow_symlinks = false });
    try testing.expectEqual(std.Io.File.Kind.sym_link, nested_link.kind);
    const chained_link = try fixture.temporary.dir.statFile(io, "src/demo/current", .{ .follow_symlinks = false });
    try testing.expectEqual(std.Io.File.Kind.sym_link, chained_link.kind);
    try fixture.temporary.dir.access(io, "pkg/demo/usr/share/demo/source.txt", .{});
}

test "PackageBuilder detects source archives by content including zip and tar zstd" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('renamed-payload.data' 'payload.tar.zst' 'ordinary.zip')
        \\sha256sums=('SKIP' 'SKIP' 'SKIP')
        \\build() {
        \\  test "$(cat "$srcdir/from-zip.txt")" = zip
        \\  test "$(cat "$srcdir/from-zstd.txt")" = zstd
        \\  test "$(cat "$srcdir/ordinary.zip")" = plain
        \\}
        \\package() {
        \\  mkdir -p "$pkgdir/usr/share/demo"
        \\  cp "$srcdir/from-zip.txt" "$srcdir/from-zstd.txt" "$pkgdir/usr/share/demo/"
        \\}
    , null, null);
    defer fixture.destroy();

    const zip_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "renamed-payload.data" });
    defer allocator.free(zip_path);
    try archive.writeZipFixture(allocator, zip_path, &.{
        .{ .path = "from-zip.txt", .contents = "zip\n" },
    });

    const tar_zstd_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "payload.tar.zst" });
    defer allocator.free(tar_zstd_path);
    try archive.writeFixture(allocator, tar_zstd_path, .zstd, &.{
        .{ .path = "from-zstd.txt", .contents = "zstd\n" },
    });
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "ordinary.zip", .data = "plain\n" });

    fixture.builder.options.sources_prepared = false;
    try fixture.temporary.dir.deleteTree(io, "src");

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 1), artifacts.len);
    try fixture.temporary.dir.access(io, "src/renamed-payload.data", .{});
    try fixture.temporary.dir.access(io, "src/payload.tar.zst", .{});
    try fixture.temporary.dir.access(io, "src/ordinary.zip", .{});
    try fixture.temporary.dir.access(io, "src/from-zip.txt", .{});
    try fixture.temporary.dir.access(io, "src/from-zstd.txt", .{});
    try fixture.temporary.dir.access(io, "pkg/demo/usr/share/demo/from-zip.txt", .{});
    try fixture.temporary.dir.access(io, "pkg/demo/usr/share/demo/from-zstd.txt", .{});
}

test "PackageBuilder extracts an extensionless source over its matching archive root" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('Fork-Awesome-1.2.0')
        \\sha256sums=('SKIP')
        \\package() {
        \\  test -d "$srcdir/Fork-Awesome-1.2.0"
        \\  install -Dm644 "$srcdir/Fork-Awesome-1.2.0/fonts/font.woff2" "$pkgdir/usr/share/demo/font.woff2"
        \\}
    , null, null);
    defer fixture.destroy();
    const archive_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "Fork-Awesome-1.2.0" });
    defer allocator.free(archive_path);
    try archive.writeFixture(allocator, archive_path, .gzip, &.{
        .{ .path = "Fork-Awesome-1.2.0", .kind = .directory, .permissions = 0o755 },
        .{ .path = "Fork-Awesome-1.2.0/fonts/font.woff2", .contents = "font\n" },
    });
    fixture.builder.options.sources_prepared = false;
    try fixture.temporary.dir.deleteTree(io, "src");

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try fixture.temporary.dir.access(io, "src/Fork-Awesome-1.2.0/fonts/font.woff2", .{});
    try fixture.temporary.dir.access(io, "pkg/demo/usr/share/demo/font.woff2", .{});
}

test "PackageBuilder rejects an archive root colliding with another staged source" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('victim.txt' 'collision')
        \\sha256sums=('SKIP' 'SKIP')
        \\package() { mkdir -p "$pkgdir"; }
    , null, null);
    defer fixture.destroy();
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "victim.txt", .data = "victim\n" });
    const archive_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "collision" });
    defer allocator.free(archive_path);
    try archive.writeFixture(allocator, archive_path, .gzip, &.{
        .{ .path = "victim.txt", .contents = "archive overwrite\n" },
    });
    fixture.builder.options.sources_prepared = false;
    try fixture.temporary.dir.deleteTree(io, "src");

    try testing.expectError(error.BuildFailed, fixture.builder.BuildPackage());
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, "src", .{}));
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, ".src.shelly-staging", .{}));
}

test "PackageBuilder preserves source archive modification timestamps" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('payload.tar.gz')
        \\sha256sums=('SKIP')
        \\build() {
        \\  test ! "$srcdir/demo/generated.c" -ot "$srcdir/demo/source.tree"
        \\}
        \\package() {
        \\  mkdir -p "$pkgdir/usr/share/demo"
        \\  cp "$srcdir/demo/generated.c" "$pkgdir/usr/share/demo/generated.c"
        \\}
    , null, null);
    defer fixture.destroy();
    const archive_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "payload.tar.gz" });
    defer allocator.free(archive_path);
    const shared_mtime: std.Io.Timestamp = .{ .nanoseconds = 1_234_567_890 * std.time.ns_per_s };
    const link_mtime: std.Io.Timestamp = .{ .nanoseconds = shared_mtime.nanoseconds + 7 * std.time.ns_per_s };
    try archive.writeFixture(allocator, archive_path, .gzip, &.{
        .{ .path = "demo", .kind = .directory, .permissions = 0o755, .mtime = shared_mtime },
        // Keep the generated target before its prerequisite to reproduce the
        // ordering that made flite1 regenerate us_pos_cart.c.
        .{ .path = "demo/generated.c", .contents = "generated\n", .mtime = shared_mtime },
        .{ .path = "demo/source.tree", .contents = "source\n", .mtime = shared_mtime },
        .{ .path = "demo/current", .link_target = "generated.c", .mtime = link_mtime },
    });
    fixture.builder.options.sources_prepared = false;
    try fixture.temporary.dir.deleteTree(io, "src");

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    const directory = try fixture.temporary.dir.statFile(io, "src/demo", .{ .follow_symlinks = false });
    const generated = try fixture.temporary.dir.statFile(io, "src/demo/generated.c", .{ .follow_symlinks = false });
    const prerequisite = try fixture.temporary.dir.statFile(io, "src/demo/source.tree", .{ .follow_symlinks = false });
    const link = try fixture.temporary.dir.statFile(io, "src/demo/current", .{ .follow_symlinks = false });
    try testing.expectEqual(shared_mtime.nanoseconds, directory.mtime.nanoseconds);
    // Updating the link itself must not follow it and change generated.c.
    try testing.expectEqual(shared_mtime.nanoseconds, generated.mtime.nanoseconds);
    try testing.expectEqual(shared_mtime.nanoseconds, prerequisite.mtime.nanoseconds);
    try testing.expectEqual(link_mtime.nanoseconds, link.mtime.nanoseconds);
}

test "PackageBuilder extracts VSIX sources into srcdir" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=codelldb-bin
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('payload.vsix')
        \\sha256sums=('SKIP')
        \\package() {
        \\  mkdir -p "$pkgdir/usr/lib/codelldb"
        \\  cp "$srcdir/extension/adapter/codelldb" "$pkgdir/usr/lib/codelldb/codelldb"
        \\}
    , null, null);
    defer fixture.destroy();
    try fixture.temporary.dir.createDirPath(io, "vsix-fixture/extension/adapter");
    try fixture.temporary.dir.writeFile(io, .{
        .sub_path = "vsix-fixture/extension/adapter/codelldb",
        .data = "debug adapter\n",
    });
    const fixture_directory = try std.fs.path.join(allocator, &.{ fixture.build_dir, "vsix-fixture" });
    defer allocator.free(fixture_directory);
    const archive_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "payload.vsix" });
    defer allocator.free(archive_path);
    try runTestCommand(
        allocator,
        io,
        &.{ "/usr/bin/bsdtar", "--format", "zip", "-cf", archive_path, "extension" },
        fixture_directory,
    );
    fixture.builder.options.sources_prepared = false;
    try fixture.temporary.dir.deleteTree(io, "src");

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 1), artifacts.len);
    try fixture.temporary.dir.access(io, "src/payload.vsix", .{});
    try fixture.temporary.dir.access(io, "src/extension/adapter/codelldb", .{});
    try fixture.temporary.dir.access(io, "pkg/codelldb-bin/usr/lib/codelldb/codelldb", .{});
}

test "PackageBuilder rebases Zoom absolute source archive link inside srcdir" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=zoom
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('zoom.pkg.tar.xz')
        \\sha256sums=('SKIP')
        \\build() {
        \\  test "$(cat "$srcdir/usr/bin/zoom")" = launcher
        \\}
        \\package() {
        \\  cp -dpr --no-preserve=ownership opt usr "$pkgdir"
        \\}
    , null, null);
    defer fixture.destroy();
    const archive_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "zoom.pkg.tar.xz" });
    defer allocator.free(archive_path);
    try archive.writeFixture(allocator, archive_path, .xz, &.{
        .{ .path = "opt/zoom/ZoomLauncher", .contents = "launcher\n", .permissions = 0o755 },
        .{ .path = "usr/bin/zoom", .link_target = "/opt/zoom/ZoomLauncher" },
    });
    fixture.builder.options.sources_prepared = false;
    try fixture.temporary.dir.deleteTree(io, "src");

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 1), artifacts.len);

    var target_buffer: [256]u8 = undefined;
    const source_target_len = try fixture.temporary.dir.readLink(io, "src/usr/bin/zoom", &target_buffer);
    try testing.expectEqualStrings("../../opt/zoom/ZoomLauncher", target_buffer[0..source_target_len]);
    const package_target_len = try fixture.temporary.dir.readLink(io, "pkg/zoom/usr/bin/zoom", &target_buffer);
    try testing.expectEqualStrings("../../opt/zoom/ZoomLauncher", target_buffer[0..package_target_len]);
}

test "PackageBuilder rejects source archive links that escape the extraction root" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('payload.tar.gz')
        \\sha256sums=('SKIP')
        \\package() {
        \\  mkdir -p "$pkgdir"
        \\}
    , null, null);
    defer fixture.destroy();
    const archive_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "payload.tar.gz" });
    defer allocator.free(archive_path);
    try archive.writeFixture(allocator, archive_path, .gzip, &.{
        .{ .path = "demo/bin/tool", .link_target = "../../../escape-marker" },
    });
    fixture.builder.options.sources_prepared = false;
    try fixture.temporary.dir.deleteTree(io, "src");

    try testing.expectError(error.BuildFailed, fixture.builder.BuildPackage());
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, "escape-marker", .{}));
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, "src", .{}));
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, ".src.shelly-staging", .{}));
}

test "PackageBuilder rejects source archive link destination collisions" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('payload.tar.gz')
        \\sha256sums=('SKIP')
        \\package() {
        \\  mkdir -p "$pkgdir"
        \\}
    , null, null);
    defer fixture.destroy();
    const archive_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "payload.tar.gz" });
    defer allocator.free(archive_path);
    try archive.writeFixture(allocator, archive_path, .gzip, &.{
        .{ .path = "demo/target", .contents = "original\n" },
        .{ .path = "demo/target", .link_target = "other" },
    });
    fixture.builder.options.sources_prepared = false;
    try fixture.temporary.dir.deleteTree(io, "src");

    try testing.expectError(error.BuildFailed, fixture.builder.BuildPackage());
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, "src", .{}));
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, ".src.shelly-staging", .{}));
}

test "PackageBuilder extracts Debian sources before package steps" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=deb-source-demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('code_1_amd64.deb')
        \\sha256sums=('SKIP')
        \\package() {
        \\  bsdtar -xf data.tar.xz -C "$pkgdir/"
        \\}
    , null, null);
    defer fixture.destroy();
    try writeDebFixture(&fixture, "code_1_amd64.deb");
    fixture.builder.options.sources_prepared = false;
    try fixture.temporary.dir.deleteTree(io, "src");

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 1), artifacts.len);
    try fixture.temporary.dir.access(io, "src/code_1_amd64.deb", .{});
    try fixture.temporary.dir.access(io, "src/debian-binary", .{});
    try fixture.temporary.dir.access(io, "src/control.tar.xz", .{});
    try fixture.temporary.dir.access(io, "src/data.tar.xz", .{});
    const payload = try fixture.temporary.dir.readFileAlloc(
        io,
        "pkg/deb-source-demo/usr/share/deb-source-demo/payload",
        allocator,
        .unlimited,
    );
    defer allocator.free(payload);
    try testing.expectEqualStrings("from deb\n", payload);
}

test "PackageBuilder honors noextract for Debian sources" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=deb-noextract-demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('opaque.deb')
        \\noextract=('opaque.deb')
        \\sha256sums=('SKIP')
        \\package() {
        \\  test ! -e "$srcdir/data.tar.xz"
        \\  install -Dm644 "$srcdir/opaque.deb" "$pkgdir/usr/share/deb-noextract-demo/opaque.deb"
        \\}
    , null, null);
    defer fixture.destroy();
    try writeDebFixture(&fixture, "opaque.deb");
    fixture.builder.options.sources_prepared = false;
    try fixture.temporary.dir.deleteTree(io, "src");

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try fixture.temporary.dir.access(io, "src/opaque.deb", .{});
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, "src/data.tar.xz", .{}));
    try fixture.temporary.dir.access(io, "pkg/deb-noextract-demo/usr/share/deb-noextract-demo/opaque.deb", .{});
}

test "PackageBuilder downloads renamed file sources before build steps" {
    const allocator = testing.allocator;
    const io = testing.io;
    var remote = std.testing.tmpDir(.{});
    defer remote.cleanup();
    try remote.dir.writeFile(io, .{ .sub_path = "source.txt", .data = "reviewed\n" });
    const remote_path = try remote.dir.realPathFileAlloc(io, "source.txt", allocator);
    defer allocator.free(remote_path);
    const pkgbuild = try std.fmt.allocPrint(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('downloaded.txt::file://{s}')
        \\sha256sums=('a9f2d25d1f71f8065e2119e538bde8846570fcdad320388236e99d9e225c290d')
        \\package() {{
        \\  mkdir -p "$pkgdir/usr/share/demo"
        \\  cp "$srcdir/downloaded.txt" "$pkgdir/usr/share/demo/downloaded.txt"
        \\}}
    , .{remote_path});
    defer allocator.free(pkgbuild);
    var fixture = try Fixture.create(allocator, pkgbuild, null, null);
    defer fixture.destroy();
    const work_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "work" });
    defer allocator.free(work_path);
    const source_cache = try std.fs.path.join(allocator, &.{ fixture.build_dir, "source-cache" });
    defer allocator.free(source_cache);
    const package_destination = try std.fs.path.join(allocator, &.{ fixture.build_dir, "packages" });
    defer allocator.free(package_destination);
    const log_destination = try std.fs.path.join(allocator, &.{ fixture.build_dir, "logs" });
    defer allocator.free(log_destination);
    fixture.builder.options.work_directory = work_path;
    fixture.builder.options.source_destination = source_cache;
    fixture.builder.options.package_destination = package_destination;
    fixture.builder.options.log_destination = log_destination;
    fixture.builder.options.sources_prepared = false;

    {
        const artifacts = try fixture.builder.BuildPackage();
        defer builder_mod.deinitArtifacts(allocator, artifacts);
        try testing.expectEqual(@as(usize, 1), artifacts.len);
        try testing.expectEqualStrings(package_destination, std.fs.path.dirname(artifacts[0].path).?);
        const build_info = try readPackageEntry(allocator, artifacts[0].path, ".BUILDINFO");
        defer allocator.free(build_info);
        const expected_builddir = try std.fmt.allocPrint(allocator, "builddir = {s}\n", .{work_path});
        defer allocator.free(expected_builddir);
        const expected_startdir = try std.fmt.allocPrint(allocator, "startdir = {s}\n", .{fixture.build_dir});
        defer allocator.free(expected_startdir);
        try testing.expect(std.mem.indexOf(u8, build_info, expected_builddir) != null);
        try testing.expect(std.mem.indexOf(u8, build_info, expected_startdir) != null);
    }
    const cached_source = try std.fs.path.join(allocator, &.{ source_cache, "downloaded.txt" });
    defer allocator.free(cached_source);
    const staged_source = try std.fs.path.join(allocator, &.{ work_path, "src/downloaded.txt" });
    defer allocator.free(staged_source);
    try std.Io.Dir.cwd().access(io, cached_source, .{});
    try std.Io.Dir.cwd().access(io, staged_source, .{});

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cached_source, .data = "corrupt\n" });
    {
        const artifacts = try fixture.builder.BuildPackage();
        defer builder_mod.deinitArtifacts(allocator, artifacts);
    }
    const repaired = try std.Io.Dir.cwd().readFileAlloc(io, cached_source, allocator, .unlimited);
    defer allocator.free(repaired);
    try testing.expectEqualStrings("reviewed\n", repaired);

    try remote.dir.deleteFile(io, "source.txt");
    {
        const artifacts = try fixture.builder.BuildPackage();
        defer builder_mod.deinitArtifacts(allocator, artifacts);
    }
}

test "PackageBuilder rejects unsupported source protocols" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('hg+https://example.invalid/demo')
        \\sha256sums=('SKIP')
        \\package() {
        \\  mkdir -p "$pkgdir"
        \\}
    , null, null);
    defer fixture.destroy();
    fixture.builder.options.sources_prepared = false;
    try fixture.temporary.dir.deleteTree(io, "src");

    try testing.expectError(error.BuildFailed, fixture.builder.BuildPackage());
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, "src", .{}));
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, ".src.shelly-staging", .{}));
}

test "PackageBuilder cancels source preparation without committing srcdir" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('helper.sh')
        \\sha256sums=('SKIP')
        \\package() {
        \\  mkdir -p "$pkgdir"
        \\}
    , null, null);
    defer fixture.destroy();
    fixture.builder.options.sources_prepared = false;
    try fixture.temporary.dir.deleteTree(io, "src");
    fixture.builder.operation_context.cancel();

    try testing.expectError(error.Cancelled, fixture.builder.BuildPackage());
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, "src", .{}));
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, ".src.shelly-staging", .{}));
}

test "PackageBuilder runs relative VCS paths from srcdir before pkgver" {
    const allocator = testing.allocator;
    const io = testing.io;
    var remote = std.testing.tmpDir(.{});
    defer remote.cleanup();
    const remote_path = try remote.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(remote_path);
    try remote.dir.writeFile(io, .{ .sub_path = "source-marker", .data = "checked out\n" });
    try runTestCommand(allocator, io, &.{ "git", "init", "-b", "development" }, remote_path);
    try runTestCommand(allocator, io, &.{ "git", "config", "user.email", "shelly-tests@example.invalid" }, remote_path);
    try runTestCommand(allocator, io, &.{ "git", "config", "user.name", "Shelly Tests" }, remote_path);
    try runTestCommand(allocator, io, &.{ "git", "add", "source-marker" }, remote_path);
    try runTestCommand(allocator, io, &.{ "git", "commit", "-m", "fixture" }, remote_path);

    const pkgbuild = try std.fmt.allocPrint(allocator,
        \\pkgname=shelly-git
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('shelly-git::git+file://{s}#branch=development')
        \\sha256sums=('SKIP')
        \\pkgver() {{
        \\  cd "$pkgname"
        \\  test -f source-marker
        \\  printf '1.r1.gfixture\n'
        \\}}
        \\package() {{
        \\  cd "$pkgname"
        \\  mkdir -p "$pkgdir/usr/share/shelly"
        \\  cp source-marker "$pkgdir/usr/share/shelly/source-marker"
        \\}}
    , .{remote_path});
    defer allocator.free(pkgbuild);
    var fixture = try Fixture.create(allocator, pkgbuild, null, null);
    defer fixture.destroy();
    const work_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "work" });
    defer allocator.free(work_path);
    const source_cache = try std.fs.path.join(allocator, &.{ fixture.build_dir, "source-cache" });
    defer allocator.free(source_cache);
    const package_destination = try std.fs.path.join(allocator, &.{ fixture.build_dir, "packages" });
    defer allocator.free(package_destination);
    const log_destination = try std.fs.path.join(allocator, &.{ fixture.build_dir, "logs" });
    defer allocator.free(log_destination);
    fixture.builder.options.work_directory = work_path;
    fixture.builder.options.source_destination = source_cache;
    fixture.builder.options.package_destination = package_destination;
    fixture.builder.options.log_destination = log_destination;
    fixture.builder.options.sources_prepared = false;

    {
        const artifacts = try fixture.builder.BuildPackage();
        defer builder_mod.deinitArtifacts(allocator, artifacts);
        try testing.expectEqual(@as(usize, 1), artifacts.len);
    }
    const cached_repository = try std.fs.path.join(allocator, &.{ source_cache, "shelly-git" });
    defer allocator.free(cached_repository);
    const staged_repository = try std.fs.path.join(allocator, &.{ work_path, "src/shelly-git/.git" });
    defer allocator.free(staged_repository);
    try std.Io.Dir.cwd().access(io, cached_repository, .{});
    try std.Io.Dir.cwd().access(io, staged_repository, .{});

    try remote.dir.writeFile(io, .{ .sub_path = "source-marker", .data = "refreshed\n" });
    try runTestCommand(allocator, io, &.{ "git", "add", "source-marker" }, remote_path);
    try runTestCommand(allocator, io, &.{ "git", "commit", "-m", "refresh" }, remote_path);
    {
        const artifacts = try fixture.builder.BuildPackage();
        defer builder_mod.deinitArtifacts(allocator, artifacts);
    }
    const refreshed_path = try std.fs.path.join(allocator, &.{ work_path, "src/shelly-git/source-marker" });
    defer allocator.free(refreshed_path);
    const refreshed = try std.Io.Dir.cwd().readFileAlloc(io, refreshed_path, allocator, .unlimited);
    defer allocator.free(refreshed);
    try testing.expectEqualStrings("refreshed\n", refreshed);
}

test "PackageBuilder verifies real checksums for pinned VCS sources" {
    const allocator = testing.allocator;
    const io = testing.io;
    var remote = std.testing.tmpDir(.{});
    defer remote.cleanup();
    const remote_path = try remote.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(remote_path);
    try remote.dir.writeFile(io, .{ .sub_path = "source-marker", .data = "checked out\n" });
    try remote.dir.writeFile(io, .{ .sub_path = ".gitattributes", .data = "source-marker export-ignore\n" });
    try runTestCommand(allocator, io, &.{ "git", "init", "-b", "main" }, remote_path);
    try runTestCommand(allocator, io, &.{ "git", "config", "user.email", "shelly-tests@example.invalid" }, remote_path);
    try runTestCommand(allocator, io, &.{ "git", "config", "user.name", "Shelly Tests" }, remote_path);
    try runTestCommand(allocator, io, &.{ "git", "add", "source-marker", ".gitattributes" }, remote_path);
    try runTestCommand(allocator, io, &.{ "git", "commit", "-m", "fixture" }, remote_path);
    try runTestCommand(allocator, io, &.{ "git", "tag", "1" }, remote_path);

    // Modern makepkg disables repository export attributes in its acquisition
    // mirror so checksum generation cannot omit or rewrite tracked content.
    try remote.dir.writeFile(io, .{
        .sub_path = ".git/info/attributes",
        .data = "* -export-subst -export-ignore\n",
    });
    var archive_result = try process_runner.run(
        allocator,
        io,
        &.{ "git", "archive", "--format=tar", "1" },
        remote_path,
        null,
    );
    try remote.dir.deleteFile(io, ".git/info/attributes");
    defer archive_result.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), archive_result.exit_code);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(archive_result.stdout, &digest, .{});
    const expected_checksum = std.fmt.bytesToHex(digest, .lower);

    // Legitimate AUR pattern (e.g. lib32-orc): a pinned VCS source with a
    // real checksum entry. makepkg hashes the deterministic archive for tags
    // and commits, rather than requiring every VCS checksum entry to be SKIP.
    const pkgbuild = try std.fmt.allocPrint(allocator,
        \\pkgname=shelly-git
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('shelly-git::git+file://{s}#tag=1')
        \\sha256sums=('{s}')
        \\package() {{
        \\  cd "$pkgname"
        \\  mkdir -p "$pkgdir/usr/share/shelly"
        \\  cp source-marker "$pkgdir/usr/share/shelly/source-marker"
        \\}}
    , .{ remote_path, expected_checksum });
    defer allocator.free(pkgbuild);
    var fixture = try Fixture.create(allocator, pkgbuild, null, null);
    defer fixture.destroy();
    const work_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "work" });
    defer allocator.free(work_path);
    const source_cache = try std.fs.path.join(allocator, &.{ fixture.build_dir, "source-cache" });
    defer allocator.free(source_cache);
    const package_destination = try std.fs.path.join(allocator, &.{ fixture.build_dir, "packages" });
    defer allocator.free(package_destination);
    const log_destination = try std.fs.path.join(allocator, &.{ fixture.build_dir, "logs" });
    defer allocator.free(log_destination);
    fixture.builder.options.work_directory = work_path;
    fixture.builder.options.source_destination = source_cache;
    fixture.builder.options.package_destination = package_destination;
    fixture.builder.options.log_destination = log_destination;
    fixture.builder.options.sources_prepared = false;

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 1), artifacts.len);

    const configured_checksum = @constCast(fixture.builder.package_builds[0].sha_256_sums.?[0]);
    const original_nibble = configured_checksum[0];
    defer configured_checksum[0] = original_nibble;
    configured_checksum[0] = if (original_nibble == '0') '1' else '0';
    try testing.expectError(error.BuildFailed, fixture.builder.BuildPackage());
}

test "PackageBuilder applies generic patch arrays and propagates dynamic pkgver" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=scx-scheds-git
        \\_gitname=scx
        \\pkgver=1.0.r1.gold
        \\pkgrel=2
        \\arch=('any')
        \\_backports=(first "second'; false; '")
        \\_backports+=(third)
        \\_reverts=()
        \\_check_dynamic_version() {
        \\  test "$pkgver" = 1.2.3.r45.gabcdef
        \\}
        \\prepare() {
        \\  cd "$_gitname"
        \\  : > applied
        \\  local commit
        \\  for commit in "${_backports[@]}"; do
        \\    printf '%s\n' "$commit" >> applied
        \\  done
        \\  for commit in "${_reverts[@]}"; do
        \\    printf 'revert:%s\n' "$commit" >> applied
        \\  done
        \\}
        \\pkgver() {
        \\  cd "$_gitname"
        \\  test -f applied
        \\  printf '1.2.3.r45.gabcdef\n'
        \\}
        \\build() {
        \\  cd "$_gitname"
        \\  _check_dynamic_version
        \\}
        \\package() {
        \\  cd "$_gitname"
        \\  pkgdesc="dynamic scx package"
        \\  depends=("runtime=$pkgver")
        \\  provides+=("scx-scheds=$pkgver")
        \\  install -Dm644 applied "$pkgdir/usr/share/scx/applied"
        \\  printf '%s\n' "$pkgver" > "$pkgdir/usr/share/scx/version"
        \\}
    , null, null);
    defer fixture.destroy();
    try fixture.temporary.dir.createDirPath(io, "src/scx");

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 1), artifacts.len);
    try testing.expect(std.mem.endsWith(
        u8,
        artifacts[0].path,
        "scx-scheds-git-1.2.3.r45.gabcdef-2-any.pkg.tar.zst",
    ));

    const applied = try fixture.temporary.dir.readFileAlloc(
        io,
        "pkg/scx-scheds-git/usr/share/scx/applied",
        allocator,
        .unlimited,
    );
    defer allocator.free(applied);
    try testing.expectEqualStrings("first\nsecond'; false; '\nthird\n", applied);

    const version = try fixture.temporary.dir.readFileAlloc(
        io,
        "pkg/scx-scheds-git/usr/share/scx/version",
        allocator,
        .unlimited,
    );
    defer allocator.free(version);
    try testing.expectEqualStrings("1.2.3.r45.gabcdef\n", version);

    const pkginfo = try fixture.temporary.dir.readFileAlloc(
        io,
        "pkg/scx-scheds-git/.PKGINFO",
        allocator,
        .unlimited,
    );
    defer allocator.free(pkginfo);
    try testing.expect(std.mem.indexOf(u8, pkginfo, "pkgver = 1.2.3.r45.gabcdef-2\n") != null);
    try testing.expect(std.mem.indexOf(u8, pkginfo, "pkgdesc = dynamic scx package\n") != null);
    try testing.expect(std.mem.indexOf(u8, pkginfo, "depend = runtime=1.2.3.r45.gabcdef\n") != null);
    try testing.expect(std.mem.indexOf(u8, pkginfo, "provides = scx-scheds=1.2.3.r45.gabcdef\n") != null);
}

test "PackageBuilder rejects invalid dynamic pkgver output" {
    const allocator = testing.allocator;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\pkgver() { printf 'invalid-version\n'; }
        \\package() { :; }
    , null, null);
    defer fixture.destroy();

    try testing.expectError(error.BuildFailed, fixture.builder.BuildPackage());
}

test "PackageBuilder tees stdout and stderr to a successful durable log" {
    const allocator = testing.allocator;
    var streams: StreamCapture = .{};
    var fixture = try Fixture.create(allocator,
        \\pkgname=log-success
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\package() {
        \\  echo 'log stdout marker'
        \\  echo 'log stderr marker' >&2
        \\}
    , .{ .function = StreamCapture.handle, .data = &streams }, null);
    defer fixture.destroy();

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    const log = try readOnlyBuildLog(allocator, testing.io, fixture.build_dir);
    defer allocator.free(log);
    try testing.expect(std.mem.indexOf(u8, log, "[phase] package") != null);
    try testing.expect(std.mem.indexOf(u8, log, "[stdout] log stdout marker") != null);
    try testing.expect(std.mem.indexOf(u8, log, "[stderr] log stderr marker") != null);
    try testing.expect(std.mem.indexOf(u8, log, "[status] success") != null);
    try testing.expect(streams.stdout_seen.load(.acquire));
    try testing.expect(streams.stderr_seen.load(.acquire));
}

test "PackageBuilder retains failed and cancelled build logs" {
    const allocator = testing.allocator;
    var failed_fixture = try Fixture.create(allocator,
        \\pkgname=log-failure
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\build() { echo 'failure marker' >&2; exit 7; }
        \\package() { :; }
    , null, null);
    defer failed_fixture.destroy();
    try testing.expectError(error.BuildFailed, failed_fixture.builder.BuildPackage());
    const failed_log = try readOnlyBuildLog(allocator, testing.io, failed_fixture.build_dir);
    defer allocator.free(failed_log);
    try testing.expect(std.mem.indexOf(u8, failed_log, "[stderr] failure marker") != null);
    try testing.expect(std.mem.indexOf(u8, failed_log, "[status] failed") != null);

    var cancelled_fixture = try Fixture.create(allocator,
        \\pkgname=log-cancelled
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\package() { :; }
    , null, null);
    defer cancelled_fixture.destroy();
    cancelled_fixture.operation_context.cancel();
    try testing.expectError(error.Cancelled, cancelled_fixture.builder.BuildPackage());
    const cancelled_log = try readOnlyBuildLog(allocator, testing.io, cancelled_fixture.build_dir);
    defer allocator.free(cancelled_log);
    try testing.expect(std.mem.indexOf(u8, cancelled_log, "[status] cancelled") != null);
}

test "PackageBuilder fails before PKGBUILD execution when log destination is unusable" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=log-unusable
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\package() { touch "$startdir/executed"; }
    , null, null);
    defer fixture.destroy();
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "not-a-directory", .data = "file" });
    const unusable = try std.fs.path.join(allocator, &.{ fixture.build_dir, "not-a-directory" });
    defer allocator.free(unusable);
    fixture.builder.options.log_destination = unusable;
    try testing.expectError(error.BuildDirectoryNotWritable, fixture.builder.BuildPackage());
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, "executed", .{}));
}

test "PackageBuilder reports failure when a step exits non-zero" {
    const allocator = testing.allocator;

    var capture: CompletionCapture = .{};
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\arch=('any')
        \\
        \\build() {
        \\  exit 3
        \\}
    , .{ .function = CompletionCapture.handle, .data = &capture }, null);
    defer fixture.destroy();

    var errors: ErrorCapture = .{};
    _ = try fixture.operation_context.subscribe(.{
        .function = ErrorCapture.handle,
        .data = &errors,
    });

    // A failing step must surface as an error result, not a silent success.
    if (fixture.builder.BuildPackage()) |artifacts| {
        builder_mod.deinitArtifacts(allocator, artifacts);
        return error.ExpectedStepFailure;
    } else |_| {}

    // The failure is reported to error listeners and to the operation.
    try testing.expectEqual(@as(usize, 1), errors.count);
    try testing.expectEqual(op_context.CompletionStatus.failed, capture.completion.?);
}

test "PackageBuilder reports failure instead of crashing without execution steps" {
    const allocator = testing.allocator;

    // A PKGBUILD that defines none of the well-known functions produces no
    // execution steps; BuildPackage must report this gracefully instead of
    // unwrapping a null optional.
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1.0
        \\arch=('any')
    , null, null);
    defer fixture.destroy();

    if (fixture.builder.BuildPackage()) |artifacts| {
        builder_mod.deinitArtifacts(allocator, artifacts);
        return error.ExpectedMissingSteps;
    } else |_| {}
}

test "PackageBuilder builds all requested split members after shared steps run once" {
    const allocator = testing.allocator;
    const io = testing.io;
    const content =
        \\pkgbase=demo
        \\pkgname=('demo' 'demo-docs')
        \\pkgver=1.0
        \\pkgrel=1
        \\arch=('any')
        \\prepare() {
        \\  echo prepare >> shared-steps
        \\}
        \\pkgver() {
        \\  printf '2.0.r3.gsplit\n'
        \\}
        \\build() {
        \\  test "$pkgver" = 2.0.r3.gsplit
        \\  echo build >> shared-steps
        \\}
        \\check() {
        \\  echo check >> shared-steps
        \\}
        \\package_demo() {
        \\  test "${#pkgname[@]}" -eq 1
        \\  test "$pkgname" = demo
        \\  mkdir -p "$pkgdir/usr/bin"
        \\  echo executable > "$pkgdir/usr/bin/demo"
        \\  chmod 755 "$pkgdir/usr/bin/demo"
        \\}
        \\package_demo-docs() {
        \\  test "${#pkgname[@]}" -eq 1
        \\  test "$pkgname" = demo-docs
        \\  mkdir -p "$pkgdir/usr/share/doc/demo"
        \\  echo documentation > "$pkgdir/usr/share/doc/demo/readme"
        \\}
    ;
    const requested = [_][]const u8{ "demo", "demo-docs" };
    var fixture = try Fixture.createMany(allocator, content, &requested, null);
    defer fixture.destroy();

    try fixture.temporary.dir.createDirPath(io, "pkg/demo");
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "pkg/demo/stale", .data = "old" });

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 2), artifacts.len);
    try testing.expectEqualStrings("demo", artifacts[0].package_name);
    try testing.expectEqualStrings("demo-docs", artifacts[1].package_name);
    try testing.expect(std.mem.endsWith(u8, artifacts[0].path, "demo-2.0.r3.gsplit-1-any.pkg.tar.zst"));
    try testing.expect(std.mem.endsWith(u8, artifacts[1].path, "demo-docs-2.0.r3.gsplit-1-any.pkg.tar.zst"));

    const shared = try fixture.temporary.dir.readFileAlloc(io, "src/shared-steps", allocator, .unlimited);
    defer allocator.free(shared);
    try testing.expectEqualStrings("prepare\nbuild\ncheck\n", shared);

    var saw_main = false;
    var saw_stale = false;
    var main_reader = try archive.Reader.init(allocator, artifacts[0].path);
    defer main_reader.deinit();
    while (try main_reader.next()) |entry| {
        if (std.mem.eql(u8, entry.path, "usr/bin/demo")) saw_main = true;
        if (std.mem.eql(u8, entry.path, "stale")) saw_stale = true;
    }
    try testing.expect(saw_main);
    try testing.expect(!saw_stale);

    var saw_docs = false;
    var docs_reader = try archive.Reader.init(allocator, artifacts[1].path);
    defer docs_reader.deinit();
    while (try docs_reader.next()) |entry| {
        if (std.mem.eql(u8, entry.path, "usr/share/doc/demo/readme")) saw_docs = true;
    }
    try testing.expect(saw_docs);
}

test "PackageBuilder keeps shared split builds under the global pkgname" {
    const allocator = testing.allocator;
    const io = testing.io;
    const content =
        \\pkgbase=shelly-git
        \\pkgname=('shelly-git' 'shelly-flatpak-backend-git')
        \\pkgver=1
        \\pkgrel=1
        \\arch=('x86_64')
        \\build() {
        \\  mkdir -p "$srcdir/$pkgname/out/bin"
        \\  printf ui > "$srcdir/$pkgname/out/bin/Shelly_Ui_Gtk"
        \\  mkdir -p "$srcdir/$pkgbase/out-flatpak-backend"
        \\  printf backend > "$srcdir/$pkgbase/out-flatpak-backend/backend"
        \\}
        \\package_shelly-git() {
        \\  install -Dm755 "$srcdir/$pkgbase/out/bin/Shelly_Ui_Gtk" "$pkgdir/usr/bin/shelly-ui"
        \\}
        \\package_shelly-flatpak-backend-git() {
        \\  install -Dm755 "$srcdir/$pkgbase/out-flatpak-backend/backend" "$pkgdir/usr/bin/backend"
        \\}
    ;
    const requested = [_][]const u8{ "shelly-flatpak-backend-git", "shelly-git" };
    var fixture = try Fixture.createMany(allocator, content, &requested, null);
    defer fixture.destroy();

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try fixture.temporary.dir.access(io, "src/shelly-git/out/bin/Shelly_Ui_Gtk", .{});
    try fixture.temporary.dir.access(io, "pkg/shelly-git/usr/bin/shelly-ui", .{});
    try fixture.temporary.dir.access(io, "pkg/shelly-flatpak-backend-git/usr/bin/backend", .{});
}

test "PackageBuilder preserves selected split metadata in PKGINFO" {
    const allocator = testing.allocator;
    const io = testing.io;
    const content =
        \\pkgbase=shelly-git
        \\pkgname=('shelly-git' 'shelly-flatpak-backend-git')
        \\pkgver=1
        \\pkgrel=2
        \\pkgdesc='Shared description'
        \\arch=('x86_64')
        \\license=('GPL-3.0-only')
        \\groups=('shared-suite')
        \\backup=('etc/shared.conf')
        \\xdata=('channel=stable')
        \\depends_x86_64=('glibc')
        \\makedepends=('zig')
        \\makedepends_x86_64=('cmake')
        \\makedepends_aarch64=('meson')
        \\checkdepends=('pytest')
        \\checkdepends_x86_64=('bats')
        \\checkdepends_aarch64=('dejagnu')
        \\pkgver() {
        \\  printf '1.1.r4.gsplit\n'
        \\}
        \\package_shelly-git() {
        \\  pkgdesc='Shelly git package'
        \\  provides=('shelly')
        \\  conflicts=('shelly' 'shelly-bin')
        \\  replaces=('old-shelly')
        \\  depends=('pacman' 'gtk4')
        \\  depends_x86_64=('libarch')
        \\  optdepends=('libstarfish: dependency viewer')
        \\  groups=('shelly-tools')
        \\  backup=('etc/shelly.conf')
        \\  mkdir -p "$pkgdir/usr/bin" "$pkgdir/etc"
        \\  printf main > "$pkgdir/usr/bin/shelly"
        \\  printf main > "$pkgdir/etc/shelly.conf"
        \\}
        \\package_shelly-flatpak-backend-git() {
        \\  pkgdesc='Shelly Flatpak backend'
        \\  depends=("shelly-git=${pkgver}-${pkgrel}" 'flatpak')
        \\  mkdir -p "$pkgdir/usr/lib" "$pkgdir/etc"
        \\  printf backend > "$pkgdir/usr/lib/backend"
        \\  printf backend > "$pkgdir/etc/shared.conf"
        \\}
    ;
    const requested = [_][]const u8{ "shelly-git", "shelly-flatpak-backend-git" };
    var fixture = try Fixture.createMany(allocator, content, &requested, null);
    defer fixture.destroy();

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    const main_info = try readPkgInfo(allocator, artifacts[0].path);
    defer allocator.free(main_info);
    try testing.expect(std.mem.indexOf(u8, main_info, "pkgdesc = Shelly git package\n") != null);
    try testing.expect(std.mem.indexOf(u8, main_info, "provides = shelly\n") != null);
    try testing.expect(std.mem.indexOf(u8, main_info, "conflict = shelly\n") != null);
    try testing.expect(std.mem.indexOf(u8, main_info, "conflict = shelly-bin\n") != null);
    try testing.expect(std.mem.indexOf(u8, main_info, "replaces = old-shelly\n") != null);
    try testing.expect(std.mem.indexOf(u8, main_info, "depend = pacman\n") != null);
    try testing.expect(std.mem.indexOf(u8, main_info, "depend = gtk4\n") != null);
    try testing.expect(std.mem.indexOf(u8, main_info, "depend = libarch\n") != null);
    try testing.expect(std.mem.indexOf(u8, main_info, "makedepend = zig\n") != null);
    try testing.expect(std.mem.indexOf(u8, main_info, "makedepend = cmake\n") != null);
    try testing.expect(std.mem.indexOf(u8, main_info, "makedepend = meson\n") == null);
    try testing.expect(std.mem.indexOf(u8, main_info, "checkdepend = pytest\n") != null);
    try testing.expect(std.mem.indexOf(u8, main_info, "checkdepend = bats\n") != null);
    try testing.expect(std.mem.indexOf(u8, main_info, "checkdepend = dejagnu\n") == null);
    try testing.expect(std.mem.indexOf(u8, main_info, "optdepend = libstarfish: dependency viewer\n") != null);
    try testing.expect(std.mem.indexOf(u8, main_info, "group = shelly-tools\n") != null);
    try testing.expect(std.mem.indexOf(u8, main_info, "backup = etc/shelly.conf\n") != null);
    try testing.expect(std.mem.indexOf(u8, main_info, "xdata = pkgtype=split\n") != null);
    try testing.expect(std.mem.indexOf(u8, main_info, "xdata = channel=stable\n") != null);

    const backend_info = try readPkgInfo(allocator, artifacts[1].path);
    defer allocator.free(backend_info);
    try testing.expect(std.mem.indexOf(u8, backend_info, "pkgdesc = Shelly Flatpak backend\n") != null);
    try testing.expect(std.mem.indexOf(u8, backend_info, "depend = shelly-git=1.1.r4.gsplit-2\n") != null);
    try testing.expect(std.mem.indexOf(u8, backend_info, "depend = flatpak\n") != null);
    try testing.expect(std.mem.indexOf(u8, backend_info, "depend = glibc\n") != null);
    try testing.expect(std.mem.indexOf(u8, backend_info, "group = shared-suite\n") != null);
    try testing.expect(std.mem.indexOf(u8, backend_info, "backup = etc/shared.conf\n") != null);
    try testing.expect(std.mem.indexOf(u8, backend_info, "xdata = pkgtype=split\n") != null);
    try testing.expect(std.mem.indexOf(u8, backend_info, "provides = shelly\n") == null);

    try fixture.temporary.dir.createDir(io, "metadata-alpm-root", .default_dir);
    try fixture.temporary.dir.createDir(io, "metadata-alpm-db", .default_dir);
    const alpm_root = try std.fs.path.joinZ(allocator, &.{ fixture.build_dir, "metadata-alpm-root" });
    defer allocator.free(alpm_root);
    const alpm_db = try std.fs.path.joinZ(allocator, &.{ fixture.build_dir, "metadata-alpm-db" });
    defer allocator.free(alpm_db);
    var alpm_error: raw_alpm.alpm_errno_t = 0;
    const handle = raw_alpm.alpm_initialize(alpm_root.ptr, alpm_db.ptr, &alpm_error) orelse
        return error.AlpmInitializeFailed;
    defer _ = raw_alpm.alpm_release(handle);
    var loaded: ?*raw_alpm.alpm_pkg_t = null;
    try testing.expectEqual(@as(c_int, 0), raw_alpm.alpm_pkg_load(handle, artifacts[0].path.ptr, 1, 0, &loaded));
    defer _ = raw_alpm.alpm_pkg_free(loaded.?);
    const candidates = raw_alpm.alpm_list_add(null, @ptrCast(loaded.?)) orelse return error.OutOfMemory;
    defer raw_alpm.alpm_list_free(candidates);
    const virtual_dependency = try allocator.dupeZ(u8, "shelly");
    defer allocator.free(virtual_dependency);
    try testing.expectEqual(loaded.?, raw_alpm.alpm_find_satisfier(candidates, virtual_dependency.ptr).?);
}

test "PackageBuilder isolates unset metadata between split members" {
    const allocator = testing.allocator;
    const content =
        \\pkgbase=metadata-unset
        \\pkgname=('metadata-one' 'metadata-two')
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\groups=('inherited-group')
        \\provides=('inherited-provider')
        \\package_metadata-one() {
        \\  unset groups provides
        \\  mkdir -p "$pkgdir/usr/share/metadata-one"
        \\}
        \\package_metadata-two() {
        \\  mkdir -p "$pkgdir/usr/share/metadata-two"
        \\}
    ;
    const requested = [_][]const u8{ "metadata-one", "metadata-two" };
    var fixture = try Fixture.createMany(allocator, content, &requested, null);
    defer fixture.destroy();

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    const one = try readPkgInfo(allocator, artifacts[0].path);
    defer allocator.free(one);
    const two = try readPkgInfo(allocator, artifacts[1].path);
    defer allocator.free(two);
    try testing.expect(std.mem.indexOf(u8, one, "group = inherited-group\n") == null);
    try testing.expect(std.mem.indexOf(u8, one, "provides = inherited-provider\n") == null);
    try testing.expect(std.mem.indexOf(u8, two, "group = inherited-group\n") != null);
    try testing.expect(std.mem.indexOf(u8, two, "provides = inherited-provider\n") != null);

    const reversed = [_][]const u8{ "metadata-two", "metadata-one" };
    var reversed_fixture = try Fixture.createMany(allocator, content, &reversed, null);
    defer reversed_fixture.destroy();
    const reversed_artifacts = try reversed_fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, reversed_artifacts);
    const reversed_two = try readPkgInfo(allocator, reversed_artifacts[0].path);
    defer allocator.free(reversed_two);
    const reversed_one = try readPkgInfo(allocator, reversed_artifacts[1].path);
    defer allocator.free(reversed_one);
    try testing.expect(std.mem.indexOf(u8, reversed_two, "group = inherited-group\n") != null);
    try testing.expect(std.mem.indexOf(u8, reversed_one, "group = inherited-group\n") == null);
}

test "PackageBuilder enforces makepkg package function contracts" {
    const allocator = testing.allocator;
    const requested = [_][]const u8{ "contract-one", "contract-two" };

    var generic_split = try Fixture.createMany(allocator,
        \\pkgname=('contract-one' 'contract-two')
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\package() { :; }
    , &requested, null);
    defer generic_split.destroy();
    try testing.expectError(error.BuildFailed, generic_split.builder.BuildPackage());

    var missing_member = try Fixture.createMany(allocator,
        \\pkgname=('contract-one' 'contract-two')
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\package_contract-one() { :; }
    , &requested, null);
    defer missing_member.destroy();
    try testing.expectError(error.BuildFailed, missing_member.builder.BuildPackage());

    var conflicting_single = try Fixture.create(allocator,
        \\pkgname=contract-one
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\package() { :; }
        \\package_contract-one() { :; }
    , null, null);
    defer conflicting_single.destroy();
    try testing.expectError(error.BuildFailed, conflicting_single.builder.BuildPackage());

    var forbidden_assignment = try Fixture.create(allocator,
        \\pkgname=contract-one
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\package() { pkgver=2; }
    , null, null);
    defer forbidden_assignment.destroy();
    try testing.expectError(error.BuildFailed, forbidden_assignment.builder.BuildPackage());

    var auxiliary_substitution = try Fixture.create(allocator,
        \\pkgname=contract-one
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\package() {
        \\  install=approved.install
        \\  install=substituted.install
        \\  mkdir -p "$pkgdir/usr/share/contract-one"
        \\}
    , null, null);
    defer auxiliary_substitution.destroy();
    try testing.expectError(
        error.ReviewedPkgbuildChanged,
        auxiliary_substitution.builder.BuildPackage(),
    );
}

test "PackageBuilder supports CachyOS generated split package functions" {
    const allocator = testing.allocator;
    const content =
        \\pkgbase=linux-cachyos
        \\pkgname=("$pkgbase" "$pkgbase-headers")
        \\pkgver=7.2.0
        \\pkgrel=1
        \\pkgdesc='CachyOS kernel'
        \\arch=('any')
        \\_package() {
        \\  pkgdesc="The $pkgdesc kernel and modules"
        \\  depends=('kmod')
        \\  mkdir -p "$pkgdir/usr/lib/modules/cachyos"
        \\}
        \\_package-headers() {
        \\  pkgdesc="Headers for the $pkgdesc kernel"
        \\  depends=("$pkgbase")
        \\  mkdir -p "$pkgdir/usr/lib/modules/cachyos/build"
        \\}
        \\for _p in "${pkgname[@]}"; do
        \\  eval "package_$_p() {
        \\    $(declare -f "_package${_p#$pkgbase}")
        \\    _package${_p#$pkgbase}
        \\  }"
        \\done
    ;
    const requested = [_][]const u8{ "linux-cachyos", "linux-cachyos-headers" };
    var fixture = try Fixture.createMany(allocator, content, &requested, null);
    defer fixture.destroy();

    for (fixture.package_builds) |package_build| {
        try testing.expect(package_build.has_selected_package_function);
        try testing.expect(package_build.has_complete_split_functions);
    }

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 2), artifacts.len);

    const kernel_info = try readPkgInfo(allocator, artifacts[0].path);
    defer allocator.free(kernel_info);
    try testing.expect(std.mem.indexOf(u8, kernel_info, "pkgdesc = The CachyOS kernel kernel and modules\n") != null);
    try testing.expect(std.mem.indexOf(u8, kernel_info, "depend = kmod\n") != null);

    const headers_info = try readPkgInfo(allocator, artifacts[1].path);
    defer allocator.free(headers_info);
    try testing.expect(std.mem.indexOf(u8, headers_info, "pkgdesc = Headers for the CachyOS kernel kernel\n") != null);
    try testing.expect(std.mem.indexOf(u8, headers_info, "depend = linux-cachyos\n") != null);
}

test "PackageBuilder rejects wrong metadata types and skips unsupported split architectures" {
    const allocator = testing.allocator;
    var wrong_type = try Fixture.create(allocator,
        \\pkgname=wrong-type
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\package() { depends=glibc; }
    , null, null);
    defer wrong_type.destroy();
    try testing.expectError(error.BuildFailed, wrong_type.builder.BuildPackage());

    const content =
        \\pkgbase=arch-split
        \\pkgname=('arch-native' 'arch-foreign')
        \\pkgver=1
        \\pkgrel=1
        \\arch=('x86_64' 'aarch64')
        \\package_arch-native() {
        \\  mkdir -p "$pkgdir/usr/share/native"
        \\}
        \\package_arch-foreign() {
        \\  arch=('aarch64')
        \\  mkdir -p "$pkgdir/usr/share/foreign"
        \\}
    ;
    const requested = [_][]const u8{ "arch-native", "arch-foreign" };
    var arch_fixture = try Fixture.createMany(allocator, content, &requested, null);
    defer arch_fixture.destroy();
    const artifacts = try arch_fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 1), artifacts.len);
    try testing.expectEqualStrings("arch-native", artifacts[0].package_name);
    const pkginfo = try readPkgInfo(allocator, artifacts[0].path);
    defer allocator.free(pkginfo);
    try testing.expect(std.mem.indexOf(u8, pkginfo, "xdata = pkgtype=split\n") != null);

    const selected = [_][]const u8{"arch-native"};
    var selected_fixture = try Fixture.createMany(allocator, content, &selected, null);
    defer selected_fixture.destroy();
    const selected_artifacts = try selected_fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, selected_artifacts);
    const selected_info = try readPkgInfo(allocator, selected_artifacts[0].path);
    defer allocator.free(selected_info);
    try testing.expect(std.mem.indexOf(u8, selected_info, "xdata = pkgtype=split\n") != null);

    var inherited_any = try Fixture.create(allocator,
        \\pkgname=arch-any
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\package() {
        \\  arch=()
        \\  mkdir -p "$pkgdir/usr/share/arch-any"
        \\}
    , null, null);
    defer inherited_any.destroy();
    const inherited_artifacts = try inherited_any.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, inherited_artifacts);
    try testing.expect(std.mem.endsWith(u8, inherited_artifacts[0].path, "arch-any-1-1-any.pkg.tar.zst"));
    const inherited_info = try readPkgInfo(allocator, inherited_artifacts[0].path);
    defer allocator.free(inherited_info);
    try testing.expect(std.mem.indexOf(u8, inherited_info, "arch = any\n") != null);
}

test "PackageBuilder honors check and overwrite policies" {
    const allocator = testing.allocator;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\check() {
        \\  exit 9
        \\}
        \\package() {
        \\  mkdir -p "$pkgdir"
        \\  echo payload > "$pkgdir/file"
        \\}
    , null, null);
    defer fixture.destroy();
    fixture.builder.options.run_check = false;

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 1), artifacts.len);
    const build_info = try readPackageEntry(allocator, artifacts[0].path, ".BUILDINFO");
    defer allocator.free(build_info);
    try testing.expect(std.mem.indexOf(u8, build_info, "buildenv = !check\n") != null);

    fixture.builder.options.overwrite = false;
    try testing.expectError(error.AlreadyBuilt, fixture.builder.BuildPackage());
    try std.Io.Dir.cwd().access(testing.io, artifacts[0].path, .{});
}

test "PackageBuilder cleans work directories only after successful configured builds" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\package() {
        \\  mkdir -p "$pkgdir"
        \\  echo payload > "$pkgdir/file"
        \\}
    , null, null);
    defer fixture.destroy();
    try fixture.temporary.dir.createDirPath(io, "src");
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "src/source", .data = "source" });
    fixture.builder.options.clean_after_success = true;

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 1), artifacts.len);
    try std.Io.Dir.cwd().access(io, artifacts[0].path, .{});
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, "src", .{}));
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, "pkg", .{}));
}

test "PackageBuilder rolls back completed split artifacts when a later member fails" {
    const allocator = testing.allocator;
    const io = testing.io;
    const content =
        \\pkgbase=demo
        \\pkgname=('demo' 'demo-docs')
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\package_demo() {
        \\  mkdir -p "$pkgdir"
        \\  echo executable > "$pkgdir/demo"
        \\}
        \\package_demo-docs() {
        \\  mkdir -p "$pkgdir"
        \\  echo documentation > "$pkgdir/docs"
        \\  exit 7
        \\}
    ;
    const requested = [_][]const u8{ "demo", "demo-docs" };
    var fixture = try Fixture.createMany(allocator, content, &requested, null);
    defer fixture.destroy();
    fixture.builder.options.clean_after_success = true;

    try testing.expectError(error.BuildFailed, fixture.builder.BuildPackage());
    try testing.expectError(
        error.FileNotFound,
        fixture.temporary.dir.access(io, "demo-1-1-any.pkg.tar.zst", .{}),
    );
    try fixture.temporary.dir.access(io, "pkg/demo/demo", .{});
    try fixture.temporary.dir.access(io, "pkg/demo-docs/docs", .{});
}
/// The repository PKGBUILD-bin, vendored verbatim: a real split package
/// whose package_shelly-bin() step installs prebuilt binaries plus
/// heredoc-generated desktop entries, a polkit policy, icons and shell
/// completions. Everything the step needs is placed in $srcdir by the
/// test, mirroring what makepkg extracts, so the build runs offline.
const shelly_bin_pkgbuild =
    \\# Maintainer: Zoey Bauer <zoey.erin.bauer@gmail.com>
    \\# Maintainer: Caroline Snyder <hirpeng@gmail.com>
    \\pkgbase=shelly-bin
    \\pkgname=('shelly-bin' 'shelly-flatpak-backend-bin')
    \\pkgver=3.0.3
    \\pkgrel=1
    \\arch=('x86_64')
    \\url="https://github.com/Seafoam-Labs/Shelly-ALPM"
    \\license=('GPL-3.0-only')
    \\source=(
    \\    "Shelly-ALPM-linux-x64-${pkgver}.tar.gz::https://github.com/Seafoam-Labs/Shelly-ALPM/releases/download/v${pkgver}/Shelly-ALPM-linux-x64.tar.gz"
    \\    "Shelly-Flatpak-Backend-linux-x64-${pkgver}.tar.gz::https://github.com/Seafoam-Labs/Shelly-ALPM/releases/download/v${pkgver}/Shelly-Flatpak-Backend-linux-x64.tar.gz"
    \\)
    \\
    \\sha256sums=('1c696140104d7f51eaa5fe6488b32f4a0d441944c1f127ad9507399b156f8ce6'
    \\            '46907ce81348430aefbb27cd865cc2470aba9087d352a5f1c3cfb9d576f34f16')
    \\
    \\package_shelly-bin() {
    \\  pkgdesc="Shelly: A Modern Arch Package Manager (prebuilt binary)"
    \\  provides=('shelly')
    \\  conflicts=('shelly' 'shelly-git')
    \\  depends=(
    \\      'pacman'
    \\      'gtk4'
    \\      'glib2'
    \\      'sudo'
    \\      'tar'
    \\      'bash'
    \\      'git'
    \\      'hicolor-icon-theme'
    \\      'dbus'
    \\      'glibc'
    \\      'libarchive'
    \\      'dconf'
    \\      'gnupg'
    \\      'zstd'
    \\      'json-glib'
    \\  )
    \\  optdepends=(
    \\      'fish: Fish shell completions'
    \\      'zsh: Zsh shell completions'
    \\      'libstarfish: dependency viewer for arch packages'
    \\      'shelly-flatpak-backend-bin: Flatpak package management support'
    \\      'fuse2: run AppImages that require FUSE 2'
    \\  )
    \\
    \\  # Install Shelly.Gtk binary
    \\  install -Dm755 "$srcdir/shelly-ui" "$pkgdir/usr/bin/shelly-ui"
    \\
    \\  # Install Shelly-Notifications binary
    \\  install -Dm755 "$srcdir/shelly-notifications" "$pkgdir/usr/bin/shelly-notifications"
    \\
    \\  # Install Shelly.Cli binary
    \\  install -Dm755 "$srcdir/shelly" "$pkgdir/usr/bin/shelly"
    \\
    \\  # Install Shelly.Key binary
    \\  install -Dm755 "$srcdir/shelly-key" "$pkgdir/usr/bin/shelly-key"
    \\
    \\  # Install desktop entry
    \\  cat <<'EOF' | install -Dm644 /dev/stdin "$pkgdir/usr/share/applications/com.shellyorg.shelly.desktop"
    \\[Desktop Entry]
    \\Name=Shelly
    \\Comment=A Modern Arch Package Manager
    \\Exec=/usr/bin/shelly-ui %u
    \\Icon=shelly
    \\Type=Application
    \\Categories=System;Utility;
    \\Keywords=program;software;store;repository;package;add;install;uninstall;remove;update;apps;applications;flatpak;pacman;aur;appimage;
    \\MimeType=x-scheme-handler/appstream;x-scheme-handler/flatpak+https;
    \\Terminal=false
    \\X-GNOME-UsesNotifications=true
    \\Actions=FlatpakInstall;FlatpakUpdate;FlatpakRemove;
    \\
    \\[Desktop Action FlatpakInstall]
    \\Name=Flatpak Install
    \\Icon=flatpak-symbolic
    \\Exec=/usr/bin/shelly-ui --page flatpak-install
    \\
    \\[Desktop Action FlatpakUpdate]
    \\Name=Flatpak Update
    \\Icon=flatpak-symbolic
    \\Exec=/usr/bin/shelly-ui --page flatpak-update
    \\
    \\[Desktop Action FlatpakRemove]
    \\Name=Flatpak Remove
    \\Icon=flatpak-symbolic
    \\Exec=/usr/bin/shelly-ui --page flatpak-remove
    \\EOF
    \\
    \\  # Install desktop entry for notification service
    \\  cat <<'EOF' | install -Dm644 /dev/stdin "$pkgdir/usr/share/applications/com.shellyorg.shelly-notifications.desktop"
    \\[Desktop Entry]
    \\Name=Shelly Notifications
    \\Comment=Notification service for Shelly package manager
    \\Exec=/usr/bin/shelly-notifications
    \\Icon=shelly-tray
    \\Type=Application
    \\Categories=System;Utility;
    \\Keywords=program;software;store;repository;package;add;install;uninstall;remove;update;apps;applications;flatpak;pacman;aur;appimage;
    \\Terminal=false
    \\NoDisplay=true
    \\EOF
    \\
    \\  # Ensure the polkit directory exists
    \\  install -m0755 -d "${pkgdir}"/usr/share/polkit-1/actions
    \\
    \\  # Install Polkit policy for privileged Shelly CLI execution via pkexec
    \\  cat <<'EOF' | install -Dm644 /dev/stdin "$pkgdir/usr/share/polkit-1/actions/com.shellyorg.shelly.policy"
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE policyconfig PUBLIC "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
    \\ "http://www.freedesktop.org/standards/PolicyKit/1.0/policyconfig.dtd">
    \\<policyconfig>
    \\  <vendor>Shelly</vendor>
    \\  <vendor_url>https://github.com/Seafoam-Labs/Shelly-ALPM</vendor_url>
    \\  <action id="com.shellyorg.shelly.pkexec.cli">
    \\    <description>Run Shelly CLI as administrator</description>
    \\    <message>Run Shelly CLI with administrator privileges.</message>
    \\    <icon_name>shelly</icon_name>
    \\    <defaults>
    \\      <allow_any>auth_admin</allow_any>
    \\      <allow_inactive>auth_admin</allow_inactive>
    \\      <allow_active>auth_admin_keep</allow_active>
    \\    </defaults>
    \\    <annotate key="org.freedesktop.policykit.exec.path">/usr/bin/shelly</annotate>
    \\  </action>
    \\</policyconfig>
    \\EOF
    \\
    \\  # Install icon
    \\  install -Dm644 "$srcdir/shellylogo.png" "$pkgdir/usr/share/icons/hicolor/256x256/apps/shelly.png"
    \\
    \\  install -Dm644 "$srcdir/shellylogo-tray.png" "$pkgdir/usr/share/icons/hicolor/256x256/apps/shelly-tray.png"
    \\  install -Dm644 "$srcdir/shellylogo-update.png" "$pkgdir/usr/share/icons/hicolor/256x256/apps/shelly-update.png"
    \\
    \\  # Install fish shell completions
    \\  install -Dm644 "$srcdir/shelly.fish" "$pkgdir/usr/share/fish/vendor_completions.d/shelly.fish"
    \\
    \\  # Install zsh shell completions
    \\  install -Dm644 "$srcdir/_shelly" "$pkgdir/usr/share/zsh/site-functions/_shelly"
    \\
    \\  # Install translations
    \\if [ -d "$srcdir/locale" ] && [ -n "$(ls -A "$srcdir/locale" 2>/dev/null)" ]; then
    \\    install -d "$pkgdir/usr/share/locale"
    \\    cp -r "$srcdir/locale/."/* "$pkgdir/usr/share/locale/" 2>/dev/null || true
    \\fi
    \\
    \\  # Install Flatpak integration script
    \\  cat <<'SCRIPT' | install -Dm755 /dev/stdin "$pkgdir/usr/bin/shelly-flatpak-integrate"
    \\#!/bin/bash
    \\# Adds "Manage in Shelly" right-click action to all Flatpak .desktop files
    \\FLATPAK_DIRS=(
    \\    "/var/lib/flatpak/exports/share/applications"
    \\    "$HOME/.local/share/flatpak/exports/share/applications"
    \\)
    \\LOCAL_APPS_DIR="$HOME/.local/share/applications"
    \\mkdir -p "$LOCAL_APPS_DIR"
    \\
    \\for dir in "${FLATPAK_DIRS[@]}"; do
    \\    [ -d "$dir" ] || continue
    \\    for desktop_file in "$dir"/*.desktop; do
    \\        [ -f "$desktop_file" ] || continue
    \\        filename=$(basename "$desktop_file")
    \\        app_id="${filename%.desktop}"
    \\        dest="$LOCAL_APPS_DIR/$filename"
    \\
    \\        # Copy if override doesn't exist yet
    \\        [ -f "$dest" ] || cp "$desktop_file" "$dest"
    \\
    \\        # Skip if already patched
    \\        grep -q "ShellyManage" "$dest" && continue
    \\
    \\        # Add action to existing Actions= line or insert one
    \\        if grep -q "^Actions=" "$dest"; then
    \\            sed -i 's/^Actions=\(.*\)/Actions=\1ShellyManage;/' "$dest"
    \\        else
    \\            sed -i '/^\[Desktop Entry\]/a Actions=ShellyManage;' "$dest"
    \\        fi
    \\
    \\        cat >> "$dest" << EOF
    \\
    \\[Desktop Action ShellyManage]
    \\Name=Manage in Shelly
    \\Icon=shelly
    \\Exec=/usr/bin/shelly-ui --page flatpak-install
    \\EOF
    \\    done
    \\done
    \\
    \\update-desktop-database "$LOCAL_APPS_DIR" 2>/dev/null || true
    \\echo "Flatpak desktop entries patched with Shelly integration."
    \\SCRIPT
    \\}
    \\
    \\package_shelly-flatpak-backend-bin() {
    \\  pkgdesc="Optional native Flatpak backend for Shelly (prebuilt binary)"
    \\  depends=("shelly-bin=${pkgver}-${pkgrel}" 'flatpak')
    \\  provides=("shelly-flatpak-backend=${pkgver}")
    \\  conflicts=('shelly-flatpak-backend' 'shelly-flatpak-backend-git')
    \\
    \\  install -Dm755 \
    \\    "$srcdir/libshelly-flatpak-backend.so.1.0.0" \
    \\    "$pkgdir/usr/lib/shelly/libshelly-flatpak-backend.so.1.0.0"
    \\  ln -s libshelly-flatpak-backend.so.1.0.0 \
    \\    "$pkgdir/usr/lib/shelly/libshelly-flatpak-backend.so.1"
    \\}
;

test "PackageBuilder builds a real package from the repository PKGBUILD-bin" {
    const allocator = testing.allocator;
    const io = testing.io;

    var capture: CompletionCapture = .{};
    var fixture = try Fixture.create(allocator, shelly_bin_pkgbuild, .{
        .function = CompletionCapture.handle,
        .data = &capture,
    }, "shelly-bin");
    defer fixture.destroy();

    const work_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "representative-work" });
    defer allocator.free(work_path);
    const source_cache = try std.fs.path.join(allocator, &.{ fixture.build_dir, "representative-sources" });
    defer allocator.free(source_cache);
    const package_destination = try std.fs.path.join(allocator, &.{ fixture.build_dir, "representative-packages" });
    defer allocator.free(package_destination);
    const log_destination = try std.fs.path.join(allocator, &.{ fixture.build_dir, "representative-logs" });
    defer allocator.free(log_destination);
    fixture.builder.options.work_directory = work_path;
    fixture.builder.options.source_destination = source_cache;
    fixture.builder.options.package_destination = package_destination;
    fixture.builder.options.log_destination = log_destination;
    try fixture.temporary.dir.createDirPath(io, "representative-work/src");

    std.debug.print("[builder-test] building vendored PKGBUILD-bin ({d} bytes) as package 'shelly-bin'\n", .{shelly_bin_pkgbuild.len});
    std.debug.print("[builder-test] build directory: {s}\n", .{fixture.build_dir});

    // Populate $srcdir the way makepkg would after extracting the release
    // tarballs referenced by the PKGBUILD's source array.
    for ([_][]const u8{ "shelly-ui", "shelly-notifications", "shelly", "shelly-key" }) |binary| {
        const sub_path = try std.fmt.allocPrint(allocator, "representative-work/src/{s}", .{binary});
        defer allocator.free(sub_path);
        try fixture.temporary.dir.writeFile(io, .{ .sub_path = sub_path, .data = "#!/bin/sh\nexit 0\n" });
    }
    for ([_][]const u8{ "representative-work/src/shellylogo.png", "representative-work/src/shellylogo-tray.png", "representative-work/src/shellylogo-update.png" }) |icon| {
        try fixture.temporary.dir.writeFile(io, .{ .sub_path = icon, .data = "placeholder icon bytes" });
    }
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "representative-work/src/shelly.fish", .data = "# fish completions\n" });
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "representative-work/src/_shelly", .data = "# zsh completions\n" });

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 1), artifacts.len);
    const artifact = artifacts[0];

    try testing.expectEqualStrings("shelly-bin", artifact.package_name);
    try testing.expect(artifact.path.len > 0);
    try testing.expect(std.mem.endsWith(u8, artifact.path, "shelly-bin-3.0.3-1-x86_64.pkg.tar.zst"));
    try testing.expectEqualStrings(package_destination, std.fs.path.dirname(artifact.path).?);
    try std.Io.Dir.cwd().access(io, artifact.path, .{});
    var pacman_result = try process_runner.run(
        allocator,
        io,
        &.{ "pacman", "-Qip", "--", artifact.path },
        null,
        null,
    );
    defer pacman_result.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), pacman_result.exit_code);
    std.debug.print("[builder-test] BuildPackage succeeded: artifact '{s}' at {s}\n", .{ artifact.package_name, artifact.path });

    // package_shelly-bin installed the full tree into $pkgdir.
    const pkgdir = try std.fs.path.join(allocator, &.{ work_path, "pkg", "shelly-bin" });
    defer allocator.free(pkgdir);
    try printPackageTree(allocator, io, pkgdir);

    // Binaries and generated scripts are installed executable.
    for ([_][]const u8{
        "usr/bin/shelly-ui",
        "usr/bin/shelly-notifications",
        "usr/bin/shelly",
        "usr/bin/shelly-key",
        "usr/bin/shelly-flatpak-integrate",
    }) |file| {
        const path = try std.fs.path.join(allocator, &.{ pkgdir, file });
        defer allocator.free(path);
        const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
        try testing.expect(stat.permissions.toMode() & 0o111 != 0);
        std.debug.print("[builder-test]   executable installed: {s}\n", .{file});
    }

    // Remaining payload files are installed as data.
    for ([_][]const u8{
        "usr/share/applications/com.shellyorg.shelly.desktop",
        "usr/share/applications/com.shellyorg.shelly-notifications.desktop",
        "usr/share/polkit-1/actions/com.shellyorg.shelly.policy",
        "usr/share/icons/hicolor/256x256/apps/shelly.png",
        "usr/share/icons/hicolor/256x256/apps/shelly-tray.png",
        "usr/share/icons/hicolor/256x256/apps/shelly-update.png",
        "usr/share/fish/vendor_completions.d/shelly.fish",
        "usr/share/zsh/site-functions/_shelly",
    }) |file| {
        const path = try std.fs.path.join(allocator, &.{ pkgdir, file });
        defer allocator.free(path);
        try std.Io.Dir.cwd().access(io, path, .{});
        std.debug.print("[builder-test]   file installed:       {s}\n", .{file});
    }

    // Quoted-heredoc bodies must reach the installed files verbatim: $HOME
    // and ${filename%.desktop} inside the flatpak integration script are
    // runtime shell, not PKGBUILD-time expansion.
    const integrate_path = try std.fs.path.join(allocator, &.{ pkgdir, "usr/bin/shelly-flatpak-integrate" });
    defer allocator.free(integrate_path);
    const integrate = try std.Io.Dir.cwd().readFileAlloc(io, integrate_path, allocator, .unlimited);
    defer allocator.free(integrate);
    try testing.expect(std.mem.indexOf(u8, integrate, "$HOME/.local/share/applications") != null);
    try testing.expect(std.mem.indexOf(u8, integrate, "${filename%.desktop}") != null);
    std.debug.print("[builder-test] quoted heredoc preserved: $HOME and ${{filename%.desktop}} intact in installed script\n", .{});

    // The desktop entry content came through the heredoc unchanged.
    const desktop_path = try std.fs.path.join(allocator, &.{ pkgdir, "usr/share/applications/com.shellyorg.shelly.desktop" });
    defer allocator.free(desktop_path);
    const desktop = try std.Io.Dir.cwd().readFileAlloc(io, desktop_path, allocator, .unlimited);
    defer allocator.free(desktop);
    try testing.expect(std.mem.indexOf(u8, desktop, "Name=Shelly\n") != null);

    // Read the assembled package back through libarchive. Metadata must be
    // present, staged modes must survive, and ownership must be normalized to
    // root independently of the user running the test.
    var package_reader = try archive.Reader.init(allocator, artifact.path);
    defer package_reader.deinit();
    var saw_pkginfo = false;
    var saw_buildinfo = false;
    var saw_mtree = false;
    var saw_executable = false;
    var saw_data_file = false;
    while (try package_reader.next()) |entry| {
        try testing.expectEqual(@as(i64, 0), entry.uid);
        try testing.expectEqual(@as(i64, 0), entry.gid);
        if (std.mem.eql(u8, entry.path, ".PKGINFO")) {
            saw_pkginfo = true;
            var contents: [16 * 1024]u8 = undefined;
            const amount = try package_reader.readPrefix(&contents);
            try testing.expect(std.mem.indexOf(u8, contents[0..amount], "pkgname = shelly-bin\n") != null);
        } else if (std.mem.eql(u8, entry.path, ".BUILDINFO")) {
            saw_buildinfo = true;
        } else if (std.mem.eql(u8, entry.path, ".MTREE")) {
            saw_mtree = true;
        } else if (std.mem.eql(u8, entry.path, "usr/bin/shelly")) {
            saw_executable = true;
            try testing.expectEqual(@as(u32, 0o755), entry.permissions);
        } else if (std.mem.eql(u8, entry.path, "usr/share/applications/com.shellyorg.shelly.desktop")) {
            saw_data_file = true;
            try testing.expectEqual(@as(u32, 0o644), entry.permissions);
        }
    }
    try testing.expect(saw_pkginfo);
    try testing.expect(saw_buildinfo);
    try testing.expect(saw_mtree);
    try testing.expect(saw_executable);
    try testing.expect(saw_data_file);

    const build_info = try readPackageEntry(allocator, artifact.path, ".BUILDINFO");
    defer allocator.free(build_info);
    const expected_builddir = try std.fmt.allocPrint(allocator, "builddir = {s}\n", .{work_path});
    defer allocator.free(expected_builddir);
    const expected_startdir = try std.fmt.allocPrint(allocator, "startdir = {s}\n", .{fixture.build_dir});
    defer allocator.free(expected_startdir);
    try testing.expect(std.mem.indexOf(u8, build_info, expected_builddir) != null);
    try testing.expect(std.mem.indexOf(u8, build_info, expected_startdir) != null);
    const build_log = try readOnlyBuildLog(allocator, io, log_destination);
    defer allocator.free(build_log);
    try testing.expect(std.mem.indexOf(u8, build_log, "[status] success") != null);
    try std.Io.Dir.cwd().access(io, source_cache, .{});

    // libalpm is the final consumer of the artifact. Loading it here catches
    // package-format or metadata defects that a libarchive readback alone
    // would accept.
    try fixture.temporary.dir.createDir(io, "alpm-root", .default_dir);
    try fixture.temporary.dir.createDir(io, "alpm-db", .default_dir);
    const alpm_root = try std.fs.path.joinZ(allocator, &.{ fixture.build_dir, "alpm-root" });
    defer allocator.free(alpm_root);
    const alpm_db = try std.fs.path.joinZ(allocator, &.{ fixture.build_dir, "alpm-db" });
    defer allocator.free(alpm_db);

    var alpm_error: raw_alpm.alpm_errno_t = 0;
    const alpm_handle = raw_alpm.alpm_initialize(alpm_root.ptr, alpm_db.ptr, &alpm_error) orelse
        return error.AlpmInitializeFailed;
    defer _ = raw_alpm.alpm_release(alpm_handle);

    var loaded_package: ?*raw_alpm.alpm_pkg_t = null;
    try testing.expectEqual(
        @as(c_int, 0),
        raw_alpm.alpm_pkg_load(alpm_handle, artifact.path.ptr, 1, 0, &loaded_package),
    );
    try testing.expect(loaded_package != null);
    defer _ = raw_alpm.alpm_pkg_free(loaded_package.?);
    try testing.expectEqualStrings("shelly-bin", std.mem.span(raw_alpm.alpm_pkg_get_name(loaded_package.?)));

    // The operation completed successfully.
    try testing.expectEqual(op_context.CompletionStatus.success, capture.completion.?);
    std.debug.print("[builder-test] operation completed: {s}\n", .{@tagName(capture.completion.?)});
}

test "sandbox policy denies paths outside the allow-list" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    if (builder_mod.sandbox.abiVersion() < 1) return error.SkipZigTest;

    const allocator = testing.allocator;
    const io = testing.io;

    var allowed_dir = std.testing.tmpDir(.{});
    defer allowed_dir.cleanup();
    try allowed_dir.dir.writeFile(io, .{ .sub_path = "allowed-file", .data = "inside\n" });
    var denied_dir = std.testing.tmpDir(.{});
    defer denied_dir.cleanup();
    try denied_dir.dir.writeFile(io, .{ .sub_path = "denied-file", .data = "outside\n" });

    const allowed_root = try allowed_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(allowed_root);
    const allowed_path = try allowed_dir.dir.realPathFileAlloc(io, "allowed-file", allocator);
    defer allocator.free(allowed_path);
    const denied_path = try denied_dir.dir.realPathFileAlloc(io, "denied-file", allocator);
    defer allocator.free(denied_path);

    // Landlock is irreversible, so the probe runs in a forked child to keep
    // the shared test process unrestricted. Exit code 0 means the policy was
    // applied, the allowed path stayed readable, and the denied path was
    // rejected.
    const fork_rc = std.os.linux.fork();
    try testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(@intCast(fork_rc)));
    if (fork_rc == 0) {
        std.process.exit(probeSandboxPolicy(allocator, allowed_root, allowed_path, denied_path));
    }
    var status: u32 = 0;
    _ = std.os.linux.waitpid(@intCast(fork_rc), &status, 0);
    try testing.expectEqual(@as(u32, 0), status & 0x7f);
    const exit_code = (status >> 8) & 0xff;
    try testing.expectEqual(@as(u32, 0), exit_code);
}

fn probeSandboxPolicy(
    allocator: std.mem.Allocator,
    allowed_root: []const u8,
    allowed_path: []const u8,
    denied_path: []const u8,
) u8 {
    builder_mod.setNoNewPrivs() catch return 10;
    builder_mod.sandbox.applyPolicy(allocator, .{
        .read_write_paths = &.{ allowed_root, "/tmp" },
        .read_only_paths = &.{},
    }) catch return 11;
    if (!probePathReadable(allocator, allowed_path)) return 12;
    if (probePathReadable(allocator, denied_path)) return 13;
    return 0;
}

fn probePathReadable(allocator: std.mem.Allocator, path: []const u8) bool {
    const path_z = allocator.dupeZ(u8, path) catch return false;
    const rc = std.os.linux.open(path_z.ptr, .{}, 0);
    if (std.os.linux.errno(@intCast(rc)) != .SUCCESS) return false;
    _ = std.os.linux.close(@intCast(rc));
    return true;
}

test "PackageBuilder wraps lifecycle steps through the sandbox wrapper when enabled" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    if (builder_mod.sandbox.abiVersion() < 1) return error.SkipZigTest;

    const allocator = testing.allocator;
    const io = testing.io;

    var fixture = try Fixture.create(allocator,
        \\pkgname=sandbox-demo
        \\pkgver=1.0
        \\arch=('any')
        \\
        \\build() {
        \\  echo built > build-marker
        \\}
        \\package() {
        \\  mkdir -p "$pkgdir"
        \\  echo packaged > "$pkgdir/package-marker"
        \\  chmod 4755 "$pkgdir/package-marker"
        \\  chown 42:84 "$pkgdir/package-marker"
        \\}
    , null, null);
    defer fixture.destroy();

    // Passthrough stub standing in for the real `__sandbox-exec` entry
    // point: it records that it ran, then execs the child argv after `--`.
    try fixture.temporary.dir.writeFile(io, .{
        .sub_path = "wrapper-stub.sh",
        .data =
        \\#!/bin/sh
        \\dir=$(dirname "$0")
        \\echo ran > "$dir/wrapper-marker"
        \\while [ "$1" != "--" ]; do shift; done
        \\shift
        \\exec "$@"
        ,
    });
    try fixture.temporary.dir.setFilePermissions(io, "wrapper-stub.sh", .fromMode(0o755), .{});
    const stub_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "wrapper-stub.sh" });
    defer allocator.free(stub_path);
    var wrapper_prefix = [_][]const u8{stub_path};

    fixture.builder.shellybuild_config.sandbox.enabled = true;
    fixture.builder.options.sandbox_wrapper_prefix = &wrapper_prefix;

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 1), artifacts.len);

    // The wrapper handled every lifecycle step before bash ran.
    try fixture.temporary.dir.access(io, "wrapper-marker", .{});
    try fixture.temporary.dir.access(io, "src/build-marker", .{});
    try fixture.temporary.dir.access(io, "pkg/sandbox-demo/package-marker", .{});

    const staged_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "pkg/sandbox-demo/package-marker" });
    defer allocator.free(staged_path);
    var stat_result = try process_runner.run(allocator, io, &.{ "stat", "-c", "%u:%g", staged_path }, null, null);
    defer stat_result.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), stat_result.exit_code);
    var expected_owner_buffer: [64]u8 = undefined;
    const expected_owner = try std.fmt.bufPrint(
        &expected_owner_buffer,
        "{d}:{d}",
        .{ std.os.linux.geteuid(), std.os.linux.getegid() },
    );
    try testing.expectEqualStrings(expected_owner, std.mem.trim(u8, stat_result.stdout, " \t\r\n"));

    var reader = try archive.Reader.init(allocator, artifacts[0].path);
    defer reader.deinit();
    var saw_marker = false;
    while (try reader.next()) |entry| {
        if (!std.mem.eql(u8, entry.path, "package-marker")) continue;
        saw_marker = true;
        try testing.expectEqual(@as(i64, 42), entry.uid);
        try testing.expectEqual(@as(i64, 84), entry.gid);
        try testing.expectEqual(@as(u32, 0o4755), entry.permissions);
    }
    try testing.expect(saw_marker);
}

test "PackageBuilder records a sandbox hint when a confined step fails" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    if (builder_mod.sandbox.abiVersion() < 1) return error.SkipZigTest;

    const allocator = testing.allocator;
    const io = testing.io;

    var fixture = try Fixture.create(allocator,
        \\pkgname=sandbox-failure-demo
        \\pkgver=1.0
        \\arch=('any')
        \\
        \\build() {
        \\  exit 1
        \\}
        \\package() {
        \\  mkdir -p "$pkgdir"
        \\}
    , null, null);
    defer fixture.destroy();

    try fixture.temporary.dir.writeFile(io, .{
        .sub_path = "wrapper-stub.sh",
        .data =
        \\#!/bin/sh
        \\while [ "$1" != "--" ]; do shift; done
        \\shift
        \\exec "$@"
        ,
    });
    try fixture.temporary.dir.setFilePermissions(io, "wrapper-stub.sh", .fromMode(0o755), .{});
    const stub_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "wrapper-stub.sh" });
    defer allocator.free(stub_path);
    var wrapper_prefix = [_][]const u8{stub_path};

    fixture.builder.shellybuild_config.sandbox.enabled = true;
    fixture.builder.options.sandbox_wrapper_prefix = &wrapper_prefix;

    try testing.expectError(error.BuildFailed, fixture.builder.BuildPackage());

    const build_log = try readOnlyBuildLog(allocator, io, fixture.build_dir);
    defer allocator.free(build_log);
    try testing.expect(std.mem.indexOf(u8, build_log, "[sandbox] step failed inside the Landlock sandbox") != null);
}
